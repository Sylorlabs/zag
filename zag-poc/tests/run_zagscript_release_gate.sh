#!/usr/bin/env bash
# Authoritative first-release gate for Zag Script on Linux x86-64.
#
# Every required suite runs sequentially and contributes exactly one result.
# Failures are collected so the complete blocker list is visible, but any
# failure makes this command exit nonzero.  This gate deliberately does not
# certify the separate i686 or full-Zag-v2 milestones.
set -uo pipefail
cd "$(dirname "$0")/.."
export ZNC="$PWD/znc"

# Evidence scripts may not launch the aggregate gate that is validating them.
# The matrix runner sets this marker only around direct evidence execution.
if [[ ${ZAGSCRIPT_MATRIX_EVIDENCE_ACTIVE:-0} == 1 ]]; then
    echo 'recursive ZagScript release gate from matrix evidence refused' >&2
    exit 1
fi

# The frozen contract is a true preflight: validate the validator itself, then
# refuse an incomplete matrix before checking the compiler or starting any
# native/self-host work.  Keep these inputs explicit because check_required_files
# is intentionally reached only after this cheap boundary passes.
for matrix_input in \
    tests/run_zagscript_1_0_matrix_selftest.sh \
    tests/run_zagscript_1_0_matrix.sh \
    tests/generate_zagscript_1_0_matrix.sh \
    tests/zagscript_1_0_capabilities.tsv \
    docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md
do
    if [[ ! -f $matrix_input ]]; then
        printf 'missing ZagScript matrix preflight input: %s\n' \
            "$matrix_input" >&2
        exit 1
    fi
done
echo "── preflight: frozen ZagScript 1.0 matrix authority"
if ! bash tests/run_zagscript_1_0_matrix_selftest.sh; then
    echo 'ZagScript matrix validator self-test failed; release refused' >&2
    exit 1
fi
if ! bash tests/run_zagscript_1_0_matrix.sh --release; then
    echo 'ZagScript 1.0 matrix is incomplete; release refused before native work' >&2
    exit 1
fi

