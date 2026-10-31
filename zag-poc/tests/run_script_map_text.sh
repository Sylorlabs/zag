#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-map-text.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$compiler" tests/script_map_text.zag -o "$tmp/map" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/map"
"$tmp/map"

cat >"$tmp/text-map-null-context.zag" <<'ZAG'
@import("std:script_map")
fn main() i32 {
    unsafe {
    let context: *opaque = null as *opaque;
    let values: ScriptMapText = script_map_text_new(context);
    if (values.failed != 1 || values.context != null as *opaque ||
        values.keys != null as *[]u8 || values.values != null as *[]u8 ||
        values.used != null as *u8) { return 1; }
    return 0;
    }
}
ZAG
# The null-context fixture deliberately uses the edition-2027 `unsafe` block.
# Give the temporary source its own nearest manifest so the result does not
# depend on the repository's edition-2026 manifest or another test's cwd.
printf 'name = "text-map-null-context"\nedition = "2027"\n' >"$tmp/zag.mod"
"$compiler" "$tmp/text-map-null-context.zag" -o "$tmp/text-map-null-context" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-null-context"

"$compiler" explain tests/script_map_text.zag --format json --no-zagd \
    >"$tmp/explain.json"
grep -q '"operation":"text_map_clear"' "$tmp/explain.json"
# Explain JSON keeps operation metadata structured under `copy.value`.
grep -q '"copy":{"value":"table_scrub"' "$tmp/explain.json"
grep -q '"map_clear","text_map"' "$tmp/explain.json"
grep -q '"text_set_clear","range"' "$tmp/explain.json"

cat >"$tmp/missing.zag" <<'ZAG'
script;
let values = text_map();
let missing: []u8 = text_map_get(values, "absent");
return missing.len as i32;
ZAG
"$compiler" "$tmp/missing.zag" -o "$tmp/missing" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/missing" >"$tmp/missing.out" 2>"$tmp/missing.err"
status=$?
set -e
test "$status" -eq 1
grep -q 'text map key is absent' "$tmp/missing.err"

cat >"$tmp/bad-clear-arity.zag" <<'ZAG'
script;
let values = text_map();
let ignored: i32 = text_map_clear(values, values);
return ignored;
ZAG
if "$compiler" "$tmp/bad-clear-arity.zag" -o "$tmp/bad-clear-arity" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-clear-arity.out" 2>&1; then
    echo 'text_map_clear arity unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-clear-arity"
grep -q 'text_map_clear expects one map' "$tmp/bad-clear-arity.out"

cat >"$tmp/text-map-clear-null.zag" <<'ZAG'
@import("std:script_map")
script;
let nothing: *ScriptMapText = null as *ScriptMapText;
return script_map_text_clear(nothing);
ZAG
"$compiler" "$tmp/text-map-clear-null.zag" -o "$tmp/text-map-clear-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp/text-map-clear-null" >"$tmp/text-map-clear-null.out" 2>&1
status=$?
set -e
test "$status" -eq 1

cat >"$tmp/text-map-mutation-null.zag" <<'ZAG'
@import("std:script_map")
script;
let nothing: *ScriptMapText = null as *ScriptMapText;
if (script_map_text_put(nothing, "key", "value") != 1) { return 1; }
if (script_map_text_del(nothing, "key") != 1) { return 2; }
if (script_map_text_rehash(nothing, 16) != 1) { return 3; }
if (script_map_text_grow(nothing) != 1) { return 4; }
return 0;
ZAG
"$compiler" "$tmp/text-map-mutation-null.zag" \
    -o "$tmp/text-map-mutation-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-mutation-null"

cat >"$tmp/text-map-operation-adversarial.zag" <<'ZAG'
script;

// The shared text-map validator scans all bounded state bytes before any
// probe or write.  Sentinels prove rejection does not partially mutate the
// retained key/value backing arrays.
let bad_state = text_map();
bad_state.keys[0] = "state-key";
bad_state.values[0] = "state-value";
bad_state.used[0] = 3;
if (text_map_put(bad_state, "new", "value") != 1 ||
    text_map_has(bad_state, "new") || text_map_failed(bad_state) != 1 ||
    !@strEq(bad_state.keys[0], "state-key") ||
    !@strEq(bad_state.values[0], "state-value") ||
    bad_state.used[0] != 3) { return 1; }

let bad_count = text_map();
bad_count.keys[0] = "count-key";
bad_count.values[0] = "count-value";
bad_count.count = 1;
if (text_map_del(bad_count, "missing") != 1 ||
    text_map_has(bad_count, "missing") || text_map_failed(bad_count) != 1 ||
    !@strEq(bad_count.keys[0], "count-key") ||
    !@strEq(bad_count.values[0], "count-value") ||
    bad_count.used[0] != 0) { return 2; }

let bad_tombstones = text_map();
bad_tombstones.keys[0] = "tombstone-key";
bad_tombstones.values[0] = "tombstone-value";
bad_tombstones.tombstones = 1;
if (text_map_put(bad_tombstones, "new", "value") != 1 ||
    text_map_failed(bad_tombstones) != 1 ||
    !@strEq(bad_tombstones.keys[0], "tombstone-key") ||
    !@strEq(bad_tombstones.values[0], "tombstone-value") ||
    bad_tombstones.used[0] != 0) { return 3; }

