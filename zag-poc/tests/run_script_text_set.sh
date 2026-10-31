#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-text-set.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_text_set.zag -o "$tmp_dir/set" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/set"

cat >"$tmp_dir/text-set-null-context.zag" <<'EOF'
@import("std:script_set")
fn main() i32 {
    unsafe {
    let context: *opaque = null as *opaque;
    let values: ScriptSetText = script_set_text_new(context);
    if (values.map.failed != 1 || values.map.context != null as *opaque ||
        values.map.keys != null as *[]u8 || values.map.values != null as *[]u8 ||
        values.map.used != null as *u8) { return 1; }
    return 0;
    }
}
EOF
# The null-context fixture deliberately uses the edition-2027 `unsafe` block.
# Give the temporary source its own nearest manifest so it does not inherit
# the repository's edition-2026 manifest or another test's working directory.
printf 'name = "text-set-null-context"\nedition = "2027"\n' >"$tmp_dir/zag.mod"
"$znc_bin" "$tmp_dir/text-set-null-context.zag" \
    -o "$tmp_dir/text-set-null-context" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/text-set-null-context"

"$znc_bin" explain tests/script_text_set.zag --format json --no-zagd \
    >"$tmp_dir/explain.json"
grep -q '"operation":"text_set_clear"' "$tmp_dir/explain.json"
grep -q '"copy":{"value":"table_scrub"' "$tmp_dir/explain.json"

cat >"$tmp_dir/bad.zag" <<'EOF'
script;
let values = text_set();
text_set_add(values);
return 0;
EOF
if "$znc_bin" "$tmp_dir/bad.zag" -o "$tmp_dir/bad" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp_dir/bad.log" 2>&1; then
    echo 'text_set_add arity negative unexpectedly compiled' >&2
    exit 1
fi
grep -q 'Zag Script text_set_add expects a set and key' "$tmp_dir/bad.log"
test ! -e "$tmp_dir/bad"

cat >"$tmp_dir/bad-clear.zag" <<'EOF'
script;
let values = text_set();
text_set_clear(values, values);
return 0;
EOF
if "$znc_bin" "$tmp_dir/bad-clear.zag" -o "$tmp_dir/bad-clear" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp_dir/bad-clear.log" 2>&1; then
    echo 'text_set_clear arity negative unexpectedly compiled' >&2
    exit 1
fi
grep -q 'Zag Script text_set_clear expects one set' "$tmp_dir/bad-clear.log"
test ! -e "$tmp_dir/bad-clear"

cat >"$tmp_dir/text-set-clear-null.zag" <<'EOF'
@import("std:script_set")
script;
let nothing: *ScriptSetText = null as *ScriptSetText;
return script_set_text_clear(nothing);
EOF
"$znc_bin" "$tmp_dir/text-set-clear-null.zag" \
    -o "$tmp_dir/text-set-clear-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp_dir/text-set-clear-null" >"$tmp_dir/text-set-clear-null.out" 2>&1
status=$?
set -e
test "$status" -eq 1

cat >"$tmp_dir/text-set-mutation-null.zag" <<'EOF'
@import("std:script_set")
script;
let nothing: *ScriptSetText = null as *ScriptSetText;
if (script_set_text_add(nothing, "key") != 1) { return 1; }
if (script_set_text_del(nothing, "key") != 1) { return 2; }
return 0;
EOF
"$znc_bin" "$tmp_dir/text-set-mutation-null.zag" \
    -o "$tmp_dir/text-set-mutation-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/text-set-mutation-null"

cat >"$tmp_dir/text-set-operation-adversarial.zag" <<'EOF'
script;

// Text sets delegate all probing and mutation to ScriptMapText.  These cases
// therefore exercise the shared complete validator through add/has/del.
let bad_state = text_set();
bad_state.map.keys[0] = "state-key";
bad_state.map.values[0] = "state-value";
bad_state.map.used[0] = 3;
if (text_set_add(bad_state, "new") != 1 ||
    text_set_has(bad_state, "new") || text_set_failed(bad_state) != 1 ||
    !@strEq(bad_state.map.keys[0], "state-key") ||
    !@strEq(bad_state.map.values[0], "state-value") ||
    bad_state.map.used[0] != 3) { return 1; }

