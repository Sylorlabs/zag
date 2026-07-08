# Zag compiler Makefile
#
# Primary compiler: ./znc  (native x86-64 ELF, zero cc/as/ld/libc)
#
# Supported workflow:
#   make           — rebuild znc from seed (= bootstrap)
#   make test      — run the authoritative v1 test suite
#   make install   — install znc to /usr/local/bin
#   make clean     — remove generated artifacts (keeps the znc seed)

.PHONY: all bootstrap znc test test-pure-tree test-authority test-bootstrap test-semantics \
        test-diagnostics test-tooling test-programs test-native test-abi-layout test-arm64 \
        test-differential-backends test-arm64-selfhost clean install

# ── Primary target ────────────────────────────────────────────────────────────
all: znc

# ── Build the native compiler from seed ──────────────────────────────────────
znc: selfhost/native/znc.zag
	@echo "── rebuilding znc from seed (no cc/as/ld/libc) ──"
	./znc selfhost/native/znc.zag -o znc.new
	mv -f znc.new znc
	@echo "   ./znc rebuilt"

bootstrap: znc
	@echo "Bootstrap complete — seed: ./znc"

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

test-diagnostics:
	bash tests/run_diag.sh

test-tooling:
	bash tests/run_tooling.sh

test-programs:
	bash tests/run_programs.sh

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

# Default `make test`: runs the v1 release gates.
test: znc test-pure-tree test-authority test-bootstrap test-semantics test-diagnostics test-tooling test-programs test-native test-abi-layout test-arm64 test-differential-backends test-arm64-selfhost
	@echo "════ all v1 release gates passed ════"

# ── Install ───────────────────────────────────────────────────────────────────
install: znc
	install -m755 znc /usr/local/bin/znc
	@echo "Installed znc → /usr/local/bin/znc"

# ── Clean ─────────────────────────────────────────────────────────────────────
# Removes generated artifacts. Does NOT remove the znc seed binary.
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
	@echo "clean done (znc seed preserved)"
