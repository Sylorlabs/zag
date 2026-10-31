# Zag compiler Makefile
#
# Primary compiler: ./znc  (native x86-64 ELF, zero cc/as/ld/libc)
#
# Supported workflow:
#   make           — rebuild znc from seed (= bootstrap)
#   make test          — run the authoritative v1 test suite
#   make release-check — run the one complete release-blocking closure
#   make build-tools   — build all installed tools without privilege
#   make install       — install already-built tools (never rebuilds)
#   make clean         — remove generated artifacts (keeps the znc seed)

.PHONY: all bootstrap znc zagd zag-lsp build-tools test release-check test-release-package test-static-elf-hardening test-static-archive-cabi test-peephole-branches test-driver-foundation test-zagscript-release test-zagscript-master test-i686-release test-v1-compat test-zagd-product test-pure-tree test-authority test-bootstrap test-semantics test-typed-authority test-analyzer test-hot-reload test-dynamic-abi test-resource-embed test-gpu-isolation test-gfx1010-vm test-gpu-std test-gpu-platform test-gpu-compat test-gpu-runtime test-gpu-zag-runtime test-linux-drm test-std-namespace test-docs-truth test-effect-witness \
        test-diagnostics test-tooling test-programs test-native test-abi-layout test-arm64 \
        test-differential-backends test-arm64-selfhost clean install install-only

PREFIX ?= /usr/local
DESTDIR ?=
INSTALL ?= install
BINDIR := $(DESTDIR)$(PREFIX)/bin
LIBDIR := $(DESTDIR)$(PREFIX)/lib/zag
SHAREDIR := $(DESTDIR)$(PREFIX)/share/zag

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

# Build the editor server users actually install. Analyzer output remains on:
# a warning here is a release-quality problem, not packaging noise.
zag-lsp: znc selfhost/lsp/zag-lsp.zag
	./znc selfhost/lsp/zag-lsp.zag -o zag-lsp --no-zagd

# Build every installed binary as the invoking, unprivileged user. Installation
# is a deliberately separate file-copy phase so `sudo make install` can never
# run the self-hosting compiler as root.
build-tools: bootstrap
	./znc selfhost/lsp/zag-lsp.zag -o zag-lsp --no-zagd

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

test-docs-truth:
	bash tests/run_docs_truth.sh

test-effect-witness:
	bash tests/run_effect_witness.sh

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

# Compat-tier artifact, loader, and bounded runtime gate. Physical dispatch is
# still opt-in inside run_gpu_runtime.sh via ZAG_RUN_PHYSICAL_GPU=1.
test-gpu-compat:
	@echo "── GPU compatibility-tier suite ──"
	bash tests/run_compat_vulkan.sh
	bash tests/run_compat_opengl.sh
	bash tests/run_compat_opencl.sh
	bash tests/run_compat_cuda.sh
	bash tests/run_compat_metal.sh
	bash tests/run_gpu_runtime.sh
	bash tests/run_gpu_zag_runtime.sh

test-gpu-runtime:
	@echo "── GPU bounded runtime gate ──"
	bash tests/run_gpu_runtime.sh

test-gpu-zag-runtime:
	@echo "── pure-Zag Vulkan/OpenGL/OpenCL runtime gate ──"
	bash tests/run_gpu_zag_runtime.sh

# Hardware-specific, read-only AMDGPU DRM boundary. This target is separate
# from the portable compatibility gate because it expects a live AMD render
# node and records the display-bound opt-in policy explicitly.
test-linux-drm:
	@echo "── Linux AMDGPU DRM discovery and native preflight gate ──"
	bash tests/run_linux_drm.sh

# Compiler-owned, non-shadowable standard-library import namespace.
test-std-namespace:
	@echo "── std namespace suite ──"
	bash tests/run_std_namespace.sh

test-programs:
	bash tests/run_programs.sh

test-zagd-product: znc zagd
	bash tests/run_zagd_product.sh
	ZAGD="$(CURDIR)/zagd" ZNC="$(CURDIR)/znc" bash tests/run_zagd_idle_cpu.sh

test-zagscript-release:
	bash tests/run_zagscript_release_gate.sh

# Deliberately manual and sequential: this workstation evidence gate requires
# a user cgroup, active earlyoom, the i686 boundary, and 30-run benchmarks. It
# is not a dependency of `test`, CI, or release packaging.
test-zagscript-master:
	bash tests/run_zagscript_master_gate.sh

test-v1-compat:
	bash tests/run_v1_compatibility_gate.sh

# The published Linux/i686 subset has its own fail-closed authority gate. Keep
# it in the canonical release closure rather than relying on the optional
# workstation benchmark/master wrapper to supply release evidence.
test-i686-release:
	bash tests/run_i686_release_gate.sh

# Full native backend suite, Zag → ELF, no cc/as/ld/libc.
test-native:
	@echo "── native backend suite ──"
	bash tests/run_native.sh

# Static ELF memory-permission policy across x86-64 and AArch64 writers.
test-static-elf-hardening: znc
	@echo "── static ELF hardening suite ──"
	bash tests/run_static_elf_hardening.sh

# Pure-Zag x86-64 ET_REL/archive generation plus a real bounded @cabi call.
test-static-archive-cabi: znc
	@echo "── static archive C ABI slice ──"
	bash tests/run_static_archive_cabi.sh

