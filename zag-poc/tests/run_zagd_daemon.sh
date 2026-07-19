#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagd-daemon.XXXXXX)
trap 'if [ -n "${daemon_pid:-}" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT

./znc tests/zagd_linux_test.zag -o "$tmp/linux-test" --no-analyze >/dev/null
"$tmp/linux-test"
./znc selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-analyze >/dev/null
./znc tests/zagd_semantic_fixture.zag -o "$tmp/semantic-fixture" --no-analyze >/dev/null

mkdir "$tmp/project"
mkdir -p "$tmp/project/.zag-cache/zagd"
printf 'pub fn api(x:i32) i32 { return x; }\n' > "$tmp/project/app.zag"
"$tmp/semantic-fixture" "$tmp/project/app.zag" "$tmp/project/.zag-cache/zagd/semantic.record"
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
grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^basis=proven-manifest-facts$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^performance_benefit=unknown$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^equivalence=canonical-literal-or-bounded-integer-arithmetic-return$' "$tmp/project/.zag-cache/zagd/plan.record"

printf 'one\n' > "$tmp/project/app.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status"
grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"
first=$(grep '^content_hash_first=' "$tmp/project/.zagd.status")

printf 'two\n' > "$tmp/project/app.zag"
for _ in $(seq 1 100); do
    now=$(grep '^content_hash_first=' "$tmp/project/.zagd.status" 2>/dev/null || true)
    [ "$now" != "$first" ] && break
    sleep 0.01
done
test "$(grep '^content_hash_first=' "$tmp/project/.zagd.status")" != "$first"

printf '// comment only\ntwo\n' > "$tmp/project/app.zag"
for _ in $(seq 1 100); do
    grep -q '^last_change=nonsemantic$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^last_change=nonsemantic$' "$tmp/project/.zagd.status"

printf 'fn local() i32 { return 1; }\n' > "$tmp/project/classify.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/classify.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
printf 'fn local() i32 { return 2; }\n' > "$tmp/project/classify.zag"
for _ in $(seq 1 100); do
    grep -q '^last_change=private-body$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^last_change=private-body$' "$tmp/project/.zagd.status"

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
if "$tmp/zagd" --root "$tmp/project" --max-cache-bytes 100 >/dev/null 2>&1; then
    echo "invalid cache limit unexpectedly accepted" >&2
    exit 1
fi

child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --max-cache-bytes 1048576 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^mode=adaptive$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=idle$' "$tmp/project/.zagd.status"
grep -q '^mode=adaptive$' "$tmp/project/.zagd.status"
grep -q '^cache_reused=false$' "$tmp/project/.zagd.status"
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
grep -q '^planner_budget=256$' "$tmp/project/.zagd.status"
grep -q '^planner_suggestions=0$' "$tmp/project/.zagd.status"
grep -q '^planner_state=complete$' "$tmp/project/.zagd.status"
test -f "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^format=zagd-artifact-index-v1$' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^compiler=' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^target=linux-x86_64-generic$' "$tmp/project/.zag-cache/zagd/artifact.record"
test -f "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^format=zagd-candidates-v1$' "$tmp/project/.zag-cache/zagd/candidates.record"
grep -q '^source_changes=false$' "$tmp/project/.zag-cache/zagd/candidates.record"
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
grep -q '^cache_reused=false$' "$tmp/project/.zagd.status"
printf 'pub fn api(x:i32) i32 { return x; }\n' > "$tmp/project/reuse.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/reuse.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^cache_reused=true$' "$tmp/project/.zagd.status"
grep -q '^incremental_cache_reused=true$' "$tmp/project/.zagd.status"
test -f "$tmp/project/.zag-cache/zagd/incremental.record"
grep -q '^format=zagd-incremental-v1$' "$tmp/project/.zag-cache/zagd/incremental.record"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/incremental.record"
before_restart=$(grep '^events=' "$tmp/project/.zagd.status")
printf 'pub fn api(x:i32) i32 { return x; }\n' > "$tmp/project/reuse.zag"
sleep 0.15
test "$(grep '^events=' "$tmp/project/.zagd.status")" = "$before_restart"
printf 'pub fn api(x:i64) i64 { return x; }\n' > "$tmp/project/reuse.zag"
for _ in $(seq 1 100); do
    grep -q '^last_change=public-shape$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^last_change=public-shape$' "$tmp/project/.zagd.status"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done

# A file changed while the daemon was stopped invalidates the restored index.
printf 'pub fn api(x:i64) i64 { return x + 1; }\n' > "$tmp/project/reuse.zag"
child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^cache_reused=false$' "$tmp/project/.zagd.status"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done

# Corrupt advisory state is a cache miss, never a startup or correctness error.
printf 'corrupt\n' > "$tmp/project/.zag-cache/zagd/snapshot.record"
printf 'corrupt\n' > "$tmp/project/.zag-cache/zagd/incremental.record"
child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^cache_reused=false$' "$tmp/project/.zagd.status"
grep -q '^incremental_cache_reused=false$' "$tmp/project/.zagd.status"
grep -q '^incremental_invalidation=unknown$' "$tmp/project/.zagd.status"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done

echo "zagd daemon: pass"
