#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-service.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project with spaces;dollar\$"
project="$tmp/project with spaces;dollar\$"
cat >"$project/zag.mod" <<'EOF'
name = "service-fixture-root"
version = "0"
edition = "2026"
EOF
cat >"$project/main.zag" <<'EOF'
fn main() i32 { return 0; }
EOF
cat >"$project/.zagd.conf" <<'EOF'
max_memory_bytes=134217728
mode=adaptive
stability_window_ms=125
max_cache_bytes=1048576
notifications=advisory
idle_deep=false
difficulty=native
script_optimization=review
regular_optimization=automatic
objective=runtime
trust_mode=autonomous
cpu=native
EOF
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
if test -n "${HANDOFF_LOG:-}"; then
    printf 'systemctl %s\n' "$*" >>"$HANDOFF_LOG"
fi
case "$*" in
*" enable --now "*|*" restart "*)
    if test -n "${PROJECT_LOCK:-}" && test -e "$PROJECT_LOCK"; then
        echo "systemctl fixture: service start attempted before singleton handoff" >&2
        exit 1
    fi
    ;;
esac
EOF
chmod +x "$tmp/bin/systemctl"
export SYSTEMCTL_LOG="$tmp/systemctl.log"
export HANDOFF_LOG="$tmp/handoff.log"
export ZAGD_ARGV_LOG="$tmp/zagd.argv"
export PROJECT_LOCK="$project/.zagd.lock"

XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh install "$project/main.zag" light >/dev/null
unit=$(find "$tmp/config/systemd/user" -type f -name 'zagd-*.service')
grep -q '^Type=simple$' "$unit"
grep -q '^Restart=always$' "$unit"
grep -q '^RestartSec=1$' "$unit"
grep -q '^TimeoutStopSec=5s$' "$unit"
grep -q '^StartLimitIntervalSec=60$' "$unit"
grep -q '^StartLimitBurst=5$' "$unit"
grep -q '^RestartPreventExitStatus=SIGKILL 75$' "$unit"
grep -q '^Nice=10$' "$unit"
grep -q '^MemoryMax=134217728$' "$unit"
grep -q '^MemoryHigh=120795955$' "$unit"
grep -q '^MemorySwapMax=0$' "$unit"
grep -q '^CPUWeight=25$' "$unit"
grep -q '^TasksMax=64$' "$unit"
grep -q '^PrivateNetwork=true$' "$unit"
grep -q '^PrivateDevices=true$' "$unit"
grep -q '^# zagd-fallback-mode=light$' "$unit"
# Raw shell-sensitive project bytes are never interpolated into unit fields.
if grep -Fq "$project" "$unit"; then
    echo "raw special-character path leaked into systemd unit" >&2
    exit 1
fi
grep -q '^WorkingDirectory=/.*\\x20' "$unit"
grep -q '^ExecStart=\\x' "$unit"
grep -q ' run \\x.* light$' "$unit"
grep -q '^--user daemon-reload$' "$tmp/systemctl.log"
grep -q '^--user stop zagd-.* --no-block$' "$tmp/systemctl.log"
grep -q '^--user enable --now zagd-' "$tmp/systemctl.log"

# A nested source must use the same nearest-zag.mod project root as `znc`, even
# when an unrelated parent-tree VCS marker exists.
mkdir -p "$tmp/.git" "$tmp/parent-project/sub/child"
printf 'name = "parent-project"\nversion = "0"\nedition = "2026"\n' \
    >"$tmp/parent-project/zag.mod"
cat >"$tmp/parent-project/.zagd.conf" <<'EOF'
max_memory_bytes=134217728
mode=adaptive
stability_window_ms=125
max_cache_bytes=1048576
notifications=advisory
EOF
cat >"$tmp/parent-project/sub/child/main.zag" <<'EOF'
fn main() i32 { return 0; }
EOF
XDG_CONFIG_HOME="$tmp/config-parent" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh install "$tmp/parent-project/sub/child/main.zag" light >/dev/null
parent_unit=$(find "$tmp/config-parent/systemd/user" -type f -name 'zagd-*.service')
grep -q '^MemoryMax=134217728$' "$parent_unit"

