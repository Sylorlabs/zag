from pathlib import Path

source = Path("zag-poc/selfhost/typed.zag")
text = source.read_text()

old_print = '''fn zt_compiler_nonretaining_call(name:[]u8)i32{
    return (@strEq(name,"_zag_println")||@strEq(name,"_zag_eprintln")||
'''
new_print = '''fn zt_compiler_nonretaining_call(name:[]u8)i32{
    return (@strEq(name,"_zag_print")||@strEq(name,"_zag_println")||@strEq(name,"_zag_eprintln")||
'''
if text.count(old_print) != 1:
    raise SystemExit(f"expected one compiler output bridge table, found {text.count(old_print)}")
text = text.replace(old_print, new_print, 1)

old_store = '''fn zt_agg_nonlocal_store(n:*Node,target:ZTAggPath,flow:ZTAggFlow,context:[]u8,arena:*ArrayList[ZTAggPathNode])i32{
    let owner:[]u8=zt_agg_expr_stored_root(n,flow.prov,1,arena);if(owner.len==0){owner=zt_owned_expr_root(n,flow.owners,flow.owner_aliases);}
    if(owner.len==0){let oi:i32=0;while(oi<flow.owners.len&&owner.len==0){if(zt_expr_uses_name(n,flow.owners.data[oi],flow.owner_aliases)==1){owner=flow.owners.data[oi];}oi=oi+1;}}
    let stack:[]u8=zt_agg_expr_stored_root(n,flow.prov,2,arena);if(stack.len==0){stack=zt_stack_return_address_root(n,flow.locals,flow.stack_aliases);}
    let local:i32=(target.name.len>0&&((target.depth==0&&zt_in_names(flow.bindings,target.name)==1)||zt_in_names(flow.containers,target.name)==1)) as i32;
    if(local==1){return 0;}
    let errors:i32=0;
    if(owner.len>0){errors=errors+zt_machine_error(_zag_str_concat("owned allocation escapes through non-local aggregate store (root `",_zag_str_concat(owner,"`)")),context);}
    if(stack.len>0){errors=errors+zt_machine_error(_zag_str_concat("address of local `",_zag_str_concat(stack,"` escapes through non-local aggregate store")),context);}
    return errors;
}
'''
new_store = '''fn zt_agg_nonlocal_store(n:*Node,target:ZTAggPath,flow:ZTAggFlow,context:[]u8,arena:*ArrayList[ZTAggPathNode])i32{
    let owner:[]u8=zt_agg_expr_stored_root(n,flow.prov,1,arena);if(owner.len==0){owner=zt_owned_expr_root(n,flow.owners,flow.owner_aliases);}
    if(owner.len==0){let oi:i32=0;while(oi<flow.owners.len&&owner.len==0){if(zt_expr_uses_name(n,flow.owners.data[oi],flow.owner_aliases)==1){owner=flow.owners.data[oi];}oi=oi+1;}}
    let stack:[]u8=zt_agg_expr_stored_root(n,flow.prov,2,arena);if(stack.len==0){stack=zt_stack_return_address_root(n,flow.locals,flow.stack_aliases);}
    let local:i32=(target.name.len>0&&((target.depth==0&&zt_in_names(flow.bindings,target.name)==1)||zt_in_names(flow.containers,target.name)==1)) as i32;
    if(local==1){return 0;}
    // `_ = expr` is an explicit discard, not storage. Calls still undergo the
    // normal argument escape/consume checks above, so this suppresses only the
    // false claim that a stack address escaped through the discard target.
    let discard:i32=(target.depth==0&&@strEq(target.name,"_")) as i32;
    let errors:i32=0;
    if(owner.len>0){errors=errors+zt_machine_error(_zag_str_concat("owned allocation escapes through non-local aggregate store (root `",_zag_str_concat(owner,"`)")),context);}
    if(stack.len>0&&discard==0){errors=errors+zt_machine_error(_zag_str_concat("address of local `",_zag_str_concat(stack,"` escapes through non-local aggregate store")),context);}
    return errors;
}
'''
if text.count(old_store) != 1:
    raise SystemExit(f"expected one aggregate nonlocal-store gate, found {text.count(old_store)}")
text = text.replace(old_store, new_store, 1)
source.write_text(text)

check = Path("zag-poc/tests/check_v2_ui_nonretaining.sh")
check.write_text(r'''#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-v2-ui-nonretaining.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/positive" "$tmp/negative"
printf 'name = "v2uinonretaining"\nversion = "0"\nedition = "2027"\n' > "$tmp/positive/zag.mod"
cat > "$tmp/positive/main.zag" <<'ZAG'
fn mutate(value: *i64) i32 {
    value.* = value.* + 1;
    return value.* as i32;
}
fn main() i32 {
    let value: i64 = 1;
    _ = mutate(&value);
    let text: []u8 = _zag_i64_to_str(value);
    _zag_print(text);
    _zag_str_free(text);
    if (value != 2) { return 3; }
    return 0;
}
ZAG
(cd "$tmp/positive" && "$OLDPWD/$ZNC" main.zag --no-zagd --analyze-strict --no-foreground-cache -o out)
output=$("$tmp/positive/out")
[ "$output" = "2" ] || { echo "unexpected positive output: $output"; exit 1; }

printf 'name = "v2uistackescape"\nversion = "0"\nedition = "2027"\n' > "$tmp/negative/zag.mod"
cat > "$tmp/negative/main.zag" <<'ZAG'
struct Escaped { pointer: *i64 }
fn leak() Escaped {
    let value: i64 = 9;
    return Escaped{ .pointer = &value };
}
fn main() i32 { let escaped: Escaped = leak(); return escaped.pointer.* as i32; }
ZAG
if (cd "$tmp/negative" && "$OLDPWD/$ZNC" main.zag --no-zagd --analyze-strict --no-foreground-cache -o out) >"$tmp/negative/log" 2>&1 || [ -e "$tmp/negative/out" ]; then
    echo "stack-address return unexpectedly compiled"
    cat "$tmp/negative/log"
    exit 1
fi
grep -q 'address of local' "$tmp/negative/log" || { cat "$tmp/negative/log"; exit 1; }
echo "v2 UI non-retaining/discard contracts: PASS"
''')
