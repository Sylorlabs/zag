#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

# Permit a freshly built compiler to exercise the current daemon source
# without replacing the checked-in product binary.  The default remains the
# repository product used by the ordinary release gate.
compiler=${ZNC:-./znc}

tmp=$(mktemp -d /tmp/zagd-daemon.XXXXXX)
cleanup_pid() {
    local pid="${1:-}"
    [ -n "$pid" ] || return 0
    for _ in $(seq 1 100); do
        kill -0 "$pid" 2>/dev/null || return 0
        sleep 0.01
    done
    kill "$pid" 2>/dev/null || true
    wait "$pid" 2>/dev/null || true
}
cleanup() {
    # Request graceful shutdown before removing watched roots.  A failed
    # assertion may otherwise delete the project while a daemon is still
    # publishing its status/cache files.
    for stop in "$tmp/project/.zagd.stop" "$tmp/planner-project/.zagd.stop" "$tmp/script-planner-project/.zagd.stop" "$tmp/self-delete/.zagd.stop"; do
        if [ -d "$(dirname "$stop")" ]; then printf 'stop\n' > "$stop" 2>/dev/null || true; fi
    done
    cleanup_pid "${daemon_pid:-}"
    cleanup_pid "${child_pid:-}"
    rm -rf "$tmp"
}
trap cleanup EXIT

"$compiler" tests/zagd_linux_test.zag -o "$tmp/linux-test" --no-analyze >/dev/null
"$tmp/linux-test"
"$compiler" selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-analyze >/dev/null
# `zagd_semantic_check` intentionally resolves its compiler beside the daemon
# executable.  Keep this fixture layout faithful to the installed pair so an
# event can republish a complete semantic graph rather than fail closed solely
# because the test omitted the sibling compiler.
cp "$compiler" "$tmp/znc"
"$compiler" tests/zagd_semantic_fixture.zag -o "$tmp/semantic-fixture" --no-analyze >/dev/null

mkdir "$tmp/project"
mkdir -p "$tmp/project/.zag-cache/zagd"
# Mark the fixture as its own project.  The compiler walks ancestor
# directories when locating zag.mod/.zagd.conf; a shared /tmp/zag.mod from
# another test lane must not redirect semantic publication outside this
# watched root.
printf 'mode=light\n' > "$tmp/project/.zagd.conf"
printf 'pub fn api(x:i32) i32 { return x; }\n' > "$tmp/project/app.zag"
"$tmp/semantic-fixture" "$tmp/project/app.zag" "$tmp/project/.zag-cache/zagd/semantic.record"
printf '999999999\n' > "$tmp/project/.zagd.lock"
"$tmp/zagd" --root "$tmp/project" --mode off
test ! -e "$tmp/project/.zagd.lock"
"$tmp/zagd" --root "$tmp/project" --mode light \
    --idle-deep false --difficulty native \
    --script-optimization review --regular-optimization automatic \
    --objective runtime --trust-mode autonomous --cpu generic \
    --window-ms 31 --max-memory-bytes 1073741824 \
    --max-cache-bytes 104857600 --max-workers 1 \
    --notifications errors_only &
daemon_pid=$!

for _ in $(seq 1 200); do
    [ -f "$tmp/project/.zagd.status" ] &&
        grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null &&
        grep -q "^pid=$daemon_pid$" "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=idle$' "$tmp/project/.zagd.status"
