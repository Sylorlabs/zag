#!/usr/bin/env bash
# Long-running daemon resource regression: repeated stable edits must not kill
# the watcher, grow without a bound, busy-loop while idle, or exceed its cache
# policy. This is a product test, not a microbenchmark.
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-"$(pwd)/znc"}
daemon_source=${ZAGD:-"$(pwd)/zagd"}
memory_bytes=${ZAGD_STRESS_MEMORY_BYTES:-134217728}
tmp=$(mktemp -d /tmp/zag-zagd-memory.XXXXXX)
project="$tmp/project"
mkdir -p "$tmp/bin"
cp "$daemon_source" "$tmp/bin/zagd"
chmod +x "$tmp/bin/zagd"
daemon="$tmp/bin/zagd"
daemon_pid=
daemon_log="$tmp/zagd.log"
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; wait "$daemon_pid" 2>/dev/null || true; fi; find "$tmp" -depth -delete 2>/dev/null || true' EXIT HUP INT TERM

mkdir -p "$project"
printf '[package]\nname = "zagd-memory-stress"\nversion = "0.0.1"\n' >"$project/zag.mod"
printf 'fn main() i32 { return 0; }\n' >"$project/main.zag"

"$daemon" --root "$project" --root-source "$project/main.zag" \
    --mode light --window-ms 5 --max-memory-bytes "$memory_bytes" \
    --max-cache-bytes 16777216 --notifications errors_only \
    >"$daemon_log" 2>&1 &
daemon_pid=$!

for _ in $(seq 1 400); do
    if [ -s "$project/.zagd.lock" ] && [ -s "$project/.zagd.status" ]; then
        break
    fi
    sleep 0.01
done
lock_pid=$(sed -n '1p' "$project/.zagd.lock")
case $lock_pid in *[!0-9]*|'') echo "zagd memory stress: no daemon identity" >&2; exit 1;; esac
if [ "$lock_pid" -ne "$daemon_pid" ]; then
    echo "zagd memory stress: lock identity does not name supervised daemon" >&2
    exit 1
fi
kill -0 "$daemon_pid"

daemon_failed() {
    status=0
    if wait "$daemon_pid"; then status=0; else status=$?; fi
    echo "zagd memory stress: daemon exited unexpectedly (status=$status)" >&2
    if [ -s "$daemon_log" ]; then sed 's/^/  /' "$daemon_log" >&2; fi
    daemon_pid=
    exit 1
}

read_rss() {
    if ! kill -0 "$daemon_pid" 2>/dev/null || [ ! -r "/proc/$daemon_pid/status" ]; then
        daemon_failed
    fi
    awk '/^VmRSS:/ { print $2 }' "/proc/$daemon_pid/status"
}

read_allocator_live() {
    if ! kill -0 "$daemon_pid" 2>/dev/null || [ ! -r "/proc/$daemon_pid/status" ]; then
        daemon_failed
    fi
    value=$(sed -n 's/^allocator_live_bytes=//p' "$project/.zagd.status")
    case $value in
        *[!0-9]*|'')
            echo "zagd memory stress: invalid allocator live-byte witness" >&2
            exit 1
            ;;
    esac
    printf '%s\n' "$value"
}

wait_for_hash_change() {
    before=$1
    for _ in $(seq 1 500); do
        after=$(sed -n 's/^content_hash_first=//p' "$project/.zagd.status" 2>/dev/null || true)
        state=$(sed -n 's/^planner_state=//p' "$project/.zagd.status" 2>/dev/null || true)
        if [ -n "$after" ] && [ "$after" != "$before" ] && [ "$state" = complete ]; then
            return 0
        fi
        kill -0 "$daemon_pid" 2>/dev/null || daemon_failed
        sleep 0.01
    done
    echo "zagd memory stress: final stable snapshot was not published" >&2
    return 1
}

run_wave() {
    first=$1
    last=$2
    before=$(sed -n 's/^content_hash_first=//p' "$project/.zagd.status")
    index=$first
    while [ "$index" -le "$last" ]; do
        # Atomic-save shape used by editors, formatters, and patch agents.
        printf 'fn main() i32 { return %s - %s; }\n// stable edit %s\n' \
            "$index" "$index" "$index" >"$project/.main.zag.tmp"
        mv "$project/.main.zag.tmp" "$project/main.zag"
        # Give the watcher enough time to process many distinct valid states;
        # occasional event coalescing is allowed and correctness uses hashes.
        sleep 0.007
        index=$((index + 1))
    done
    wait_for_hash_change "$before"
}