let bad_cap = text_map();
bad_cap.keys[0] = "cap-key";
bad_cap.values[0] = "cap-value";
bad_cap.cap = 10;
if (text_map_put(bad_cap, "new", "value") != 1 ||
    text_map_del(bad_cap, "new") != 1 || text_map_has(bad_cap, "new") ||
    text_map_failed(bad_cap) != 1 || !@strEq(bad_cap.keys[0], "cap-key") ||
    !@strEq(bad_cap.values[0], "cap-value") || bad_cap.used[0] != 0) {
    return 4;
}
return 0;
ZAG
"$compiler" "$tmp/text-map-operation-adversarial.zag" \
    -o "$tmp/text-map-operation-adversarial" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-operation-adversarial"

cat >"$tmp/text-map-slice-adversarial.zag" <<'ZAG'
script;

// Positive-length null input slices are rejected before lookup, allocation,
// or table writes.  A rejected caller slice must not poison a valid map.
let values = text_map();
let bad_input: []u8 = (null as *u8)[0..1];
if (text_map_put(values, bad_input, "value") != 1 ||
    text_map_put(values, "key", bad_input) != 1 ||
    text_map_has(values, bad_input) || text_map_del(values, bad_input) != 1 ||
    text_map_len(values) != 0 || text_map_failed(values) != 0) { return 1; }

// Every live key and value slice is validated before hashing/equality.
let bad_key = text_map();
bad_key.keys[0] = (null as *u8)[0..1];
bad_key.values[0] = "value";
bad_key.used[0] = 1;
if (text_map_has(bad_key, "key") || text_map_put(bad_key, "new", "value") != 1 ||
    text_map_failed(bad_key) != 1 || bad_key.used[0] != 1) { return 2; }

let bad_value = text_map();
bad_value.keys[0] = "key";
bad_value.values[0] = (null as *u8)[0..1];
bad_value.used[0] = 1;
if (text_map_has(bad_value, "key") || text_map_del(bad_value, "key") != 1 ||
    text_map_failed(bad_value) != 1 || bad_value.used[0] != 1) { return 3; }
return 0;
ZAG
"$compiler" "$tmp/text-map-slice-adversarial.zag" \
    -o "$tmp/text-map-slice-adversarial" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-slice-adversarial"

cat >"$tmp/text-map-clear-user.zag" <<'ZAG'
fn text_map_clear(value: i32) i32 { return value + 1; }
script;
if (text_map_clear(41) != 42) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/text-map-clear-user.zag" -o "$tmp/text-map-clear-user" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-clear-user"

# User constructor names must not suppress discovery of an independently used
# built-in helper from the shared map module.
cat >"$tmp/text-map-clear-auto-import.zag" <<'ZAG'
fn map(seed: i32) i32 { return seed; }
fn text_map(seed: i32) ScriptMapText {
    return ScriptMapText{.keys = null, .values = null, .used = null,
        .cap = 0, .count = 0, .tombstones = 0,
        .context = null, .failed = 0};
}
script;
let values = text_map(0);
if (text_map_clear(values) != 1 || values.failed != 1) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/text-map-clear-auto-import.zag" \
    -o "$tmp/text-map-clear-auto-import" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-clear-auto-import"

# A text-map-only explicit view must materialize its runtime import and remain
# a compilable/runnable strict Zag candidate.
cat >"$tmp/text-map-explicit-input.zag" <<'ZAG'
script;
let values = text_map();
if (text_map_put(values, "alpha", "one") != 0) { return 1; }
return text_map_clear(values);
ZAG
"$compiler" view "$tmp/text-map-explicit-input.zag" --level explicit \
    --format json --no-zagd >"$tmp/text-map-explicit.json"
grep -q '"candidate_compilable":true' "$tmp/text-map-explicit.json"
"$compiler" expand "$tmp/text-map-explicit-input.zag" --to explicit \
    --output "$tmp/text-map-explicit.zag" --no-zagd >/dev/null
grep -q '@import("std:script_map")' "$tmp/text-map-explicit.zag"
"$compiler" "$tmp/text-map-explicit.zag" -o "$tmp/text-map-explicit" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/text-map-explicit"

cat >"$tmp/bad-arity.zag" <<'ZAG'
script;
let values = text_map("initial");
return text_map_len(values);
ZAG
if "$compiler" "$tmp/bad-arity.zag" -o "$tmp/bad-arity" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-arity.out" 2>&1; then
    echo 'text_map constructor arity unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-arity"
grep -q 'text_map expects no initial values' "$tmp/bad-arity.out"

cat >"$tmp/bad-delete-arity.zag" <<'ZAG'
script;
let values = text_map();
let ignored: i32 = text_map_del(values);
return ignored;
ZAG
if "$compiler" "$tmp/bad-delete-arity.zag" -o "$tmp/bad-delete-arity" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-delete-arity.out" 2>&1; then
    echo 'text_map_del arity unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-delete-arity"
grep -q 'text_map_del expects a map and key' "$tmp/bad-delete-arity.out"

"$(dirname "$0")/run_script_map_text_literal.sh"

echo 'script text map: PASS (put/get/delete/clear/reuse)'