pass=0
fail=0
total=0
expected_total=82
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
        docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md \
        docs/DYNAMIC_PLUGIN.md \
        docs/DATABASE_KV.md \
        docs/NETWORK_FOUNDATION.md \
        docs/LINUX_OS_SERVICES.md \
        docs/LINUX_FS_CONCURRENT_INDEXER.md \
        docs/CONFIGURATION_AND_LOGGING.md \
        docs/HTTP_WEBSOCKET_FOUNDATION.md \
        docs/TLS_OPENSSL.md \
        docs/CONCURRENCY_SERVICES.md \
        docs/COLLECTIONS_UNICODE.md \
        docs/RESOURCE_EMBEDDING.md \
        docs/V2_RESOURCE_CONTRACT_SYNTAX.md \
        docs/ZAGD_ARCHITECTURE.md \
        docs/ZAGD_GUIDE.md \
        docs/ZAGD_RESOURCE_POLICY.md \
        docs/X86_TARGET_POLICY.md \
        docs/X86_FEATURES.md \
        examples/script_hello.zag \
        examples/script_files.zag \
        examples/script_process.zag \
        examples/script_collections.zag \
        examples/script_harden.zag \
        examples/script_comment_scanner.zag \
        selfhost/derivation_ledger.zag \
        selfhost/derivation_ledger_test.zag \
        selfhost/package_resolve.zag \
        selfhost/package_resolve_test.zag \
        selfhost/zagd_manifest_inputs.zag \
        selfhost/zagd_manifest_inputs_test.zag \
        selfhost/zagd_generation.zag \
        selfhost/zagd_generation_test.zag \
        selfhost/script_projection_test.zag \
        selfhost/script_syntax_test.zag \
        selfhost/source_origin_test.zag \
        selfhost/zir_contract.zag \
        selfhost/zir_authority_test.zag \
        selfhost/native/zir_native_backend_test.zag \
        selfhost/resource_contract_syntax_test.zag \
        tests/zagscript_1_0_capabilities.tsv \
        tests/generate_zagscript_1_0_matrix.sh \
        tests/run_zagscript_1_0_matrix.sh \
        tests/run_zagscript_1_0_matrix_selftest.sh \
        tests/run_derivation_ledger.sh \
        tests/run_zagd_generation.sh \
        tests/run_zagscript_reference_apps.sh \
        tests/package_resolution/workspace.inventory.tsv \
        tests/reference_apps/cli_automation/input.zag \
        tests/run_reference_cli_automation.sh \
        std/database_kv.zag \
        std/database_memory.zag \
        std/sqlite_kv.zag \
        std/net_ipv4.zag \
        std/dns_ipv4.zag \
        std/os_linux.zag \
        std/linux_fs.zag \
        std/config_flat.zag \
        std/log_json.zag \
        std/http1.zag \
        std/http1_service.zag \
        std/websocket.zag \
        std/tls_openssl.zag \
        std/linux_epoll.zag \
        std/channel_i64.zag \
        std/hashmap.zag \
        std/set.zag \
        std/range.zag \
        std/iterator.zag \
        std/utf8.zag \
        tests/database_memory_conformance.zag \
        tests/database_sqlite_conformance.zag \
        tests/run_database_drivers.sh \
        tests/net_ipv4_loopback.zag \
        tests/dns_ipv4_wire.zag \
        tests/run_network_foundation.sh \
        tests/os_linux_services.zag \
        tests/run_os_linux_services.sh \
        tests/linux_fs_bounded.zag \
        tests/reference_apps/concurrent_file_indexer/main.zag \
        tests/run_reference_concurrent_file_indexer.sh \
        tests/config_log_services.zag \
        tests/run_config_log_services.sh \
        tests/http1_wire.zag \
        tests/websocket_wire.zag \
        tests/reference_apps/http_service/main.zag \
        tests/reference_apps/websocket_service/main.zag \
        tests/run_http_websocket_foundation.sh \
        tests/run_reference_http_service.sh \
        tests/run_reference_websocket_service.sh \
        tests/reference_apps/tls_http_service/main.zag \
        tests/run_reference_tls_http_service.sh \
        tests/linux_epoll_channel.zag \
        tests/reference_apps/async_worker/main.zag \
        tests/run_linux_concurrency_services.sh \
        std/cancel_token_i64.zag \
        tests/cancel_token_i64.zag \
        tests/run_cancel_token.sh \
        std/channel_i64_cancel.zag \
        tests/channel_i64_cancel.zag \
        tests/run_channel_cancel.sh \
        tests/collections_unicode.zag \
        tests/script_collections_unicode.zag \
        tests/collections_mixed_type_bad.zag \
        tests/run_collections_unicode.sh \
        tests/run_resource_contract_syntax.sh \
        tests/run_resource_affine.sh \
        tests/run_param_contracts.sh \
        tests/resource_affine/double_consume_bad.zag \
        tests/resource_affine/early_owner_release_bad.zag \
        tests/resource_affine/generic_bare_t_resource_bad.zag \
        tests/resource_affine/generic_concrete_wrapper_leak_bad.zag \
        tests/resource_affine/leak_bad.zag \
        tests/resource_affine/move_revival_bad.zag \
        tests/resource_affine/move_use_bad.zag \
        tests/resource_affine/moved_owner_retained_bad.zag \
        tests/resource_affine/overwrite_live_bad.zag \
        tests/resource_affine/partial_cleanup_bad.zag \
        tests/resource_affine/pointer_alias_consume_bad.zag \
        tests/resource_affine/positive.zag \
        tests/resource_affine/post_release_read_bad.zag \
        tests/resource_affine/post_release_write_bad.zag \
        tests/resource_affine/resource_list_get_bad.zag \
        tests/resource_affine/resource_list_pop_bad.zag \
        tests/resource_affine/resource_list_push_bad.zag \
        tests/resource_affine/resource_list_set_bad.zag \
        tests/resource_affine/retained_owner_release_bad.zag \
        tests/resource_affine/retained_subtitle_owner_release_bad.zag \
        tests/resource_affine/scalar_list_positive.zag \
        tests/resource_affine/scoped_resource_leak_bad.zag \
        tests/resource_affine/untracked_consume_field_bad.zag \
        tests/resource_affine/untracked_release_field_bad.zag \
        tests/run_resource_embed.sh \
        tests/run_script_json.sh \
        tests/run_script_csv.sh \
        tests/run_script_json_csv.sh \
        tests/script_json.zag \
        tests/script_csv.zag \
        tests/script_json_csv_profile.zag \
        tests/run_package_resolution.sh \
        tests/run_package_lock_generator.sh \
        tests/run_script_cst.sh \
        tests/run_source_origins.sh \
        tests/run_zagscript_views.sh \
        tests/run_script_projection.sh \
        tests/run_zir_authority.sh \
        tests/zir_division.zag \
        tests/i686_literal.zag \
        tests/run_native_authority.sh \
        tests/check_native_bootstrap_repro.sh \
        tests/reference_apps/sqlite_kv/main.zag \
        tests/run_reference_sqlite_kv.sh \
        tests/reference_apps/sqlite_http_service/main.zag \
        tests/run_reference_sqlite_http_service.sh \
        std/dynamic_plugin.zag \
        tests/reference_apps/dynamic_plugin/answer_plugin.c \
        tests/reference_apps/dynamic_plugin/main.zag \
        tests/run_reference_dynamic_plugin.sh \
        tests/reference_apps/zagkit_contract/platform_capabilities_v1.zag \
        tests/reference_apps/zagkit_contract/main.zag \
        tests/reference_apps/zagkit_contract/provenance.tsv \
        tests/run_reference_zagkit_contract.sh
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

