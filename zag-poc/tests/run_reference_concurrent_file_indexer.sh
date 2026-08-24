#!/usr/bin/env bash
# Bounded Linux/x86-64 concurrent file-indexer reference application gate.
# The fixture proves real join-only threads and direct regular-file syscalls;
# it is not evidence for recursive traversal, async I/O, or a worker pool.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$root/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-reference-concurrent-indexer.XXXXXX)
denied_root="$tmp/denied-root"
denied_file="$tmp/denied-file/blocked.txt"
cleanup() {
    chmod 700 "$denied_root" 2>/dev/null || true
    chmod 600 "$denied_file" 2>/dev/null || true
    if [ "${KEEP_TMP:-0}" = 1 ]; then
        echo "kept $tmp" >&2
    else
        rm -rf "$tmp"
    fi
}
trap cleanup EXIT
pass=0
expected_pass=13
release_evidence=${ZAGSCRIPT_RELEASE_EVIDENCE:-0}
case "$release_evidence" in
    0|1) ;;
    *) echo 'ZAGSCRIPT_RELEASE_EVIDENCE must be 0 or 1' >&2; exit 2 ;;
esac

mkdir -p "$tmp/project"
printf '%s\n' \
    'name = "concurrent-file-indexer"' \
    'version = "0"' \
    'edition = "2027"' >"$tmp/project/zag.mod"
cp "$root/tests/reference_apps/concurrent_file_indexer/main.zag" \
    "$tmp/project/main.zag"

mkdir -p "$tmp/valid"
printf 'alpha\n' >"$tmp/valid/a.txt"
printf 'bravo-bravo\n' >"$tmp/valid/b.txt"
printf 'charlie-charlie-charlie\n' >"$tmp/valid/c.txt"

build_app() {
    local output=$1
    (cd "$tmp/project" && "$compiler" main.zag \
        --no-zagd --no-analyze --no-foreground-cache -o "$output") \
        >"$output.build.log" 2>&1
    test -x "$output"
}

assert_static_x86_64() {
    local artifact=$1
    test -x "$artifact"
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64'
    file "$artifact" | grep -q 'statically linked'
    readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
    readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC'
    readelf -h "$artifact" | \
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
    if readelf -l "$artifact" | grep -q 'INTERP'; then
        echo "$artifact unexpectedly has a dynamic interpreter" >&2
        return 1
    fi
    if readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'; then
        echo "$artifact unexpectedly has a dynamic dependency" >&2
        return 1
    fi
}

build_app "$tmp/indexer"
assert_static_x86_64 "$tmp/indexer"
pass=$((pass + 1))

"$tmp/indexer" "$tmp/valid" >"$tmp/valid.out" 2>"$tmp/valid.err"
printf '%s\n' \
    'a.txt bytes=6 checksum=1610' \
    'b.txt bytes=12 checksum=6906' \
    'c.txt bytes=24 checksum=27585' \
    'total files=3 bytes=42 checksum=36101' >"$tmp/expected.out"
cmp -s "$tmp/expected.out" "$tmp/valid.out"
test ! -s "$tmp/valid.err"
pass=$((pass + 1))

# A second foreground compile must be byte-identical and execute identically.
build_app "$tmp/indexer-second"
assert_static_x86_64 "$tmp/indexer-second"
cmp -s "$tmp/indexer" "$tmp/indexer-second"
"$tmp/indexer-second" "$tmp/valid" >"$tmp/second.out" 2>"$tmp/second.err"
cmp -s "$tmp/expected.out" "$tmp/second.out"
test ! -s "$tmp/second.err"
pass=$((pass + 1))

expect_status() {
    local expected=$1
    local path=$2
    local label=$3
    set +e
    timeout 5 "$tmp/indexer" "$path" \
        >"$tmp/$label.out" 2>"$tmp/$label.err"
    local status=$?
    set -e
    if [ "$status" -ne "$expected" ]; then
        echo "$label returned $status, expected $expected" >&2
        sed -n '1,80p' "$tmp/$label.err" >&2
        exit 1
    fi
    test ! -s "$tmp/$label.out"
    test ! -s "$tmp/$label.err"
    pass=$((pass + 1))
}

expect_status 2 "$tmp/missing" missing-root
expect_status 2 "$tmp/valid/../valid" traversal-root

ln -s "$tmp/valid" "$tmp/symlink-root"
expect_status 2 "$tmp/symlink-root" symlink-root

mkdir -p "$denied_root"
chmod 000 "$denied_root"
expect_status 2 "$denied_root" inaccessible-root
chmod 700 "$denied_root"

