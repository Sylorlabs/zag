#!/usr/bin/env bash
# Adaptive watcher regression: daemon-owned semantic markers and nested project
# controls must not feed work back into the root daemon, and a quiet timed poll
# must return to kernel sleep instead of consuming a core.
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-"$(pwd)/znc"}
provided_daemon=${ZAGD:-}
tmp=$(mktemp -d /tmp/zagd-idle-cpu.XXXXXX)
project="$tmp/project"
daemon_pid=

cleanup() {
    if [ -n "$daemon_pid" ] && kill -0 "$daemon_pid" 2>/dev/null; then
        printf 'stop\n' >"$project/.zagd.stop" 2>/dev/null || true
        for _ in $(seq 1 200); do
            kill -0 "$daemon_pid" 2>/dev/null || break
            sleep 0.01
        done
        if kill -0 "$daemon_pid" 2>/dev/null; then
            kill "$daemon_pid" 2>/dev/null || true
        fi
        wait "$daemon_pid" 2>/dev/null || true
    fi
    find "$tmp" -depth -delete 2>/dev/null || true
}
trap cleanup EXIT HUP INT TERM

mkdir -p "$tmp/bin" "$project/nested"
if [ -n "$provided_daemon" ]; then
    cp "$provided_daemon" "$tmp/bin/zagd"
else
    "$compiler" selfhost/zagd_daemon.zag -o "$tmp/bin/zagd" \
        --no-analyze --no-zagd --no-foreground-cache >/dev/null
fi
cp "$compiler" "$tmp/bin/znc"
chmod +x "$tmp/bin/zagd" "$tmp/bin/znc"

printf '[package]\nname = "zagd-idle-cpu"\nversion = "0.0.1"\n' >"$project/zag.mod"
printf 'fn main() i32 { return 0; }\n' >"$project/main.zag"

"$tmp/bin/zagd" --root "$project" --root-source "$project/main.zag" \
    --mode adaptive --idle-deep true --window-ms 20 \
    --max-memory-bytes 268435456 --max-cache-bytes 16777216 \
    --max-workers 1 --notifications errors_only --cpu generic \
    >"$tmp/zagd.log" 2>&1 &
daemon_pid=$!

for _ in $(seq 1 500); do
    if grep -q '^state=idle$' "$project/.zagd.status" 2>/dev/null &&
       grep -q "^pid=$daemon_pid$" "$project/.zagd.status" 2>/dev/null; then
        break
    fi
    kill -0 "$daemon_pid" 2>/dev/null || {
        sed 's/^/  /' "$tmp/zagd.log" >&2
        echo 'zagd idle cpu: daemon exited during startup' >&2
        exit 1
    }
    sleep 0.01
done
grep -q '^state=idle$' "$project/.zagd.status"
grep -q '^mode=adaptive$' "$project/.zagd.status"
grep -q '^idle_deep=true$' "$project/.zagd.status"
grep -q '^semantic_validation=validated$' "$project/.zagd.status"

# Control files in a recursively watched nested project are not controls for
# this root. Before the fix either marker could reprocess root semantics or stop
# the daemon because dispatch matched only the basename.
events_before_nested=$(sed -n 's/^events=//p' "$project/.zagd.status")
printf 'ready\n' >"$project/nested/.zagd.semantic-ready"
sleep 0.25
kill -0 "$daemon_pid"
test "$(sed -n 's/^events=//p' "$project/.zagd.status")" = "$events_before_nested"
printf 'stop\n' >"$project/nested/.zagd.stop"
sleep 0.25
kill -0 "$daemon_pid"
grep -q '^state=idle$' "$project/.zagd.status"
test "$(sed -n 's/^events=//p' "$project/.zagd.status")" = "$events_before_nested"

# A root source edit launches the daemon-owned sibling `znc check`. The child
# publishes `.zagd.semantic-ready`, but the source-event path consumes and
# unlinks that marker itself. Queued create/close hints must not process the same
# semantic graph again or replace last_file with the internal marker.
events_before_source=$(sed -n 's/^events=//p' "$project/.zagd.status")
printf 'fn main() i32 { return 1; }\n' >"$project/main.zag"
for _ in $(seq 1 800); do
    if grep -q "^last_file=$project/main.zag$" "$project/.zagd.status" 2>/dev/null &&
       grep -q '^semantic_validation=validated$' "$project/.zagd.status" 2>/dev/null; then
        break
    fi
    kill -0 "$daemon_pid" 2>/dev/null || {
        sed 's/^/  /' "$tmp/zagd.log" >&2
        echo 'zagd idle cpu: daemon exited while processing source edit' >&2
        exit 1
    }
    sleep 0.01
done
grep -q "^last_file=$project/main.zag$" "$project/.zagd.status"
grep -q '^semantic_validation=validated$' "$project/.zagd.status"
events_after_source=$(sed -n 's/^events=//p' "$project/.zagd.status")
test "$events_after_source" -eq $((events_before_source + 1))

# Allow every queued inotify hint to drain. The internal marker must remain
# absent, status must remain source-owned, and CPU must return to the timed poll.
sleep 1
test ! -e "$project/.zagd.semantic-ready"
grep -q "^last_file=$project/main.zag$" "$project/.zagd.status"
test "$(sed -n 's/^events=//p' "$project/.zagd.status")" = "$events_after_source"
ticks_before=$(awk '{ print $14 + $15 }' "/proc/$daemon_pid/stat")
sleep 2
ticks_after=$(awk '{ print $14 + $15 }' "/proc/$daemon_pid/stat")
idle_ticks=$((ticks_after - ticks_before))
if [ "$idle_ticks" -gt 4 ]; then
    echo "zagd idle cpu: adaptive daemon consumed $idle_ticks CPU ticks while quiet" >&2
    exit 1
fi

printf 'stop\n' >"$project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
grep -q '^state=stopped$' "$project/.zagd.status"

echo "zagd idle cpu: pass self_events=0 idle_ticks=$idle_ticks"
