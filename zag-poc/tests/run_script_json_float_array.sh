#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d "${ZAG_TEST_TMPDIR:-/tmp}/zag-script-json-float-array.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_json_float_array.zag \
    -o "$tmp_dir/strict" --no-zagd --no-analyze >/dev/null
"$tmp_dir/strict"

"$znc_bin" tests/script_json_float_array_profile.zag \
    -o "$tmp_dir/profile" --no-zagd --no-analyze >/dev/null
"$tmp_dir/profile"

if "$znc_bin" tests/script_json_float_array_encode_escape_bad.zag \
    -o "$tmp_dir/encode-escape-bad" --no-zagd --no-analyze \
    >"$tmp_dir/encode-escape.log" 2>&1; then
    echo "script JSON floating encoder aggregate escape negative unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp_dir/encode-escape-bad"
grep -Fxq 'znc script lifetime: Script-context value may escape through an untrusted helper, extern, or unknown call' \
    "$tmp_dir/encode-escape.log"

mkdir -p "$tmp_dir/limit"
cp tests/script_json_float_array_limit.zag "$tmp_dir/limit/main.zag"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp_dir/limit/.zagd.conf"
"$znc_bin" "$tmp_dir/limit/main.zag" \
    -o "$tmp_dir/limit/float-array" --no-zagd --no-analyze >/dev/null
"$tmp_dir/limit/float-array"

# Keep the focused gate tied to the source authority as well as the executable
# witness.  A stale compiler image must not silently omit the encoder surface.
rg -q 'fn script_json_float_array_encode' selfhost/std/script_json.zag
rg -q 'json_float_array_encode' selfhost/parse.zag
rg -q 'script_json_float_array_encode' selfhost/native/znc.zag
# Once the retained output buffer is reserved, the encoder must have no
# fallible parser/validation exits that could charge Script budget and return
# an empty result. Preflight owns all rejection decisions.
encoder_after_alloc=$(sed -n '/fn script_json_float_array_encode/,/fn script_json_string_array_encode/p' \
    selfhost/std/script_json.zag)
if printf '%s\n' "$encoder_after_alloc" | grep -Eq 'json_parse_float|spelling\.len <= 0|if \(at > capacity'; then
    echo "script JSON floating encoder retains post-allocation failure paths" >&2
    exit 1
fi

echo "script JSON floating-point array: PASS"
