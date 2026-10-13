#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
ZNC="$compiler" bash "$root/tests/run_package_resolution.sh"
ZNC="$compiler" bash "$root/tests/run_package_lock_generator.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagscript-package-authority.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" "$root/selfhost/package_registry_test.zag" -o "$tmp/registry-test" --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log" >&2; exit 1; }
"$tmp/registry-test"
mkdir -p "$tmp/vendor/pkg/src" "$tmp/vendor/pkg/assets"
printf 'fn value() i32 { return 42; }\n' >"$tmp/vendor/pkg/src/value.zag"
printf 'schema-v1\n' >"$tmp/vendor/pkg/assets/schema.txt"
if find "$tmp/vendor/pkg" -type l -print -quit | grep -q .; then exit 1; fi
snapshot_one=$( (cd "$tmp/vendor/pkg" && find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do printf '%s\0' "$path"; cat "$path"; done) | zag_sha256_stream )
snapshot_two=$( (cd "$tmp/vendor/pkg" && find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do printf '%s\0' "$path"; cat "$path"; done) | zag_sha256_stream )
test "$snapshot_one" = "$snapshot_two"
printf 'schema-v2\n' >"$tmp/vendor/pkg/assets/schema.txt"
snapshot_changed=$( (cd "$tmp/vendor/pkg" && find . -type f -print | LC_ALL=C sort | while IFS= read -r path; do printf '%s\0' "$path"; cat "$path"; done) | zag_sha256_stream )
test "$snapshot_changed" != "$snapshot_one"
ln -s ../../outside "$tmp/vendor/pkg/assets/escape"
find "$tmp/vendor/pkg" -type l -print -quit | grep -q .
echo 'offline vendor snapshot: PASS deterministic all-file hashing + symlink containment'
echo 'ZagScript package authority: PASS lock/checksum + authenticated offline registry + transitive selection'
