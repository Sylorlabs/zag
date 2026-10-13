#!/usr/bin/env bash
# ZagScript static-language core authority.
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh

ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
test -x "$ZNC"

bash tests/run_typed_authority.sh
bash tests/run_script_records.sh
bash tests/run_shift_signedness.sh

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-static-core.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

cat >"$tmp/core.zag" <<'ZAG'
enum Choice { zero, answer }
error { Missing }
struct Box[T] { value: T }
fn boxed[T](value: T) Box[T] { return Box[T]{ .value = value }; }
fn maybe(ok: bool) !i32 { if (!ok) { return error.Missing; } return 40; }
fn add(box: Box[i32], n: i32) i32 { return box.value + n; }
script;
let choice: Choice = Choice.answer;
let base: i32 = maybe(true) catch 0;
let box: Box[i32] = boxed[i32](base);
let result: i32 = add(box, 2);
if (choice == Choice.answer && result == 42) { return 42; }
return 1;
ZAG

target_args=()
if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    target_args=(--target macos-arm64)
fi
"$ZNC" "$tmp/core.zag" "${target_args[@]}" --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/core" >"$tmp/build.log" 2>&1
zag_assert_native_executable "$tmp/core"
set +e
zag_run_bounded 10 "$tmp/core"
rc=$?
set -e
test "$rc" -eq 42

cat >"$tmp/error.zag" <<'ZAG'
error { Missing }
fn maybe() !i32 { return error.Missing; }
script;
let code: i32 = maybe() catch |e| e;
if (code > 0) { return 42; }
return 1;
ZAG
"$ZNC" "$tmp/error.zag" "${target_args[@]}" --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/error" >/dev/null
set +e
zag_run_bounded 10 "$tmp/error"
error_rc=$?
set -e
test "$error_rc" -eq 42

echo 'ZagScript static typed core: PASS functions + records + enums + generics + optionals + errors'
