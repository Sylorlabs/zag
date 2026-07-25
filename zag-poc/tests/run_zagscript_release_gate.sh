#!/usr/bin/env bash
# Authoritative first-release gate for Zag Script on Linux x86-64.
#
# Every required suite runs sequentially and contributes exactly one result.
# Failures are collected so the complete blocker list is visible, but any
# failure makes this command exit nonzero.  This gate deliberately does not
# certify the separate i686 or full-Zag-v2 milestones.
set -uo pipefail
cd "$(dirname "$0")/.."

pass=0
fail=0
total=0
if ! log_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-release.XXXXXX"); then
    echo "cannot create release-gate log directory" >&2
    exit 1
fi
trap 'rm -rf "$log_dir"' EXIT

pass_case() {
    echo "  ok  $1"
    pass=$((pass + 1))
}

fail_case() {
    echo "  XX  $1"
    fail=$((fail + 1))
}

run_gate() {
    name=$1
    shift
    total=$((total + 1))
    log="$log_dir/$total.log"
    echo "── [$total] $name"
    if "$@" >"$log" 2>&1; then
        pass_case "$name"
        summary=$(awk 'NF { line=$0 } END { print line }' "$log")
        if [ -n "$summary" ]; then
            printf '      %s\n' "$summary"
        fi
    else
        status=$?
        fail_case "$name (exit=$status)"
        if [ -s "$log" ]; then
            sed 's/^/      /' "$log"
        else
            echo "      suite produced no diagnostic output"
        fi
    fi
}

check_toolchain() {
    test -x ./znc
    test -x ./zagd
    ./znc version
}

check_required_files() {
    missing=0
    for path in \
        docs/ZAGSCRIPT_IMPLEMENTATION_AUDIT.md \
        docs/ZAGSCRIPT_GUIDE.md \
        docs/ZAGSCRIPT_SEMANTICS.md \
        docs/ZAGSCRIPT_HARDENING.md \
        docs/ZAGD_ARCHITECTURE.md \
        docs/ZAGD_GUIDE.md \
        docs/ZAGD_RESOURCE_POLICY.md \
        docs/X86_TARGET_POLICY.md \
        docs/X86_FEATURES.md \
        examples/script_hello.zag \
        examples/script_files.zag \
        examples/script_process.zag \
        examples/script_collections.zag \
        examples/script_harden.zag
    do
        if [ ! -f "$path" ]; then
            echo "missing required release file: $path" >&2
            missing=1
        fi
    done
    test "$missing" -eq 0 || return 1
    # Keep the public release boundary honest: the required user-facing
    # description and the two most important non-claims are contractual.
    grep -q "Zag Script is Zag's built-in low-friction profile" docs/ZAGSCRIPT_GUIDE.md
    grep -q 'This policy does not make Zag memory-safe' docs/ZAGSCRIPT_SEMANTICS.md
    grep -q 'Full i686 target' docs/X86_TARGET_POLICY.md
    grep -q 'not complete' docs/X86_TARGET_POLICY.md
}

echo "════ Zag Script Linux x86-64 first-release gate ════"
echo "Scope: Script profile, bounded runtime, CLI/hardening, zagd, cache,"
echo "       generic/native x86-64, regular-Zag compatibility, self-hosting."

run_gate "built self-hosted toolchain is present" check_toolchain
run_gate "required Zag Script documentation and examples" check_required_files
run_gate "documentation support claims remain fail-closed" \
    bash tests/run_docs_consistency.sh
run_gate "shipped editable zagd policy template" \
    bash tests/run_zagd_config_template.sh
run_gate "relocatable installed compiler and complete Script prelude layout" \
    bash tests/run_zagscript_install_layout.sh
run_gate "published Zag Script examples compile without side effects" \
    bash tests/run_zagscript_examples.sh

echo
echo "── Zag Script profile, runtime, and progressive explicitness"
run_gate "Script parsing, lowering, imports, and generated entry point" \
    bash tests/run_script_frontend.sh
run_gate "Script runtime, prelude, arguments, shutdown, and error boundary" \
    bash tests/run_script_runtime_integration.sh
run_gate "Script capability policy" \
    bash tests/run_script_capabilities.sh
run_gate "Script bounded allocation accounting" \
    bash tests/run_script_allocation_accounting.sh
run_gate "Script explicit allocator policy and cache identity" \
    bash tests/run_script_allocator_policy.sh
run_gate "Script-context lifetime and escape diagnostics" \
    bash tests/run_script_lifetime.sh
run_gate "native allocator lifetime fail-closed checks" \
    bash tests/run_allocator_lifetime.sh
run_gate "native exec command temporary-allocation lifetime" \
    bash tests/run_exec_runtime_lifetime.sh
run_gate "edition-2027 ownership, borrow, alias, and control-flow checks" \
    bash tests/run_v2_edition.sh
run_gate "edition-2027 mutation-aware aggregate provenance" \
    bash tests/run_v2_aggregate_provenance.sh
run_gate "typed Script list behavior" \
    bash tests/run_script_list.sh
run_gate "bounded Script string builder" \
    bash tests/run_script_string_builder.sh
run_gate "bounded process timeout and capture boundary" \
    bash tests/run_script_process_boundary.sh
