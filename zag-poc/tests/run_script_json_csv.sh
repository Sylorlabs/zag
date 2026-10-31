#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
test_tmp_root=${ZAG_TEST_TMPDIR:-/tmp}
mkdir -p "$test_tmp_root"
tmp_dir=$(mktemp -d "${test_tmp_root%/}/zag-script-json-csv-profile.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$script_dir/run_script_json.sh"
"$script_dir/run_script_csv.sh"
"$script_dir/run_script_json_csv_descriptor.sh"

"$znc_bin" tests/script_json_csv_profile.zag \
    -o "$tmp_dir/profile" --no-zagd --no-analyze >/dev/null
"$tmp_dir/profile"

"$znc_bin" tests/script_json_csv_wrappers.zag \
    -o "$tmp_dir/wrappers" --no-zagd --no-analyze >/dev/null
"$tmp_dir/wrappers"

"$znc_bin" tests/script_json_csv_rows.zag \
    -o "$tmp_dir/rows" --no-zagd --no-analyze >/dev/null
"$tmp_dir/rows"

# A valid native array must still fail closed when its ScriptContext copy has
# no budget. The bridge frees its native temporary and returns a failed list;
# it does not expose an ordinary-allocator pointer or abort the process.
mkdir -p "$tmp_dir/int-array-limit"
cp tests/script_json_csv_int_array_limit.zag "$tmp_dir/int-array-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/int-array-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/int-array-limit/main.zag" \
    -o "$tmp_dir/int-array-limit/int-array" --no-zagd --no-analyze >/dev/null
"$tmp_dir/int-array-limit/int-array"

mkdir -p "$tmp_dir/int-array-encode-limit"
cp tests/script_json_csv_int_array_encode_limit.zag "$tmp_dir/int-array-encode-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/int-array-encode-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/int-array-encode-limit/main.zag" \
    -o "$tmp_dir/int-array-encode-limit/int-array-encode" --no-zagd --no-analyze >/dev/null
"$tmp_dir/int-array-encode-limit/int-array-encode"

mkdir -p "$tmp_dir/string-array-encode-limit"
cp tests/script_json_csv_string_array_encode_limit.zag "$tmp_dir/string-array-encode-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/string-array-encode-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/string-array-encode-limit/main.zag" \
    -o "$tmp_dir/string-array-encode-limit/string-array-encode" --no-zagd --no-analyze >/dev/null
"$tmp_dir/string-array-encode-limit/string-array-encode"

mkdir -p "$tmp_dir/string-map-limit"
cp tests/script_json_csv_string_map_limit.zag "$tmp_dir/string-map-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/string-map-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/string-map-limit/main.zag" \
    -o "$tmp_dir/string-map-limit/string-map" --no-zagd --no-analyze >/dev/null
"$tmp_dir/string-map-limit/string-map"

mkdir -p "$tmp_dir/string-map-encode-limit"
cp tests/script_json_csv_string_map_encode_limit.zag "$tmp_dir/string-map-encode-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/string-map-encode-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/string-map-encode-limit/main.zag" \
    -o "$tmp_dir/string-map-encode-limit/string-map-encode" --no-zagd --no-analyze >/dev/null
"$tmp_dir/string-map-encode-limit/string-map-encode"

mkdir -p "$tmp_dir/csv-rows-encode-limit"
cp tests/script_json_csv_rows_encode_limit.zag "$tmp_dir/csv-rows-encode-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/csv-rows-encode-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/csv-rows-encode-limit/main.zag" \
    -o "$tmp_dir/csv-rows-encode-limit/csv-rows-encode" --no-zagd --no-analyze >/dev/null
"$tmp_dir/csv-rows-encode-limit/csv-rows-encode"

mkdir -p "$tmp_dir/first-column-limit"
cp tests/script_json_csv_first_column_limit.zag "$tmp_dir/first-column-limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/first-column-limit/.zagd.conf"
"$znc_bin" "$tmp_dir/first-column-limit/main.zag" \
    -o "$tmp_dir/first-column-limit/first-column" --no-zagd --no-analyze >/dev/null
"$tmp_dir/first-column-limit/first-column"

# Fill the exact minimum Script budget before invoking either bridge. Native
# JSON/CSV temporaries must still be released when the final context copy is
# denied; an empty result is the wrapper's bounded failure value.
mkdir -p "$tmp_dir/limit"
cp tests/script_json_csv_wrapper_limit.zag "$tmp_dir/limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/limit/.zagd.conf"
"$znc_bin" "$tmp_dir/limit/main.zag" \
    -o "$tmp_dir/limit/wrappers" --no-zagd --no-analyze >/dev/null
set +e
"$tmp_dir/limit/wrappers" >"$tmp_dir/limit/wrappers.out" 2>"$tmp_dir/limit/wrappers.err"
limit_status=$?
set -e
test "$limit_status" -eq 1
grep -q 'Zag Script JSON output allocation failed' "$tmp_dir/limit/wrappers.err"

if "$znc_bin" tests/script_json_csv_escape_bad.zag \
    -o "$tmp_dir/escape-bad" --no-zagd --no-analyze \
    >"$tmp_dir/escape.log" 2>&1; then
    echo "script JSON/CSV lifetime escape negative unexpectedly compiled" >&2
    exit 1
fi
grep -q 'Script-context value may escape' "$tmp_dir/escape.log"

echo "script JSON and CSV (including script profile): PASS"