let bad_count = text_set();
bad_count.map.keys[0] = "count-key";
bad_count.map.values[0] = "count-value";
bad_count.map.count = 1;
if (text_set_del(bad_count, "missing") != 1 ||
    text_set_has(bad_count, "missing") || text_set_failed(bad_count) != 1 ||
    !@strEq(bad_count.map.keys[0], "count-key") ||
    !@strEq(bad_count.map.values[0], "count-value") ||
    bad_count.map.used[0] != 0) { return 2; }

let bad_cap = text_set();
bad_cap.map.keys[0] = "cap-key";
bad_cap.map.values[0] = "cap-value";
bad_cap.map.cap = 10;
if (text_set_add(bad_cap, "new") != 1 ||
    text_set_del(bad_cap, "new") != 1 || text_set_has(bad_cap, "new") ||
    text_set_failed(bad_cap) != 1 ||
    !@strEq(bad_cap.map.keys[0], "cap-key") ||
    !@strEq(bad_cap.map.values[0], "cap-value") || bad_cap.map.used[0] != 0) {
    return 3;
}
return 0;
EOF
"$znc_bin" "$tmp_dir/text-set-operation-adversarial.zag" \
    -o "$tmp_dir/text-set-operation-adversarial" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/text-set-operation-adversarial"

cat >"$tmp_dir/text-set-slice-adversarial.zag" <<'EOF'
script;

// The text-set facade must preserve the map's no-allocation/no-write behavior
// for malformed caller slices and must validate delegated live entries.
let values = text_set();
let bad_input: []u8 = (null as *u8)[0..1];
if (text_set_add(values, bad_input) != 1 ||
    text_set_has(values, bad_input) || text_set_del(values, bad_input) != 1 ||
    text_set_len(values) != 0 || text_set_failed(values) != 0) { return 1; }

let bad_key = text_set();
bad_key.map.keys[0] = (null as *u8)[0..1];
bad_key.map.values[0] = "";
bad_key.map.used[0] = 1;
if (text_set_has(bad_key, "key") || text_set_add(bad_key, "new") != 1 ||
    text_set_failed(bad_key) != 1 || bad_key.map.used[0] != 1) { return 2; }

let bad_value = text_set();
bad_value.map.keys[0] = "key";
bad_value.map.values[0] = (null as *u8)[0..1];
bad_value.map.used[0] = 1;
if (text_set_has(bad_value, "key") || text_set_del(bad_value, "key") != 1 ||
    text_set_failed(bad_value) != 1 || bad_value.map.used[0] != 1) { return 3; }
return 0;
EOF
"$znc_bin" "$tmp_dir/text-set-slice-adversarial.zag" \
    -o "$tmp_dir/text-set-slice-adversarial" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/text-set-slice-adversarial"

cat >"$tmp_dir/text-set-clear-user.zag" <<'EOF'
fn text_set_clear(value: i32) i32 { return value + 1; }
script;
if (text_set_clear(41) != 42) { return 1; }
return 0;
EOF
"$znc_bin" "$tmp_dir/text-set-clear-user.zag" \
    -o "$tmp_dir/text-set-clear-user" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/text-set-clear-user"

cat >"$tmp_dir/text-set-clear-auto-import.zag" <<'EOF'
fn set(seed: i32) i32 { return seed; }
fn text_set(seed: i32) ScriptSetText {
    return ScriptSetText{.map = ScriptMapText{.keys = null, .values = null,
        .used = null, .cap = 0, .count = 0, .tombstones = 0,
        .context = null, .failed = 0}};
}
script;
let values = text_set(0);
if (text_set_clear(values) != 1 || values.map.failed != 1) { return 1; }
return 0;
EOF
"$znc_bin" "$tmp_dir/text-set-clear-auto-import.zag" \
    -o "$tmp_dir/text-set-clear-auto-import" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/text-set-clear-auto-import"

echo 'script text set: PASS'