echo
echo "── checked-in compiler authority before application aggregates"
run_gate "pure self-hosted native authority and ABI/layout" \
    bash tests/run_native_authority.sh
run_gate "byte-identical pure-Zag bootstrap reproduction" \
    bash tests/check_native_bootstrap_repro.sh

run_gate "shipped editable zagd policy template" \
    bash tests/run_zagd_config_template.sh
run_gate "relocatable installed compiler and complete Script prelude layout" \
    bash tests/run_zagscript_install_layout.sh
run_gate "published Zag Script examples compile without side effects" \
    bash tests/run_zagscript_examples.sh
run_gate "bounded Linux clock and secure-randomness services" \
    bash tests/run_os_linux_services.sh
run_gate "bounded flat configuration and JSON logging services" \
    bash tests/run_config_log_services.sh
run_gate "bounded epoll, channel, and async-worker services" \
    bash tests/run_linux_concurrency_services.sh
run_gate "bounded cooperative cancellation token" \
    bash tests/run_cancel_token.sh
run_gate "bounded cancellation-aware channel waits" \
    bash tests/run_channel_cancel.sh
run_gate "typed collections, ranges, iterators, and UTF-8 services" \
    bash tests/run_collections_unicode.sh
run_gate "compiler-owned bounded embedded resources" \
    bash tests/run_resource_embed.sh
run_gate "bounded IPv4 loopback and DNS wire/runtime foundation" \
    bash tests/run_network_foundation.sh
run_gate "bounded HTTP/1.1 and WebSocket wire/service foundation" \
    bash tests/run_http_websocket_foundation.sh
run_gate "database driver contract, memory implementation, and SQLite adapter" \
    bash tests/run_database_drivers.sh
run_gate "SQLite-backed native reference application" \
    bash tests/run_reference_sqlite_kv.sh
run_gate "frozen nine-member native ZagScript reference-application suite" \
    env ZNC="$PWD/znc" bash tests/run_zagscript_reference_apps.sh

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
run_gate "edition-2027 resource contract syntax and identity" \
    bash tests/run_resource_contract_syntax.sh
run_gate "edition-2027 affine resources and retained views" \
    bash tests/run_resource_affine.sh
run_gate "edition-2027 parameter-local borrow and escape contracts" \
    bash tests/run_param_contracts.sh
run_gate "typed Script list behavior" \
    bash tests/run_script_list.sh
run_gate "bounded Script string builder" \
    bash tests/run_script_string_builder.sh
run_gate "bounded process timeout and capture boundary" \
    bash tests/run_script_process_boundary.sh
run_gate "typed JSON and CSV behavior" \
    bash tests/run_script_json_csv.sh
run_gate "deterministic local package-import foundation" \
    bash tests/run_package_resolution.sh
run_gate "create-only canonical vendored package-lock generation" \
    bash tests/run_package_lock_generator.sh
run_gate "beginner-facing Script conveniences" \
    bash tests/run_script_beginner.sh
run_gate "Python-shaped Script syntax remains Zag lowering" \
    bash tests/run_script_python_shape.sh
run_gate "lossless indentation CST spans and generated origin coverage" \
    bash tests/run_script_cst.sh
run_gate "exact parser and typed-IR source origin authority" \
    bash tests/run_source_origins.sh
run_gate "portable fail-closed derivation ledger v2 codec" \
    bash tests/run_derivation_ledger.sh
run_gate "Zag Script parser and watcher malformed-input smoke" \
    bash tests/run_zagscript_fuzz_smoke.sh
run_gate "script/explain/harden/check CLI and explicit-choice authority" \
    bash tests/run_script_cli.sh
run_gate "four ZagScript views, explicit promotion, and portable bounded reversal" \
    bash tests/run_zagscript_views.sh
run_gate "unique-context structural projection and localized conflicts" \
    bash tests/run_script_projection.sh
run_gate "versioned verified Zag IR production contract, origins, and explicit migration bridge" \
    bash tests/run_zir_authority.sh
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
run_gate "zagd stable generation metadata, quarantine, and rollback remain non-executable" \
    bash tests/run_zagd_generation.sh
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
echo "════ zagscript-release pass=$pass fail=$fail total=$total expected=$expected_total ════"
if [[ $total -ne $expected_total ]]; then
    printf 'release gate inventory drift: expected %d suites, ran %d\n' \
        "$expected_total" "$total" >&2
    exit 1
fi
test "$pass" -eq "$expected_total" && test "$fail" -eq 0
