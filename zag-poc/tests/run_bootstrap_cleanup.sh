#!/usr/bin/env bash
# Prove an interrupted or timed-out guarded bootstrap leaves no compiler,
# transient service, or stage tree behind. The seed is deliberately a sleeping
# executable so the test exercises process ownership without compiling Zag.
set -euo pipefail

cd "$(dirname "$0")/.."

command -v timeout >/dev/null 2>&1 || {
    echo 'bootstrap cleanup: SKIP — timeout(1) unavailable'
    exit 77
}
cleanup_systemd_available=1
if ! command -v systemd-run >/dev/null 2>&1 ||
   ! timeout --foreground --kill-after=2s 10 systemctl --user is-system-running >/dev/null 2>&1; then
    cleanup_systemd_available=0
    echo 'bootstrap cleanup: guarded cleanup cases SKIP — user systemd manager unavailable'
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-bootstrap-cleanup.XXXXXX")
fixture_repo="$work/repo"
mkdir -p "$fixture_repo/selfhost/native" "$fixture_repo/std"
cp bootstrap.sh "$fixture_repo/bootstrap.sh"
chmod +x "$fixture_repo/bootstrap.sh"
: >"$fixture_repo/zag.mod"
recorded_pids=()
recorded_starts=()
recorded_units=()
cleanup_systemctl() {
    timeout --foreground --kill-after=2s 10 systemctl --user "$@"
}
cleanup_systemd_unit_owned() {
    local unit=$1 nonce description serial stem
    case "$unit" in
        zag-bootstrap-[[:alnum:]]+-[0-9]*.service)
            stem=${unit%.service}
            nonce=${stem#zag-bootstrap-}
            serial=${nonce##*-}
            nonce=${nonce%-${serial}}
            case "$nonce" in ''|*[![:alnum:]-]*) return 1 ;; esac
            case "$serial" in ''|*[!0-9]*) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    description=$(cleanup_systemctl show --value --property=Description \
        "$unit" 2>/dev/null || true)
    [ "$description" = "zag-bootstrap-owner:$nonce" ]
}
cleanup() {
    local unit pid recorded_start current_start index
    trap ':' HUP INT TERM
    for unit in "${recorded_units[@]}"; do
        [ -n "$unit" ] || continue
        if ! cleanup_systemd_unit_owned "$unit"; then
            echo "bootstrap cleanup: refusing destructive test cleanup for unauthenticated unit $unit" >&2
            continue
        fi
        cleanup_systemctl kill --kill-who=all --signal=KILL \
            "$unit" >/dev/null 2>&1 || true
        cleanup_systemctl stop "$unit" >/dev/null 2>&1 || true
    done
    for index in "${!recorded_pids[@]}"; do
        pid=${recorded_pids[$index]}
        recorded_start=${recorded_starts[$index]}
        [ -n "$pid" ] || continue
        if [ -r "/proc/$pid/stat" ]; then
            current_start=$(/usr/bin/awk '{ print $22; exit }' "/proc/$pid/stat" 2>/dev/null || true)
            if [ "$current_start" = "$recorded_start" ]; then
                kill -KILL "$pid" 2>/dev/null || true
            fi
        fi
    done
    rm -rf "$work"
}
test_signal() {
    trap ':' HUP INT TERM
    cleanup
    trap - EXIT HUP INT TERM
    exit 130
}
trap cleanup EXIT
trap test_signal HUP INT TERM

fake_seed="$work/fake-znc"
cat >"$fake_seed" <<'SEED'
#!/usr/bin/env bash
set -eu
output=""
while [ "$#" -gt 0 ]; do
    if [ "$1" = -o ] && [ "$#" -ge 2 ]; then
        output=$2
        break
    fi
    shift
done
[ -n "$output" ]
if [ "${ZAG_BOOTSTRAP_FAKE_EXIT:-}" = 143 ]; then
    # Leave a stable process long enough for bootstrap to authenticate the
    # wrapper; the test must not depend on an unbounded post-exit wait.
    /bin/sleep 0.1
    exit 143