# Reinstalling is an idempotent policy refresh: it rewrites the same private
# unit and asks systemd to enable/start it, without creating another unit.
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh install "$project/main.zag" light >/dev/null
test "$(find "$tmp/config/systemd/user" -type f -name 'zagd-*.service' | wc -l)" -eq 1

# A foreground compiler may have auto-started a project singleton immediately
# before service installation. Exercise the real launcher handoff with a
# fixtured zagd: the existing owner must receive a bounded off request and
# release the lock before systemd is allowed to start the supervised owner.
fixture_repo="$tmp/service-fixture"
collision_project="$tmp/collision-project"
default_project="$tmp/default-project"
mkdir -p "$fixture_repo/tools" "$collision_project" "$default_project"
cp tools/zagd-user-service.sh "$fixture_repo/tools/zagd-user-service.sh"
chmod +x "$fixture_repo/tools/zagd-user-service.sh"
cat >"$fixture_repo/zagd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=
root_source=
mode=
idle_deep=
difficulty=
script_optimization=
regular_optimization=
objective=
trust_mode=
cpu=
window_ms=
max_memory_bytes=
max_cache_bytes=
max_workers=
notifications=
{
    printf 'argc=%s\n' "$#"
    argv_index=0
    for raw_arg in "$@"; do
        printf 'argv[%02d]=%s\n' "$argv_index" "$raw_arg"
        argv_index=$((argv_index + 1))
    done
} >>"$ZAGD_ARGV_LOG"
while (( $# > 0 )); do
    case "$1" in
    --root) root=$2; shift 2 ;;
    --root-source) root_source=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    --idle-deep) idle_deep=$2; shift 2 ;;
    --difficulty) difficulty=$2; shift 2 ;;
    --script-optimization) script_optimization=$2; shift 2 ;;
    --regular-optimization) regular_optimization=$2; shift 2 ;;
    --objective) objective=$2; shift 2 ;;
    --trust-mode) trust_mode=$2; shift 2 ;;
    --cpu) cpu=$2; shift 2 ;;
    --window-ms) window_ms=$2; shift 2 ;;
    --max-memory-bytes) max_memory_bytes=$2; shift 2 ;;
    --max-cache-bytes) max_cache_bytes=$2; shift 2 ;;
    --max-workers) max_workers=$2; shift 2 ;;
    --notifications) notifications=$2; shift 2 ;;
    *) printf 'fake-zagd: unexpected or incomplete argument: %s\n' "$1" >&2; exit 64 ;;
    esac
done
test -n "$root"
test -n "$root_source"
test -n "$mode"
test -n "$idle_deep"
test -n "$difficulty"
test -n "$script_optimization"
test -n "$regular_optimization"
test -n "$objective"
test -n "$trust_mode"
test -n "$cpu"
test -n "$window_ms"
test -n "$max_memory_bytes"
test -n "$max_cache_bytes"
test -n "$max_workers"
test -n "$notifications"
lock_state=absent
if test -e "$root/.zagd.lock"; then lock_state=present; fi
printf 'fake-zagd mode=%s lock=%s\n' "$mode" "$lock_state" >>"$HANDOFF_LOG"
printf 'fake-zagd-policy idle_deep=%s difficulty=%s script_optimization=%s regular_optimization=%s objective=%s trust_mode=%s cpu=%s\n' \
    "$idle_deep" "$difficulty" "$script_optimization" \
    "$regular_optimization" "$objective" "$trust_mode" "$cpu" \
    >>"$HANDOFF_LOG"
if test "$mode" = off; then
    if test "${ZAGD_FAKE_REFUSE_OFF:-0}" = 1; then exit 7; fi
    rm -f -- "$root/.zagd.lock"
    exit 0
