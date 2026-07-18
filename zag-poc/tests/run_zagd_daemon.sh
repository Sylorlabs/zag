#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-daemon.XXXXXX)
trap 'if [ -n "${daemon_pid:-}" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT

./znc tests/zagd_linux_test.zag -o "$tmp/linux-test" --no-analyze >/dev/null
"$tmp/linux-test"
./znc selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-analyze >/dev/null

mkdir "$tmp/project"
printf '999999999\n' > "$tmp/project/.zagd.lock"
"$tmp/zagd" --root "$tmp/project" --mode off
test ! -e "$tmp/project/.zagd.lock"
"$tmp/zagd" --root "$tmp/project" --mode light &
daemon_pid=$!

for _ in $(seq 1 100); do
    [ -f "$tmp/project/.zagd.status" ] && break
    sleep 0.01
done
grep -q '^state=idle$' "$tmp/project/.zagd.status"
grep -q '^mode=light$' "$tmp/project/.zagd.status"
grep -q '^network=false$' "$tmp/project/.zagd.status"
grep -q '^gpu_background=false$' "$tmp/project/.zagd.status"

printf 'one\n' > "$tmp/project/app.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status"
first=$(grep '^content_hash_first=' "$tmp/project/.zagd.status")

printf 'two\n' > "$tmp/project/app.zag"
for _ in $(seq 1 100); do
    now=$(grep '^content_hash_first=' "$tmp/project/.zagd.status" 2>/dev/null || true)
    [ "$now" != "$first" ] && break
    sleep 0.01
done
test "$(grep '^content_hash_first=' "$tmp/project/.zagd.status")" != "$first"

"$tmp/zagd" --root "$tmp/project" --mode off
wait "$daemon_pid"
daemon_pid=
grep -q '^state=stopped$' "$tmp/project/.zagd.status"
test ! -e "$tmp/project/.zagd.lock"

"$tmp/zagd" --root "$tmp/project" --mode off
grep -q '^mode=off$' "$tmp/project/.zagd.status"
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

if "$tmp/zagd" --root "$tmp/project" --mode mystery >/dev/null 2>&1; then
    echo "unknown mode unexpectedly accepted" >&2
    exit 1
fi
if "$tmp/zagd" --root "$tmp/project" --window-ms 0 >/dev/null 2>&1; then
    echo "invalid stability window unexpectedly accepted" >&2
    exit 1
fi

child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^mode=adaptive$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=idle$' "$tmp/project/.zagd.status"
grep -q '^mode=adaptive$' "$tmp/project/.zagd.status"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

if "$tmp/zagd" --root "$tmp/project" --mode mystery >/dev/null 2>&1; then
    echo "unknown mode unexpectedly accepted" >&2; exit 1
fi
if "$tmp/zagd" --root "$tmp/project" --window-ms 0 >/dev/null 2>&1; then
    echo "invalid stability window unexpectedly accepted" >&2; exit 1
fi

"$tmp/zagd" --root "$tmp/project" --mode deep --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 100); do
    grep -q '^mode=deep$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
if "$tmp/zagd" --root "$tmp/project" --mode light >/dev/null 2>&1; then
    echo "duplicate daemon unexpectedly started" >&2; exit 1
fi

mkdir -p "$tmp/project/src/deep"
sleep 0.1
printf nested > "$tmp/project/src/deep/nested.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/src/deep/nested.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q 'last_file=.*/src/deep/nested.zag$' "$tmp/project/.zagd.status"

printf renamed > "$tmp/project/.atomic.tmp"
mv "$tmp/project/.atomic.tmp" "$tmp/project/atomic.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/atomic.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q 'last_file=.*/atomic.zag$' "$tmp/project/.zagd.status"
before=$(grep '^events=' "$tmp/project/.zagd.status")
printf renamed > "$tmp/project/atomic.zag"
sleep 0.15
test "$(grep '^events=' "$tmp/project/.zagd.status")" = "$before"

rm "$tmp/project/atomic.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/atomic.zag$' "$tmp/project/.zagd.status" 2>/dev/null &&
        grep -q '^content_hash_first=216613626$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^content_hash_first=216613626$' "$tmp/project/.zagd.status"

printf stop > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=

child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^mode=adaptive$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^singleton=true$' "$tmp/project/.zagd.status"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

echo "zagd daemon: pass"
