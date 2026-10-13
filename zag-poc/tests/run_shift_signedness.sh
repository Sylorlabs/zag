#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh

ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
test -x "$ZNC"

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-shift-signedness.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$ZNC" tests/shift_signedness.zag -o "$tmp/shift" \
    --no-analyze --no-zagd --no-foreground-cache >/dev/null
zag_assert_native_executable "$tmp/shift"
set +e
output=$(zag_run_bounded 10 "$tmp/shift")
rc=$?
set -e
test "$rc" -eq 0
test "$output" = 4611686018427387904

echo 'integer right-shift signedness: PASS u64/u32 logical + i64/i32 arithmetic'
