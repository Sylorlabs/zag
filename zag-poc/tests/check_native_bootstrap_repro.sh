#!/usr/bin/env bash
# Prove the native Zag compiler reaches a byte-identical self-hosting fixpoint.
#
# The compiler invocations run with an empty PATH, so no C compiler, assembler,
# linker, shell, or other host executable can be resolved by command lookup.
# The shell is used only to orchestrate and compare completed results.
set -eu
set -o pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$root/selfhost/native/znc.zag"

selfhost_heartbeat=${ZAG_SELFHOST_HEARTBEAT_SECONDS:-30}
case "$selfhost_heartbeat" in
    ''|*[!0-9]*|0) echo "native bootstrap: invalid heartbeat interval: $selfhost_heartbeat" >&2; exit 1;;
esac
selfhost_stage_timeout=${ZAG_SELFHOST_STAGE_TIMEOUT_SECONDS:-3600}
case "$selfhost_stage_timeout" in
    ''|*[!0-9]*|0) echo "native bootstrap: invalid stage timeout: $selfhost_stage_timeout" >&2; exit 1;;
esac
timeout_bin=$(command -v timeout || true)
if [ -z "$timeout_bin" ]; then
    echo "native bootstrap: timeout(1) is required for bounded compiler stages" >&2
    exit 1
fi

