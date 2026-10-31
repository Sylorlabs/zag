#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-list.XXXXXX")
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM
printf '%s\n' 'name = "script-list-regression"' 'edition = "2027"' >"$tmp/zag.mod"

"$compiler" tests/script_frontend/list.zag -o "$tmp/list" --no-zagd --no-analyze >/dev/null
test -x "$tmp/list"
"$tmp/list"

cat >"$tmp/list_text.zag" <<'ZAG'
script;
let values = list("a", "b");
if (length(values) != 2) { return 1; }
if (@strEq(item_at(values, 0), "a") == 0 ||
    @strEq(item_at(values, 1), "b") == 0) { return 2; }
if (append(values, "c") != 0 || @strEq(item_at(values, 2), "c") == 0) { return 3; }
if (set_at(values, 1, "B") != 0 || @strEq(item_at(values, 1), "B") == 0) { return 4; }
return 0;
ZAG
"$compiler" "$tmp/list_text.zag" -o "$tmp/list_text" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_text"
set +e
"$tmp/list_text" >"$tmp/list_text.out" 2>"$tmp/list_text.err"
list_text_status=$?
set -e
if [ "$list_text_status" -ne 0 ]; then
    cat "$tmp/list_text.out" >&2 || true
    cat "$tmp/list_text.err" >&2 || true
    echo "Script string-list literal runtime failed (status=$list_text_status)" >&2
    exit 1
fi

cat >"$tmp/list_text_identifier.zag" <<'ZAG'
script;
let first: []u8 = "left";
let second: []u8 = "right";
let values = list(first, second);
if (length(values) != 2 || @strEq(item_at(values, 0), "left") == 0 ||
    @strEq(item_at(values, 1), "right") == 0) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/list_text_identifier.zag" -o "$tmp/list_text_identifier" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_text_identifier"
"$tmp/list_text_identifier"

cat >"$tmp/list_clear.zag" <<'ZAG'
script;
let values = list(10, 20, 30);
let original_cap: i32 = values.cap;
if (clear(values) != 0 || values.len != 0 || values.cap != original_cap ||
    values.data == null as *i32 || values.data[0] != 0 ||
    values.data[1] != 0 || values.data[2] != 0) { return 1; }
if (append(values, 77) != 0 || values.len != 1 || values.cap != original_cap ||
    item_at(values, 0) != 77) { return 2; }
let failed = list(1);
failed.failed = 1;
if (clear(failed) != 1 || failed.failed != 1 || failed.len != 1) { return 3; }
let forged = list(2);
forged.cap = 0;
if (clear(forged) != 1 || forged.failed != 1 || forged.len != 1) { return 4; }
return 0;
ZAG
"$compiler" "$tmp/list_clear.zag" -o "$tmp/list_clear" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_clear"
"$tmp/list_clear"

cat >"$tmp/list_clear_null.zag" <<'ZAG'
@import("std:script_list")
script;
let nothing: *ScriptList[i32] = null as *ScriptList[i32];
if (script_list_clear[i32](nothing) != 1) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/list_clear_null.zag" -o "$tmp/list_clear_null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_clear_null"
"$tmp/list_clear_null"

cat >"$tmp/list_clear_arity_bad.zag" <<'ZAG'
script;
let values = list(1);
return clear(values, values);
ZAG
if "$compiler" "$tmp/list_clear_arity_bad.zag" -o "$tmp/list_clear_arity_bad" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/list_clear_arity_bad.log" 2>&1; then
    echo "Script clear wrong arity unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/list_clear_arity_bad"
grep -q 'Zag Script clear expects one list' "$tmp/list_clear_arity_bad.log"

cat >"$tmp/list_clear_user_precedence.zag" <<'ZAG'
fn clear(value: i32) i32 { return value + 1; }
script;
if (clear(41) != 42) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/list_clear_user_precedence.zag" -o "$tmp/list_clear_user_precedence" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_clear_user_precedence"
"$tmp/list_clear_user_precedence"