fi
stage_dir=${output%/*}
tmp_dir=${stage_dir%/*}
case_dir=${tmp_dir%/*}
if [ -n "${ZAG_BOOTSTRAP_FAKE_FAST_EXIT:-}" ]; then
    fast_status=$ZAG_BOOTSTRAP_FAKE_FAST_EXIT
    printf '%s\n' "$fast_status" >"$case_dir/fast.status"
    # Exercise a genuinely short stage while retaining a bounded identity
    # capture window on slow or heavily loaded hosts.
    /bin/sleep 0.1
    if [ "$fast_status" -eq 0 ]; then
        if [ "${ZAG_BOOTSTRAP_FAKE_NO_ARTIFACT:-}" = 1 ]; then
            # Remain live long enough for the wrapper identity to be captured,
            # then prove that exit zero without an output is rejected at the
            # exact bootstrap stage.
            /bin/sleep 0.1
            exit 0
        fi
        # Keep later self-hosting stages hermetic while allowing this test to
        # exercise a truly fast successful direct child.
        {
            printf '%s\n' '#!/usr/bin/env bash'
            printf '%s\n' 'set -eu'
            printf '%s\n' 'out=""'
            printf '%s\n' 'while [ "$#" -gt 0 ]; do'
            printf '%s\n' '    if [ "$1" = -o ] && [ "$#" -ge 2 ]; then out=$2; break; fi'
            printf '%s\n' '    shift'
            printf '%s\n' 'done'
            printf '%s\n' '[ -n "$out" ]'
            printf '%s\n' '/bin/sleep 0.1'
            printf '%s\n' 'cp "$0" "$out"'
            printf '%s\n' 'chmod +x "$out"'
        } >"$output"
        chmod +x "$output"
    fi
    exit "$fast_status"
fi
pid_file="$case_dir/compiler.pid"
start_file="$case_dir/compiler.start"
unit_file="$case_dir/compiler.unit"
sleep_pid_file="$case_dir/sleep.pid"
sleep_start_file="$case_dir/sleep.start"
group_file="$case_dir/compiler.group"
printf '%s\n' "$$" >"$pid_file"
/usr/bin/awk '{ print $22; exit }' "/proc/$$/stat" >"$start_file"
/usr/bin/awk '{ print $5 " " $6; exit }' "/proc/$$/stat" >"$group_file"
/bin/sleep 60 &
sleep_pid=$!
printf '%s\n' "$sleep_pid" >"$sleep_pid_file"
/usr/bin/awk '{ print $22; exit }' "/proc/$sleep_pid/stat" >"$sleep_start_file"
while IFS=: read -r hierarchy controllers cgroup_path; do
    if [ "$hierarchy" = 0 ]; then
        printf '%s\n' "${cgroup_path##*/}" >"$unit_file"
    fi
done </proc/self/cgroup
trap 'exit 0' HUP INT TERM
if [ "${ZAG_BOOTSTRAP_FAKE_PROGRESS:-}" = 1 ]; then
    trap 'exit 143' HUP INT TERM
    while :; do :; done
fi
# Poll instead of using an unbounded shell wait.  The bootstrap cleanup path
# kills the recorded sleep child; this loop then exits without leaving a test
# process behind if a wait implementation regresses.
while [ -r "/proc/$sleep_pid/stat" ]; do
    sleep_state=$(/usr/bin/awk '{ print $3; exit }' "/proc/$sleep_pid/stat" 2>/dev/null || true)
    if [ "$sleep_state" = Z ] || [ -z "$sleep_state" ]; then
        break
    fi
    sleep 0.05
done
SEED
chmod +x "$fake_seed"

wait_for_file() {
    local file=$1 attempt
    for attempt in $(seq 1 100); do
        [ -s "$file" ] && return 0
        sleep 0.05
    done
    return 1
}

test_pid_running() {
    local pid=$1 state
    [ -r "/proc/$pid/stat" ] || return 1
    state=$(/usr/bin/awk '{ print $3; exit }' "/proc/$pid/stat" 2>/dev/null || true)
    [ -n "$state" ] && [ "$state" != Z ]
}

