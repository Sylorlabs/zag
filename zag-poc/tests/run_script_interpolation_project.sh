#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-interpolation-project.XXXXXX)
trap 'rc=$?; if [ "$rc" -ne 0 ]; then for log in "$tmp"/*.log; do [ ! -f "$log" ] || cat "$log" >&2; done; [ ! -f "$tmp/projected.zag" ] || head -12 "$tmp/projected.zag" >&2; fi; if [ "${ZAG_KEEP_TEST_TMP:-0}" = 1 ]; then echo "test artifacts: $tmp" >&2; else rm -rf "$tmp"; fi' EXIT
projector=${ZAG_INTERPOLATION_PROJECTOR:-}
if [ -z "$projector" ]; then
    "$compiler" selfhost/script_interpolation_project_test.zag --no-zagd --no-analyze -o "$tmp/project" >"$tmp/build.log" 2>&1
    projector="$tmp/project"
fi
cp selfhost/std/script_interpolate.zag selfhost/std/script_format.zag selfhost/std/script_map.zag "$tmp/"
printf '%s\n' 'name="interpolation-project"' 'edition="2027"' >"$tmp/zag.mod"
cat >"$tmp/input.zag" <<'ZAG'
@import("script_interpolate.zag")
extern fn _zag_script_context_init(limit:i64,capabilities:i64,execution_policy:i64)*opaque
extern fn _zag_script_context_shutdown(context:*opaque)void
fn next(counter:*i32)i32{counter.*=counter.*+1;return counter.*;}
fn main()i32{
    unsafe{
    let __zag_script_context:*opaque=_zag_script_context_init(1048576,7,16843009);
    let count:i32=0;
    let output:[]u8=f"{{λ}} {next(&count)}:{next(&count)} {false} {"a'b"}";
    if(count!=2||!@strEq(output,"{λ} 1:2 false a'b")){return 1;}
    _zag_script_context_shutdown(__zag_script_context);return 0;
    }
}
ZAG
"$projector" "$tmp/input.zag" >"$tmp/projected.zag" 2>"$tmp/project.log"
! grep -q '__zag_script_format(' "$tmp/projected.zag"
grep -q 'script_format_i64_checked(__zag_script_context,' "$tmp/projected.zag"
"$compiler" "$tmp/projected.zag" --no-zagd --no-analyze -o "$tmp/native" >"$tmp/native.log" 2>&1
"$tmp/native"
cat >"$tmp/map.zag" <<'ZAG'
@import("script_map.zag")
extern fn _zag_script_context_init(limit:i64,capabilities:i64,execution_policy:i64)*opaque
extern fn _zag_script_context_shutdown(context:*opaque)void
global let count:i32;
fn next()i32{count=count+1;return count;}
fn main()i32{
    unsafe{
    let __zag_script_context:*opaque=_zag_script_context_init(1048576,7,16843009);
    let values={"a":next(),"b":next(),"a":0};
    let empty:ScriptMap[i32]={};
    if(count!=2||script_list_len(values)!=2||script_list_len(empty)!=0){return 1;}
    if(script_list_get(values,"a")!=0||script_list_get(values,"b")!=2){return 2;}
    _zag_script_context_shutdown(__zag_script_context);return 0;
    }
}
ZAG
"$projector" "$tmp/map.zag" >"$tmp/map-projected.zag" 2>"$tmp/map-project.log"
! grep -q '__zag_script_map_literal(' "$tmp/map-projected.zag"
"$compiler" "$tmp/map-projected.zag" --no-zagd --no-analyze -o "$tmp/map-native" >"$tmp/map-native.log" 2>&1
"$tmp/map-native"
echo 'script interpolation/map typed native projection: PASS' 
