#!/usr/bin/env bash
set -euo pipefail

compiler="${ZNC:-./znc}"
case "$compiler" in /*) ;; *) compiler="$(pwd)/${compiler#./}" ;; esac
work="$(mktemp -d)"
cleanup() {
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "foreground cache integration failed; retained command diagnostics:" >&2
        for log in "$work"/*.log "$work"/*.err; do
            [ -f "$log" ] || continue
            echo "── $(basename "$log")" >&2
            sed -n '1,80p' "$log" >&2
        done
    fi
    trap - EXIT
    rm -rf -- "$work"
    exit "$rc"
}
trap cleanup EXIT

cat >"$work/dep.zag" <<'EOF'
fn cached_value() i32 { return 42; }
EOF
cat >"$work/main.zag" <<'EOF'
@import("dep.zag")
fn main() i32 { return cached_value(); }
EOF

cd "$work"
expect_exit() {
    expected=$1
    binary=$2
    set +e
    "$binary"
    actual=$?
    set -e
    test "$actual" -eq "$expected"
}

expect_miss_equivalent() {
    name=$1
    "$compiler" main.zag -o "$name" --cache-report --no-zagd >"$name.log"
    grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
        "$name.log"
    expect_exit 42 "./$name"
    cmp fresh-app "$name"
}

"$compiler" main.zag -o fresh-app --cache-report --no-zagd \
    --no-foreground-cache >fresh.log
grep -q 'znc cache: MISS cache unavailable; lowering_calls=1' fresh.log
expect_exit 42 ./fresh-app

"$compiler" main.zag -o app --cache-report --no-zagd >cold.log
grep -q 'znc cache: MISS stored machine code and data' cold.log
grep -q 'lowering_calls=1' cold.log
grep -q '^format=zag-foreground-machine-cache-v4$' \
    .zag-cache/foreground/machine.record
grep -q '^compiler_version=' .zag-cache/foreground/machine.record
grep -q '^project_root=' .zag-cache/foreground/machine.record
grep -q '^semantic_graph=' .zag-cache/foreground/machine.record
grep -q '^policy=' .zag-cache/foreground/machine.record
expect_exit 42 ./app
cmp fresh-app app

"$compiler" main.zag -o warm-app --cache-report --no-zagd >warm.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' warm.log
grep -q 'lowering_calls=0 payload_substituted=true code=' warm.log
grep -q ' data=' warm.log
expect_exit 42 ./warm-app
cmp fresh-app warm-app

# Comment/formatting-only rewrites preserve the token identity and therefore
# reuse the exact validated payload for both root and imported modules.
printf '\n// root comment-only edit\n' >>main.zag
printf '\n// dependency comment-only edit\n' >>dep.zag
"$compiler" main.zag -o comment-app --cache-report --no-zagd >comment.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' comment.log
grep -q 'lowering_calls=0 payload_substituted=true' comment.log
expect_exit 42 ./comment-app
cmp fresh-app comment-app

# The cache stores only the already-encoded main code/data blob. Static archive
# merging remains a fresh, self-hosted foreground link step. Use a copied glibc
# archive only as an input fixture: `znc` itself parses/merges it without cc,
# as, ld, or ar. The uncalled extern causes one real archive member to be
# selected, while main remains a simple executable witness. Some minimal Linux
# environments omit development archives, so report that as an explicit skip
# rather than pretending this optional platform fixture was exercised.
static_fixture=""
for candidate in /usr/lib/x86_64-linux-gnu/libm-*.a /lib/x86_64-linux-gnu/libm-*.a; do
    if [ -f "$candidate" ]; then
        static_fixture=$candidate
        break
    fi
done
if [ -n "$static_fixture" ]; then
    mkdir -p "$work/lib"
    cp "$static_fixture" "$work/lib/libcachefixture.a"
    cat >linked-cache.zag <<'EOF'
@link("cachefixture");
extern fn feclearexcept(mask: i32) i32;
fn main() i32 { return 43; }
EOF
    "$compiler" linked-cache.zag -o linked-cache --cache-report --no-zagd -L "$work/lib" >link-cold.log
    grep -q 'znc cache: MISS stored machine code and data' link-cold.log
    grep -Eq '\+ [1-9][0-9]* bytes libs' link-cold.log
    expect_exit 43 ./linked-cache
    "$compiler" linked-cache.zag -o linked-cache --cache-report --no-zagd -L "$work/lib" >link-warm.log
    grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' link-warm.log
    grep -Eq '\+ [1-9][0-9]* bytes libs' link-warm.log
    expect_exit 43 ./linked-cache
else
    echo 'foreground cache static-link witness: SKIP (no glibc libm archive fixture)'
fi

# Re-establish a validated main entry after the optional link fixture. The
# second build must consume the triplet that every adversarial case mutates.
"$compiler" main.zag -o reprime-app --cache-report --no-zagd >reprime.log
"$compiler" main.zag -o reprime-warm --cache-report --no-zagd >reprime-warm.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    reprime-warm.log
grep -q 'lowering_calls=0 payload_substituted=true' reprime-warm.log
expect_exit 42 ./reprime-warm
cmp fresh-app reprime-warm

# A record with trailing bytes is not a prefix-valid record. A fresh lowering
# replaces it, and the corrupt bytes never reach the executable.
printf 'trailing=untrusted\n' >>.zag-cache/foreground/machine.record
expect_miss_equivalent trailing-record-app

# A torn final record is rejected before any payload can become authoritative.
record_size=$(stat -c %s .zag-cache/foreground/machine.record)
test "$record_size" -gt 1
truncate -s "$((record_size - 1))" .zag-cache/foreground/machine.record
expect_miss_equivalent truncated-record-app

# A syntactically complete record with the wrong final checksum is a miss.
sed -i 's/^record_checksum=.*/record_checksum=invalid/' \
    .zag-cache/foreground/machine.record