wait_bounded() {
    local pid=$1 seconds=$2 attempt limit
    case "$seconds" in ''|*[!0-9]*) return 2 ;; esac
    limit=$((seconds * 20))
    for attempt in $(seq 1 "$limit"); do
        if ! test_pid_running "$pid"; then
            wait "$pid" 2>/dev/null
            return $?
        fi
        sleep 0.05
    done
    return 124
}

terminate_test_pid() {
    local pid=$1 status
    kill -TERM "$pid" 2>/dev/null || true
    set +e
    wait_bounded "$pid" 2
    status=$?
    set -e
    [ "$status" -eq 124 ] || return 0
    kill -KILL "$pid" 2>/dev/null || true
    set +e
    wait_bounded "$pid" 2
    status=$?
    set -e
    return "$status"
}

run_bootstrap() {
    local case_dir=$1
    shift
    (cd "$fixture_repo" && env TMPDIR="$case_dir/tmp" \
        ZAG_BOOTSTRAP_SEED="$fake_seed" "$@" bash bootstrap.sh)
}

assert_case_clean() {
    local case_dir=$1 expected_status=$2 actual_status=$3 expected_unit=$4
    local pid unit recorded_start sleep_pid sleep_start leftover
    wait_for_file "$case_dir/compiler.pid"
    wait_for_file "$case_dir/compiler.start"
    wait_for_file "$case_dir/sleep.pid"
    wait_for_file "$case_dir/sleep.start"
    pid=$(sed -n '1p' "$case_dir/compiler.pid")
    recorded_start=$(sed -n '1p' "$case_dir/compiler.start")
    sleep_pid=$(sed -n '1p' "$case_dir/sleep.pid")
    sleep_start=$(sed -n '1p' "$case_dir/sleep.start")
    recorded_pids+=("$pid")
    recorded_starts+=("$recorded_start")
    recorded_pids+=("$sleep_pid")
    recorded_starts+=("$sleep_start")
    if [ "$expected_unit" = guarded ]; then
        wait_for_file "$case_dir/compiler.unit"
        unit=$(sed -n '1p' "$case_dir/compiler.unit")
        [[ "$unit" =~ ^zag-bootstrap-[[:alnum:]]+-[0-9]+\.service$ ]] || {
            echo "bootstrap cleanup: unsafe/unexpected transient unit $unit" >&2
            return 1
        }
        recorded_units+=("$unit")
    else
        unit=none
    fi
    [ "$actual_status" -eq "$expected_status" ] || {
        echo "bootstrap cleanup: unexpected status $actual_status (wanted $expected_status)" >&2
        sed -n '1,80p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    assert_pid_dead() {
        local label=$1 check_pid=$2 check_start=$3 attempt current_start state
        for attempt in $(seq 1 100); do
            [ -r "/proc/$check_pid/stat" ] || return 0
            current_start=$(/usr/bin/awk '{ print $22; exit }' \
                "/proc/$check_pid/stat" 2>/dev/null || true)
            [ -n "$current_start" ] || return 0
            [ "$current_start" = "$check_start" ] || return 0
            state=$(/usr/bin/awk '{ print $3; exit }' \
                "/proc/$check_pid/stat" 2>/dev/null || true)
            [ "$state" = Z ] && return 0
            sleep 0.05
        done
        if [ -r "/proc/$check_pid/stat" ] &&
           [ "$(/usr/bin/awk '{ print $22; exit }' "/proc/$check_pid/stat" 2>/dev/null || true)" = "$check_start" ]; then
            echo "bootstrap cleanup: $label pid $check_pid survived" >&2
            sed -n '1,120p' "$case_dir/bootstrap.log" >&2 || true
            return 1
        fi
    }
    assert_pid_dead compiler "$pid" "$recorded_start"
    assert_pid_dead sleep "$sleep_pid" "$sleep_start"
    if [ "$expected_unit" = guarded ] &&
       cleanup_systemctl is-active --quiet "$unit"; then
        echo "bootstrap cleanup: transient unit $unit survived" >&2
        return 1
    fi
    leftover=$(find "$case_dir/tmp" -mindepth 1 -maxdepth 1 \
        -name 'zag-bootstrap.*' -print -quit)
    if [ -n "$leftover" ]; then
        echo "bootstrap cleanup: stage tree survived: $leftover" >&2
        return 1
    fi
}

