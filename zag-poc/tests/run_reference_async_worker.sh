#!/usr/bin/env bash
# Native application evidence for the bounded asynchronous worker example.
#
# This gate proves the application itself without treating ptrace/strace as a
# prerequisite.  The broader Linux concurrency gate retains its kernel-level
# syscall witness for release evidence; this app gate only claims the native
# artifact, deterministic rebuild, exact result, and clean shutdown contract.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
caller_dir=$PWD
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$caller_dir/${compiler#./}" ;;
esac
if [[ ! -x $compiler ]]; then
    printf 'async-worker compiler is not executable: %s\n' "$compiler" >&2
    exit 1
fi

tmp=$(mktemp -d /tmp/zag-reference-async-worker.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# Relocated compiler products need the immutable prelude beside the image.
compiler_dir=$(cd "$(dirname "$compiler")" && pwd)
compiler_dir_name=${compiler_dir##*/}
if [[ ! -f $compiler_dir/selfhost/std/script_io.zag &&
      ! -f $compiler_dir/std/script_io.zag &&
      ! -f $compiler_dir/../lib/zag/std/script_io.zag &&
      $compiler_dir_name != bin ]]; then
    stage="$tmp/compiler-layout"
    mkdir -p "$stage"
    ln -s "$compiler" "$stage/znc"
    ln -s "$root/selfhost" "$stage/selfhost"
    ln -s "$root/std" "$stage/std"
    compiler="$stage/znc"
fi

source="$root/tests/reference_apps/async_worker/main.zag"
expected='async-worker jobs=8 result_sum=212'

make_project() {
    local project=$1
    mkdir -p "$project"
    printf '%s\n' \
        'name = "async-worker-reference"' \
        'version = "0"' \
        'edition = "2027"' >"$project/zag.mod"
    cp "$source" "$project/main.zag"
}

build() {
    local project=$1 output=$2
    (cd "$project" && "$compiler" main.zag \
        --safety=checked --analyze-strict --no-zagd \
        --no-foreground-cache -o "$output") >"$output.build.log" 2>&1
    test -x "$output"
}

assert_static_x86_64() {
    local artifact=$1
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64'
    file "$artifact" | grep -q 'statically linked'
    readelf -h "$artifact" | grep -Eq 'Class:[[:space:]]+ELF64'
    readelf -h "$artifact" | grep -Eq 'Type:[[:space:]]+EXEC'
    readelf -h "$artifact" | \
        grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64'
    if readelf -l "$artifact" | grep -q 'INTERP'; then
        echo "unexpected dynamic interpreter: $artifact" >&2
        exit 1
    fi
    if readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'; then
        echo "unexpected dynamic dependency: $artifact" >&2
        exit 1
    fi
}

project_a="$tmp/project-a"
project_b="$tmp/project-b"
make_project "$project_a"
make_project "$project_b"

build "$project_a" "$tmp/async-worker-a"
build "$project_b" "$tmp/async-worker-b"
assert_static_x86_64 "$tmp/async-worker-a"
assert_static_x86_64 "$tmp/async-worker-b"
cmp -s "$tmp/async-worker-a" "$tmp/async-worker-b"

timeout 10 "$tmp/async-worker-a" >"$tmp/a.out" 2>"$tmp/a.err"
timeout 10 "$tmp/async-worker-b" >"$tmp/b.out" 2>"$tmp/b.err"
printf '%s\n' "$expected" | cmp -s - "$tmp/a.out"
printf '%s\n' "$expected" | cmp -s - "$tmp/b.out"
test ! -s "$tmp/a.err"
test ! -s "$tmp/b.err"

# A normal compiler failure must not leave a misleading native artifact.
bad="$tmp/bad"
bad_project="$tmp/bad-project"
mkdir -p "$bad_project"
printf '%s\n' 'name = "bad-async-worker"' 'version = "0"' \
    'edition = "2027"' >"$bad_project/zag.mod"
printf '%s\n' 'async fn broken(x:i32) i64 { return x as i64; }' \
    'fn main() i32 { unsafe { let h:*opaque=broken(1); return 0; } }' \
    >"$bad_project/main.zag"
if "$compiler" "$bad_project/main.zag" --no-zagd --no-analyze \
    --no-foreground-cache -o "$bad" >"$tmp/bad.log" 2>&1; then
    echo 'malformed async worker unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$bad"
if ! grep -Eq 'async fn requires a captureless non-generic fn\(\) i64 or fn\(i64\) i64' \
    "$tmp/bad.log"; then
    sed -n '1,80p' "$tmp/bad.log" >&2
    exit 1
fi

printf 'Async worker reference app: pass=7 fail=0\n'