expect_miss_equivalent bad-record-checksum-app

# Payload corruption is a miss and a correct executable is still produced.
printf '\177' >>.zag-cache/foreground/machine.code
expect_miss_equivalent corrupt-code-app

# A truncated payload and either kind of partial triplet are misses.
code_size=$(stat -c %s .zag-cache/foreground/machine.code)
test "$code_size" -gt 1
truncate -s "$((code_size - 1))" .zag-cache/foreground/machine.code
expect_miss_equivalent truncated-code-app
rm -- .zag-cache/foreground/machine.data
expect_miss_equivalent missing-data-app
rm -- .zag-cache/foreground/machine.record
expect_miss_equivalent missing-record-app

# Final-component symlinks and non-regular files are never read. Publication
# atomically replaces them with regular files after a fresh lowering.
cp .zag-cache/foreground/machine.data "$work/saved-machine.data"
rm -- .zag-cache/foreground/machine.data
ln -s "$work/saved-machine.data" .zag-cache/foreground/machine.data
expect_miss_equivalent symlink-payload-app
test ! -L .zag-cache/foreground/machine.data
test -f .zag-cache/foreground/machine.data

rm -- .zag-cache/foreground/machine.record
mkfifo .zag-cache/foreground/machine.record
expect_miss_equivalent fifo-record-app
test -f .zag-cache/foreground/machine.record
test ! -p .zag-cache/foreground/machine.record

# The cache directory itself must be a real directory. A symlink disables both
# reads and writes, so even an attacker-controlled target stays byte-identical.
mv .zag-cache/foreground .zag-cache/foreground-real
ln -s foreground-real .zag-cache/foreground
before_dir_record=$(sha256sum .zag-cache/foreground-real/machine.record)
"$compiler" main.zag -o symlink-dir-app --cache-report --no-zagd \
    >symlink-dir.log
grep -q 'znc cache: MISS cache unavailable; lowering_calls=1' symlink-dir.log
expect_exit 42 ./symlink-dir-app
cmp fresh-app symlink-dir-app
after_dir_record=$(sha256sum .zag-cache/foreground-real/machine.record)
test "$before_dir_record" = "$after_dir_record"
rm -- .zag-cache/foreground
mv .zag-cache/foreground-real .zag-cache/foreground

# A copied cache triplet cannot be substituted under another project root even
# when relative source names and every source byte are identical.
mkdir -p "$work/other/.zag-cache"
cp main.zag dep.zag "$work/other/"
cp -a .zag-cache/foreground "$work/other/.zag-cache/foreground"
(
    cd "$work/other"
    "$compiler" main.zag -o path-substitution-app --cache-report --no-zagd \
        >path-substitution.log
)
grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
    "$work/other/path-substitution.log"
expect_exit 42 "$work/other/path-substitution-app"
cmp fresh-app "$work/other/path-substitution-app"

# CPU feature identities partition the cache. Native is never allowed to reuse
# generic code, and a second native build proves the selected profile can hit.
"$compiler" main.zag -o native-cold-app --cache-report --no-zagd \
    --cpu native >native-cold.log
grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
    native-cold.log
expect_exit 42 ./native-cold-app
"$compiler" main.zag -o native-warm-app --cache-report --no-zagd \
    --cpu native >native-warm.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    native-warm.log
grep -q 'lowering_calls=0 payload_substituted=true' native-warm.log
expect_exit 42 ./native-warm-app
"$compiler" main.zag -o generic-restored-app --cache-report --no-zagd \
    --cpu generic >generic-restored.log
grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
    generic-restored.log
expect_exit 42 ./generic-restored-app
cmp fresh-app generic-restored-app

# Debug and hot artifacts are deliberately produced after the cached blob
# boundary. A cached build must match a fresh build while regenerating those
# current-invocation artifacts.
"$compiler" main.zag -o debug-fresh-app --debug --cache-report --no-zagd \
    --no-foreground-cache >debug-fresh.log