run_wave 1 300
rss_after_first=$(read_rss)
live_after_first=$(read_allocator_live)
printf 'ready\n' >"$project/.zagd.semantic-ready"
sleep 0.1
run_wave 301 600
rss_after_second=$(read_rss)
live_after_second=$(read_allocator_live)
printf 'ready\n' >"$project/.zagd.semantic-ready"
sleep 0.1
run_wave 601 900
rss_after_third=$(read_rss)
live_after_third=$(read_allocator_live)
case "$rss_after_first:$rss_after_second:$rss_after_third" in
    *[!0-9:]*|:*|*:) echo "zagd memory stress: invalid RSS witness" >&2; exit 1 ;;
esac

# RLIMIT_AS/cgroup policy is the hard boundary.  After the first warm-up wave,
# each additional 300-edit wave may retain at most 2 MiB of allocator/page
# noise.  This deliberately rejects the earlier ~10 MiB-per-wave leak rather
# than waiting for the 128 MiB service limit to kill the daemon.
if [ "$rss_after_second" -gt $((rss_after_first + 2048)) ]; then
    echo "zagd memory stress: RSS trend ${rss_after_first} -> ${rss_after_second} -> ${rss_after_third} KiB" >&2
    exit 1
fi
if [ "$rss_after_third" -gt $((rss_after_second + 2048)) ]; then
    echo "zagd memory stress: RSS trend ${rss_after_first} -> ${rss_after_second} -> ${rss_after_third} KiB" >&2
    exit 1
fi
if [ "$rss_after_third" -gt 65536 ]; then
    echo "zagd memory stress: RSS ${rss_after_third} KiB exceeds 64 MiB steady-state budget" >&2
    exit 1
fi

# Logical live bytes should plateau after warm-up. Allow one small
# status/manifest size-class transition, but reject event-proportional
# retained payloads even when allocator arenas keep RSS below the hard cap.
if [ "$live_after_second" -gt $((live_after_first + 65536)) ] ||
   [ "$live_after_third" -gt $((live_after_second + 65536)) ]; then
    echo "zagd memory stress: allocator live-byte trend ${live_after_first} -> ${live_after_second} -> ${live_after_third}" >&2
    exit 1
fi

# Once stable, the event-driven daemon should consume at most a scheduling
# tick or two instead of polling the source tree.
ticks_before=$(awk '{ print $14 + $15 }' "/proc/$daemon_pid/stat")
sleep 1
ticks_after=$(awk '{ print $14 + $15 }' "/proc/$daemon_pid/stat")
if [ $((ticks_after - ticks_before)) -gt 2 ]; then
    echo "zagd memory stress: idle daemon consumed $((ticks_after - ticks_before)) CPU ticks" >&2
    exit 1
fi

cache_bytes=$(du -sb "$project/.zag-cache" | awk '{ print $1 }')
case $cache_bytes in *[!0-9]*|'') echo "zagd memory stress: invalid cache-size witness" >&2; exit 1;; esac
if [ "$cache_bytes" -gt 16777216 ]; then
    echo "zagd memory stress: cache policy exceeded: $cache_bytes bytes" >&2
    exit 1
fi

"$daemon" --root "$project" --mode off --window-ms 5 \
    --max-memory-bytes "$memory_bytes" --max-cache-bytes 16777216 \
    --notifications errors_only >/dev/null
for _ in $(seq 1 300); do
    if [ ! -e "$project/.zagd.lock" ]; then break; fi
    sleep 0.01
done
test ! -e "$project/.zagd.lock"
wait "$daemon_pid"
daemon_pid=

echo "zagd memory stress: pass edits=900 rss_first_kib=$rss_after_first rss_second_kib=$rss_after_second rss_third_kib=$rss_after_third live_first_bytes=$live_after_first live_second_bytes=$live_after_second live_third_bytes=$live_after_third cache_bytes=$cache_bytes"