grep -q '^mode=light$' "$tmp/project/.zagd.status"
grep -q '^idle_deep=false$' "$tmp/project/.zagd.status"
grep -q '^difficulty=native$' "$tmp/project/.zagd.status"
grep -q '^script_optimization=review$' "$tmp/project/.zagd.status"
grep -q '^regular_optimization=automatic$' "$tmp/project/.zagd.status"
grep -q '^objective=runtime$' "$tmp/project/.zagd.status"
grep -q '^trust_mode=autonomous$' "$tmp/project/.zagd.status"
grep -q '^cpu=generic$' "$tmp/project/.zagd.status"
grep -q '^stability_window_ms=31$' "$tmp/project/.zagd.status"
grep -q '^max_memory_bytes=1073741824$' "$tmp/project/.zagd.status"
grep -q '^max_cache_bytes=104857600$' "$tmp/project/.zagd.status"
grep -q '^max_workers=1$' "$tmp/project/.zagd.status"
grep -q '^notifications=errors_only$' "$tmp/project/.zagd.status"
grep -q '^trust_mode_scope=policy-only$' "$tmp/project/.zagd.status"
grep -q '^optimizer_generation=unimplemented$' "$tmp/project/.zagd.status"
grep -q '^network=false$' "$tmp/project/.zagd.status"
grep -q '^gpu_background=false$' "$tmp/project/.zagd.status"
grep -q '^watcher=inotify$' "$tmp/project/.zagd.status"
grep -q '^watcher_health=ok$' "$tmp/project/.zagd.status"
grep -q '^cache_bytes=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^cache_eviction=within-limit$' "$tmp/project/.zagd.status"
grep -q '^cache_bytes_before_trim=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^cache_bytes_after_trim=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^allocator_allocation_count=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^allocator_live_bytes=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^allocator_peak_live_bytes=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^snapshot_root_module_first=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^snapshot_root_source_first=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^snapshot_semantic_graph_first=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^snapshot_semantic_graph_complete=1$' "$tmp/project/.zagd.status"
grep -q '^snapshot_timestamp_ms=[0-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"
grep -q '^semantic_validation=restored$' "$tmp/project/.zagd.status"
grep -q '^planner_cancellations=0$' "$tmp/project/.zagd.status"
snapshot_record="$tmp/project/.zag-cache/zagd/snapshot.record"
grep -q '^format=zagd-snapshot-v2$' "$snapshot_record"
grep -q '^complete=true$' "$snapshot_record"
grep -q '^validity=valid$' "$snapshot_record"
grep -q '^root_module_present=1$' "$snapshot_record"
grep -q '^root_module=app.zag$' "$snapshot_record"
grep -Eq '^root_project=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$snapshot_record"
grep -Eq '^root_source=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$snapshot_record"
grep -Eq '^semantic_graph=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$snapshot_record"
grep -q '^semantic_graph_complete=1$' "$snapshot_record"
grep -Eq '^timestamp_ms=[0-9]+$' "$snapshot_record"
grep -q '^timestamp_basis=linux-monotonic-ms$' "$snapshot_record"
grep -q '^timestamp_in_identity=false$' "$snapshot_record"
grep -Eq '^snapshot_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$snapshot_record"
grep -Eq '^parent_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$snapshot_record"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^basis=proven-manifest-facts$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^performance_benefit=unknown$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^equivalence=canonical-literal-or-bounded-integer-arithmetic-return$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^cpu_profile=x86-64-v1$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^target_cache_key=linux-x86_64|x86-64-v1|sse2$' "$tmp/project/.zag-cache/zagd/plan.record"

printf 'one\n' > "$tmp/project/app.zag"
for _ in $(seq 1 100); do
    grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q 'last_file=.*/app.zag$' "$tmp/project/.zagd.status"
grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"
grep -q '^semantic_validation=failed$' "$tmp/project/.zagd.status"
grep -Eq '^planner_cancellations=[1-9][0-9]*$' "$tmp/project/.zagd.status"
grep -q '^root_module=app.zag$' "$snapshot_record"
grep -q $'^semantic_graph=216613626\t131542391\t0$' "$snapshot_record"
grep -q '^semantic_graph_complete=0$' "$snapshot_record"
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

# The target key is planner/cache identity only.  Native discovery may select
# already implemented POPCNT/BMI1 plans, but never changes foreground build
# authority or permits unimplemented SIMD.
"$tmp/zagd" --root "$tmp/project" --mode light --cpu native &
daemon_pid=$!
for _ in $(seq 1 100); do
    grep -q '^cpu_detection=cpuid-xgetbv$' "$tmp/project/.zag-cache/zagd/plan.record" 2>/dev/null && break
    sleep 0.01
done
grep -q '^cpu_detection=cpuid-xgetbv$' "$tmp/project/.zag-cache/zagd/plan.record"
grep -q '^target_cache_key=linux-x86_64|native|permitted=sse2' "$tmp/project/.zag-cache/zagd/plan.record"
"$tmp/zagd" --root "$tmp/project" --mode off
wait "$daemon_pid"
daemon_pid=

if "$tmp/zagd" --root "$tmp/project" --cpu no-such-cpu >/dev/null 2>&1; then
    echo "unknown CPU profile unexpectedly accepted" >&2
    exit 1