case ${ZNC_SEED:-} in
    '') seed="$root/znc" ;;
    /*) seed=$ZNC_SEED ;;
    *) seed="$PWD/$ZNC_SEED" ;;
esac

cd "$root"

if [ ! -x "$seed" ]; then
    echo "native bootstrap: seed is not executable: $seed" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-bootstrap.XXXXXX")
stage_pid=""
cleanup() {
    if [ -n "$stage_pid" ]; then
        kill "$stage_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
signal_cleanup() {
    cleanup
    exit 130
}
trap cleanup EXIT
trap signal_cleanup HUP INT TERM
mkdir "$tmp/empty-path"

# A multi-generation comparison is meaningful only for one immutable source
# snapshot. The shared development checkout may be active while this expensive
# gate runs, so bind the proof to every Zag source path and byte under the
# compiler/runtime roots. A change fails explicitly instead of being reported
# as compiler nondeterminism.
source_fingerprint() {
    {
        find selfhost std -type f -name '*.zag' -print0
        printf '%s\0' zag.mod
    } | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{ print $1 }'
}
source_snapshot=$(source_fingerprint)
echo "  source snapshot sha256=$source_snapshot"

assert_source_stable() {
    label=$1
    current=$(source_fingerprint)
    if [ "$current" != "$source_snapshot" ]; then
        echo "  XX  source tree changed during $label; reproducibility proof is invalid" >&2
        echo "      before=$source_snapshot" >&2
        echo "      after =$current" >&2
        exit 1
    fi
}

# Keep the independent fixpoint proof safe on an interactive Linux host too.
# This duplicates bootstrap.sh's optional OS envelope deliberately: the test
# runs with an empty compiler PATH and must not depend on the bootstrap script
# to perform any of its three generations.
guard_limit=${ZAG_SELFHOST_MEMORY_MAX_BYTES:-}
guard_swap=${ZAG_SELFHOST_SWAP_MAX_BYTES:-0}
guard_enabled=0
case "$guard_swap" in ''|*[!0-9]*) echo "native bootstrap: invalid swap guard" >&2; exit 1;; esac
if command -v systemd-run >/dev/null 2>&1 &&
   systemctl --user is-system-running >/dev/null 2>&1; then
    if [ -z "$guard_limit" ]; then
        total_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
        available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        physical_limit=$((total_kib * 1024 * 60 / 100))
        available_limit=$(((available_kib - 2097152) * 1024))
        guard_limit=$physical_limit
        if [ "$guard_limit" -gt "$available_limit" ]; then guard_limit=$available_limit; fi
    fi
    case "$guard_limit" in ''|*[!0-9]*) echo "native bootstrap: invalid memory guard" >&2; exit 1;; esac
    if [ "$guard_limit" -lt 1073741824 ]; then
        echo "native bootstrap: refusing to run with less than 1 GiB after the workstation reserve" >&2
        exit 1
    fi
    guard_enabled=1
    echo "  memory guard: cgroup memory max=$guard_limit bytes, swap max=$guard_swap bytes"
elif [ -n "$guard_limit" ] || [ "$guard_swap" -ne 0 ]; then
    echo "native bootstrap: explicit memory or swap limit requires a user systemd manager" >&2
    exit 1
fi

run_stage_compiler() {
    compiler=$1
    output=$2
    if [ "$guard_enabled" -eq 1 ]; then
        "$timeout_bin" --foreground --kill-after=30s "$selfhost_stage_timeout" \
        systemd-run --user --quiet --wait --collect --pipe \
            -p Type=exec -p "WorkingDirectory=$root" \
            -p "MemoryMax=$guard_limit" -p "MemorySwapMax=$guard_swap" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            /usr/bin/env -i "PATH=$tmp/empty-path" "$compiler" "$source_file" \
            -o "$output" --no-analyze --no-zagd --no-foreground-cache
    else
        "$timeout_bin" --foreground --kill-after=30s "$selfhost_stage_timeout" \
            env "PATH=$tmp/empty-path" "$compiler" "$source_file" -o "$output" \
            --no-analyze --no-zagd --no-foreground-cache
    fi
}

build_stage() {
    compiler=$1
    output=$2
    label=$3
    log="$tmp/$label.log"

    # Reproducibility is a code-generation property. Keep the advisory analyzer
    # and correctness-independent daemon out of the fixpoint measurement.
    run_stage_compiler "$compiler" "$output" >"$log" 2>&1 &
    stage_pid=$!
    stage_started=$SECONDS
    stage_process_running() {
        [ -r "/proc/$stage_pid/stat" ] || return 1
        stage_state=$(awk '{ print $3; exit }' "/proc/$stage_pid/stat")
        [ "$stage_state" != Z ]
    }
    while stage_process_running; do
        sleep "$selfhost_heartbeat"
        if stage_process_running; then
            stage_rss="unavailable"
            if [ -r "/proc/$stage_pid/status" ]; then
                stage_rss=$(awk '/^VmRSS:/ { print $2 " KiB"; exit }' \
                    "/proc/$stage_pid/status")
            fi
            echo "  progress $label: elapsed=$((SECONDS - stage_started))s rss=$stage_rss"
        fi
    done
    if wait "$stage_pid"; then
        :
    else
        stage_pid=""
        echo "  XX  $label failed" >&2
        sed -n '1,40p' "$log" >&2
        exit 1
    fi
    stage_pid=""
    if [ ! -x "$output" ]; then
        echo "  XX  $label did not produce an executable" >&2
        exit 1
    fi
    echo "  ok  $label"
}

same_bytes() {
    left=$1
    right=$2
    label=$3

    if cmp -s "$left" "$right"; then
        echo "  ok  $label"
        return
    fi

    echo "  XX  $label" >&2
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$left" "$right" >&2
    fi
    exit 1
}

echo "── native bootstrap reproducibility (Zag → ELF, empty PATH) ──"
build_stage "$seed" "$tmp/znc-stage1" "seed builds stage 1"
assert_source_stable "stage 1"
build_stage "$tmp/znc-stage1" "$tmp/znc-stage2" "stage 1 builds stage 2"
assert_source_stable "stage 2"
build_stage "$tmp/znc-stage2" "$tmp/znc-stage3" "stage 2 builds stage 3"
assert_source_stable "stage 3"

same_bytes "$seed" "$tmp/znc-stage1" "input seed matches its source rebuild"
same_bytes "$tmp/znc-stage1" "$tmp/znc-stage2" "stage 1 equals stage 2 byte-for-byte"
same_bytes "$tmp/znc-stage2" "$tmp/znc-stage3" "stage 2 equals stage 3 byte-for-byte"

if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$tmp/znc-stage3")
    digest=${digest%% *}
    echo "  sha256  $digest"
fi
assert_source_stable "final report"
echo "  source snapshot unchanged sha256=$source_snapshot"
echo "════ native bootstrap reproducible: pass=6 fail=0 ════"
