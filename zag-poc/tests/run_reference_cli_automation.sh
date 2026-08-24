#!/usr/bin/env bash
# Native reference application: a bounded command-line source scanner written
# in the low-ceremony Script profile.  This is application evidence, not just a
# parser or prelude unit test.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"
caller_dir=$PWD
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$caller_dir/$compiler" ;;
esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-cli.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
app="$tmp/comment-scanner"
app_repro="$tmp/comment-scanner-repro"
input="$root/tests/reference_apps/cli_automation/input.zag"
pass=0
expected_pass=7

mkdir -p "$tmp/build-cwd-a" "$tmp/build-cwd-b"
(cd "$tmp/build-cwd-a" && \
    "$compiler" "$root/examples/script_comment_scanner.zag" \
    --no-zagd --no-analyze --no-foreground-cache -o "$app") \
    >"$tmp/build.out" 2>&1
test -x "$app"
pass=$((pass + 1))

assert_native_executable() {
    local artifact=$1
    zag_assert_native_executable "$artifact"
}

assert_native_executable "$app"
pass=$((pass + 1))

set +e
"$app" "$input" >"$tmp/success.out" 2>"$tmp/success.err"
success_status=$?
set -e
test "$success_status" -eq 0
printf '3\n' | cmp -s - "$tmp/success.out"
test ! -s "$tmp/success.err"
pass=$((pass + 1))

set +e
"$app" >"$tmp/missing-arg.out" 2>"$tmp/missing-arg.err"
missing_arg_status=$?
set -e
test "$missing_arg_status" -eq 2
test ! -s "$tmp/missing-arg.out"
test ! -s "$tmp/missing-arg.err"
pass=$((pass + 1))

set +e
"$app" "$tmp/does-not-exist.zag" \
    >"$tmp/missing-file.out" 2>"$tmp/missing-file.err"
missing_file_status=$?
set -e
test "$missing_file_status" -eq 2
test ! -s "$tmp/missing-file.out"
test ! -s "$tmp/missing-file.err"
pass=$((pass + 1))

mkdir "$tmp/denied"
cp "$root/examples/script_comment_scanner.zag" "$tmp/denied/scanner.zag"
cp "$root/zag.mod" "$tmp/denied/zag.mod"
printf '%s\n' \
    'allow_filesystem_read=false' \
    'allow_filesystem_write=false' \
    'allow_process=false' \
    'mode=off' >"$tmp/denied/.zagd.conf"
set +e
$compiler "$tmp/denied/scanner.zag" --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/denied/scanner" \
    >"$tmp/denied/build.out" 2>"$tmp/denied/build.err"
denied_status=$?
set -e
test "$denied_status" -ne 0
grep -F -q 'znc script capability: read_file denied by allow_filesystem_read=false' \
    "$tmp/denied/build.err"
test ! -s "$tmp/denied/build.out"
test ! -x "$tmp/denied/scanner"
test ! -s "$tmp/denied/build.out"
pass=$((pass + 1))

(cd "$tmp/build-cwd-b" && \
    "$compiler" "$root/examples/script_comment_scanner.zag" \
        --no-zagd --no-analyze --no-foreground-cache -o "$app_repro") \
    >"$tmp/repro-build.out" 2>&1
assert_native_executable "$app_repro"
cmp -s "$app" "$app_repro"
"$app_repro" "$input" >"$tmp/repro.out" 2>"$tmp/repro.err"
printf '3\n' | cmp -s - "$tmp/repro.out"
test ! -s "$tmp/repro.err"
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'CLI automation reference app: pass=%d fail=0\n' "$pass"