fi

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
assert_usage_rc4() {
    local label=$1
    shift
    set +e
    "$tmp/zagd" --root "$tmp/project" "$@" >"$tmp/$label.out" 2>&1
    local rc=$?
    set -e
    if [[ $rc -ne 4 ]]; then
        printf '%s returned %s instead of fail-closed usage status 4\n' \
            "$label" "$rc" >&2
        return 1
    fi
}
assert_usage_rc4 invalid-trust-mode --trust-mode unsafe
grep -q 'trust_mode must be stable, reviewed, or autonomous' \
    "$tmp/invalid-trust-mode.out"
assert_usage_rc4 incomplete-policy-argument --difficulty
grep -q 'unknown or incomplete argument: --difficulty' \
    "$tmp/incomplete-policy-argument.out"
assert_usage_rc4 unknown-policy-argument --unknown-policy value
grep -q 'unknown or incomplete argument: --unknown-policy' \
    "$tmp/unknown-policy-argument.out"

# Foreground machine payloads share the daemon's configured project cache
# ceiling. A sparse oversized payload must be sized with stat and evicted as a
# unit; the daemon must not read/allocate the payload merely to count it.
mkdir -p "$tmp/project/.zag-cache/foreground"
printf 'record\n' >"$tmp/project/.zag-cache/foreground/machine.record"
truncate -s 2097152 "$tmp/project/.zag-cache/foreground/machine.code"
printf 'data\n' >"$tmp/project/.zag-cache/foreground/machine.data"
child_pid=$("$tmp/zagd" --root "$tmp/project" --mode adaptive --window-ms 20 --max-cache-bytes 1048576 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^mode=adaptive$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=idle$' "$tmp/project/.zagd.status"
grep -q '^mode=adaptive$' "$tmp/project/.zagd.status"
grep -q '^cache_reused=false$' "$tmp/project/.zagd.status"
test ! -e "$tmp/project/.zag-cache/foreground/machine.record"
test ! -e "$tmp/project/.zag-cache/foreground/machine.code"
test ! -e "$tmp/project/.zag-cache/foreground/machine.data"
grep -q '^cache_eviction=trimmed$' "$tmp/project/.zagd.status"
test "$(sed -n 's/^cache_bytes_after_trim=//p' "$tmp/project/.zagd.status")" -le 1048576
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

# Candidate reporting is exercised in its own valid semantic project so this
# assertion does not change the watcher/index history below.
mkdir -p "$tmp/planner-project/.zag-cache/zagd"
printf 'pub fn api(x:i32) i32 { return x; }\n' > "$tmp/planner-project/app.zag"
"$tmp/semantic-fixture" "$tmp/planner-project/app.zag" "$tmp/planner-project/.zag-cache/zagd/semantic.record"
"$tmp/zagd" --root "$tmp/planner-project" --mode deep --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 100); do
    test -f "$tmp/planner-project/.zag-cache/zagd/candidates.record" &&
        grep -q '^state=idle$' "$tmp/planner-project/.zagd.status" 2>/dev/null &&
        grep -q "^pid=$daemon_pid$" "$tmp/planner-project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
candidate_record="$tmp/planner-project/.zag-cache/zagd/candidates.record"
test -f "$candidate_record"
grep -q '^state=idle$' "$tmp/planner-project/.zagd.status"
grep -q "^pid=$daemon_pid$" "$tmp/planner-project/.zagd.status"
grep -q '^format=zagd-candidates-v2$' "$candidate_record"
grep -q '^source_changes=false$' "$candidate_record"
grep -q '^selection=unsupported-roadmap-alternatives$' "$candidate_record"
grep -q '^semantic_identity=[0-9][0-9]*[[:blank:]][0-9][0-9]*[[:blank:]][0-9][0-9]*$' "$candidate_record"
grep -q '^generated=5$' "$candidate_record"
grep -q '^finalists=0$' "$candidate_record"
test "$(grep -c $'^candidate=.*\tautomatic=0\tsupported=0\tequivalent=0\t' "$candidate_record")" -eq 5
grep -q $'^candidate=31\t.*rejected_reason=parallel execution and ordering equivalence are not implemented\t' "$candidate_record"
grep -q $'^candidate=41\t.*rejected_reason=physical GPU dispatch and device equivalence validation are not implemented\t' "$candidate_record"
printf stop > "$tmp/planner-project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=

