#!/usr/bin/env bash
# Focused bounded descriptor-relative regular-file replacement/write contract.
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
case "$compiler" in /*) ;; *) compiler="$root/${compiler#./}" ;; esac
tmp=$(mktemp -d /tmp/zag-linux-fs-write.XXXXXX)
cleanup() { chmod 700 "$tmp/denied-root" 2>/dev/null || true; rm -rf "$tmp"; }
trap cleanup EXIT

mkdir -p "$tmp/project" "$tmp/valid" "$tmp/symlink-entry" \
    "$tmp/nested-entry/child" "$tmp/entry-limit" "$tmp/file-limit" \
    "$tmp/denied-root" "$tmp/denied-file"
printf 'name = "linux-fs-write"\nversion = "0"\nedition = "2027"\n' >"$tmp/project/zag.mod"
cp "$root/tests/linux_fs_bounded.zag" "$tmp/project/contract.zag"
printf 'alpha\n' >"$tmp/valid/a.txt"
printf 'bravo-bravo\n' >"$tmp/valid/b.txt"
printf 'charlie-charlie-charlie\n' >"$tmp/valid/c.txt"
printf 'one\n' >"$tmp/symlink-entry/a.txt"
printf 'two\n' >"$tmp/symlink-entry/b.txt"
ln -s "$tmp/valid/c.txt" "$tmp/symlink-entry/c.txt"
printf 'one\n' >"$tmp/nested-entry/a.txt"
printf 'two\n' >"$tmp/nested-entry/b.txt"
printf 'a\n' >"$tmp/entry-limit/a.txt"
printf 'b\n' >"$tmp/entry-limit/b.txt"
printf 'c\n' >"$tmp/entry-limit/c.txt"
printf 'd\n' >"$tmp/entry-limit/d.txt"
printf 'small-a\n' >"$tmp/file-limit/a.txt"
printf 'small-b\n' >"$tmp/file-limit/b.txt"
head -c 65 /dev/zero | tr '\0' x >"$tmp/file-limit/c.txt"
printf 'blocked\n' >"$tmp/denied-file/blocked.txt"
chmod 000 "$tmp/denied-root" "$tmp/denied-file/blocked.txt"
ln -s "$tmp/valid" "$tmp/symlink-root"

(cd "$tmp/project" && "$compiler" contract.zag --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/contract") >"$tmp/build.log" 2>&1
test -x "$tmp/contract"
set +e
timeout 15 "$tmp/contract" "$tmp/valid" "$tmp/valid/../valid" \
    "$tmp/missing" "$tmp/symlink-root" "$tmp/symlink-entry" \
    "$tmp/nested-entry" "$tmp/entry-limit" "$tmp/file-limit" \
    "$tmp/denied-root" "$tmp/valid/a.txt" >"$tmp/out" 2>"$tmp/err"
rc=$?
set -e
chmod 700 "$tmp/denied-root" "$tmp/denied-file/blocked.txt"
if [ "$rc" -ne 0 ] || test -s "$tmp/out" || test -s "$tmp/err"; then
    echo "linux fs write contract failed: rc=$rc" >&2
    sed -n '1,40p' "$tmp/build.log" >&2
    exit 1
fi
echo 'linux fs bounded write: PASS (replacement, empty rewrite, traversal/symlink rejection, recovery)'