run_timeout_case() {
    local case_dir="$work/timeout" bootstrap_pid status
    mkdir -p "$case_dir/tmp"
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_MAX_BYTES=1073741824 \
        ZAG_BOOTSTRAP_SWAP_MAX_BYTES=0 \
        ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=1 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 \
        >"$case_dir/bootstrap.log" 2>&1 &
    bootstrap_pid=$!
    set +e
    wait_bounded "$bootstrap_pid" 15
    status=$?
    set -e
    if test_pid_running "$bootstrap_pid"; then
        terminate_test_pid "$bootstrap_pid" || true
    fi
    # timeout(1) reports 124; bootstrap propagates that bounded stage failure.
    assert_case_clean "$case_dir" 124 "$status" guarded
}

run_interrupt_case() {
    local case_dir="$work/interrupt" bootstrap_pid status
    mkdir -p "$case_dir/tmp"
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_MAX_BYTES=1073741824 \
        ZAG_BOOTSTRAP_SWAP_MAX_BYTES=0 \
        ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=60 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 \
        >"$case_dir/bootstrap.log" 2>&1 &
    bootstrap_pid=$!
    wait_for_file "$case_dir/compiler.pid"
    wait_for_file "$case_dir/compiler.unit"
    set +e
    kill -TERM "$bootstrap_pid"
    wait_bounded "$bootstrap_pid" 15
    status=$?
    set -e
    if test_pid_running "$bootstrap_pid"; then
        terminate_test_pid "$bootstrap_pid" || true
    fi
    assert_case_clean "$case_dir" 130 "$status" guarded
}