# The supported deep candidate is deliberately narrow: a Script root with an
# unspecified CPU inherits the already compiler-applied, target-qualified
# project default.  This records no source rewrite and no daemon foreground
# authority.  A regular Zag root above still receives only roadmap rejections.
mkdir -p "$tmp/script-planner-project/.zag-cache/zagd"
printf 'script;\npub fn api(x:i32) i32 { return x; }\n' > "$tmp/script-planner-project/app.zag"
printf 'cpu=generic\n' > "$tmp/script-planner-project/.zagd.conf"
"$tmp/semantic-fixture" "$tmp/script-planner-project/app.zag" "$tmp/script-planner-project/.zag-cache/zagd/semantic.record"
"$tmp/zagd" --root "$tmp/script-planner-project" --mode deep --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 100); do
    test -f "$tmp/script-planner-project/.zag-cache/zagd/candidates.record" &&
        grep -q '^state=idle$' "$tmp/script-planner-project/.zagd.status" 2>/dev/null &&
        grep -q "^pid=$daemon_pid$" "$tmp/script-planner-project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
script_candidate_record="$tmp/script-planner-project/.zag-cache/zagd/candidates.record"
test -f "$script_candidate_record"
grep -q '^state=idle$' "$tmp/script-planner-project/.zagd.status"
grep -q "^pid=$daemon_pid$" "$tmp/script-planner-project/.zagd.status"
grep -q '^selection=script-default-cpu$' "$script_candidate_record"
grep -q '^generated=5$' "$script_candidate_record"
grep -q '^finalists=1$' "$script_candidate_record"
grep -q $'^candidate=51\tautomatic=1\tsupported=1\tequivalent=1\tprovenance=derived\tevidence_basis=derived\tvalidity=Script root; no foreground --cpu override; project CPU default matches active target; znc validates it before lowering\trejected_reason=\truntime_ns=0\tmemory_bytes=0$' "$script_candidate_record"
test "$(grep -c $'^candidate=.*\tautomatic=0\tsupported=0\tequivalent=0\tprovenance=unknown\t' "$script_candidate_record")" -eq 4
printf stop > "$tmp/script-planner-project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=

# Direct daemon policy is argv-only: znc is the authority that parses project
# configuration and transports it. Prove a transported native CPU overrides a
# stale on-disk generic value instead of the daemon silently rereading config.
"$tmp/zagd" --root "$tmp/script-planner-project" --mode deep --window-ms 20 \
    --cpu native &
daemon_pid=$!
for _ in $(seq 1 100); do
    test -f "$tmp/script-planner-project/.zag-cache/zagd/candidates.record" &&
        grep -q '^selection=script-default-cpu$' "$tmp/script-planner-project/.zag-cache/zagd/candidates.record" 2>/dev/null &&
        grep -q '^state=idle$' "$tmp/script-planner-project/.zagd.status" 2>/dev/null &&
        grep -q "^pid=$daemon_pid$" "$tmp/script-planner-project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=idle$' "$tmp/script-planner-project/.zagd.status"
grep -q "^pid=$daemon_pid$" "$tmp/script-planner-project/.zagd.status"
grep -q '^cpu=native$' "$tmp/script-planner-project/.zagd.status"
grep -q '^selection=script-default-cpu$' "$tmp/script-planner-project/.zag-cache/zagd/candidates.record"
grep -q $'^candidate=51\tautomatic=1\tsupported=1\tequivalent=1\tprovenance=derived\tevidence_basis=derived\tvalidity=Script root; no foreground --cpu override; project CPU default matches active target; znc validates it before lowering\trejected_reason=\truntime_ns=0\tmemory_bytes=0$' "$tmp/script-planner-project/.zag-cache/zagd/candidates.record"
printf stop > "$tmp/script-planner-project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=

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
grep -q '^format=zagd-artifact-index-v2$' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^foreground_machine_cache_authority=false$' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^compiler=' "$tmp/project/.zag-cache/zagd/artifact.record"
grep -q '^target=linux-x86_64-generic$' "$tmp/project/.zag-cache/zagd/artifact.record"
cp "$tmp/project/.zag-cache/zagd/snapshot.record" "$tmp/snapshot.before-duplicate"
cp "$tmp/project/.zag-cache/zagd/plan.record" "$tmp/plan.before-duplicate"
cp "$tmp/project/.zag-cache/zagd/artifact.record" "$tmp/artifact.before-duplicate"
if "$tmp/zagd" --root "$tmp/project" --mode light >/dev/null 2>&1; then
    echo "duplicate daemon unexpectedly started" >&2; exit 1
