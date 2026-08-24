#!/usr/bin/env bash
set -eu
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-script-list.XXXXXX)
trap 'find "$tmp" -depth -delete' EXIT HUP INT TERM
printf '%s\n' 'name = "script-list-regression"' 'edition = "2027"' >"$tmp/zag.mod"

"$compiler" tests/script_frontend/list.zag -o "$tmp/list" --no-zagd --no-analyze >/dev/null
"$tmp/list"
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
"$tmp/list_budget_failure"

cat >"$tmp/list_index_bad.zag" <<'ZAG'
script;
let values = list(7);
let bad:i32 = script_list_get(values, 1);
return bad;
ZAG
"$compiler" "$tmp/list_index_bad.zag" -o "$tmp/list_index_bad" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
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
"$tmp/list_invalid_state"

echo "script typed list: PASS"
