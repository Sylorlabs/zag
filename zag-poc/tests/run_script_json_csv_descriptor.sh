#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp_dir=$(mktemp -d "${ZAG_TEST_TMPDIR:-/tmp}/zag-script-json-csv-descriptor.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

znc_bin=${ZNC:-./znc}
mkdir -p "$tmp_dir/project"
cp tests/script_json_csv_descriptor_adversarial.zag "$tmp_dir/project/main.zag"
printf '%s\n' 'name = "script-json-csv-descriptor"' \
    'version = "0"' 'edition = "2027"' >"$tmp_dir/project/zag.mod"
ln -s "$PWD/std" "$tmp_dir/project/std"
"$znc_bin" "$tmp_dir/project/main.zag" -o "$tmp_dir/descriptor" \
    --no-zagd --no-analyze >/dev/null
"$tmp_dir/descriptor"

# The exemption is origin-bound, not name- or suffix-bound.  A user module
# whose path happens to end in std/json.zag must still fail the ordinary v2
# ownership checks.
spoof_dir="$tmp_dir/origin-spoof"
mkdir -p "$spoof_dir/project/std"
printf '%s\n' \
    'struct Node { value:i32 }' \
    'fn choose(flag:i32) *mut Node { unsafe { if (flag == 1) { let p:*mut Node = new(Node{.value=42}) as *mut Node; return p; } return null as *mut Node; } }' \
    >"$spoof_dir/project/std/json.zag"
printf '%s\n' \
    'name = "script-json-csv-origin-spoof"' \
    'version = "0"' \
    'edition = "2027"' >"$spoof_dir/project/zag.mod"
printf '%s\n' \
    '@import("std/json.zag")' \
    'fn main() i32 { return 0; }' >"$spoof_dir/project/main.zag"
if "$znc_bin" "$spoof_dir/project/main.zag" -o "$spoof_dir/spoof" \
    --no-zagd --no-analyze >"$spoof_dir/out" 2>&1; then
    echo "origin-spoof helper unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$spoof_dir/spoof"
rg -q 'mixes owned and non-owned return provenance' "$spoof_dir/out"

# Keep the source-level gate beside the runtime fixture: these checks make a
# stale compiler binary unable to silently erase the descriptor boundary.
rg -q 'script_list_descriptor_valid\[i64\]' selfhost/std/script_json.zag
rg -q 'script_list_descriptor_valid\[bool\]' selfhost/std/script_json.zag
rg -q 'script_list_descriptor_valid\[\[\]u8\]' selfhost/std/script_json.zag
rg -q 'script_list_descriptor_valid\[ScriptList\[\[\]u8\]\]' selfhost/std/script_csv.zag
rg -q 'live == map.count && tombstones == map.tombstones' selfhost/std/script_json.zag
rg -q 'script_list_descriptor_valid' selfhost/native/znc.zag
rg -q 'script_args' selfhost/native/znc.zag
# The descriptor helper is retained in the ownership classifier; its call
# name and the `== 1` guard are intentionally separated by the classifier's
# origin checks, so assert each source-level contract independently.
rg -q 'script_json_string_map_descriptor_valid' selfhost/native/znc.zag
rg -q 'script_json_string_array_encode' selfhost/native/znc.zag
rg -q 'script_json_float_array_encode' selfhost/native/znc.zag
rg -q 'script_csv_rows_encode' selfhost/native/znc.zag

echo "script JSON/CSV descriptor adversarial: PASS"
