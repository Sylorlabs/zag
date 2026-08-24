#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zag-zagd-identity.XXXXXX)
daemon_pid=
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
compiler=${ZNC_ZAGD_IDENTITY_TEST:-"$(pwd)/znc"}
daemon=${ZAGD_IDENTITY_TEST:-"$(pwd)/zagd"}
"$compiler" selfhost/zagd_identity_test.zag -o "$tmp/zagd_identity" --no-zagd --no-analyze >/dev/null
"$tmp/zagd_identity"

# An unrelated, live process with a real /proc start token must not block a
# project daemon. The forged lock is reclaimed without signalling that PID.
project="$tmp/project with spaces "'$special'
mkdir -p "$project"
printf '[package]\nname = "identity"\nversion = "0.0.1"\n' > "$project/zag.mod"
printf 'fn main() i32 { return 0; }\n' > "$project/main.zag"
sleep 30 &
unrelated=$!
start=$(awk '{ p=index($0,") "); n=split(substr($0,p+2),a," "); print a[20] }' "/proc/$unrelated/stat")
printf '%s\n%s\n' "$unrelated" "$start" > "$project/.zagd.lock"
"$daemon" --root "$project" --mode light --window-ms 10 --daemonize >/dev/null
for _ in $(seq 1 100); do test -s "$project/.zagd.lock" && break; sleep 0.01; done
kill -0 "$unrelated"
test "$(head -n1 "$project/.zagd.lock")" != "$unrelated"
"$daemon" --root "$project" --mode off --window-ms 10 >/dev/null
test ! -e "$project/.zagd.lock"

# A mismatched /proc start token is stale even when its PID is live.
printf '%s\n1\n' "$unrelated" > "$project/.zagd.lock"
"$daemon" --root "$project" --mode light --window-ms 10 --daemonize >/dev/null
for _ in $(seq 1 100); do test "$(head -n1 "$project/.zagd.lock")" != "$unrelated" && break; sleep 0.01; done
test "$(head -n1 "$project/.zagd.lock")" != "$unrelated"
"$daemon" --root "$project" --mode off --window-ms 10 >/dev/null
test ! -e "$project/.zagd.lock"

# A crash between O_EXCL and identity write leaves an empty lock; startup
# waits briefly, then reclaims it rather than becoming permanently wedged.
: > "$project/.zagd.lock"
"$daemon" --root "$project" --mode light --window-ms 10 --daemonize >/dev/null
for _ in $(seq 1 100); do test -s "$project/.zagd.lock" && break; sleep 0.01; done
test -s "$project/.zagd.lock"
"$daemon" --root "$project" --mode off --window-ms 10 >/dev/null
kill "$unrelated" 2>/dev/null || true
echo "zagd identity: pass"
