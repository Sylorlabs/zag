#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d "${ZAG_TEST_TMPDIR:-/tmp}/zag-script-json-bool-array.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_json_bool_array.zag -o "$tmp_dir/strict" --no-zagd --no-analyze >/dev/null
"$tmp_dir/strict"

if "$znc_bin" tests/script_json_bool_array_escape_bad.zag \
    -o "$tmp_dir/escape-bad" --no-zagd --no-analyze \
    >"$tmp_dir/escape.log" 2>&1; then
    echo "script JSON boolean aggregate escape negative unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp_dir/escape-bad"
grep -Fxq 'znc script lifetime: Script-context value may escape through an untrusted helper, extern, or unknown call' \
    "$tmp_dir/escape.log"

if "$znc_bin" tests/script_json_bool_array_encode_escape_bad.zag \
    -o "$tmp_dir/encode-escape-bad" --no-zagd --no-analyze \
    >"$tmp_dir/encode-escape.log" 2>&1; then
    echo "script JSON boolean encoder aggregate escape negative unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp_dir/encode-escape-bad"
grep -Fxq 'znc script lifetime: Script-context value may escape through an untrusted helper, extern, or unknown call' \
    "$tmp_dir/encode-escape.log"

"$znc_bin" tests/script_json_bool_array_profile.zag -o "$tmp_dir/profile" --no-zagd --no-analyze >/dev/null
"$tmp_dir/profile"

mkdir -p "$tmp_dir/limit"
cp tests/script_json_bool_array_limit.zag "$tmp_dir/limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/limit/.zagd.conf"
"$znc_bin" "$tmp_dir/limit/main.zag" -o "$tmp_dir/limit/bool-array" --no-zagd --no-analyze >/dev/null
"$tmp_dir/limit/bool-array"

echo "script JSON boolean array: PASS"
