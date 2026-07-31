# Zag compiler Makefile
#
# Primary compiler: ./znc (built by bootstrap.sh from bootstrap/znc seed) or Apple Silicon Mach-O, zero cc/as/ld/libc)
#
# Supported workflow:
#   make           — rebuild znc from seed (bootstrap/)
#   make test      — run the authoritative v1 test suite
#   make install   — install znc to /usr/local/bin
#   make clean     — remove generated artifacts (keeps the bootstrap/ seed)

.PHONY: all bootstrap znc zagd test test-zagscript-release test-zagscript-master test-v1-compat test-zagd-product test-zagd-launchd-service test-macho-debug-writer test-pure-tree test-authority test-bootstrap test-semantics test-typed-authority test-analyzer test-hot-reload test-dynamic-abi test-gpu-isolation test-gfx1010-vm test-gpu-std test-gpu-platform test-std-namespace \
        test-diagnostics test-tooling test-programs test-native test-abi-layout test-arm64 \
        test-differential-backends test-arm64-selfhost test-macos-arm64-release test-macos-dyld-import clean install

# ── Primary target ────────────────────────────────────────────────────────────
all: bootstrap

# ── Build the native compiler from seed ──────────────────────────────────────
bootstrap: selfhost/native/znc.zag selfhost/zagd_daemon.zag
	@echo "── rebuilding fixed-point znc + zagd (no cc/as/ld/libc) ──"
	bash bootstrap.sh

# Keep the historical target names, but route both through the fixpoint
# bootstrap so `make znc` cannot install an unproven stage-1 compiler.
znc: bootstrap

zagd: bootstrap

# ── Test targets ─────────────────────────────────────────────────────────────

test-pure-tree:
	bash tests/check_pure_zag_tree.sh

# THE authoritative release gate: poisons host C tools, self-rebuilds znc, smoke tests.
test-authority:
	@echo "── native authority gate (v1 release gate) ──"
	bash tests/run_native_authority.sh

# Byte-identical three-generation native bootstrap proof.
test-bootstrap:
	bash tests/check_native_bootstrap_repro.sh

test-semantics:
	bash tests/run_semantics.sh

test-typed-authority:
	bash tests/run_typed_authority.sh

test-diagnostics:
	bash tests/run_diag.sh

test-tooling:
	bash tests/run_tooling.sh

# Static analyzer (analyze.zag): leak (L00xx) + efficiency (E01xx) lints.
test-analyzer:
	@echo "── static analyzer suite ──"
	bash tests/run_analyzer.sh

# Live code hot-reload (hot_rt.zag + `znc hot-patch`): end-to-end swap test.
test-hot-reload:
	@echo "── hot-reload suite ──"
	bash tests/run_hot_reload.sh

# Fail-closed Linux GPU reset/fault-domain classification.
test-gpu-isolation:
	@echo "── GPU isolation classification suite ──"
	bash tests/run_gpu_isolation.sh

# Strict ZGK1 instruction and PM4 virtual command processor.
test-gfx1010-vm:
	@echo "── virtual GFX10.1 command processor suite ──"
	bash tests/run_gfx1010_vm.sh

test-gpu-std:
	@echo "── evidence-first GPU standard library suite ──"
	bash tests/run_gpu_std.sh

test-gpu-platform:
	@echo "── GPU compiler/runtime/driver boundary suite ──"
	bash tests/run_gpu_platform.sh

# Compiler-owned, non-shadowable standard-library import namespace.
test-std-namespace:
	@echo "── std namespace suite ──"
	bash tests/run_std_namespace.sh

test-programs:
	bash tests/run_programs.sh

test-zagd-product: znc zagd
	bash tests/run_zagd_product.sh

test-zagd-launchd-service:
	bash tests/run_zagd_launchd_service.sh

test-macho-debug-writer:
	bash tests/run_macho_debug_writer.sh

test-macos-dyld-import:
	bash tests/run_macos_dyld_import.sh

test-zagscript-release:
	bash tests/run_zagscript_release_gate.sh

test-zagscript-master:
	bash tests/run_zagscript_master_gate.sh

test-v1-compat:
	bash tests/run_v1_compatibility_gate.sh

# Full native backend suite, Zag → ELF, no cc/as/ld/libc.
test-native:
	@echo "── native backend suite ──"
	bash tests/run_native.sh

# ABI/layout edge-case regression (release-blocking — documents CURRENT behavior).
test-abi-layout:
	@echo "── ABI/layout regression suite (release gate) ──"
	bash tests/run_abi_layout.sh

# AArch64 Linux backend (runs via qemu-user; requires qemu-aarch64-static).
test-arm64:
	@echo "── arm64 backend suite (qemu-user) ──"
	bash tests/run_native_arm64.sh