# Branch-retargeting and short/near jump coverage for the native peephole pass.
test-peephole-branches: znc
	@echo "── native peephole branch suite ──"
	bash tests/run_peephole_branches.sh

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

test-dynamic-abi:
	@echo "── explicit dynamic system ABI gate ──"
	bash tests/run_dynamic_abi.sh

test-resource-embed:
	@echo "── deterministic resource embedding gate ──"
	bash tests/run_resource_embed.sh

# Unified pure-Zag driver foundation release gate. This stays separate from
# the broad v1 suite because its six Linux-series/architecture QEMU matrix is
# an explicit support claim and must fail closed when images or module evidence
# are absent.
test-driver-foundation: znc
	@echo "── pure-Zag driver foundation release gate ──"
	bash tests/run_driver_foundation.sh

# Default `make test`: runs the v1 release gates. The intentionally
# fail-closed ZagScript 1.0 authority remains `make test-zagscript-release`.
test: znc test-pure-tree test-authority test-bootstrap test-semantics test-typed-authority test-diagnostics test-effect-witness test-tooling test-docs-truth test-analyzer test-hot-reload test-dynamic-abi test-resource-embed test-gpu-isolation test-gfx1010-vm test-gpu-std test-gpu-platform test-gpu-compat test-std-namespace test-programs test-native test-static-elf-hardening test-static-archive-cabi test-peephole-branches test-abi-layout test-arm64 test-differential-backends test-arm64-selfhost
	@echo "════ all v1 release gates passed ════"

# The sole release-blocking closure. Keep release.sh and release documentation
# pointed at this target instead of copying a second, inevitably drifting list.
# The frozen matrix runs first so an incomplete ZagScript contract refuses the
# release before bootstrap or any heavyweight suite starts.
release-check:
	bash tests/run_zagscript_1_0_matrix_selftest.sh
	bash tests/run_zagscript_1_0_matrix.sh --release
	$(MAKE) --no-print-directory -j1 test-release-package
	$(MAKE) --no-print-directory -j1 test
	$(MAKE) --no-print-directory -j1 test-v1-compat
	$(MAKE) --no-print-directory -j1 test-i686-release
	$(MAKE) --no-print-directory -j1 test-zagd-product
	$(MAKE) --no-print-directory -j1 test-driver-foundation
	$(MAKE) --no-print-directory -j1 test-zagscript-release
	@echo "════ canonical Zag release closure passed ════"

test-release-package:
	bash tests/check_release_package.sh

# ── Install ───────────────────────────────────────────────────────────────────
# `install` is an alias for the copy-only phase. It intentionally has no build
# prerequisite; run `make build-tools` before invoking an elevated install.
install: install-only

install-only:
	@for artifact in znc zagd zag-lsp tools/zagd-user-service.sh; do \
		test -x "$$artifact" || { echo "install: missing executable $$artifact; run 'make build-tools' without sudo first" >&2; exit 1; }; \
	done
	$(INSTALL) -d "$(BINDIR)" "$(LIBDIR)/std" "$(SHAREDIR)"
	$(INSTALL) -m755 znc "$(BINDIR)/znc"
	$(INSTALL) -m755 zagd "$(BINDIR)/zagd"
	$(INSTALL) -m755 zag-lsp "$(BINDIR)/zag-lsp"
	$(INSTALL) -m755 tools/zagd-user-service.sh "$(BINDIR)/zagd-user-service"
	$(INSTALL) -m644 examples/zagd.conf "$(SHAREDIR)/zagd.conf.example"
	$(INSTALL) -m644 std/*.zag "$(LIBDIR)/std/"
	$(INSTALL) -m644 selfhost/std/process.zag "$(LIBDIR)/std/process.zag"
	$(INSTALL) -m644 selfhost/std/script_io.zag "$(LIBDIR)/std/script_io.zag"
	$(INSTALL) -m644 selfhost/std/script_input.zag "$(LIBDIR)/std/script_input.zag"
	$(INSTALL) -m644 selfhost/std/script_string_builder.zag "$(LIBDIR)/std/script_string_builder.zag"
	$(INSTALL) -m644 selfhost/std/script_list.zag "$(LIBDIR)/std/script_list.zag"
	$(INSTALL) -m644 selfhost/std/script_string.zag "$(LIBDIR)/std/script_string.zag"
	$(INSTALL) -m644 selfhost/std/script_path.zag "$(LIBDIR)/std/script_path.zag"
	$(INSTALL) -m644 selfhost/std/script_map.zag "$(LIBDIR)/std/script_map.zag"
	$(INSTALL) -m644 selfhost/std/script_json.zag "$(LIBDIR)/std/script_json.zag"
	$(INSTALL) -m644 selfhost/std/script_csv.zag "$(LIBDIR)/std/script_csv.zag"
	$(INSTALL) -m644 selfhost/std/script_set.zag "$(LIBDIR)/std/script_set.zag"
	$(INSTALL) -m644 selfhost/std/script_range.zag "$(LIBDIR)/std/script_range.zag"
	@echo "Installed prebuilt Zag tools under $(DESTDIR)$(PREFIX)"

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
