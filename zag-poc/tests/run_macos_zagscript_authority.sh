#!/usr/bin/env bash
# Physical Apple-Silicon authority for the portable ZagScript product surface.
# This is deliberately narrower than run_zagscript_release_gate.sh: it reuses
# that gate's target-independent rows and names every Linux/x86-only omission.
set -uo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
cd "$root"
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS ZagScript authority: unsupported host (requires physical Apple Silicon macOS)' >&2
    exit 2
fi

real_compiler=${ZNC:-$(zag_native_compiler "$root")}
case "$real_compiler" in
    /*) ;;
    *) real_compiler="$root/${real_compiler#./}" ;;
esac
if ! zag_assert_native_executable "$real_compiler"; then
    echo "macOS ZagScript authority: compiler is not a signed arm64 Mach-O executable: $real_compiler" >&2
    exit 2
fi

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-zagscript.XXXXXX")
cleanup() { rm -rf -- "$work"; }
trap cleanup EXIT
trap 'exit 129' HUP
trap 'exit 130' INT
trap 'exit 143' TERM
compiler_stage="$work/compiler-layout"
mkdir -p "$compiler_stage"
ln -s "$real_compiler" "$compiler_stage/znc-real"
ln -s "$root/selfhost" "$compiler_stage/selfhost"
ln -s "$root/std" "$compiler_stage/std"
artifact_log="$compiler_stage/artifacts.log"
invalid_artifact_log="$compiler_stage/invalid-artifacts.log"
: >"$artifact_log"
: >"$invalid_artifact_log"

# A relocated compiler needs its immutable source-module roots beside argv[0].
# The wrapper also closes an evidence hole in older component scripts: every
# executable they expose through an exact `-o` is verified at creation time.
# Absolute tool paths keep this check active under package tests' `env -i` row.
cat >"$compiler_stage/znc" <<'WRAPPER'
#!/bin/bash
wrapper_dir=${0%/*}
real="$wrapper_dir/znc-real"
artifact_log="$wrapper_dir/artifacts.log"
invalid_log="$wrapper_dir/invalid-artifacts.log"
output=
want_output=0
for argument in "$@"; do
    if [ "$want_output" -eq 1 ]; then
        output=$argument
        want_output=0
    elif [ "$argument" = -o ]; then
        want_output=1
    fi
done

"$real" "$@"
status=$?
if [ -n "$output" ]; then
    case "$output" in
        /*) artifact=$output ;;
        *) artifact="$PWD/$output" ;;
    esac
    if [ -x "$artifact" ]; then
        kind=$(/usr/bin/file -b "$artifact" 2>/dev/null)
        if [ "$kind" = 'Mach-O 64-bit executable arm64' ] &&
           /usr/bin/codesign --verify --deep --strict "$artifact" >/dev/null 2>&1; then
            printf '%s\n' "$artifact" >>"$artifact_log"
        else
            printf '%s\n' "$artifact" >>"$invalid_log"
            if [ "$status" -eq 0 ]; then status=97; fi
        fi
    fi
fi
exit "$status"
WRAPPER
chmod +x "$compiler_stage/znc"
compiler="$compiler_stage/znc"
export ZNC="$compiler"
export ZAGSCRIPT_RELEASE_EVIDENCE=0

pass=0
fail=0
run_gate() {
    label=$1
    shift
    printf '\n── %s\n' "$label"
    # Invoke first and inspect the status afterward. Calling a shell function
    # directly as an `if` condition disables errexit throughout that function,
    # which could turn an early missing artifact into a false pass.
    "$@"
    status=$?
    if [ "$status" -eq 0 ]; then
        pass=$((pass + 1))
        printf '  ok  %s\n' "$label"
    else
        fail=$((fail + 1))
        printf '  XX  %s (exit=%s)\n' "$label" "$status" >&2
    fi
}

markerless_activation() (
    set -euo pipefail
    source_file="$root/tests/script_frontend/cli_markerless.zag"
    before=$(zag_sha256_file "$source_file")
    "$compiler" script "$source_file" --cpu generic \
        -o "$work/markerless" --no-zagd --no-analyze --no-foreground-cache \
        >/dev/null
    zag_assert_native_executable "$work/markerless"
    set +e
    "$work/markerless"
    status=$?
    set -e
    [ "$status" -eq 5 ]
    [ "$before" = "$(zag_sha256_file "$source_file")" ]
)

portable_runtime() (
    set -euo pipefail
    runtime="$work/runtime"
    mkdir -p "$runtime"

    "$compiler" tests/script_frontend/uncaught_error.zag \
        -o "$runtime/uncaught" --no-zagd --no-analyze --no-foreground-cache \
        >/dev/null
    set +e
    "$runtime/uncaught" >"$runtime/uncaught.out" 2>"$runtime/uncaught.err"
    status=$?
    set -e
    [ "$status" -eq 1 ]
    grep -q 'uncaught Zag Script error name: ScriptFailure' "$runtime/uncaught.err"
    grep -q 'operation: root script top-level try call `fail`' "$runtime/uncaught.err"

    "$compiler" tests/script_frontend/prelude_override.zag \
        -o "$runtime/override" --no-zagd --no-analyze --no-foreground-cache \
        >/dev/null
    [ "$("$runtime/override")" = override:yes ]
    "$compiler" tests/script_frontend/args_strings.zag \
        -o "$runtime/args" --no-zagd --no-analyze --no-foreground-cache \
        >/dev/null
    [ "$("$runtime/args" value)" = arg:value ]
    "$compiler" tests/script_frontend/println_int.zag \
        -o "$runtime/integer" --no-zagd --no-analyze --no-foreground-cache \
        >/dev/null
    [ "$("$runtime/integer")" = 42 ]

    cat >"$runtime/file_path.zag" <<ZAG
script;
let path: []u8 = "$runtime/runtime_file.txt";
let value: []u8 = "runtime";
if (write_file(path, value) != 0) { return 70; }
let data: []u8 = read_file(path);
if (!@strEq(data, value)) { return 71; }
if (!@strEq(path_join("tmp", "report.json"), "tmp/report.json")) { return 72; }
if (!@strEq(path_basename("/tmp/report.json"), "report.json")) { return 73; }
if (!@strEq(path_dirname("/tmp/report.json"), "/tmp")) { return 74; }
if (!@strEq(path_extension("/tmp/report.json"), ".json")) { return 75; }
return 0;
ZAG
    "$compiler" "$runtime/file_path.zag" -o "$runtime/file-path" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    "$runtime/file-path"

    cat >"$runtime/environment.zag" <<'ZAG'
script;
if (!@strEq(env("ZAG_RUNTIME_SCRIPT_ENV"), "visible")) { return 80; }
let missing: []u8 = env("ZAG_RUNTIME_SCRIPT_MISSING");
if (missing.len != 0) { return 81; }
return 0;
ZAG
    printf '%s\n' \
        'allow_filesystem_read=true' \
        'allow_filesystem_write=true' \
        'allow_process=false' \
        'environment_allow=ZAG_RUNTIME_SCRIPT_ENV,ZAG_RUNTIME_SCRIPT_MISSING' \
        'mode=off' >"$runtime/.zagd.conf"
    "$compiler" "$runtime/environment.zag" -o "$runtime/environment" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    ZAG_RUNTIME_SCRIPT_ENV=visible "$runtime/environment"
    printf '%s\n' \
        'allow_filesystem_read=true' \
        'allow_filesystem_write=true' \
        'allow_process=false' \
        'environment_allow=' \
        'mode=off' >"$runtime/.zagd.conf"
    if "$compiler" "$runtime/environment.zag" -o "$runtime/environment-denied" \
        --no-zagd --no-analyze --no-foreground-cache \
        >"$runtime/environment-denied.log" 2>&1; then
        echo 'portable runtime: denied environment lookup compiled' >&2
        exit 1
    fi
    grep -q 'env("ZAG_RUNTIME_SCRIPT_ENV") denied' \
        "$runtime/environment-denied.log"
    test ! -e "$runtime/environment-denied"
)

portable_list() (
    set -euo pipefail
    list_dir="$work/list"
    mkdir -p "$list_dir"
    "$compiler" tests/script_frontend/list.zag -o "$list_dir/list" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    "$list_dir/list"
    if "$compiler" tests/script_frontend/list_mixed_bad.zag \
        -o "$list_dir/mixed" --no-zagd --no-analyze --no-foreground-cache \
        >"$list_dir/mixed.log" 2>&1; then
        echo 'portable list: mixed element types compiled' >&2
        exit 1
    fi
    test ! -e "$list_dir/mixed"

    cat >"$list_dir/budget.zag" <<'ZAG'
script;
let fill:*i8 = script_alloc(1048576);
if (fill == null as *i8) { return 4; }
let values = list(7);
if (values.data != null as *i32 || script_list_failed(values) != 1 ||
    script_list_len(values) != 0) { return 1; }
if (script_list_append(&values, 9) != 1) { return 2; }
if (values.data != null as *i32 || values.len != 0 || values.failed != 1) {
    return 3;
}
return 0;
ZAG
    printf '%s\n' 'script_memory_bytes=1048576' 'mode=off' \
        >"$list_dir/.zagd.conf"
    "$compiler" "$list_dir/budget.zag" -o "$list_dir/budget" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    "$list_dir/budget"

    cat >"$list_dir/index.zag" <<'ZAG'
script;
let values = list(7);
let bad:i32 = script_list_get(values, 1);
return bad;
ZAG
    "$compiler" "$list_dir/index.zag" -o "$list_dir/index" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    set +e
    "$list_dir/index" >"$list_dir/index.out" 2>"$list_dir/index.err"
    status=$?
    set -e
    [ "$status" -eq 1 ]
    grep -q 'list index is out of bounds or the list state is invalid' \
        "$list_dir/index.err"

    cat >"$list_dir/invalid.zag" <<'ZAG'
script;
let values = list(7);
values.len = 9;
if (script_list_append(&values, 8) != 1 || script_list_failed(values) != 1) { return 1; }
return 0;
ZAG
    "$compiler" "$list_dir/invalid.zag" -o "$list_dir/invalid" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    "$list_dir/invalid"
)

portable_process() (
    set -euo pipefail
    process_dir="$work/process"
    mkdir -p "$process_dir"
    printf '%s\n' \
        'allow_filesystem_read=true' \
        'allow_filesystem_write=true' \
        'allow_process=true' \
        'environment_allow=' \
        'mode=off' >"$process_dir/.zagd.conf"
    cat >"$process_dir/process.zag" <<'ZAG'
script;
let fast = process_run_timeout("printf rt-ok", 1000, 16);
if (process_result_state(fast) != process_state_exited()) { return 90; }
if (!@strEq(process_result_output(fast), "rt-ok")) { return 91; }
let timed = process_run_timeout("sleep 2", 25, 16);
if (process_result_state(timed) != process_state_timed_out()) { return 92; }
let bounded = process_run_timeout("printf 123456789", 1000, 4);
if (process_result_state(bounded) != process_state_output_limit()) { return 93; }
return 0;
ZAG
    "$compiler" "$process_dir/process.zag" -o "$process_dir/process" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    zag_run_bounded 10 "$process_dir/process"
)

portable_parser_corpus() (
    set -euo pipefail
    corpus="$work/parser-corpus"
    mkdir -p "$corpus"
    reject_script() {
        name=$1
        source=$2
        printf '%s' "$source" >"$corpus/$name.zag"
        set +e
        zag_run_bounded 8 "$compiler" script "$corpus/$name.zag" \
            -o "$corpus/$name.bin" --no-zagd --no-foreground-cache \
            >"$corpus/$name.log" 2>&1
        status=$?
        set -e
        case "$status" in
            0|124) return 1 ;;
        esac
        [ "$status" -lt 128 ]
        test ! -e "$corpus/$name.bin"
    }
    reject_script duplicate_profile 'script; script; say("bad")'
    reject_script conflicting_main \
        'script; fn main() i32 { return 0; } say("bad")'
    reject_script unfinished_call 'script; say((("bad")'
    reject_script unfinished_collection \
        'script; let xs = [1, 2, 3; say(xs)'
    reject_script mixed_collection 'script; let xs = [1, "two"]; say(xs)'
    reject_script bad_try 'script; let value = try; say(value)'
    reject_script generated_name_collision \
        'script; fn __zag_compiler_script_body_7f3a() i32 { return 0; }'
    reject_script async_surface 'async fn main() i32 { return 0; }'
    reject_script await_surface 'fn main() i32 { return await(1); }'
    printf '\377script;\nshow("bad")\n' >"$corpus/invalid_utf8.zag"
    reject_script invalid_utf8 "$(cat "$corpus/invalid_utf8.zag")"
    printf 'script;\nshow("bad")\000\n' >"$corpus/nul_byte.zag"
    set +e
    zag_run_bounded 8 "$compiler" script "$corpus/nul_byte.zag" \
        -o "$corpus/nul_byte.bin" --no-zagd --no-foreground-cache \
        >"$corpus/nul_byte.log" 2>&1
    status=$?
    set -e
    [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$status" -lt 128 ]
    test ! -e "$corpus/nul_byte.bin"
    printf 'script;\nsay("fuzz-ok")\n' >"$corpus/valid.zag"
    "$compiler" script "$corpus/valid.zag" -o "$corpus/valid.bin" \
        --no-zagd --no-foreground-cache >/dev/null
    [ "$("$corpus/valid.bin")" = fuzz-ok ]
)

portable_ledger() (
    set -euo pipefail
    grep -q 'module_graph_checksum' selfhost/derivation_ledger.zag
    grep -q 'ast_origin_count' selfhost/derivation_ledger.zag
    grep -q 'choice_scope' selfhost/derivation_ledger.zag
    grep -q 'formal_proof_certificate' selfhost/derivation_ledger.zag
    grep -Eq '^fn znc_ledger_runtime_enabled\(\)i32\{return [01];\}' \
        selfhost/native/znc.zag
    grep -q 'let semantic_manifest:\[\]u8=smp_bounded_manifest' \
        selfhost/native/znc.zag
    grep -q '.semantic_graph=semantic_view.graph_identity' \
        selfhost/native/znc.zag
    grep -q 'semantic_view.graph_complete==0' selfhost/native/znc.zag
    if rg -q '\.semantic_manifest=""' selfhost/native/znc.zag; then
        echo 'portable ledger: adapter publishes an empty semantic manifest' >&2
        exit 1
    fi
    "$compiler" selfhost/derivation_ledger_test.zag \
        -o "$work/derivation-ledger" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    "$work/derivation-ledger"
)

cat <<'EXCLUSIONS'
macOS ZagScript authority exclusions (not counted as passes):
  - selfhost/native/script_lowering_native_test.zag: generates fixed /tmp Linux/x86-64 ELF witnesses
  - tests/run_zagscript_views.sh: native view/object assertions are Linux/x86-64-specific
  - tests/run_allocator_lifetime.sh ulimit-v row: macOS has no GNU/Linux `ulimit -v` contract
  - tests/run_zagscript_fuzz_smoke.sh watcher half: GNU timeout plus Linux inotify daemon authority
  - frozen aggregate reference members whose Linux contracts require ELF tooling,
    Linux kernel services, or OpenSSL SONAMEs; native Darwin equivalents run below
EXCLUSIONS

run_gate 'markerless `znc script` activation is compilation-local' \
    markerless_activation
run_gate 'Script frontend parsing, lowering, imports, and entry point' \
    bash tests/run_script_frontend.sh
run_gate 'portable Script runtime, file/path, environment, and errors' \
    portable_runtime
run_gate 'Script capability policy' bash tests/run_script_capabilities.sh
run_gate 'Script bounded allocation accounting' \
    bash tests/run_script_allocation_accounting.sh
run_gate 'Script-context lifetime and escape diagnostics' \
    bash tests/run_script_lifetime.sh
run_gate 'typed Script list behavior and fail-closed state' portable_list
run_gate 'bounded Script string builder' bash tests/run_script_string_builder.sh
run_gate 'bounded process success, timeout, and capture limit' portable_process
run_gate 'typed JSON and CSV behavior' bash tests/run_script_json_csv.sh
run_gate 'context-accounted typed formatting' bash tests/run_script_format.sh
run_gate 'context-accounted JSON string output' bash tests/run_script_json_context.sh
run_gate 'typed interpolation parsing' bash tests/run_script_interpolation_parser.sh
run_gate 'typed interpolation native and explicit parity' bash tests/run_script_interpolation.sh
run_gate 'bounded monomorphic function inference' bash tests/run_script_inference.sh
run_gate 'named record shorthand' bash tests/run_script_records.sh
run_gate 'context-accounted typed map storage' bash tests/run_script_map.sh
run_gate 'module-aware compiler error-set import dedupe' bash tests/run_error_import_dedupe.sh
run_gate 'typed map literals' bash tests/run_script_map_literals.sh
run_gate 'typed map literal explicit expansion parity' bash tests/run_script_map_explicit.sh
run_gate 'typed JSON document convenience' bash tests/run_script_json_document.sh
run_gate 'exhaustively checked finite auto engine' bash tests/run_script_auto.sh
run_gate 'finite auto CLI and evidence replay' bash tests/run_script_auto_cli.sh
run_gate 'source auto opt-in lowering' bash tests/run_script_auto_lower.sh
run_gate 'JSON root convenience and shadowing' bash tests/run_script_json_root.sh
run_gate 'typed interpolation and map projection' bash tests/run_script_interpolation_project.sh
run_gate 'deterministic local package-import foundation' \
    bash tests/run_package_resolution.sh
run_gate 'canonical create-only vendored package lock' \
    bash tests/run_package_lock_generator.sh
run_gate 'beginner-facing collection conveniences' \
    bash tests/run_script_beginner.sh
run_gate 'lossless indentation CST and generated origins' \
    bash tests/run_script_cst.sh
run_gate 'compact expression semantics and compound assignment' \
    bash tests/run_script_ergonomics.sh
run_gate 'selective function exposure and option validation' \
    bash tests/run_zagscript_symbol_view.sh
run_gate 'exact parser and typed-IR source origins' \
    bash tests/run_source_origins.sh
run_gate 'portable derivation-ledger codec and semantic binding' portable_ledger
run_gate 'portable malformed-input parser corpus' portable_parser_corpus
run_gate 'script/explain/harden/check CLI authority' bash tests/run_script_cli.sh
run_gate 'localized structural projection' bash tests/run_script_projection.sh
run_gate 'CLI automation reference application' \
    bash tests/run_reference_cli_automation.sh
run_gate 'HTTP service reference application' \
    bash tests/run_reference_http_service.sh
run_gate 'WebSocket service reference application' \
    bash tests/run_reference_websocket_service.sh
run_gate 'Network.framework TLS HTTP reference application' \
    bash tests/run_reference_tls_http_service_macos.sh
run_gate 'Darwin clock, entropy, and filesystem services' \
    bash tests/run_os_macos_services.sh
run_gate 'Darwin dynamic plugin reference application' \
    bash tests/run_reference_dynamic_plugin_macos.sh
run_gate 'Darwin bounded concurrency service reference application' \
    bash tests/run_macos_concurrency_services.sh
run_gate 'pinned Zagkit contract reference application' \
    bash tests/run_reference_zagkit_contract.sh

if [ -s "$invalid_artifact_log" ]; then
    fail=$((fail + 1))
    echo '  XX  compiler exposed a non-arm64 or unsigned executable:' >&2
    sed 's/^/      /' "$invalid_artifact_log" >&2
fi
artifact_count=$(wc -l <"$artifact_log" | tr -d '[:space:]')
unique_artifact_count=$(LC_ALL=C sort -u "$artifact_log" | awk 'END { print NR + 0 }')
if [ "$artifact_count" -eq 0 ]; then
    fail=$((fail + 1))
    echo '  XX  no compiler-produced executable reached the signature authority' >&2
fi

printf '\nmacOS ZagScript authority: pass=%d fail=%d signed-artifacts=%d unique-artifacts=%d\n' \
    "$pass" "$fail" "$artifact_count" "$unique_artifact_count"
[ "$fail" -eq 0 ]