run_gate "typed basic JSON behavior" \
    bash tests/run_script_json.sh
run_gate "beginner-facing Script conveniences" \
    bash tests/run_script_beginner.sh
run_gate "Python-shaped Script syntax remains Zag lowering" \
    bash tests/run_script_python_shape.sh
run_gate "Zag Script parser and watcher malformed-input smoke" \
    bash tests/run_zagscript_fuzz_smoke.sh
run_gate "script/explain/harden/check CLI and explicit-choice authority" \
    bash tests/run_script_cli.sh
run_gate "regular Zag remains explicit and independent of Script lowering" \
    bash tests/run_regular_zag_compat.sh

echo
echo "── zagd observation, planning, service, and cache correctness"
run_gate "zagd content-addressed snapshot primitives" \
    bash tests/run_zagd_core.sh
run_gate "zagd dependency invalidation" \
    bash tests/run_zagd_incremental.sh
run_gate "zagd semantic manifest public-layout dependent invalidation" \
    bash tests/run_semantic_manifest_e2e.sh
run_gate "zagd AST-proven local buffer lifetime advisory remains read-only" \
    bash tests/run_zagd_buffer_lifetime.sh
run_gate "zagd transitive diamond dependent invalidation" \
    bash tests/run_semantic_manifest_diamond.sh
run_gate "zagd bounded profile model" \
    bash tests/run_zagd_profile.sh
run_gate "regular-Zag advisory and Script-default planner authority" \
    bash tests/run_planner_authority.sh
run_gate "zagd deep finalist executor isolation" \
    bash tests/run_zagd_executor.sh
run_gate "zagd benchmark authority policy" \
    bash tests/run_zagd_benchmark_policy.sh
run_gate "zagd inotify watcher, stability, atomic saves, and cache recovery" \
    bash tests/run_zagd_daemon.sh
run_gate "zagd singleton PID-reuse and lock-publication identity" \
    bash tests/run_zagd_identity.sh
run_gate "zagd overflow, symlink, identical-rewrite, and rapid-patch recovery" \
    bash tests/run_zagd_watcher_correctness.sh
run_gate "zagd repeated-edit memory, idle CPU, and cache bounds" \
    bash tests/run_zagd_memory_stress.sh
run_gate "zagd stable background semantic analysis" \
    bash tests/run_zagd_background_semantics.sh
run_gate "zagd bounded deep-mode equivalence integration" \
    bash tests/run_zagd_deep_integration.sh
run_gate "zagd product autostart/status/suggest/shutdown authority" \
    bash tests/run_zagd_product.sh
run_gate "zagd optimize preview remains read-only advisory" \
    bash tests/run_optimize_preview.sh
run_gate "zagd persistent user-service policy" \
    bash tests/run_zagd_user_service.sh
run_gate "foreground cache record validation" \
    bash tests/run_foreground_cache.sh
run_gate "foreground cache hit, nonsemantic reuse, corruption, and stale-input rejection" \
    bash tests/run_foreground_cache_integration.sh

echo
echo "── Linux x86-64 target and existing release compatibility"
run_gate "x86 CPU discovery and feature permission model" \
    bash tests/run_x86_cpu_profile.sh
run_gate "generic/native Linux x86-64 execution and target rejection" \
    bash tests/run_x86_target_policy.sh
run_gate "x86 POPCNT feature-gated instruction selection" \
    bash tests/run_x86_popcount.sh
run_gate "x86 BMI1 ANDN feature-gated instruction selection" \
    bash tests/run_x86_andn.sh
run_gate "x86 trailing-zero feature-gated instruction selection" \
    bash tests/run_x86_trailing_zeros.sh
run_gate "x86 SSE2 memcpy feature-gated instruction selection" \
    bash tests/run_x86_sse2_memcpy.sh
run_gate "optimizer allocation hygiene guardrails" \
    bash tests/check_optimizer_memory_hygiene.sh
run_gate "pure self-hosted native authority and ABI/layout" \
    bash tests/run_native_authority.sh
run_gate "existing native x86-64 release suite" \
    env ZNC=./znc bash tests/run_native.sh
run_gate "existing GPU frontend regression suite (not physical execution)" \
    bash tests/run_native_gpu.sh
run_gate "existing WASM emission regression suite" \
    bash tests/run_native_wasm.sh
run_gate "existing total/effect regression suite" \
    bash tests/run_native_total.sh

echo
echo "── Separate milestones — explicitly not certified by this gate"
echo "  --  i686 full target: NOT CLAIMED; the current bounded milestone has"
echo "      the separate authoritative run_i686_release_gate.sh suite."
echo "  --  full Zag v2: NOT CLAIMED; run_v2_release_gate.sh remains the"
echo "      fail-closed authority for its broader machine-control roadmap."
echo "  --  broader PGO/SIMD/kernel-tuning search: NOT CLAIMED; this gate"
echo "      covers only the bounded, equivalence-checked deep finalist path."
echo "  --  physical GPU execution: NOT CLAIMED; the GPU suite above validates"
echo "      frontend/bundle behavior only."

echo
echo "════ zagscript-release pass=$pass fail=$fail total=$total ════"
test "$fail" -eq 0