mkdir -p "$tmp/symlink-entry"
printf 'one\n' >"$tmp/symlink-entry/a.txt"
printf 'two\n' >"$tmp/symlink-entry/b.txt"
ln -s "$tmp/valid/c.txt" "$tmp/symlink-entry/c.txt"
expect_status 3 "$tmp/symlink-entry" symlink-entry

mkdir -p "$tmp/nested-entry/child"
printf 'one\n' >"$tmp/nested-entry/a.txt"
printf 'two\n' >"$tmp/nested-entry/b.txt"
expect_status 3 "$tmp/nested-entry" nested-entry

mkdir -p "$tmp/entry-limit"
printf 'a\n' >"$tmp/entry-limit/a.txt"
printf 'b\n' >"$tmp/entry-limit/b.txt"
printf 'c\n' >"$tmp/entry-limit/c.txt"
printf 'd\n' >"$tmp/entry-limit/d.txt"
expect_status 3 "$tmp/entry-limit" entry-limit

mkdir -p "$tmp/file-limit"
printf 'small-a\n' >"$tmp/file-limit/a.txt"
printf 'small-b\n' >"$tmp/file-limit/b.txt"
head -c 65 /dev/zero | tr '\0' x >"$tmp/file-limit/c.txt"
expect_status 4 "$tmp/file-limit" file-size-limit

mkdir -p "$tmp/denied-file"
printf 'small-a\n' >"$tmp/denied-file/a.txt"
printf 'small-b\n' >"$tmp/denied-file/b.txt"
printf 'blocked\n' >"$denied_file"
chmod 000 "$denied_file"
expect_status 4 "$tmp/denied-file" inaccessible-file
chmod 600 "$denied_file"

cp "$root/tests/linux_fs_bounded.zag" "$tmp/project/contract.zag"
(cd "$tmp/project" && "$compiler" contract.zag \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmp/fs-contract") \
    >"$tmp/fs-contract.build.log" 2>&1
test -x "$tmp/fs-contract"
chmod 000 "$denied_root"
set +e
timeout 10 "$tmp/fs-contract" \
    "$tmp/valid" \
    "$tmp/valid/../valid" \
    "$tmp/missing" \
    "$tmp/symlink-root" \
    "$tmp/symlink-entry" \
    "$tmp/nested-entry" \
    "$tmp/entry-limit" \
    "$tmp/file-limit" \
    "$denied_root" \
    "$tmp/valid/a.txt" \
    >"$tmp/fs-contract.out" 2>"$tmp/fs-contract.err"
contract_status=$?
set -e
chmod 700 "$denied_root"
if [ "$contract_status" -ne 0 ]; then
    echo "linux_fs contract returned $contract_status" >&2
    sed -n '1,80p' "$tmp/fs-contract.err" >&2
    exit 1
fi
test ! -s "$tmp/fs-contract.out"
test ! -s "$tmp/fs-contract.err"
assert_static_x86_64 "$tmp/fs-contract"
pass=$((pass + 1))

trace_available=0
if command -v strace >/dev/null 2>&1 &&
   timeout 5 strace -qq -e trace=none -o "$tmp/strace-probe" /bin/true \
       >/dev/null 2>&1; then
    trace_available=1
fi
if [ "$trace_available" -eq 1 ]; then
    timeout 10 strace -f -qq \
        -e trace=clone,futex,getdents64,openat,newfstatat,fstat,read,close \
        -o "$tmp/indexer.strace" "$tmp/indexer" "$tmp/valid" \
        >"$tmp/strace.out" 2>"$tmp/strace.err"
    cmp -s "$tmp/expected.out" "$tmp/strace.out"
    test ! -s "$tmp/strace.err"
    test "$(grep -c 'clone(' "$tmp/indexer.strace")" -eq 3
    grep -q 'FUTEX_WAIT' "$tmp/indexer.strace"
    grep -q 'FUTEX_WAKE' "$tmp/indexer.strace"
    grep -q 'getdents64(' "$tmp/indexer.strace"
    grep -Eq 'openat\([0-9]+, "a\.txt"' "$tmp/indexer.strace"
    grep -Eq 'openat\([0-9]+, "b\.txt"' "$tmp/indexer.strace"
    grep -Eq 'openat\([0-9]+, "c\.txt"' "$tmp/indexer.strace"
    grep -q 'fstat(' "$tmp/indexer.strace"
    grep -q 'read(' "$tmp/indexer.strace"
    grep -q 'close(' "$tmp/indexer.strace"
    trace_status=evidence-pass
elif [ "$release_evidence" -eq 1 ]; then
    echo 'Concurrent file indexer release evidence requires strace kernel witnesses' >&2
    exit 2
else
    trace_status=portable-skip
fi

test "$pass" -eq "$expected_pass"
printf 'Concurrent file indexer reference app: pass=%d fail=0 trace=%s\n' \
    "$pass" "$trace_status"