fi
if test -e "$root/.zagd.lock"; then exit 6; fi
{
    printf 'mode=%s\n' "$mode"
    printf 'idle_deep=%s\n' "$idle_deep"
    printf 'difficulty=%s\n' "$difficulty"
    printf 'script_optimization=%s\n' "$script_optimization"
    printf 'regular_optimization=%s\n' "$regular_optimization"
    printf 'objective=%s\n' "$objective"
    printf 'trust_mode=%s\n' "$trust_mode"
    printf 'cpu=%s\n' "$cpu"
    printf 'stability_window_ms=%s\n' "$window_ms"
    printf 'max_memory_bytes=%s\n' "$max_memory_bytes"
    printf 'max_cache_bytes=%s\n' "$max_cache_bytes"
    printf 'max_workers=%s\n' "$max_workers"
    printf 'notifications=%s\n' "$notifications"
} >"$root/.zagd.status"
printf 'supervised\n' >"$root/.zagd.lock"
exit 0
EOF
chmod +x "$fixture_repo/zagd"
cat >"$default_project/main.zag" <<'EOF'
fn main() i32 { return 0; }
EOF
cat >"$default_project/zag.mod" <<'EOF'
name = "service-fixture-default"
version = "0"
edition = "2026"
EOF
cat >"$collision_project/main.zag" <<'EOF'
fn main() i32 { return 0; }
EOF
cat >"$collision_project/zag.mod" <<'EOF'
name = "service-fixture-collision"
version = "0"
edition = "2026"
EOF
cat >"$collision_project/.zagd.conf" <<'EOF'
mode=light
max_memory_bytes=134217728
max_cache_bytes=1048576
idle_deep=false
difficulty=native
script_optimization=review
regular_optimization=automatic
objective=runtime
trust_mode=autonomous
cpu=native
EOF

write_expected_daemon_argv() {
    local output=$1 root=$2 root_source=$3 mode=$4 idle_deep=$5
    local difficulty=$6 script_optimization=$7 regular_optimization=$8
    local objective=$9 trust_mode=${10} cpu=${11} window_ms=${12}
    local max_memory_bytes=${13} max_cache_bytes=${14} max_workers=${15}
    local notifications=${16}
    {
        printf 'argc=30\n'
        printf 'argv[00]=--root\nargv[01]=%s\n' "$root"
        printf 'argv[02]=--root-source\nargv[03]=%s\n' "$root_source"
        printf 'argv[04]=--mode\nargv[05]=%s\n' "$mode"
        printf 'argv[06]=--idle-deep\nargv[07]=%s\n' "$idle_deep"
        printf 'argv[08]=--difficulty\nargv[09]=%s\n' "$difficulty"
        printf 'argv[10]=--script-optimization\nargv[11]=%s\n' "$script_optimization"
        printf 'argv[12]=--regular-optimization\nargv[13]=%s\n' "$regular_optimization"
        printf 'argv[14]=--objective\nargv[15]=%s\n' "$objective"
        printf 'argv[16]=--trust-mode\nargv[17]=%s\n' "$trust_mode"
        printf 'argv[18]=--cpu\nargv[19]=%s\n' "$cpu"
        printf 'argv[20]=--window-ms\nargv[21]=%s\n' "$window_ms"
        printf 'argv[22]=--max-memory-bytes\nargv[23]=%s\n' "$max_memory_bytes"
        printf 'argv[24]=--max-cache-bytes\nargv[25]=%s\n' "$max_cache_bytes"
        printf 'argv[26]=--max-workers\nargv[27]=%s\n' "$max_workers"
        printf 'argv[28]=--notifications\nargv[29]=%s\n' "$notifications"
    } >"$output"
}

write_expected_daemon_status() {
    local output=$1 mode=$2 idle_deep=$3 difficulty=$4
    local script_optimization=$5 regular_optimization=$6 objective=$7
    local trust_mode=$8 cpu=$9 window_ms=${10} max_memory_bytes=${11}
    local max_cache_bytes=${12} max_workers=${13} notifications=${14}
    {
        printf 'mode=%s\n' "$mode"
        printf 'idle_deep=%s\n' "$idle_deep"
        printf 'difficulty=%s\n' "$difficulty"
        printf 'script_optimization=%s\n' "$script_optimization"
        printf 'regular_optimization=%s\n' "$regular_optimization"
        printf 'objective=%s\n' "$objective"
        printf 'trust_mode=%s\n' "$trust_mode"
        printf 'cpu=%s\n' "$cpu"
        printf 'stability_window_ms=%s\n' "$window_ms"
        printf 'max_memory_bytes=%s\n' "$max_memory_bytes"
        printf 'max_cache_bytes=%s\n' "$max_cache_bytes"
        printf 'max_workers=%s\n' "$max_workers"
        printf 'notifications=%s\n' "$notifications"
    } >"$output"
}

