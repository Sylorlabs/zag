#!/usr/bin/env bash
# The Script release gate already executes native authority, native backend,
# GPU frontend, WASM emission, and total/effect regressions. This companion
# gate covers the remaining distinct checks behind `make test` without running
# another bootstrap. Keep every suite sequential: several compile large
# self-hosted sources and must not contend for workstation memory.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
total=0
if ! log_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-v1-compat.XXXXXX"); then
    echo "cannot create v1 compatibility log directory" >&2
    exit 1
fi
trap 'rm -rf "$log_dir"' EXIT

run_gate() {
    name=$1
    shift
    total=$((total + 1))
    log="$log_dir/$total.log"
    echo "── [$total] $name"
    if "$@" >"$log" 2>&1; then
        pass=$((pass + 1))
        summary=$(awk 'NF { line=$0 } END { print line }' "$log")
        printf '  ok  %s%s\n' "$name" "${summary:+: $summary}"
    else
        status=$?
        fail=$((fail + 1))
        printf '  XX  %s (exit=%s)\n' "$name" "$status" >&2
        if [ -s "$log" ]; then sed 's/^/      /' "$log" >&2; fi
    fi
}

echo "════ Existing v1 compatibility authority (no bootstrap) ════"
run_gate "pure self-host source tree" bash tests/check_pure_zag_tree.sh
run_gate "language semantics" bash tests/run_semantics.sh
run_gate "typed authority" bash tests/run_typed_authority.sh
run_gate "diagnostics" bash tests/run_diag.sh
run_gate "tooling" bash tests/run_tooling.sh
run_gate "static analyzer" bash tests/run_analyzer.sh
run_gate "hot reload" bash tests/run_hot_reload.sh
run_gate "dynamic ABI" bash tests/run_dynamic_abi.sh
run_gate "GPU isolation classification" bash tests/run_gpu_isolation.sh
run_gate "GFX10.1 virtual command processor" bash tests/run_gfx1010_vm.sh
run_gate "GPU standard-library boundary" bash tests/run_gpu_std.sh
run_gate "GPU platform boundary" bash tests/run_gpu_platform.sh
run_gate "compiler-owned std namespace" bash tests/run_std_namespace.sh
run_gate "program integration" bash tests/run_programs.sh
run_gate "native ABI/layout" bash tests/run_abi_layout.sh
# The master gate has already established the x86-64 fixed point. Supplying
# that exact compiler avoids the default wrappers rebuilding three redundant
# x86 drivers; the ARM backend executions, differential comparisons, and the
# two ARM self-host generations still run unchanged.
run_gate "existing ARM64 backend compatibility" \
    env ZNC=./znc bash tests/run_native_arm64.sh
run_gate "existing x86-64/ARM64 differential compatibility" \
    env ZNC=./znc bash tests/run_differential.sh
run_gate "existing ARM64 self-hosting compatibility" \
    env ZNC=./znc bash tests/run_arm64_selfhost.sh

echo "════ v1-compat pass=$pass fail=$fail total=$total ════"
test "$fail" -eq 0
