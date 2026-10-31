#!/usr/bin/env bash
set -euo pipefail

script_dir=$(cd "$(dirname "$0")/.." && pwd)
caller_dir=$(pwd)
cd "$script_dir"
znc_bin=${ZNC:-./znc}
case "$znc_bin" in
    /*) ;;
    *) znc_bin="$caller_dir/${znc_bin#./}" ;;
esac
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-cli.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

compile_and_expect_status() {
    local source=$1 binary=$2 expected=$3 actual
    "$znc_bin" "$source" -o "$binary" \
        --no-analyze --no-zagd --no-foreground-cache >/dev/null
    set +e
    "$binary" >/dev/null 2>&1
    actual=$?
    set -e
    test "$actual" -eq "$expected"
}

"$znc_bin" script tests/script_frontend/cli_markerless.zag \
    --cpu generic -o "$tmp_dir/markerless" --no-analyze >/dev/null
set +e
"$tmp_dir/markerless"
markerless_status=$?
set -e
test "$markerless_status" -eq 5

"$znc_bin" script tests/script_frontend/basic.zag \
    -o "$tmp_dir/already-marked" --no-analyze >/dev/null

# The documented compact command compiles and runs a markerless `.zag` source
# under the same Script profile; a successful child status is surfaced by the
# CLI rather than requiring a caller to locate a generated binary.
printf '%s\n' 'let code: i32 = 0; return code;' >"$tmp_dir/run-markerless.zag"
"$znc_bin" script "$tmp_dir/run-markerless.zag" --run --no-zagd --no-analyze \
    >"$tmp_dir/run-markerless.out"
grep -q 'znc: program exited 0' "$tmp_dir/run-markerless.out"

"$znc_bin" explain tests/script_frontend/basic.zag --format json >"$tmp_dir/explain.json"
grep -q '"profile":{"value":"script","basis":"proven"}' "$tmp_dir/explain.json"
grep -q '"allocator":{"value":"script_process_arena","basis":"derived"}' "$tmp_dir/explain.json"
grep -q '"script_memory_bytes":{"value":67108864' "$tmp_dir/explain.json"
grep -q '"hidden_copies":' "$tmp_dir/explain.json"
grep -q '"semantic_facts":{"format":"zag-semantic-manifest-v1"' "$tmp_dir/explain.json"
grep -q 'decl_fn=' "$tmp_dir/explain.json"
grep -q 'value_type=' "$tmp_dir/explain.json"
grep -q 'basis=explicit' "$tmp_dir/explain.json"
grep -q 'expr_fact=' "$tmp_dir/explain.json"
grep -q 'type_basis=typed' "$tmp_dir/explain.json"
grep -q 'effect_basis=sema' "$tmp_dir/explain.json"
"$znc_bin" explain tests/script_frontend/basic.zag --format text >"$tmp_dir/explain.txt"
grep -q 'expression types/effects: typed frontend and sema witnesses' "$tmp_dir/explain.txt"
grep -q 'hidden copies:' "$tmp_dir/explain.txt"
grep -q 'expr_fact=' "$tmp_dir/explain.txt"

"$znc_bin" view tests/script_frontend/basic.zag --level explicit \
    --output "$tmp_dir/view-explicit.zag" --no-zagd >"$tmp_dir/view-explicit.log"
grep -q 'harden status: preview' "$tmp_dir/view-explicit.log"
grep -q 'fn main() i32' "$tmp_dir/view-explicit.zag"
grep -q 'extern fn _zag_script_context_init' "$tmp_dir/view-explicit.zag"
grep -q 'fn __zag_hardened_status_boundary' "$tmp_dir/view-explicit.zag"
"$znc_bin" "$tmp_dir/view-explicit.zag" -o "$tmp_dir/view-explicit-bin" --no-analyze --no-zagd >/dev/null
test -x "$tmp_dir/view-explicit-bin"
set +e
"$tmp_dir/view-explicit-bin" >/dev/null 2>&1
view_explicit_status=$?
set -e
test "$view_explicit_status" -eq 7
# The edition exception is bound to the exact four-spelling compiler wrapper;
# an edited generated file with an extra opaque pointer must still fail closed.
cp "$tmp_dir/view-explicit.zag" "$tmp_dir/view-explicit-forged.zag"
printf '%s\n' 'extern fn __forged_context_use(context:*opaque) void' >>"$tmp_dir/view-explicit-forged.zag"
if "$znc_bin" "$tmp_dir/view-explicit-forged.zag" -o "$tmp_dir/view-explicit-forged-bin" --no-analyze --no-zagd >/dev/null 2>&1; then
    echo "edited explicit wrapper unexpectedly bypassed the edition gate" >&2
    exit 1
fi
test ! -e "$tmp_dir/view-explicit-forged-bin"
"$znc_bin" view tests/script_frontend/basic.zag --level explicit --format json \
    --output "$tmp_dir/view-explicit-json.zag" --no-zagd >"$tmp_dir/view-explicit.json"
grep -q '"status":"preview"' "$tmp_dir/view-explicit.json"
grep -q '"candidate_compilable":true' "$tmp_dir/view-explicit.json"
test -s "$tmp_dir/view-explicit-json.zag"
cmp "$tmp_dir/view-explicit-json.zag" "$tmp_dir/view-explicit.zag"

"$znc_bin" expand tests/script_frontend/basic.zag --to explicit --no-zagd \
    --output "$tmp_dir/expand-explicit.zag" > "$tmp_dir/expand-explicit.log"
cmp "$tmp_dir/view-explicit.zag" "$tmp_dir/expand-explicit.zag"

# Explain witnesses are emitted from the already-bound Script root AST. They
# name only facts the runtime implementation proves, distinguish zero from
# dynamic unknown bytes, and bind parsed calls to their parser origin rather
# than guessing statement locations.
cat >"$tmp_dir/explain-operations.zag" <<'EOF'
script;
let data = read_file("input.txt");
let joined = string_concat("one", "two");
let values = list(1);
append(values, 2);
let base = path_basename("dir/file.txt");
EOF
"$znc_bin" explain "$tmp_dir/explain-operations.zag" --format json --no-zagd >"$tmp_dir/explain-operations.json"
grep -q '"implicit_operations":{"scope":"compiler_bound_root_script_calls","items":\[' "$tmp_dir/explain-operations.json"
grep -q '"operation":"read_file","allocation":{"value":"script_context","bytes":"unknown","basis":"proven"},"copy":{"value":"file_bytes_to_script_context","bytes":"unknown","basis":"proven"}' "$tmp_dir/explain-operations.json"
grep -q '"operation":"string_concat"' "$tmp_dir/explain-operations.json"
grep -q '"operation":"list_append","allocation":{"value":"conditional_script_context"' "$tmp_dir/explain-operations.json"
grep -q '"operation":"path_basename","allocation":{"value":"zero","bytes":"0","basis":"proven"},"copy":{"value":"zero","bytes":"0","basis":"proven"}' "$tmp_dir/explain-operations.json"
grep -Eq '"source_location":\{"module":"[^"]+","line":[0-9]+,"col":[0-9]+,"byte_start":[0-9]+,"byte_end":[0-9]+,"stable_id":[0-9]+,"exact":true,"basis":"parser-origin"\}' "$tmp_dir/explain-operations.json"
grep -q '"unresolved":\["synthetic wrapper origins remain unavailable","strict-library allocation contracts remain explicit"\]' "$tmp_dir/explain-operations.json"
"$znc_bin" explain "$tmp_dir/explain-operations.zag" --format text --no-zagd >"$tmp_dir/explain-operations.txt"
grep -Eq '^implicit operation: read_file allocation=script_context allocation_bytes=unknown copy=file_bytes_to_script_context copy_bytes=unknown location=[^[:space:]]+:[0-9]+:[0-9]+ bytes=[0-9]+\.\.[0-9]+ stable_id=[0-9]+ exact=false basis=projected-origin provenance=proven$' "$tmp_dir/explain-operations.txt"
grep -Eq '^implicit operation: list_append allocation=conditional_script_context allocation_bytes=unknown copy=conditional_existing_elements_on_growth copy_bytes=unknown location=[^[:space:]]+:[0-9]+:[0-9]+ bytes=[0-9]+\.\.[0-9]+ stable_id=[0-9]+ exact=true basis=parser-origin provenance=proven$' "$tmp_dir/explain-operations.txt"
grep -Eq '^implicit operation: path_basename allocation=zero allocation_bytes=0 copy=zero copy_bytes=0 location=[^[:space:]]+:[0-9]+:[0-9]+ bytes=[0-9]+\.\.[0-9]+ stable_id=[0-9]+ exact=false basis=projected-origin provenance=proven$' "$tmp_dir/explain-operations.txt"
grep -q 'implicit operations: compiler-bound root Script calls carry parser-backed locations; synthetic wrappers remain unavailable \[proven\]' "$tmp_dir/explain-operations.txt"

# Compact projections retain their enclosing origin but are explicitly marked
# inexact; no line-order or callee-name heuristic may upgrade them to exact.
cat >"$tmp_dir/explain-projected.zs" <<'EOF'
joined = string_concat("one", "two")
return joined
EOF
"$znc_bin" explain "$tmp_dir/explain-projected.zs" --format json --no-zagd >"$tmp_dir/explain-projected.json"
grep -Eq '"source_location":\{"module":"[^"]+","line":[0-9]+,"col":[0-9]+,"byte_start":[0-9]+,"byte_end":[0-9]+,"stable_id":[0-9]+,"exact":false,"basis":"projected-origin"\}' "$tmp_dir/explain-projected.json"
# The report never builds an unbounded operation table. It emits at most 64
# root witnesses and carries an explicit truncation bit instead of a fake total.
printf 'script;\n' >"$tmp_dir/explain-capped.zag"
for index in $(seq 1 65); do
    printf 'let part%s = path_basename("dir/file");\n' "$index" >>"$tmp_dir/explain-capped.zag"
done
"$znc_bin" explain "$tmp_dir/explain-capped.zag" --format json --no-zagd >"$tmp_dir/explain-capped.json"
grep -q '"emitted":64,"truncated":true,"basis":"proven"' "$tmp_dir/explain-capped.json"
printf 'fn main() i32 { return 0; }\n' >"$tmp_dir/explain-strict.zag"
"$znc_bin" explain "$tmp_dir/explain-strict.zag" --format json --no-zagd >"$tmp_dir/explain-strict.json"
grep -q '"implicit_operations":{"scope":"not_script","items":\[\],"emitted":0,"truncated":false,"basis":"proven"}' "$tmp_dir/explain-strict.json"

if "$znc_bin" explain tests/script_frontend/basic.zag --format yaml >/dev/null 2>&1; then
    echo "invalid explain format unexpectedly succeeded" >&2
    exit 1
fi
if "$znc_bin" check tests/script_frontend/basic.zag --strict >/dev/null 2>&1; then
    echo "strict script check unexpectedly succeeded" >&2
    exit 1
fi
strict_collection=$("$znc_bin" check tests/script_frontend/materialized_args.zag --strict --no-zagd 2>&1 || true)
printf '%s\n' "$strict_collection" | grep -q 'temporary collection remains tied to the Script context'
"$znc_bin" --cpu native tests/script_frontend/basic.zag -o "$tmp_dir/native" --no-analyze --no-zagd >/dev/null

"$znc_bin" harden tests/script_frontend/basic.zag >"$tmp_dir/harden.txt"
grep -q 'fn main() i32' "$tmp_dir/harden.txt"
grep -q 'const __zag_hardened_script_memory_limit: i64 = ' "$tmp_dir/harden.txt"
grep -q 'extern fn _zag_script_context_init' "$tmp_dir/harden.txt"
grep -q 'fn __zag_hardened_status_boundary' "$tmp_dir/harden.txt"
grep -q 'harden report: conservative explicit context/allocator/capability expansion' "$tmp_dir/harden.txt"
"$znc_bin" harden tests/script_frontend/basic.zag \
    --output "$tmp_dir/hardened.zag" >"$tmp_dir/harden-report.txt"
test -e "$tmp_dir/hardened.zag"
grep -q 'fn main() i32' "$tmp_dir/hardened.zag"

# Marker removal is token-span based, so legal whitespace between `script` and
# its semicolon cannot leave a stray semicolon in the strict candidate.
printf 'script    ;\nreturn 7;\n' >"$tmp_dir/harden-spaced-marker.zag"
"$znc_bin" harden "$tmp_dir/harden-spaced-marker.zag" \
    --output "$tmp_dir/harden-spaced-marker-output.zag" --no-zagd >/dev/null
grep -q 'return 7;' "$tmp_dir/harden-spaced-marker-output.zag"
! grep -q '^script' "$tmp_dir/harden-spaced-marker-output.zag"
"$znc_bin" check "$tmp_dir/harden-spaced-marker-output.zag" --no-zagd >/dev/null
compile_and_expect_status "$tmp_dir/harden-spaced-marker-output.zag" \
    "$tmp_dir/harden-spaced-marker-output" 7
"$znc_bin" "$tmp_dir/hardened.zag" -o "$tmp_dir/hardened" --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/hardened"
hardened_status=$?
set -e
test "$hardened_status" -eq 7

# AST rendering must preserve structured loop control rather than replacing
# break/continue nodes with formatter placeholders.
cat >"$tmp_dir/harden-loop.zag" <<'EOF'
script;
let i: i32 = 0;
while (i < 4) {
    i = i + 1;
    if (i == 2) { continue; }
    if (i == 3) { break; }
}
return i;
EOF
"$znc_bin" harden "$tmp_dir/harden-loop.zag" \
    --output "$tmp_dir/harden-loop-output.zag" --no-zagd >/dev/null
grep -q 'continue;' "$tmp_dir/harden-loop-output.zag"
grep -q 'break;' "$tmp_dir/harden-loop-output.zag"
"$znc_bin" check "$tmp_dir/harden-loop-output.zag" --no-zagd >/dev/null
compile_and_expect_status "$tmp_dir/harden-loop-output.zag" \
    "$tmp_dir/harden-loop-output" 3

"$znc_bin" harden tests/script_frontend/harden_declarations.zag \
    --output "$tmp_dir/hardened-declarations.zag" >/dev/null
"$znc_bin" "$tmp_dir/hardened-declarations.zag" -o "$tmp_dir/hardened-declarations" --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/hardened-declarations"
declaration_status=$?
set -e
test "$declaration_status" -eq 42

"$znc_bin" harden tests/script_frontend/basic.zag --format json --no-zagd > "$tmp_dir/harden.json"
grep -q '"status":"preview"' "$tmp_dir/harden.json"
grep -q '"source_modified":false' "$tmp_dir/harden.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden.json"
grep -q '"parity_tests"' "$tmp_dir/harden.json"
grep -q '"unsupported"' "$tmp_dir/harden.json"

# `harden` remains a compatibility alias only; the alias is explicit in stderr.
"$znc_bin" harden tests/script_frontend/basic.zag --format json --no-zagd \
    > "$tmp_dir/harden-alias.json" 2> "$tmp_dir/harden-alias.err"
grep -q 'warning: `harden` is deprecated' "$tmp_dir/harden-alias.err"
grep -q '"status":"preview"' "$tmp_dir/harden-alias.json"

# A compiler-bound Script prelude call has an implicit context/capability
# contract. The bound AST is rendered into strict Zag, with the required
# compiler-owned modules made explicit and the context handle renamed at the
# strict boundary.
cat >"$tmp_dir/harden-prelude.zag" <<'EOF'
script;
let contents = read_file("input.txt");
return 0;
EOF
printf 'hello from the Script context\n' >"$tmp_dir/input.txt"
"$znc_bin" harden "$tmp_dir/harden-prelude.zag" --format json \
    --output "$tmp_dir/harden-prelude-output.zag" --no-zagd >"$tmp_dir/harden-prelude.json"
grep -q '"status":"preview"' "$tmp_dir/harden-prelude.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-prelude.json"
! grep -q '"kind":"script_prelude"' "$tmp_dir/harden-prelude.json"
test -s "$tmp_dir/harden-prelude-output.zag"
grep -q '@import("std:script_io")' "$tmp_dir/harden-prelude-output.zag"
! grep -q '@import("std:process")' "$tmp_dir/harden-prelude-output.zag"
! grep -q '@import("std:script_list")' "$tmp_dir/harden-prelude-output.zag"
grep -q 'script_read_file' "$tmp_dir/harden-prelude-output.zag"
"$znc_bin" check "$tmp_dir/harden-prelude-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-prelude-output.zag" -o "$tmp_dir/harden-prelude" --no-analyze --no-zagd >/dev/null
(cd "$tmp_dir" && ./harden-prelude)

# The bounded process helper is materialized into the explicit preview with
# its compiler-owned process prelude and remains checkable/runnable as a
# bounded native program.
cat >"$tmp_dir/harden-process.zag" <<'EOF'
script;
let result = process_run_timeout("true", 1000, 64);
return 0;
EOF
"$znc_bin" harden "$tmp_dir/harden-process.zag" --format json \
    --output "$tmp_dir/harden-process-output.zag" --no-zagd >"$tmp_dir/harden-process.json"
grep -q '"status":"preview"' "$tmp_dir/harden-process.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-process.json"
test -s "$tmp_dir/harden-process-output.zag"
grep -q '@import("std:process")' "$tmp_dir/harden-process-output.zag"
"$znc_bin" check "$tmp_dir/harden-process-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-process-output.zag" -o "$tmp_dir/harden-process" --no-analyze --no-zagd >/dev/null
"$tmp_dir/harden-process"

# Ordinary user-defined scalar calls are also materialized through the bound
# AST. Context-sensitive and resource calls remain fail-closed below this
# bounded explicit-expansion contract.
cat >"$tmp_dir/harden-call.zag" <<'EOF'
fn harden_call_helper(x:i32)i32 { return x + 1; }
script;
let value:i32 = harden_call_helper(41);
return value;
EOF
"$znc_bin" harden "$tmp_dir/harden-call.zag" --format json \
    --output "$tmp_dir/harden-call-output.zag" --no-zagd \
    >"$tmp_dir/harden-call.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-call.json"
"$znc_bin" check "$tmp_dir/harden-call-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-call-output.zag" -o "$tmp_dir/harden-call" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-call" >/dev/null 2>&1
harden_call_status=$?
set -e
test "$harden_call_status" -eq 42

# The same source-preserving explicit boundary handles a declaration-proven
# two-argument i64 call. This remains a local, captureless scalar witness;
# imported/contextual/resource calls stay outside the bounded expansion.
cat >"$tmp_dir/harden-i64-call.zag" <<'EOF'
fn harden_i64_call_helper(a:i64,b:i64) i64 { return a + b; }
script;
let value:i64 = harden_i64_call_helper(40,2);
return 42;
EOF
"$znc_bin" harden "$tmp_dir/harden-i64-call.zag" --format json \
    --output "$tmp_dir/harden-i64-call-output.zag" --no-zagd \
    >"$tmp_dir/harden-i64-call.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-i64-call.json"
grep -q 'harden_i64_call_helper' "$tmp_dir/harden-i64-call-output.zag"
grep -q 'harden_i64_call_helper(40, 2)' "$tmp_dir/harden-i64-call-output.zag"
"$znc_bin" check "$tmp_dir/harden-i64-call-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-i64-call-output.zag" -o "$tmp_dir/harden-i64-call" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-i64-call" >/dev/null 2>&1
harden_i64_call_status=$?
set -e
test "$harden_i64_call_status" -eq 42

# Keep the explicit scalar-call witness width-independent for the bounded
# primitive path: a declaration-proven two-argument i32 call must survive
# source-preserving expansion, strict checking, and native execution too.
cat >"$tmp_dir/harden-i32-call.zag" <<'EOF'
fn harden_i32_call_helper(a:i32,b:i32) i32 { return a + b; }
script;
let value:i32 = harden_i32_call_helper(40,2);
return value;
EOF
"$znc_bin" harden "$tmp_dir/harden-i32-call.zag" --format json \
    --output "$tmp_dir/harden-i32-call-output.zag" --no-zagd \
    >"$tmp_dir/harden-i32-call.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-i32-call.json"
grep -q 'harden_i32_call_helper' "$tmp_dir/harden-i32-call-output.zag"
grep -q 'harden_i32_call_helper(40, 2)' "$tmp_dir/harden-i32-call-output.zag"
"$znc_bin" check "$tmp_dir/harden-i32-call-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-i32-call-output.zag" -o "$tmp_dir/harden-i32-call" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-i32-call" >/dev/null 2>&1
harden_i32_call_status=$?
set -e
test "$harden_i32_call_status" -eq 42

# The same bounded process expansion is valid in an explicit edition-2026
# project. The generated strict candidate is still checked and executed; the
# root edition must not be a proxy for imported std:process implementation
# authority.
mkdir -p "$tmp_dir/harden-process-2026"
printf '%s\n' 'name = "harden-process-2026"' 'edition = "2026"' >"$tmp_dir/harden-process-2026/zag.mod"
cp "$tmp_dir/harden-process.zag" "$tmp_dir/harden-process-2026/app.zag"
"$znc_bin" harden "$tmp_dir/harden-process-2026/app.zag" \
    --format json --output "$tmp_dir/harden-process-2026/generated.zag" \
    --no-zagd >"$tmp_dir/harden-process-2026/report.json"
grep -q '"status":"preview"' "$tmp_dir/harden-process-2026/report.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-process-2026/report.json"
"$znc_bin" check "$tmp_dir/harden-process-2026/generated.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-process-2026/generated.zag" \
    -o "$tmp_dir/harden-process-2026/bin" --no-analyze --no-zagd >/dev/null
"$tmp_dir/harden-process-2026/bin"

# Propagated error unions use the same explicit catch/report boundary as the
# compiler-generated Script wrapper, instead of being rejected by expansion.
cat >"$tmp_dir/harden-try.zag" <<'EOF'
error { Failed }
fn fail() !i32 { return error.Failed; }
script;
let value = try fail();
return value;
EOF
"$znc_bin" harden "$tmp_dir/harden-try.zag" --format json \
    --output "$tmp_dir/harden-try-output.zag" --no-zagd >"$tmp_dir/harden-try.json"
grep -q '"status":"preview"' "$tmp_dir/harden-try.json"
grep -q 'propagated root errors use an explicit catch/report boundary' "$tmp_dir/harden-try.json"
grep -q '__zag_hardened_script_body(__zag_script_context) catch' "$tmp_dir/harden-try-output.zag"
grep -F -q 'fn __zag_hardened_script_body(__zag_script_context:*opaque) !i32' "$tmp_dir/harden-try-output.zag"
"$znc_bin" check "$tmp_dir/harden-try-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-try-output.zag" -o "$tmp_dir/harden-try" --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-try" >"$tmp_dir/harden-try.out" 2>"$tmp_dir/harden-try.err"
harden_try_status=$?
set -e
test "$harden_try_status" -eq 1
grep -q 'uncaught Zag Script error code' "$tmp_dir/harden-try.err"

# --output publishes through an exclusive sibling staging file and a
# create-only final rename. A human-owned final path is never overwritten.
printf 'human-owned output\n' >"$tmp_dir/atomic-output.zag"
if "$znc_bin" harden tests/script_frontend/basic.zag \
    --output "$tmp_dir/atomic-output.zag" --no-zagd >/dev/null 2>&1; then
    echo "harden unexpectedly overwrote an existing output" >&2
    exit 1
fi
test "$(cat "$tmp_dir/atomic-output.zag")" = "human-owned output"

# `harden` is a source-preserving compatibility alias. The removed legacy
# apply mode must reject before candidate publication or execution of the
# caller-supplied command, leaving no rollback file or other side effect.
mkdir "$tmp_dir/apply-refused"
cp tests/script_frontend/basic.zag "$tmp_dir/apply-refused/app.zag"
cp "$tmp_dir/apply-refused/app.zag" "$tmp_dir/apply-refused/expected.zag"
if (cd "$tmp_dir/apply-refused" && "$znc_bin" harden app.zag --apply \
    --output derived.zag --test-command 'touch parity-command-ran' \
    --format json --no-zagd > report.json 2> report.err); then
    echo "removed harden --apply mode unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'harden: --apply is no longer supported' "$tmp_dir/apply-refused/report.err"
cmp "$tmp_dir/apply-refused/app.zag" "$tmp_dir/apply-refused/expected.zag"
test ! -e "$tmp_dir/apply-refused/app.zag.harden.bak"
test ! -e "$tmp_dir/apply-refused/derived.zag"
test ! -e "$tmp_dir/apply-refused/parity-command-ran"

# Project Script defaults reach foreground code generation. Explicit CLI CPU
# selection wins; regular Zag remains independent of Script defaults.
mkdir -p "$tmp_dir/project"
printf 'name = "planner-e2e"\n' > "$tmp_dir/project/zag.mod"
cp tests/script_frontend/basic.zag "$tmp_dir/project/app.zag"
printf 'mode=off\ncpu=native\nallocator=script_process_arena\ndevice=cpu\nlayout=compiler_owned\n' > "$tmp_dir/project/.zagd.conf"
(cd "$tmp_dir/project" && "$znc_bin" explain app.zag --format text --no-zagd) > "$tmp_dir/planner-explain.txt"
grep -q 'execution plan: cpu=native, device=cpu, layout=compiler_owned' "$tmp_dir/planner-explain.txt"
(cd "$tmp_dir/project" && "$znc_bin" explain app.zag --format json --no-zagd) > "$tmp_dir/planner-explain.json"
grep -q '"execution_plan":{"cpu":"native","device":"cpu","layout":"compiler_owned","basis":"derived"}' "$tmp_dir/planner-explain.json"
(cd "$tmp_dir/project" && "$znc_bin" app.zag -o configured --no-analyze --no-zagd >/dev/null)
(cd "$tmp_dir/project" && "$znc_bin" app.zag -o explicit --cpu generic --no-analyze --no-zagd >/dev/null)

printf 'mode=off\nallocator=unsupported_allocator\ndevice=cpu\nlayout=compiler_owned\n' > "$tmp_dir/project/.zagd.conf"
if (cd "$tmp_dir/project" && "$znc_bin" app.zag -o rejected --no-analyze --no-zagd >/dev/null 2>&1); then
    echo "unsupported automatic Script default unexpectedly accepted" >&2
    exit 1
fi
(cd "$tmp_dir/project" && "$znc_bin" app.zag -o overridden --script-allocator script_process_arena --device cpu --layout compiler_owned --no-analyze --no-zagd >/dev/null)
printf 'fn main() i32 { return 0; }\n' > "$tmp_dir/project/regular.zag"
(cd "$tmp_dir/project" && "$znc_bin" regular.zag -o regular --no-analyze --no-zagd >/dev/null)

# Strict promotion diagnostics are evaluated against a valid default policy;
# the unsupported-default rejection above is an independent fail-closed case.
printf 'mode=off\ncpu=native\nallocator=script_process_arena\ndevice=cpu\nlayout=compiler_owned\n' > "$tmp_dir/project/.zagd.conf"
strict_report=$(cd "$tmp_dir/project" && "$znc_bin" check app.zag --strict --no-zagd 2>&1 || true)
printf '%s\n' "$strict_report" | grep -q 'CPU/device/layout defaults remain compiler-selected'

echo "script CLI: PASS"
