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

"$znc_bin" explain tests/script_frontend/basic.zag --format json >"$tmp_dir/explain.json"
grep -q '"profile":{"value":"script","basis":"proven"}' "$tmp_dir/explain.json"
grep -q '"allocator":{"value":"script_process_arena","basis":"derived"}' "$tmp_dir/explain.json"
grep -q '"script_memory_bytes":{"value":67108864' "$tmp_dir/explain.json"
grep -q '"semantic_facts":{"format":"zag-semantic-manifest-v1"' "$tmp_dir/explain.json"
grep -q 'decl_fn=' "$tmp_dir/explain.json"
grep -q 'value_type=' "$tmp_dir/explain.json"
grep -q 'basis=explicit' "$tmp_dir/explain.json"
grep -q 'expr_fact=' "$tmp_dir/explain.json"
grep -q 'type_basis=typed' "$tmp_dir/explain.json"
grep -q 'effect_basis=sema' "$tmp_dir/explain.json"
"$znc_bin" explain tests/script_frontend/basic.zag --format text >"$tmp_dir/explain.txt"
grep -q 'expression types/effects: typed frontend and sema witnesses' "$tmp_dir/explain.txt"
grep -q 'expr_fact=' "$tmp_dir/explain.txt"

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
grep -q 'harden report: conservative statement-only expansion' "$tmp_dir/harden.txt"
"$znc_bin" harden tests/script_frontend/basic.zag \
    --output "$tmp_dir/hardened.zag" >"$tmp_dir/harden-report.txt"
test -e "$tmp_dir/hardened.zag"
grep -q 'fn main() i32' "$tmp_dir/hardened.zag"
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
grep -q '"parity_tests"' "$tmp_dir/harden.json"
grep -q '"unsupported"' "$tmp_dir/harden.json"

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

strict_report=$(cd "$tmp_dir/project" && "$znc_bin" check app.zag --strict --no-zagd 2>&1 || true)
printf '%s\n' "$strict_report" | grep -q 'CPU/device/layout defaults remain compiler-selected'

echo "script CLI: PASS"