# Cross-backend differential gate: identical output on x86-64 and arm64.
test-differential-backends:
	@echo "── differential x86/arm64 gate ──"
	bash tests/run_differential.sh

test-arm64-selfhost:
	@echo "── arm64 self-hosting fixpoint ──"
	bash tests/run_arm64_selfhost.sh

# Native Apple-Silicon Darwin/Mach-O release gate.  Must be run on macOS arm64.
test-macos-arm64-release:
	@echo "── native macOS arm64 release gate ──"
	bash tests/run_macos_arm64_release.sh

test-dynamic-abi:
	@echo "── explicit dynamic system ABI gate ──"
	bash tests/run_dynamic_abi.sh

# Default `make test`: runs the v1 release gates.
test: znc test-pure-tree test-authority test-bootstrap test-semantics test-typed-authority test-diagnostics test-tooling test-analyzer test-hot-reload test-dynamic-abi test-gpu-isolation test-gfx1010-vm test-gpu-std test-gpu-platform test-std-namespace test-programs test-native test-abi-layout test-arm64 test-differential-backends test-arm64-selfhost
	@echo "════ all v1 release gates passed ════"

# ── Install ───────────────────────────────────────────────────────────────────
install: znc zagd
	install -m755 znc /usr/local/bin/znc
	install -m755 zagd /usr/local/bin/zagd
	install -m755 tools/zagd-user-service.sh /usr/local/bin/zagd-user-service
	install -m755 tools/zagd-launchd-service.sh /usr/local/bin/zagd-launchd-service
	install -d /usr/local/lib/zag/std
	install -d /usr/local/share/zag
	install -m644 examples/zagd.conf /usr/local/share/zag/zagd.conf.example
	install -m644 std/*.zag /usr/local/lib/zag/std/
	install -m644 selfhost/std/process.zag /usr/local/lib/zag/std/process.zag
	install -m644 selfhost/std/script_io.zag /usr/local/lib/zag/std/script_io.zag
	install -m644 selfhost/std/script_input.zag /usr/local/lib/zag/std/script_input.zag
	install -m644 selfhost/std/script_string_builder.zag /usr/local/lib/zag/std/script_string_builder.zag
	install -m644 selfhost/std/script_list.zag /usr/local/lib/zag/std/script_list.zag
	install -m644 selfhost/std/script_string.zag /usr/local/lib/zag/std/script_string.zag
	install -m644 selfhost/std/script_path.zag /usr/local/lib/zag/std/script_path.zag
	@echo "Installed znc + zagd + service control → /usr/local/bin, std → /usr/local/lib/zag/std, policy template → /usr/local/share/zag"

# ── Clean ─────────────────────────────────────────────────────────────────────
# Removes generated artifacts. Does NOT remove the bootstrap/ seed binaries.
clean:
	@echo "── removing generated outputs ──"
	find . -name '*.zag.out' -delete 2>/dev/null || true
	rm -f nt_src.zag
	@echo "── removing scratch and test build binaries ──"
	rm -f znc_fp znc_fp2 znc_new znc_new2 znc_new3 znc_test
	rm -f znc.fp2 znc.fp3 znc.new2
	rm -f _pt.zag.out
	rm -f test_escape_debug test_escape_debug.zag test_escape_debug.zag.out
	rm -f test_infer test_infer.zag test_infer.zag.out
	rm -f test_let test_let.zag test_let.zag.out
	rm -f test_unannotated.zag
	rm -f cagg_debug.zag cagg_min.zag cagg_simple.zag cscalar.zag
	@echo "── removing compiled example binaries at project root ──"
	rm -f audio_render audio_render_bad cache_control cache_control_bad
	rm -f closure_basic closure_bad closure_effvar closure_effvar_bad closure_escape_bad
	rm -f effvar_local effvar_local_bad effvar_return embedded_sensor
	rm -f error_union generic_box generic_map generic_map_rt generic_map_rt_bad
	rm -f hot_demo hpc_rns interfaces io list main map methods
	rm -f modules modules_generic modules_struct numeric operator_contract operator_contract_bad
	rm -f optionals patterns posit32 posit_multi process_bounded process_bounded_bad
	rm -f process_poly process_poly_bad quire realtime_io_lock_bad safe_bignum
	rm -f sensor_pipeline sensor_pipeline_bad strings struct_basic synth
	rm -f total_bad total_guarded total_nonzero voice_struct voice_struct_bad wasm_op
	@echo "── removing compiled example binaries in examples/ ──"
	rm -f examples/cache_control examples/cache_control_bad
	rm -f examples/operator_contract examples/operator_contract_bad
	rm -f examples/sensor_pipeline examples/sensor_pipeline_bad
	rm -f examples/total_guarded examples/total_nonzero
	rm -f examples/interfaces examples/hot_demo
	rm -f examples/*.mlir
	@echo "clean done (bootstrap/ seed preserved)"
