#!/usr/bin/env bash
set -u

cd "$(dirname "$0")/.."

# Select the host-native compiler before running any expensive bootstrap or
# truncating an existing completion log. Unsupported hosts fail explicitly.
host="$(uname -s):$(uname -m)"
case "$host" in
    Darwin:arm64)
        native_compiler=znc-macos-arm64
        native_daemon=zagd-macos-arm64
        ;;
    Linux:x86_64|Linux:amd64)
        native_compiler=znc
        native_daemon=zagd
        ;;
    *)
        echo "ZagScript 1.0 completion: unsupported host: $host" >&2
        exit 2
        ;;
esac

log=${ZAGSCRIPT_1_0_COMPLETION_LOG:-"$PWD/zagscript-1.0-completion.log"}
: >"$log"
exec > >(tee -a "$log") 2>&1

fail=0
run() {
    name=$1
    shift
    printf '\n=== %s ===\n' "$name"
    "$@"
    rc=$?
    printf '=== %s rc=%s ===\n' "$name" "$rc"
    if [ "$rc" -ne 0 ]; then
        fail=1
    fi
    return 0
}

echo '== ZagScript 1.0: clean self-host bootstrap =='
if [ "$host" = Darwin:arm64 ]; then
    # macOS has no Linux memory cgroup. Bootstrap still bounds each stage.
    ZAG_BOOTSTRAP_MEMORY_GUARD=off bash bootstrap.sh
else
    # Preserve Linux workstation memory guards.
    bash bootstrap.sh
fi
bootstrap_rc=$?
if [ "$bootstrap_rc" -ne 0 ]; then
    echo "ZagScript 1.0 completion: bootstrap failed rc=$bootstrap_rc" >&2
    exit "$bootstrap_rc"
fi

export ZNC="$PWD/$native_compiler"
export ZAGD="$PWD/$native_daemon"

for binary in "$ZNC" "$ZAGD"; do
    if [ ! -x "$binary" ]; then
        echo "ZagScript 1.0 completion: rebuilt binary missing: $binary" >&2
        exit 1
    fi
done

suites=(
    tests/run_compiler_bundle_helper.sh
    tests/run_zagscript_static_core.sh
    tests/run_zagscript_closures.sh
    tests/run_zagscript_async.sh
    tests/run_zagscript_fuzz_smoke.sh
    tests/run_zagscript_views.sh
    tests/run_script_cli.sh
    tests/run_script_python_shape.sh
    tests/run_script_cst.sh
    tests/run_script_inference.sh
    tests/run_script_interpolation.sh
    tests/run_error_import_dedupe.sh
    tests/run_script_map_literals.sh
    tests/run_script_map_explicit.sh
    tests/run_script_records.sh
    tests/run_script_json_root.sh
    tests/run_script_json_document.sh
    tests/run_script_json_installed.sh
    tests/run_script_auto_lower.sh
    tests/run_script_auto_cli.sh
    tests/run_collections_unicode.sh
    tests/run_script_projection.sh
    tests/run_script_allocation_accounting.sh
    tests/run_zag_zagscript_separation.sh
)

for suite in "${suites[@]}"; do
    if [ -f "$suite" ]; then
        run "$suite" bash "$suite"
    else
        echo "missing suite: $suite" >&2
        fail=1
    fi
done

# Runtime integration now validates its canonical x86 lowering fixture without
# executing that foreign artifact off-host, then continues through the native
# compiler/runtime cases. Keep only the frozen reference-app aggregate scoped
# to Linux x86-64.
run tests/run_script_runtime_integration.sh bash tests/run_script_runtime_integration.sh
if [ "$(uname -s)" = "Linux" ] && [ "$(uname -m)" = "x86_64" ]; then
    run tests/run_zagscript_reference_apps.sh bash tests/run_zagscript_reference_apps.sh
elif [ "$(uname -s):$(uname -m)" = "Darwin:arm64" ]; then
    run tests/run_zagscript_reference_apps_macos.sh bash tests/run_zagscript_reference_apps_macos.sh
fi

run matrix_selftest bash tests/run_zagscript_1_0_matrix_selftest.sh

if [ -f tests/generate_zagscript_1_0_matrix.sh ]; then
    run matrix_generate sh -c \
        'bash tests/generate_zagscript_1_0_matrix.sh > docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md'
fi

run matrix_release bash tests/run_zagscript_1_0_matrix.sh --release
run diff_check git diff --check

for shell_file in \
    tests/run_zagscript_1_0_completion.sh \
    tests/run_zagscript_async.sh \
    tests/run_zagscript_fuzz_smoke.sh \
    tests/run_zagscript_views.sh \
    tests/run_script_cli.sh \
    tests/run_error_import_dedupe.sh \
    tests/run_script_map_explicit.sh \
    tests/run_zagscript_1_0_matrix.sh \
    tests/run_zagscript_1_0_matrix_selftest.sh; do
    if [ -f "$shell_file" ]; then
        run "bash-n:$shell_file" bash -n "$shell_file"
    fi
done

printf '\n== capability counts ==\n'
awk -F '\t' 'NR>1{c[$3]++} END{for(k in c) print k,c[k]}' \
    tests/zagscript_1_0_capabilities.tsv | sort

if [ "$fail" -ne 0 ]; then
    echo 'ZagScript 1.0 completion: FAIL'
    exit 1
fi

echo 'ZagScript 1.0 completion: PASS'