assert_exact_file() {
    local expected=$1 actual=$2 label=$3
    if ! cmp -s -- "$expected" "$actual"; then
        printf '%s mismatch\n' "$label" >&2
        diff -u -- "$expected" "$actual" >&2 || true
        return 1
    fi
}

# With no project policy, the private runner must preserve every documented
# resource/policy default and transport one exact, injection-safe argv vector.
: >"$ZAGD_ARGV_LOG"
: >"$HANDOFF_LOG"
XDG_CONFIG_HOME="$tmp/default-config" PATH="$tmp/bin:$PATH" \
    "$fixture_repo/tools/zagd-user-service.sh" run \
    "$default_project/main.zag" adaptive >/dev/null
write_expected_daemon_argv "$tmp/default.argv.expected" \
    "$default_project" "$default_project/main.zag" adaptive true simple \
    automatic review runtime stable generic 75 536870912 2147483648 1 advisory
assert_exact_file "$tmp/default.argv.expected" "$ZAGD_ARGV_LOG" \
    "default service argv"
write_expected_daemon_status "$tmp/default.status.expected" \
    adaptive true simple automatic review runtime stable generic 75 \
    536870912 2147483648 1 advisory
assert_exact_file "$tmp/default.status.expected" \
    "$default_project/.zagd.status" "default effective status"
rm -f -- "$default_project/.zagd.lock"

# Project overrides must arrive at the receiving executable as the same exact
# argv/status contract, including the existing resource and notification flags.
: >"$ZAGD_ARGV_LOG"
: >"$HANDOFF_LOG"
XDG_CONFIG_HOME="$tmp/collision-config" PATH="$tmp/bin:$PATH" \
    "$fixture_repo/tools/zagd-user-service.sh" run \
    "$collision_project/main.zag" light >/dev/null
write_expected_daemon_argv "$tmp/override.argv.expected" \
    "$collision_project" "$collision_project/main.zag" light false native \
    review automatic runtime autonomous native 75 134217728 1048576 1 advisory
assert_exact_file "$tmp/override.argv.expected" "$ZAGD_ARGV_LOG" \
    "override service argv"
write_expected_daemon_status "$tmp/override.status.expected" \
    light false native review automatic runtime autonomous native 75 \
    134217728 1048576 1 advisory
assert_exact_file "$tmp/override.status.expected" \
    "$collision_project/.zagd.status" "override effective status"
rm -f -- "$collision_project/.zagd.lock"

# The installed layout keeps the adapter and zagd as sibling executables
# rather than a repository tools/ + root pair. It must select that exact
# sibling without depending on PATH or a source checkout.
installed_bin="$tmp/installed/bin"
mkdir -p "$installed_bin"
cp tools/zagd-user-service.sh "$installed_bin/zagd-user-service"
cp "$fixture_repo/zagd" "$installed_bin/zagd"
chmod +x "$installed_bin/zagd-user-service" "$installed_bin/zagd"
XDG_CONFIG_HOME="$tmp/installed-config" PATH="$tmp/bin:$PATH" \
    "$installed_bin/zagd-user-service" install "$collision_project/main.zag" light >/dev/null
test "$(find "$tmp/installed-config/systemd/user" -type f -name 'zagd-*.service' | wc -l)" -eq 1

printf 'auto-started\n' >"$collision_project/.zagd.lock"
export PROJECT_LOCK="$collision_project/.zagd.lock"
: >"$HANDOFF_LOG"
: >"$ZAGD_ARGV_LOG"
XDG_CONFIG_HOME="$tmp/collision-config" PATH="$tmp/bin:$PATH" \
    "$fixture_repo/tools/zagd-user-service.sh" install "$collision_project/main.zag" light >/dev/null
test ! -e "$collision_project/.zagd.lock"
grep -q '^fake-zagd mode=off lock=present$' "$HANDOFF_LOG"
write_expected_daemon_argv "$tmp/handoff.argv.expected" \
    "$collision_project" "$collision_project/main.zag" off false native \
    review automatic runtime autonomous native 75 134217728 1048576 1 advisory
