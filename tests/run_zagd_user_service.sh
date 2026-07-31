#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-service.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project with spaces;dollar\$"
project="$tmp/project with spaces;dollar\$"
cat >"$project/main.zag" <<'EOF'
fn main() i32 { return 0; }
EOF
cat >"$project/.zagd.conf" <<'EOF'
max_memory_bytes=134217728
mode=adaptive
stability_window_ms=125
max_cache_bytes=1048576
notifications=advisory
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
mkdir -p "$fixture_repo/tools" "$collision_project"
cp tools/zagd-user-service.sh "$fixture_repo/tools/zagd-user-service.sh"
chmod +x "$fixture_repo/tools/zagd-user-service.sh"
cat >"$fixture_repo/zagd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
root=
mode=
while (( $# > 0 )); do
    case "$1" in
    --root) root=$2; shift 2 ;;
    --mode) mode=$2; shift 2 ;;
    *) shift ;;
    esac
done
test -n "$root"
test -n "$mode"
lock_state=absent
if test -e "$root/.zagd.lock"; then lock_state=present; fi
printf 'fake-zagd mode=%s lock=%s\n' "$mode" "$lock_state" >>"$HANDOFF_LOG"
if test "$mode" = off; then
    if test "${ZAGD_FAKE_REFUSE_OFF:-0}" = 1; then exit 7; fi
    rm -f -- "$root/.zagd.lock"
    exit 0
fi
if test -e "$root/.zagd.lock"; then exit 6; fi
printf 'supervised\n' >"$root/.zagd.lock"
exit 0
EOF
chmod +x "$fixture_repo/zagd"
cat >"$collision_project/main.zag" <<'EOF'
fn main() i32 { return 0; }
EOF
cat >"$collision_project/.zagd.conf" <<'EOF'
mode=light
max_memory_bytes=134217728
max_cache_bytes=1048576
EOF

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
XDG_CONFIG_HOME="$tmp/collision-config" PATH="$tmp/bin:$PATH" \
    "$fixture_repo/tools/zagd-user-service.sh" install "$collision_project/main.zag" light >/dev/null
test ! -e "$collision_project/.zagd.lock"
grep -q '^fake-zagd mode=off lock=present$' "$HANDOFF_LOG"
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
cat >"$project/.zagd.conf" <<'EOF'
max_memory_bytes=not-a-number
EOF
if XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh install "$project/main.zag" adaptive >/dev/null 2>&1; then
    echo "invalid service memory config unexpectedly accepted" >&2
    exit 1
fi
echo "zagd user service: pass"