run_progress_case() {
    local case_dir="$work/progress" status bootstrap_pid
    mkdir -p "$case_dir/tmp"
    set +e
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=2 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 ZAG_BOOTSTRAP_FAKE_PROGRESS=1 \
        >"$case_dir/bootstrap.log" 2>&1 &
    bootstrap_pid=$!
    wait_bounded "$bootstrap_pid" 15
    status=$?
    set -e
    if test_pid_running "$bootstrap_pid"; then
        terminate_test_pid "$bootstrap_pid" || true
    fi
    [ "$status" -eq 124 ] || {
        echo "bootstrap cleanup: progress case status $status (wanted 124)" >&2
        sed -n '1,80p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    grep -Fq 'compiler progress:' "$case_dir/bootstrap.log"
    grep -Fq 'wrapper_pid=' "$case_dir/bootstrap.log"
    grep -Fq 'compiler_rss=' "$case_dir/bootstrap.log"
    assert_case_clean "$case_dir" 124 "$status" none
}

run_diagnostic_case() {
    local case_dir="$work/diagnostic" status
    mkdir -p "$case_dir/tmp"
    set +e
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=60 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 ZAG_BOOTSTRAP_FAKE_EXIT=143 \
        >"$case_dir/bootstrap.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 143 ] || {
        echo "bootstrap cleanup: diagnostic case status $status (wanted 143)" >&2
        sed -n '1,80p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    grep -Fq "status 143 is a SIGTERM-style status" "$case_dir/bootstrap.log"
    grep -Fq "host memory snapshot: MemAvailable=" "$case_dir/bootstrap.log"
    grep -Fq "cgroup memory.events" "$case_dir/bootstrap.log"
}

run_identity_failure_case() {
    local case_dir="$work/identity-failure" status
    mkdir -p "$case_dir/tmp"
    set +e
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=60 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 ZAG_BOOTSTRAP_FAKE_PROGRESS=1 \
        ZAG_BOOTSTRAP_FORCE_IDENTITY_CAPTURE_FAILURE=1 \
        >"$case_dir/bootstrap.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 1 ] || {
        echo "bootstrap cleanup: identity-failure case status $status (wanted 1)" >&2
        sed -n '1,80p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    grep -Fq 'failed to capture stage wrapper identity' "$case_dir/bootstrap.log"
    # The forced-capture path must use the bounded ownership/cleanup path; a
    # missing identity must never turn teardown into an unbounded wait.
    if grep -Fq 'unbounded wait' "$case_dir/bootstrap.log"; then
        echo "bootstrap cleanup: identity-failure path attempted an unbounded wait" >&2
        sed -n '1,120p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    fi
    assert_case_clean "$case_dir" 1 "$status" none
}

run_missing_artifact_case() {
    local case_dir="$work/missing-artifact" status leftover
    mkdir -p "$case_dir/tmp"
    set +e
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=60 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 ZAG_BOOTSTRAP_FAKE_FAST_EXIT=0 \
        ZAG_BOOTSTRAP_FAKE_NO_ARTIFACT=1 \
        >"$case_dir/bootstrap.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 1 ] || {
        echo "bootstrap cleanup: missing-artifact case status $status (wanted 1)" >&2
        sed -n '1,100p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    grep -Fq 'reported success without a nonempty executable artifact' \
        "$case_dir/bootstrap.log"
    leftover=$(find "$case_dir/tmp" -mindepth 1 -maxdepth 1 \
        -name 'zag-bootstrap.*' -print -quit)
    if [ -n "$leftover" ]; then
        echo "bootstrap cleanup: missing-artifact stage tree survived: $leftover" >&2
        return 1
    fi
}

run_fast_exit_case() {
    local case_dir="$work/fast-success" status marker leftover
    mkdir -p "$case_dir/tmp"
    set +e
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=5 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 ZAG_BOOTSTRAP_FAKE_FAST_EXIT=0 \
        >"$case_dir/bootstrap.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 0 ] || {
        echo "bootstrap cleanup: fast-success case status $status (wanted 0)" >&2
        sed -n '1,120p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    marker=$(sed -n '1p' "$case_dir/fast.status")
    [ "$marker" = 0 ] || return 1
    if grep -Fq 'unbounded wait' "$case_dir/bootstrap.log"; then
        echo 'bootstrap cleanup: fast-success case attempted an unbounded wait' >&2
        return 1
    fi
    leftover=$(find "$case_dir/tmp" -mindepth 1 -maxdepth 1 \
        -name 'zag-bootstrap.*' -print -quit)
    [ -z "$leftover" ] || {
        echo "bootstrap cleanup: fast-success stage tree survived: $leftover" >&2
        return 1
    }
}

run_fast_nonzero_case() {
    local case_dir="$work/fast-nonzero" status marker leftover
    mkdir -p "$case_dir/tmp"
    set +e
    run_bootstrap "$case_dir" \
        ZAG_BOOTSTRAP_MEMORY_GUARD=off ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS=5 \
        ZAG_BOOTSTRAP_HEARTBEAT_SECONDS=1 ZAG_BOOTSTRAP_FAKE_FAST_EXIT=7 \
        >"$case_dir/bootstrap.log" 2>&1
    status=$?
    set -e
    [ "$status" -eq 7 ] || {
        echo "bootstrap cleanup: fast-nonzero case status $status (wanted 7)" >&2
        sed -n '1,120p' "$case_dir/bootstrap.log" >&2 || true
        return 1
    }
    marker=$(sed -n '1p' "$case_dir/fast.status")
    [ "$marker" = 7 ] || return 1
    if grep -Fq 'unbounded wait' "$case_dir/bootstrap.log"; then
        echo 'bootstrap cleanup: fast-nonzero case attempted an unbounded wait' >&2
        return 1
    fi
    leftover=$(find "$case_dir/tmp" -mindepth 1 -maxdepth 1 \
        -name 'zag-bootstrap.*' -print -quit)
    [ -z "$leftover" ] || {
        echo "bootstrap cleanup: fast-nonzero stage tree survived: $leftover" >&2
        return 1
    }
}

if [ "$cleanup_systemd_available" -eq 1 ]; then
    run_timeout_case
    run_interrupt_case
fi
run_progress_case
run_diagnostic_case
run_identity_failure_case
run_missing_artifact_case
run_fast_exit_case
run_fast_nonzero_case
if [ "$cleanup_systemd_available" -eq 1 ]; then
    echo 'bootstrap cleanup: PASS — guarded timeout/TERM, unguarded descendants, diagnostics, and cleanup are covered'
else
    echo 'bootstrap cleanup: PARTIAL — guarded systemd cases skipped because no usable user manager was available; unguarded descendants, diagnostics, and cleanup are covered'
fi