cat >"$tmp/list_text_mixed_bad.zag" <<'ZAG'
script;
let values = list("text", 7);
return length(values);
ZAG
if "$compiler" "$tmp/list_text_mixed_bad.zag" -o "$tmp/list_text_mixed_bad" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/list_text_mixed_bad.log" 2>&1; then
    echo "mixed Script text/integer list unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/list_text_mixed_bad"
grep -q 'list elements have incompatible literal types' \
    "$tmp/list_text_mixed_bad.log"

cat >"$tmp/list_mutation.zag" <<'ZAG'
script;
let values = list(7, 9);
if (set_at(values, 1, 12) != 0 || item_at(values, 1) != 12) { return 1; }
let removed: i32 = pop(values);
if (removed != 12 || length(values) != 1 || item_at(values, 0) != 7) { return 2; }
let removed_first: i32 = pop(values);
if (removed_first != 7 || length(values) != 0) { return 3; }
let invalid = list(4);
if (set_at(invalid, 1, 8) != 1 || script_list_failed(invalid) != 1) { return 4; }
return 0;
ZAG
"$compiler" "$tmp/list_mutation.zag" -o "$tmp/list_mutation" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_mutation"
"$tmp/list_mutation"

cat >"$tmp/list_pop_empty.zag" <<'ZAG'
script;
let values = list(1);
let first: i32 = pop(values);
let second: i32 = pop(values);
return first + second;
ZAG
"$compiler" "$tmp/list_pop_empty.zag" -o "$tmp/list_pop_empty" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_pop_empty"
set +e
"$tmp/list_pop_empty" >"$tmp/list_pop_empty.out" 2>"$tmp/list_pop_empty.err"
pop_status=$?
set -e
test "$pop_status" -eq 1
grep -q 'list pop is empty or the list state is invalid' "$tmp/list_pop_empty.err"

if "$compiler" tests/script_frontend/list_mixed_bad.zag -o "$tmp/bad" --no-zagd --no-analyze >"$tmp/bad.log" 2>&1; then
    echo "mixed Script list unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/bad"

cat >"$tmp/list_budget_failure.zag" <<'ZAG'
script;
let fill:*i8 = script_alloc(1048576);
if (fill == null as *i8) { return 4; }
let values = list(7);
if (values.data != null as *i32 || script_list_failed(values) != 1 ||
    script_list_len(values) != 0) { return 1; }
// A failed constructor must make append return failure before it can
// dereference the null backing pointer or mutate observable list state.
if (script_list_append(&values, 9) != 1) { return 2; }
if (values.data != null as *i32 || values.len != 0 || values.failed != 1) {
    return 3;
}
return 0;
ZAG
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp/.zagd.conf"
"$compiler" "$tmp/list_budget_failure.zag" -o "$tmp/list_budget_failure" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_budget_failure"
"$tmp/list_budget_failure"

cat >"$tmp/list_index_bad.zag" <<'ZAG'
script;
let values = list(7);
let bad:i32 = script_list_get(values, 1);
return bad;
ZAG
"$compiler" "$tmp/list_index_bad.zag" -o "$tmp/list_index_bad" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_index_bad"
set +e
"$tmp/list_index_bad" >"$tmp/list_index_bad.out" 2>"$tmp/list_index_bad.err"
status=$?
set -e
if [ "$status" -ne 1 ] || ! grep -q 'list index is out of bounds or the list state is invalid' "$tmp/list_index_bad.err"; then
    echo "Script list out-of-bounds access did not fail closed" >&2
    exit 1
fi

cat >"$tmp/list_invalid_state.zag" <<'ZAG'
script;
let values = list(7);
values.len = 9;
if (script_list_append(&values, 8) != 1 || script_list_failed(values) != 1) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/list_invalid_state.zag" -o "$tmp/list_invalid_state" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/list_invalid_state"
"$tmp/list_invalid_state"

echo "script typed list: PASS"
