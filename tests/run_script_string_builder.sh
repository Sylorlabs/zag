#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-builder.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_frontend/string_builder.zag -o "$tmp_dir/script" --no-analyze --no-zagd >/dev/null
"$tmp_dir/script"
"$znc_bin" tests/script_frontend/string_builder_limit.zag -o "$tmp_dir/limit" --no-analyze --no-zagd >/dev/null
"$tmp_dir/limit"
"$znc_bin" tests/string_builder_strict.zag -o "$tmp_dir/strict" --no-analyze --no-zagd >/dev/null
"$tmp_dir/strict"

cat >"$tmp_dir/invalid_builder.zag" <<'ZAG'
script;
let b=string_builder(0 - 1);
if (string_builder_append(&b, "x") != 1 || string_builder_failed(&b) != 1) { return 1; }
let out:[]u8=string_builder_output(&b);
if (out.len != 0) { return 2; }
return 0;
ZAG
# A negative requested capacity constructs a failed descriptor before touching
# its context; it must remain fail-closed without a null dereference.
"$znc_bin" "$tmp_dir/invalid_builder.zag" -o "$tmp_dir/invalid_builder" --no-analyze --no-zagd >/dev/null
"$tmp_dir/invalid_builder"

cat >"$tmp_dir/corrupt_builder.zag" <<'ZAG'
script;
let b=string_builder(0);
b.len = 1;
if (string_builder_append(&b, "") != 1 || string_builder_failed(&b) != 1) { return 1; }
return 0;
ZAG
"$znc_bin" "$tmp_dir/corrupt_builder.zag" -o "$tmp_dir/corrupt_builder" --no-analyze --no-zagd >/dev/null
"$tmp_dir/corrupt_builder"
echo "script string builder: PASS"