assert_exact_file "$tmp/handoff.argv.expected" "$ZAGD_ARGV_LOG" \
    "singleton handoff argv"
handoff_line=$(grep -n '^fake-zagd mode=off lock=present$' "$HANDOFF_LOG" | head -1 | cut -d: -f1)
enable_line=$(grep -n '^systemctl --user enable --now zagd-' "$HANDOFF_LOG" | head -1 | cut -d: -f1)
test "$handoff_line" -lt "$enable_line"

# Repeat the check at the private service-runner boundary. This covers an
# auto-start race after the public command's handoff but before ExecStart.
printf 'racing-auto-start\n' >"$collision_project/.zagd.lock"
: >"$HANDOFF_LOG"
XDG_CONFIG_HOME="$tmp/collision-config" PATH="$tmp/bin:$PATH" \
    "$fixture_repo/tools/zagd-user-service.sh" run "$collision_project/main.zag" light >/dev/null
grep -q '^fake-zagd mode=off lock=present$' "$HANDOFF_LOG"
grep -q '^fake-zagd mode=light lock=absent$' "$HANDOFF_LOG"
grep -q '^fake-zagd-policy idle_deep=false difficulty=native script_optimization=review regular_optimization=automatic objective=runtime trust_mode=autonomous cpu=native$' "$HANDOFF_LOG"

# Refusing to release a live owner must fail closed rather than launching a
# second daemon that repeatedly exits with singleton status 6.
printf 'uncooperative-owner\n' >"$collision_project/.zagd.lock"
: >"$HANDOFF_LOG"
if ZAGD_FAKE_REFUSE_OFF=1 XDG_CONFIG_HOME="$tmp/collision-config" PATH="$tmp/bin:$PATH" \
    "$fixture_repo/tools/zagd-user-service.sh" reload "$collision_project/main.zag" >/dev/null 2>&1
then
    echo "service handoff unexpectedly ignored a daemon shutdown failure" >&2
    exit 1
fi
grep -q '^fake-zagd mode=off lock=present$' "$HANDOFF_LOG"
if grep -q '^systemctl --user restart zagd-' "$HANDOFF_LOG"; then
    echo "service restarted despite failed singleton handoff" >&2
    exit 1
fi
rm -f -- "$collision_project/.zagd.lock"
export PROJECT_LOCK="$project/.zagd.lock"

# The service runner reads current policy at start. mode=off is a controlled
# no-restart exit rather than an always-restart CPU loop.
cat >"$project/.zagd.conf" <<'EOF'
mode=off
EOF
set +e
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh run "$project/main.zag" light >/dev/null 2>&1
off_status=$?
set -e
test "$off_status" -eq 75

# reload preserves the fallback when no new one is supplied and refreshes the
# cgroup memory cap from project configuration without uninstalling.
cat >"$project/.zagd.conf" <<'EOF'
max_memory_bytes=268435456
mode=adaptive
EOF
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh reload "$project/main.zag" >/dev/null
grep -q '^# zagd-fallback-mode=light$' "$unit"
grep -q '^MemoryMax=268435456$' "$unit"
grep -q '^--user restart zagd-' "$tmp/systemctl.log"
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh restart "$project/main.zag" >/dev/null
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh status "$project/main.zag" >/dev/null
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh shutdown "$project/main.zag" >/dev/null
grep -q '^--user status zagd-.* --no-pager$' "$tmp/systemctl.log"
grep -q '^--user stop zagd-' "$tmp/systemctl.log"

# systemd-analyze checks parser validity when it is locally available. Its
# environment does not need a running user manager for verify.
if command -v systemd-analyze >/dev/null 2>&1; then
    systemd-analyze verify "$unit" >/dev/null 2>&1
fi

XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh uninstall "$project/main.zag" >/dev/null
test ! -e "$unit"
if XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh status "$project/main.zag" >/dev/null 2>&1; then
    echo "uninstalled service unexpectedly reported status" >&2
    exit 1