"$compiler" main.zag -o debug-cache-app --debug --cache-report --no-zagd \
    >debug-cache.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    debug-cache.log
expect_exit 42 ./debug-fresh-app
expect_exit 42 ./debug-cache-app
cmp debug-fresh-app debug-cache-app

"$compiler" main.zag -o hot-fresh-app --hot --cache-report --no-zagd \
    --no-foreground-cache >hot-fresh.log
cp .zag_hotlen "$work/hot-fresh.code-len"
cp .zag_hotdlen "$work/hot-fresh.data-len"
"$compiler" main.zag -o hot-cache-app --hot --cache-report --no-zagd \
    >hot-cache.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    hot-cache.log
expect_exit 42 ./hot-fresh-app
expect_exit 42 ./hot-cache-app
cmp hot-fresh-app hot-cache-app
cmp "$work/hot-fresh.code-len" .zag_hotlen
cmp "$work/hot-fresh.data-len" .zag_hotdlen

# Concurrent publishers may interleave payload-first writes, but the record
# remains the sole authority and is published last. Both foreground outputs
# must match a no-cache oracle; after repair, the next build must be a hit.
rm -rf -- .zag-cache/foreground
"$compiler" main.zag -o race-a-app --cache-report --no-zagd >race-a.log &
race_a_pid=$!
"$compiler" main.zag -o race-b-app --cache-report --no-zagd >race-b.log &
race_b_pid=$!
wait "$race_a_pid"
wait "$race_b_pid"
expect_exit 42 ./race-a-app
expect_exit 42 ./race-b-app
cmp fresh-app race-a-app
cmp fresh-app race-b-app
"$compiler" main.zag -o post-race-app --cache-report --no-zagd >post-race.log
expect_exit 42 ./post-race-app
cmp fresh-app post-race-app
"$compiler" main.zag -o post-race-warm-app --cache-report --no-zagd \
    >post-race-warm.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    post-race-warm.log
grep -q 'lowering_calls=0 payload_substituted=true' post-race-warm.log
expect_exit 42 ./post-race-warm-app
cmp fresh-app post-race-warm-app
if find .zag-cache/foreground -maxdepth 1 -name '*.tmp.*' -print -quit |
    grep -q .; then
    echo "foreground cache left a publication temporary behind" >&2
    exit 1
fi

# Imported-module content participates in the dependency key.
sed -i 's/42/41/' dep.zag
"$compiler" main.zag -o app --cache-report --no-zagd >stale.log
grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
    stale.log
set +e
./app
rc=$?
set -e
test "$rc" -eq 41

# Script diagnostics contain their source label. Identical token streams under
# different root names must not reuse data carrying the first file's label.
cat >first-error.zag <<'EOF'
script;
error { CachedFailure }
fn fail() !i32 { return error.CachedFailure; }
let value: i32 = try fail();
return value;
EOF
cp first-error.zag second-error.zag
"$compiler" first-error.zag -o first-error --cache-report --no-zagd >first-error.log
grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
    first-error.log
"$compiler" first-error.zag -o first-error-warm --cache-report --no-zagd \
    >first-error-warm.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' \
    first-error-warm.log
grep -q 'lowering_calls=0 payload_substituted=true' first-error-warm.log
cmp first-error first-error-warm
set +e
./first-error 2>first-error.err
first_rc=$?
./first-error-warm 2>first-error-warm.err
first_warm_rc=$?
set -e
test "$first_rc" -eq 1
test "$first_warm_rc" -eq 1
cmp first-error.err first-error-warm.err
"$compiler" second-error.zag -o second-error --cache-report --no-zagd >second-error.log
grep -q 'znc cache: MISS stored machine code and data; lowering_calls=1' \
    second-error.log
set +e
./second-error 2>second-error.err
rc=$?
set -e
test "$rc" -eq 1
grep -q 'source: second-error.zag' second-error.err
if grep -q 'source: first-error.zag' second-error.err; then
    echo "foreground cache reused the wrong Script source label" >&2
    exit 1
fi

# Cache payloads are fstat-bounded before allocation. A sparse corrupt entry
# cannot push a low-memory foreground compile over its address-space limit.
printf 'max_cache_bytes=1048576\n' >.zagd.conf
truncate -s 536870912 .zag-cache/foreground/machine.code
test "$(stat -c %s .zag-cache/foreground/machine.code)" -eq 536870912
(
    ulimit -v 131072
    "$compiler" second-error.zag -o second-error --cache-report --no-zagd >oversized.log
)
grep -q 'znc cache: MISS stored machine code and data' oversized.log
test "$(stat -c %s .zag-cache/foreground/machine.code)" -lt 1048576
set +e
./second-error 2>oversized.err
rc=$?
set -e
test "$rc" -eq 1
grep -q 'source: second-error.zag' oversized.err

echo 'foreground cache integration: PASS'
