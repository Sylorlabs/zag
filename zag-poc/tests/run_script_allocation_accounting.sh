#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
znc_bin=$(realpath "$znc_bin")
tmp_dir=$(mktemp -d /tmp/zag-script-accounting.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

printf '1234567890' >"$tmp_dir/input.txt"
printf 'script_memory_bytes=1048576\nmode=off\n' >"$tmp_dir/.zagd.conf"
printf 'script;\nlet data:[]u8=read_file("input.txt");\nif(data.len!=10){return 1;}\nif(script_alloc_used()!=10){return 2;}\nreturn 0;\n' >"$tmp_dir/read_ok.zag"
(cd "$tmp_dir" && "$znc_bin" read_ok.zag -o read_ok --no-zagd >/dev/null && ./read_ok)

printf 'script_memory_bytes=1048576\nmode=off\n' >"$tmp_dir/.zagd.conf"
dd if=/dev/zero of="$tmp_dir/large.bin" bs=1048576 count=1 status=none
printf 'script;\nlet data:[]u8=read_file("large.bin");\nif(data.len!=1048576){return 1;}\nif(script_alloc_used()!=1048576){return 2;}\nreturn 0;\n' >"$tmp_dir/read_boundary.zag"
(cd "$tmp_dir" && "$znc_bin" read_boundary.zag -o read_boundary --no-zagd >/dev/null && ./read_boundary)

printf 'script_memory_bytes=1048576\nmode=off\n' >"$tmp_dir/.zagd.conf"
dd if=/dev/zero of="$tmp_dir/over.bin" bs=1048576 count=1 status=none
printf x >>"$tmp_dir/over.bin"
printf 'script;\nlet data:[]u8=read_file("over.bin");\nif(data.len!=0){return 1;}\nif(script_alloc_used()!=0){return 2;}\nreturn 0;\n' >"$tmp_dir/read_over.zag"
(cd "$tmp_dir" && "$znc_bin" read_over.zag -o read_over --no-zagd >/dev/null && ./read_over 2>read_over.err && grep -q 'memory limit exceeded by read_file result' read_over.err)

printf 'script;\nlet result=process_run_timeout("printf bounded",1000,1048400);\nif(process_result_state(result)!=process_state_exited()){return 1;}\nif(!@strEq(process_result_output(result),"bounded")){return 2;}\nif(script_alloc_used()!=1048512){return 3;}\nreturn 0;\n' >"$tmp_dir/process_ok.zag"
(cd "$tmp_dir" && "$znc_bin" process_ok.zag -o process_ok --no-zagd >/dev/null && ./process_ok)

printf 'script;\nlet result=process_run_timeout("printf blocked",1000,1048576);\nreturn 0;\n' >"$tmp_dir/process_over.zag"
(cd "$tmp_dir" && "$znc_bin" process_over.zag -o process_over --no-zagd >/dev/null && ./process_over 2>process_over.err && grep -q 'memory limit exceeded by process capture' process_over.err)

printf 'script;\nstruct Pair{x:i64,y:i64}\nlet p:*Pair=new(Pair{.x=7,.y=9});\nif(p==null as *Pair){return 1;}\nif(p.*.x+p.*.y!=16){return 2;}\nif(script_alloc_used()!=16){return 3;}\nreturn 0;\n' >"$tmp_dir/new_ok.zag"
(cd "$tmp_dir" && "$znc_bin" new_ok.zag -o new_ok --no-zagd >/dev/null && ./new_ok)

printf 'script;\nstruct Pair{x:i64,y:i64}\nlet fill:*i8=script_alloc(1048570);\nlet p:*Pair=new(Pair{.x=7,.y=9});\nif(p!=null as *Pair){return 1;}\nif(script_alloc_used()!=1048570){return 2;}\nreturn 0;\n' >"$tmp_dir/new_over.zag"
(cd "$tmp_dir" && "$znc_bin" new_over.zag -o new_over --no-zagd >/dev/null && ./new_over)

# A strict imported helper keeps its explicit ordinary allocation behavior.
# Its `make` is neither rewritten nor falsely charged to the root ScriptContext.
cat >"$tmp_dir/strict_alloc.zag" <<'ZAG'
@import("std:list")
fn strict_make() ArrayList[u8] {
    let values:ArrayList[u8]=make[u8](2);
    push[u8](&values,7); push[u8](&values,9);
    return values;
}
ZAG
cat >"$tmp_dir/import_strict.zag" <<'ZAG'
script;
@import("strict_alloc.zag")
let before:i64=script_alloc_used();
let values:ArrayList[u8]=strict_make();
if(values.len!=2||values.data[0]!=7||values.data[1]!=9){return 1;}
if(script_alloc_used()!=before){return 2;}
return 0;
ZAG
(cd "$tmp_dir" && "$znc_bin" import_strict.zag -o import_strict --no-zagd >/dev/null && ./import_strict)

echo "script allocation accounting: PASS"