fi
# Every policy value transported to direct zagd argv is validated before a
# systemd unit can be activated. Missing keys select documented defaults;
# present empty, malformed, duplicate, unknown, or out-of-domain values fail
# with status 1 and must not reach systemctl.
assert_invalid_service_config() {
    local label=$1 config_text=$2 expected_diagnostic=$3
    local before_calls after_calls invalid_status actual_diagnostic
    printf '%s\n' "$config_text" >"$project/.zagd.conf"
    before_calls=$(wc -l <"$SYSTEMCTL_LOG")
    set +e
    XDG_CONFIG_HOME="$tmp/config-invalid" PATH="$tmp/bin:$PATH" \
        tools/zagd-user-service.sh install "$project/main.zag" adaptive \
        >"$tmp/invalid.out" 2>&1
    invalid_status=$?
    set -e
    actual_diagnostic=$(<"$tmp/invalid.out")
    if test "$invalid_status" -ne 1; then
        printf '%s returned status %s instead of 1\n' \
            "$label" "$invalid_status" >&2
        return 1
    fi
    if test "$actual_diagnostic" != "$expected_diagnostic"; then
        printf '%s diagnostic mismatch\nexpected: %s\nactual:   %s\n' \
            "$label" "$expected_diagnostic" "$actual_diagnostic" >&2
        return 1
    fi
    after_calls=$(wc -l <"$SYSTEMCTL_LOG")
    if test "$after_calls" -ne "$before_calls"; then
        printf '%s reached systemctl despite invalid configuration\n' \
            "$label" >&2
        return 1
    fi
}

assert_invalid_service_config mode-value 'mode=turbo' \
    'zagd service: mode must be off, light, adaptive, or deep'
assert_invalid_service_config idle-deep 'idle_deep=maybe' \
    'zagd service: invalid idle_deep=maybe'
assert_invalid_service_config difficulty 'difficulty=opaque' \
    'zagd service: invalid difficulty=opaque'
assert_invalid_service_config script-optimization 'script_optimization=always' \
    'zagd service: invalid script_optimization=always'
assert_invalid_service_config regular-optimization 'regular_optimization=silent' \
    'zagd service: invalid regular_optimization=silent'
assert_invalid_service_config objective 'objective=size' \
    'zagd service: invalid objective=size'
assert_invalid_service_config trust-mode 'trust_mode=unsafe' \
    'zagd service: invalid trust_mode=unsafe'
assert_invalid_service_config cpu 'cpu=quantum' \
    'zagd service: invalid cpu=quantum'
assert_invalid_service_config empty-cpu 'cpu=' \
    'zagd service: cpu must not be empty'
assert_invalid_service_config notifications 'notifications=noisy' \
    'zagd service: invalid notifications=noisy'
assert_invalid_service_config max-workers 'max_workers=2' \
    'zagd service: invalid max_workers=2'
assert_invalid_service_config stability-window 'stability_window_ms=0' \
    'zagd service: stability_window_ms must be 1..60000'
assert_invalid_service_config malformed-memory \
    'max_memory_bytes=not-a-number' \
    'zagd service: max_memory_bytes must be a decimal value from 67108864 through 2147483648'
assert_invalid_service_config cache-range 'max_cache_bytes=0' \
    'zagd service: max_cache_bytes must be 1048576..2147483648'
assert_invalid_service_config foreground-bool 'allow_process=maybe' \
    'zagd service: invalid allow_process=maybe'
assert_invalid_service_config script-memory 'script_memory_bytes=0' \
    'zagd service: script_memory_bytes must be 1048576..2147483648'
assert_invalid_service_config environment-name \
    'environment_allow=OK,bad-name' \
    'zagd service: environment_allow must be comma-separated variable names'
assert_invalid_service_config environment-length \
    "environment_allow=$(printf 'A%.0s' {1..129})" \
    'zagd service: environment_allow must be comma-separated variable names'
assert_invalid_service_config unknown-key 'unknown_policy=true' \
    'zagd service: invalid .zagd.conf syntax, unknown key, or duplicate key'
assert_invalid_service_config duplicate-key $'mode=adaptive\nmode=light' \
    'zagd service: invalid .zagd.conf syntax, unknown key, or duplicate key'
assert_invalid_service_config missing-equals 'mode adaptive' \
    'zagd service: invalid .zagd.conf syntax, unknown key, or duplicate key'
assert_invalid_service_config empty-key '=adaptive' \
    'zagd service: invalid .zagd.conf syntax, unknown key, or duplicate key'
echo "zagd user service: pass"
