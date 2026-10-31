#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC_ZAGD_POLICY_TEST:-./znc}
tmp=$(mktemp -d /tmp/zagd-policy-integration.XXXXXX)
daemon_pid=
cleanup() {
    if [ -n "${daemon_pid:-}" ]; then
        printf 'stop\n' > "$tmp/project/.zagd.stop" 2>/dev/null || true
        wait "$daemon_pid" 2>/dev/null || true
    fi
}
trap cleanup EXIT

"$compiler" selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-zagd --no-analyze >/dev/null
cp "$compiler" "$tmp/znc"
mkdir -p "$tmp/project"
printf '%s\n' \
    'idle_deep=false' \
    'difficulty=explained' \
    'script_optimization=off' \
    'regular_optimization=automatic' \
    'objective=runtime' \
    'trust_mode=reviewed' > "$tmp/project/.zagd.conf"
printf 'fn main() i32 { return 0; }\n' > "$tmp/project/main.zag"

# Project policy feeds the daemon's validated runtime status.
"$tmp/zagd" --root "$tmp/project" --mode light --window-ms 10 & daemon_pid=$!
for _ in $(seq 1 200); do
    if [ -f "$tmp/project/.zagd.status" ] && grep -q '^state=idle$' "$tmp/project/.zagd.status"; then break; fi
    sleep 0.01
done
grep -q '^mode=light$' "$tmp/project/.zagd.status"
grep -q '^idle_deep=false$' "$tmp/project/.zagd.status"
grep -q '^difficulty=explained$' "$tmp/project/.zagd.status"
grep -q '^script_optimization=off$' "$tmp/project/.zagd.status"
grep -q '^regular_optimization=automatic$' "$tmp/project/.zagd.status"
grep -q '^objective=runtime$' "$tmp/project/.zagd.status"
grep -q '^trust_mode=reviewed$' "$tmp/project/.zagd.status"
printf 'stop\n' > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=

# Every adaptive field supplied on the CLI wins over the project file.
"$tmp/zagd" --root "$tmp/project" --mode light --window-ms 10 \
    --idle-deep true --difficulty native --script-optimization review \
    --regular-optimization off --objective runtime --trust-mode autonomous & daemon_pid=$!
for _ in $(seq 1 200); do
    if [ -f "$tmp/project/.zagd.status" ] && grep -q '^state=idle$' "$tmp/project/.zagd.status"; then break; fi
    sleep 0.01
done
grep -q '^idle_deep=true$' "$tmp/project/.zagd.status"
grep -q '^difficulty=native$' "$tmp/project/.zagd.status"
grep -q '^script_optimization=review$' "$tmp/project/.zagd.status"
grep -q '^regular_optimization=off$' "$tmp/project/.zagd.status"
grep -q '^trust_mode=autonomous$' "$tmp/project/.zagd.status"
printf 'stop\n' > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=

# Invalid project policy is rejected before the daemon starts.
printf 'difficulty=expert\n' > "$tmp/project/.zagd.conf"
if "$tmp/zagd" --root "$tmp/project" --mode off >/tmp/zagd-policy-invalid.out 2>&1; then
    echo 'invalid project policy unexpectedly accepted' >&2
    exit 1
fi
grep -q 'invalid .zagd.conf' /tmp/zagd-policy-invalid.out

# Duplicate keys are ambiguous policy, not a supported override mechanism.
printf 'difficulty=simple\ndifficulty=native\n' > "$tmp/project/.zagd.conf"
if "$tmp/zagd" --root "$tmp/project" --mode off >/tmp/zagd-policy-duplicate.out 2>&1; then
    echo 'duplicate project policy unexpectedly accepted' >&2
    exit 1
fi
grep -q 'duplicate key' /tmp/zagd-policy-duplicate.out

echo 'zagd policy integration: pass=4 fail=0'