fi
cmp "$tmp/snapshot.before-duplicate" "$tmp/project/.zag-cache/zagd/snapshot.record"
cmp "$tmp/plan.before-duplicate" "$tmp/project/.zag-cache/zagd/plan.record"
cmp "$tmp/artifact.before-duplicate" "$tmp/project/.zag-cache/zagd/artifact.record"

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

child_pid=$("$tmp/zagd" --root "$tmp/project" --root-source reuse.zag --mode adaptive --window-ms 20 --daemonize)
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
for _ in $(seq 1 200); do
    grep -q '^semantic_graph_complete=1$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^semantic_graph_complete=1$' "$tmp/project/.zagd.status"
grep -q '^graph_complete=1$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^graph_complete=1$' "$tmp/project/.zag-cache/zagd/incremental.record"
grep -q '^root_module=reuse.zag$' "$tmp/project/.zag-cache/zagd/snapshot.record"
grep -q '^semantic_graph_complete=1$' "$tmp/project/.zag-cache/zagd/snapshot.record"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^state=stopped$' "$tmp/project/.zagd.status"

child_pid=$("$tmp/zagd" --root "$tmp/project" --root-source reuse.zag --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^cache_reused=true$' "$tmp/project/.zagd.status"
grep -q '^incremental_cache_reused=true$' "$tmp/project/.zagd.status"
grep -q '^root_module=reuse.zag$' "$tmp/project/.zag-cache/zagd/snapshot.record"
grep -q '^semantic_graph_complete=1$' "$tmp/project/.zag-cache/zagd/snapshot.record"
test -f "$tmp/project/.zag-cache/zagd/incremental.record"
grep -q '^format=zagd-incremental-index-v2$' "$tmp/project/.zag-cache/zagd/incremental.record"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/incremental.record"
if ! grep -Eq '^file=.*/reuse\.zag[[:blank:]]' "$tmp/project/.zag-cache/zagd/incremental.record" ||
   ! grep -Eq '^file=.*/classify\.zag[[:blank:]]' "$tmp/project/.zag-cache/zagd/incremental.record" ||
   ! grep -Eq '^decl=.*/reuse\.zag[[:blank:]]api[[:blank:]]' "$tmp/project/.zag-cache/zagd/incremental.record"; then
    echo "incremental restart record is missing a required file or declaration fingerprint" >&2
    sed -n '1,80p' "$tmp/project/.zag-cache/zagd/incremental.record" >&2
    exit 1
fi
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
child_pid=$("$tmp/zagd" --root "$tmp/project" --root-source reuse.zag --mode adaptive --window-ms 20 --daemonize)
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
child_pid=$("$tmp/zagd" --root "$tmp/project" --root-source reuse.zag --mode adaptive --window-ms 20 --daemonize)
test "$child_pid" -gt 1
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^cache_reused=false$' "$tmp/project/.zagd.status"
grep -q '^incremental_cache_reused=false$' "$tmp/project/.zagd.status"
grep -q '^incremental_invalidation=unknown$' "$tmp/project/.zagd.status"
# A corrupt advisory snapshot is rebuilt from a bounded stable source scan;
# the replacement must contain the live source set rather than an empty index.
grep -Eq '^file=reuse\.zag[[:blank:]]' "$tmp/project/.zag-cache/zagd/snapshot.record"
grep -Eq '^file=classify\.zag[[:blank:]]' "$tmp/project/.zag-cache/zagd/snapshot.record"
printf stop > "$tmp/project/.zagd.stop"
for _ in $(seq 1 100); do
    grep -q '^state=stopped$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done

# A short-lived/generated project must not leave a blocked watcher after its
# root disappears. This is the cleanup path used by compiler test harnesses.
mkdir "$tmp/self-delete"
"$tmp/zagd" --root "$tmp/self-delete" --mode light --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 100); do
    test -f "$tmp/self-delete/.zagd.status" && break
    sleep 0.01
done
test -f "$tmp/self-delete/.zagd.status"
rm -rf "$tmp/self-delete"
for _ in $(seq 1 100); do
    if ! kill -0 "$daemon_pid" 2>/dev/null; then break; fi
    sleep 0.01
done
if kill -0 "$daemon_pid" 2>/dev/null; then
    echo "daemon remained alive after watched root deletion" >&2
    exit 1
fi
wait "$daemon_pid" || true
daemon_pid=

echo "zagd daemon: pass"
