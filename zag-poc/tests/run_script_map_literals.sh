#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-map-literals.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "script-map-literal-test"' 'edition = "2027"' >"$tmp/zag.mod"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp/.zagd.conf"
cp tests/script_map_literals.zag "$tmp/literals.zag"

compile_map() {
    local source=$1 output=$2 policy=$3
    "$compiler" "$source" -o "$output" --script-allocator "$policy" \
        --no-zagd --no-analyze --no-foreground-cache >"$output.compile.log" 2>&1 || {
        cat "$output.compile.log" >&2
        return 1
    }
}

for policy in script_process_arena script_bounded_heap; do
    compile_map "$tmp/literals.zag" "$tmp/literals-$policy" "$policy"
    "$tmp/literals-$policy"
    overhead=0
    if [ "$policy" = script_bounded_heap ]; then overhead=16; fi
    # Literal lowering reserves 2*pairs+8 entries: one pair has cap10. Account for
    # policy overhead for those requests and for the explicit budget filler.
    for spare in 0 1; do
        cat >"$tmp/budget.zag" <<ZAG
script;
let cost: i64 = script_map_storage_bytes[i32](10) + 1 + 2 * $overhead;
let fill: *i8 = script_alloc(1048576 - cost - $overhead - $spare);
if (fill == null as *i8) { return 2; }
let value = {"a": 0};
let item: ScriptMapLookup[i32] = script_map_get[i32](value, "a");
if (!item.found || item.value.* != 0) { return 3; }
if (script_alloc_used() != 1048576 - $spare) { return 4; }
return 0;
ZAG
        compile_map "$tmp/budget.zag" "$tmp/exact-$policy-$spare" "$policy"
        "$tmp/exact-$policy-$spare"
    done
    # Leave one byte less than the complete literal requires. A failed put
    # must not publish a successful empty/partial root binding.
    cat >"$tmp/denied.zag" <<ZAG
script;
let cost: i64 = script_map_storage_bytes[i32](10) + 1 + 2 * $overhead;
let fill: *i8 = script_alloc(1048576 - cost - $overhead + 1);
if (fill == null as *i8) { return 2; }
let value = {"a": 0};
return 0;
ZAG
    compile_map "$tmp/denied.zag" "$tmp/denied-$policy" "$policy"
    set +e
    "$tmp/denied-$policy" >"$tmp/denied.out" 2>"$tmp/denied.err"
    status=$?
    set -e
    if [ "$status" -ne 1 ]; then
        echo "map literal allocation failure must exit 1, got $status ($policy)" >&2
        exit 1
    fi
    grep -Eqi 'map.*(alloc|memory|budget)|((alloc|memory|budget).*map)' "$tmp/denied.err"
    cat >"$tmp/constructor-denied.zag" <<ZAG
script;
let fill: *i8 = script_alloc(1048576 - $overhead);
if (fill == null as *i8) { return 2; }
let value = {"a": 0};
return 0;
ZAG
    compile_map "$tmp/constructor-denied.zag" "$tmp/constructor-denied-$policy" "$policy"
    set +e
    "$tmp/constructor-denied-$policy" >"$tmp/constructor-denied.out" 2>"$tmp/constructor-denied.err"
    status=$?
    set -e
    test "$status" -eq 1
    grep -q 'Zag Script map allocation failed' "$tmp/constructor-denied.err"
done

for kind in mixed key empty; do
    case "$kind" in
        mixed) literal='{"a": 1, "b": false}' ;;
        key) literal='{1: 2}' ;;
        empty) literal='{}' ;;
    esac
    printf 'script;\nlet bad = %s;\nreturn 0;\n' "$literal" >"$tmp/bad-$kind.zag"
    if "$compiler" "$tmp/bad-$kind.zag" -o "$tmp/bad-$kind" \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-$kind.log" 2>&1; then
        echo "invalid map literal unexpectedly compiled: $kind" >&2
        exit 1
    fi
    test ! -e "$tmp/bad-$kind"
done

echo "script map literals: PASS"
