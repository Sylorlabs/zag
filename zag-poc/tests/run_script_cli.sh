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
tmp_dir=$(mktemp -d /tmp/zag-script-cli.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

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
! grep -q '\*opaque' "$tmp_dir/view-explicit.zag"
"$znc_bin" check "$tmp_dir/view-explicit.zag" --no-analyze --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/view-explicit.zag" -o "$tmp_dir/view-explicit-bin" --no-analyze --no-zagd >/dev/null
test -x "$tmp_dir/view-explicit-bin"
set +e
"$tmp_dir/view-explicit-bin"
explicit_status=$?
set -e
test "$explicit_status" -eq 7
"$znc_bin" view tests/script_frontend/basic.zag --level explicit --format json \
    --output "$tmp_dir/view-explicit-json.zag" --no-zagd >"$tmp_dir/view-explicit.json"
grep -q '"status":"preview"' "$tmp_dir/view-explicit.json"
grep -q '"candidate_compilable":true' "$tmp_dir/view-explicit.json"
test -s "$tmp_dir/view-explicit-json.zag"
cmp "$tmp_dir/view-explicit-json.zag" "$tmp_dir/view-explicit.zag"

# Generated wrappers and user source obey the same edition gate. A
# user-authored v2 qualifier in edition-2026 Script fails before publication.
cat >"$tmp_dir/view-user-v2.zag" <<'EOF'
script;
fn user_context(value:*opaque) i32 { return 0; }
return user_context(null as *opaque);
EOF
if "$znc_bin" view "$tmp_dir/view-user-v2.zag" --level explicit \
    --output "$tmp_dir/view-user-v2-output.zag" --no-zagd \
    >"$tmp_dir/view-user-v2.log" 2>&1; then
    echo "explicit view bypassed the user-source edition gate" >&2
    exit 1
fi
grep -q 'v2 machine-control syntax requires `edition = "2027"`' \
    "$tmp_dir/view-user-v2.log"
test ! -e "$tmp_dir/view-user-v2-output.zag"

"$znc_bin" expand tests/script_frontend/basic.zag --to explicit --no-zagd \
    --output "$tmp_dir/expand-explicit.zag" > "$tmp_dir/expand-explicit.log"
cmp "$tmp_dir/view-explicit.zag" "$tmp_dir/expand-explicit.zag"

# Explain witnesses are emitted from the already-bound Script root AST. They
# name only facts the runtime implementation proves, distinguish zero from
# dynamic unknown bytes, and never invent statement locations.
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
grep -q '"source_location":{"value":"unavailable","basis":"unknown"}' "$tmp_dir/explain-operations.json"
"$znc_bin" explain "$tmp_dir/explain-operations.zag" --format text --no-zagd >"$tmp_dir/explain-operations.txt"
grep -q '^implicit operation: read_file allocation=script_context allocation_bytes=unknown copy=file_bytes_to_script_context copy_bytes=unknown location=unavailable provenance=proven$' "$tmp_dir/explain-operations.txt"
grep -q '^implicit operation: path_basename allocation=zero allocation_bytes=0 copy=zero copy_bytes=0 location=unavailable provenance=proven$' "$tmp_dir/explain-operations.txt"
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

# Expansion imports the module that owns a helper even when the selected helper
# is not the module's constructor/primary entry point. `path_basename` is the
# minimal regression: the bound root contains only `script_path_basename`, so a
# constructor-keyed import check would produce strict output with an unknown id.
cat >"$tmp_dir/harden-path-basename.zag" <<'EOF'
script;
let base = path_basename("dir/file.txt");
if (!@strEq(base, "file.txt")) { return 1; }
return 0;
EOF
"$znc_bin" harden "$tmp_dir/harden-path-basename.zag" --format json \
    --output "$tmp_dir/harden-path-basename-output.zag" --no-zagd \
    >"$tmp_dir/harden-path-basename.json"
grep -q '"status":"preview"' "$tmp_dir/harden-path-basename.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-path-basename.json"
grep -q '@import("std:script_path")' "$tmp_dir/harden-path-basename-output.zag"
grep -q 'script_path_basename' "$tmp_dir/harden-path-basename-output.zag"
"$znc_bin" check "$tmp_dir/harden-path-basename-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-path-basename-output.zag" \
    -o "$tmp_dir/harden-path-basename" --no-analyze --no-zagd >/dev/null
"$tmp_dir/harden-path-basename"

# The bounded process helper is valid in edition 2026. Expansion must publish
# ordinary Zag that imports the owning module, type-checks, builds, and runs.
cat >"$tmp_dir/harden-process.zag" <<'EOF'
script;
let result = process_run_timeout("printf harden-ok", 1000, 64);
if (process_result_state(result) != process_state_exited()) { return 21; }
if (process_result_status(result) != 0) { return 22; }
if (!@strEq(process_result_output(result), "harden-ok")) { return 23; }
return 0;
EOF
"$znc_bin" harden "$tmp_dir/harden-process.zag" --format json \
    --output "$tmp_dir/harden-process-output.zag" --no-zagd >"$tmp_dir/harden-process.json"
grep -q '"status":"preview"' "$tmp_dir/harden-process.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-process.json"
test -s "$tmp_dir/harden-process-output.zag"
grep -q '@import("std:process")' "$tmp_dir/harden-process-output.zag"
grep -q 'process_run_bounded_script' "$tmp_dir/harden-process-output.zag"
"$znc_bin" check "$tmp_dir/harden-process-output.zag" --no-zagd >/dev/null
"$znc_bin" "$tmp_dir/harden-process-output.zag" -o "$tmp_dir/harden-process" --no-analyze --no-zagd >/dev/null
"$tmp_dir/harden-process"

# Root `try` already has a precise Script contract: the hidden body returns
# !i32, the wrapper catches through the compiler-generated uncaught reporter,
# then shuts the Script context down. Explicit expansion must preserve both the
# successful payload path and the uncaught-error stderr/exit boundary.
cat >"$tmp_dir/harden-try-success.zag" <<'EOF'
script;
error { Exploded }
fn maybe_value(fail: i32) !i32 {
    if (fail != 0) { return error.Exploded; }
    return 42;
}
let value: i32 = try maybe_value(0);
return value;
EOF
"$znc_bin" harden "$tmp_dir/harden-try-success.zag" --format json \
    --output "$tmp_dir/harden-try-success-output.zag" --no-zagd \
    >"$tmp_dir/harden-try-success.json"
grep -q '"status":"preview"' "$tmp_dir/harden-try-success.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-try-success.json"
grep -q 'fn __zag_hardened_script_body(__zag_script_context:\*i8) !i32' \
    "$tmp_dir/harden-try-success-output.zag"
grep -q 'catch |__zag_script_error_code| __zag_compiler_script_uncaught_7f3a' \
    "$tmp_dir/harden-try-success-output.zag"
"$znc_bin" "$tmp_dir/harden-try-success-output.zag" \
    -o "$tmp_dir/harden-try-success" --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-try-success"
harden_try_success_status=$?
set -e
test "$harden_try_success_status" -eq 42

cat >"$tmp_dir/harden-try-error.zag" <<'EOF'
script;
error { Exploded }
fn maybe_value(fail: i32) !i32 {
    if (fail != 0) { return error.Exploded; }
    return 42;
}
let value: i32 = try maybe_value(1);
return value;
EOF
"$znc_bin" "$tmp_dir/harden-try-error.zag" -o "$tmp_dir/harden-try-error-compact" \
    --no-analyze --no-zagd >/dev/null
"$znc_bin" harden "$tmp_dir/harden-try-error.zag" --format json \
    --output "$tmp_dir/harden-try-error-output.zag" --no-zagd \
    >"$tmp_dir/harden-try-error.json"
grep -q '"status":"preview"' "$tmp_dir/harden-try-error.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-try-error.json"
"$znc_bin" "$tmp_dir/harden-try-error-output.zag" -o "$tmp_dir/harden-try-error-explicit" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-try-error-compact" >"$tmp_dir/harden-try-error-compact.out" \
    2>"$tmp_dir/harden-try-error-compact.err"
harden_try_compact_status=$?
"$tmp_dir/harden-try-error-explicit" >"$tmp_dir/harden-try-error-explicit.out" \
    2>"$tmp_dir/harden-try-error-explicit.err"
harden_try_explicit_status=$?
set -e
test "$harden_try_compact_status" -eq 1
test "$harden_try_explicit_status" -eq 1
cmp -s "$tmp_dir/harden-try-error-compact.out" "$tmp_dir/harden-try-error-explicit.out"
cmp -s "$tmp_dir/harden-try-error-compact.err" "$tmp_dir/harden-try-error-explicit.err"
grep -q 'uncaught Zag Script error name: Exploded' "$tmp_dir/harden-try-error-explicit.err"

# Script declarations are static and the parser already separates them from
# executable root statements. A declaration after a statement must therefore
# be hoisted into the ordinary-Zag declaration section instead of making the
# explicit view fail closed.
cat >"$tmp_dir/harden-late-declaration.zag" <<'EOF'
script;
let value: i32 = late_value();
fn late_value() i32 { return 42; }
return value;
EOF
"$znc_bin" harden "$tmp_dir/harden-late-declaration.zag" --format json \
    --output "$tmp_dir/harden-late-declaration-output.zag" --no-zagd \
    >"$tmp_dir/harden-late-declaration.json"
grep -q '"status":"preview"' "$tmp_dir/harden-late-declaration.json"
grep -q '"candidate_compilable":true' "$tmp_dir/harden-late-declaration.json"
grep -q '^fn late_value() i32' "$tmp_dir/harden-late-declaration-output.zag"
"$znc_bin" "$tmp_dir/harden-late-declaration-output.zag" \
    -o "$tmp_dir/harden-late-declaration" --no-analyze --no-zagd >/dev/null
set +e
"$tmp_dir/harden-late-declaration"
harden_late_declaration_status=$?
set -e
test "$harden_late_declaration_status" -eq 42

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
