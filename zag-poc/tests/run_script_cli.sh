#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
case "$znc_bin" in /*) ;; *) znc_bin="$(pwd)/${znc_bin#./}" ;; esac
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

# A compiler-bound Script prelude call has an implicit context/capability
# contract. Harden must report that boundary honestly, produce no candidate,
# and never create the requested output file.
cat >"$tmp_dir/harden-prelude.zag" <<'EOF'
script;
let contents = read_file("input.txt");
return 0;
EOF
"$znc_bin" harden "$tmp_dir/harden-prelude.zag" --format json \
    --output "$tmp_dir/harden-prelude-output.zag" --no-zagd >"$tmp_dir/harden-prelude.json"
grep -q '"status":"unsupported"' "$tmp_dir/harden-prelude.json"
grep -q '"candidate_compilable":false' "$tmp_dir/harden-prelude.json"
grep -q '"kind":"script_prelude"' "$tmp_dir/harden-prelude.json"
test ! -e "$tmp_dir/harden-prelude-output.zag"

# --output is a sibling-temp atomic publish. An existing temp is treated as a
# recovery signal rather than silently overwritten.
printf 'interrupted candidate\n' >"$tmp_dir/atomic-output.zag.harden.tmp"
if "$znc_bin" harden tests/script_frontend/basic.zag \
    --output "$tmp_dir/atomic-output.zag" --no-zagd >/dev/null 2>&1; then
    echo "harden unexpectedly overwrote an existing atomic temporary" >&2
    exit 1
fi
test ! -e "$tmp_dir/atomic-output.zag"

mkdir "$tmp_dir/apply"
cp tests/script_frontend/basic.zag "$tmp_dir/apply/app.zag"
(cd "$tmp_dir/apply" && "$znc_bin" harden app.zag --apply \
    --test-command "$znc_bin app.zag -o applied --no-zagd --no-analyze" \
    --format json --no-zagd) > "$tmp_dir/apply-report.json"
grep -q '"status":"applied"' "$tmp_dir/apply-report.json"
test -f "$tmp_dir/apply/app.zag.harden.bak"
grep -q 'fn main() i32' "$tmp_dir/apply/app.zag"

mkdir "$tmp_dir/rollback"
cp tests/script_frontend/basic.zag "$tmp_dir/rollback/app.zag"
if (cd "$tmp_dir/rollback" && "$znc_bin" harden app.zag --apply \
    --test-command false --no-zagd >/dev/null 2>&1); then
    echo "failing harden parity command unexpectedly applied" >&2
    exit 1
fi
grep -q '^script;' "$tmp_dir/rollback/app.zag"
cmp "$tmp_dir/rollback/app.zag" "$tmp_dir/rollback/app.zag.harden.bak"

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
