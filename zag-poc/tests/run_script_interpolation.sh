#!/usr/bin/env bash
# Full driver integration; run against the parent's newly built compiler.
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-interpolation.XXXXXX)
trap 'rc=$?; if [ "$rc" -ne 0 ]; then for log in "$tmp"/*.log; do [ ! -f "$log" ] || cat "$log" >&2; done; [ ! -f "$tmp/view.zag" ] || head -20 "$tmp/view.zag" >&2; fi; if [ "${ZAG_KEEP_TEST_TMP:-0}" = 1 ]; then echo "test artifacts: $tmp" >&2; else rm -rf "$tmp"; fi' EXIT
printf '%s\n' 'name="interpolation"' 'edition="2027"' >"$tmp/zag.mod"
printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' >"$tmp/.zagd.conf"
compile() {
    "$compiler" "$1" --no-zagd --no-analyze --no-foreground-cache -o "$2" "${@:3}" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log" >&2; return 1; }
}
cat >"$tmp/main.zs" <<'ZAG'
script;
fn next(counter:*i32)i32 { counter.*=counter.*+1; return counter.*; }
let counter:i32=0;
let value:[]u8=f"{{λ}} {next(&counter)}:{next(&counter)} {true} {"a'b"}";
if (!@strEq(value,"{λ} 1:2 true a'b") || counter!=2) { return 1; }
let minimum:i64=(0-9223372036854775807)-1;
let maximum:i64=9223372036854775807;
if (!@strEq(f"{minimum}:{maximum}","-9223372036854775808:9223372036854775807")) { return 2; }
if (!@strEq(f"{false}:{""}","false:")) { return 3; }
if (!@strEq(f"{{}} \" \\ \n", "{} \" \\ \n")) { return 4; }
if (!@strEq("{counter}","{counter}")) { return 5; }
if (!@strEq(f"plain", "plain")) { return 6; }
return 0;
ZAG
compile "$tmp/main.zs" "$tmp/main"
"$tmp/main"
pass=1
for operation in view expand; do
    level=--level; if [ "$operation" = expand ]; then level=--to; fi
    "$compiler" "$operation" "$tmp/main.zs" "$level" explicit --no-zagd >"$tmp/$operation.zag" 2>"$tmp/$operation.err"
    ! grep -q '__zag_script_format(' "$tmp/$operation.zag"
    grep -q 'script_format_i64_checked' "$tmp/$operation.zag"
    compile "$tmp/$operation.zag" "$tmp/$operation"
    "$tmp/$operation"
    pass=$((pass+1))
done
for expr in '1.5' '(1 as u64)' 'null' '{"x":1}'; do
    if [ "$expr" = '{"x":1}' ]; then
        printf 'script;\nlet bad=f"{ {"x":1} }";\nreturn 0;\n' >"$tmp/bad.zs"
    else
        printf 'script;\nlet bad=f"{%s}";\nreturn 0;\n' "$expr" >"$tmp/bad.zs"
    fi
    if "$compiler" "$tmp/bad.zs" --no-zagd --no-analyze -o "$tmp/bad" >"$tmp/bad.log" 2>&1; then echo "unsupported interpolation compiled: $expr" >&2; exit 1; fi
    grep -Eqi 'interpol|format' "$tmp/bad.log"
    test ! -e "$tmp/bad"
    pass=$((pass+1))
done
for literal in 'f"plain"' 'f"{1}"'; do
    printf '@import("std:script_interpolate")\nfn main()i32{let bad=%s;return 0;}\n' "$literal" >"$tmp/no-context.zag"
    if "$compiler" "$tmp/no-context.zag" --no-zagd --no-analyze -o "$tmp/no-context" >"$tmp/context.log" 2>&1; then echo 'context-free interpolation compiled' >&2; exit 1; fi
    grep -Eqi 'context' "$tmp/context.log"
    pass=$((pass+1))
done
for policy in script_process_arena script_bounded_heap; do
    overhead=0; if [ "$policy" = script_bounded_heap ]; then overhead=16; fi
    for denied in 0 1; do
        cat >"$tmp/budget.zs" <<ZAG
script;
let fill:*i8=script_alloc(1048576-65537-3*$overhead+$denied);
if(fill==null as *i8){return 2;}
let value:[]u8=f"{0}";
if(!@strEq(value,"0")){return 3;}
if(script_alloc_used()!=1048576){return 4;}
return 0;
ZAG
        compile "$tmp/budget.zs" "$tmp/budget" --script-allocator "$policy"
        if [ "$denied" = 0 ]; then "$tmp/budget"; else
            if "$tmp/budget" >"$tmp/denied.out" 2>"$tmp/denied.err"; then echo 'over-budget interpolation succeeded' >&2; exit 1; fi
            grep -q 'interpolation: allocation or output limit exceeded' "$tmp/denied.err"
            test ! -s "$tmp/denied.out"
        fi
        pass=$((pass+1))
    done
done
echo "script interpolation pass=$pass fail=0"
