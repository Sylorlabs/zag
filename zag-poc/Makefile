# Zag compiler Makefile
#
# Native compiler: ./znc on Linux x86-64; platform-qualified on ARM hosts
# (zero cc/as/ld/libc on every supported bootstrap path)
#
# Supported workflow:
#   make           — rebuild znc from seed (= bootstrap)
#   make test      — run the authoritative v1 test suite
#   make install   — install under PREFIX (default: /usr/local)
#   make clean     — remove scratch artifacts (keeps native toolchain seeds)

.PHONY: all bootstrap znc zagd zag-lsp print-native-host test test-host-selection test-driver-foundation test-zagscript-release test-zagscript-master test-v1-compat test-zagd-product test-zagd-launchd-service test-zagd-core test-zagd-incremental test-zagd-executor test-zagd-background-semantics test-macho-debug-writer test-pure-tree test-authority test-bootstrap test-semantics test-typed-authority test-analyzer test-native-total test-native-lint test-hot-reload test-dynamic-abi test-resource-embed test-release-package-layout test-database-drivers test-script-capabilities test-script-allocation-accounting test-zagscript-install-layout test-gpu-isolation test-gfx1010-vm test-gpu-std test-gpu-platform test-gpu-compat test-gpu-runtime test-gpu-zag-runtime test-linux-drm test-std-namespace test-docs-truth test-effect-witness \
		test-diagnostics test-tooling test-programs test-native test-abi-layout test-arm64 test-arm64-cabi-object \
		test-arm64-memory-offsets test-arm64-rt-builtins test-differential-backends test-arm64-selfhost test-macos-arm64-release test-macos-dyld-import clean install

# Bootstrap and release gates create and consume compiler generations. Keep a
# single evidence stream even when callers pass `-j`; GNU make 3.81 supports
# this global special target on the oldest macOS toolchain in scope.
.NOTPARALLEL:
.DEFAULT_GOAL := all

PREFIX ?= /usr/local
BINDIR ?= $(PREFIX)/bin
LIBDIR ?= $(PREFIX)/lib
DATADIR ?= $(PREFIX)/share
DESTDIR ?=
INSTALL ?= install

HOST_ID := $(shell uname -s)-$(shell uname -m)

ifeq ($(HOST_ID),Darwin-arm64)
NATIVE_PLATFORM = macos-arm64
NATIVE_TARGET_ARGS = --target macos-arm64
NATIVE_ZNC = ./znc-macos-arm64
NATIVE_ZAGD = ./zagd-macos-arm64
NATIVE_LSP = ./zag-lsp-macos-arm64
else ifeq ($(HOST_ID),Linux-aarch64)
NATIVE_PLATFORM = linux-arm64
NATIVE_TARGET_ARGS = --target arm64
NATIVE_ZNC = ./znc-linux-arm64
NATIVE_ZAGD = ./zagd-linux-arm64
NATIVE_LSP = ./zag-lsp-linux-arm64
else ifeq ($(HOST_ID),Linux-arm64)
NATIVE_PLATFORM = linux-arm64
NATIVE_TARGET_ARGS = --target arm64
NATIVE_ZNC = ./znc-linux-arm64
NATIVE_ZAGD = ./zagd-linux-arm64
NATIVE_LSP = ./zag-lsp-linux-arm64
else ifneq ($(filter $(HOST_ID),Linux-x86_64 Linux-amd64),)
NATIVE_PLATFORM = linux-x86_64
NATIVE_TARGET_ARGS =
NATIVE_ZNC = ./znc
NATIVE_ZAGD = ./zagd
NATIVE_LSP = ./zag-lsp
else
$(error unsupported native host '$(HOST_ID)'; supported hosts: Darwin-arm64, Linux-x86_64, Linux-amd64, Linux-aarch64, Linux-arm64)
endif
ZNC ?= $(abspath $(NATIVE_ZNC))
export ZNC

# Stable, build-free host selector output for diagnostics and its regression
# test. HOST_ID may be overridden on the make command line for that test only.
print-native-host:
	@printf 'host=%s platform=%s target_args=%s znc=%s zagd=%s lsp=%s\n' \
		'$(HOST_ID)' '$(NATIVE_PLATFORM)' '$(NATIVE_TARGET_ARGS)' \
		'$(NATIVE_ZNC)' '$(NATIVE_ZAGD)' '$(NATIVE_LSP)'

# ── Primary target ────────────────────────────────────────────────────────────
all: bootstrap

# ── Build the native compiler from seed ──────────────────────────────────────
bootstrap: selfhost/native/znc.zag selfhost/zagd_daemon.zag selfhost/zagd_macos_daemon.zag
	@echo "── rebuilding fixed-point znc + zagd (no cc/as/ld/libc) ──"
	ZAG_BOOTSTRAP_OUTPUT="$(NATIVE_ZNC)" \
	ZAG_BOOTSTRAP_DAEMON_OUTPUT="$(NATIVE_ZAGD)" bash bootstrap.sh

# Keep the historical target names, but route both through the fixpoint
# bootstrap so `make znc` cannot install an unproven stage-1 compiler.
znc: bootstrap

zagd: bootstrap

# Build the editor server users actually install. Analyzer output remains on:
# a warning here is a release-quality problem, not packaging noise.
zag-lsp: znc selfhost/lsp/zag-lsp.zag
	"$(NATIVE_ZNC)" selfhost/lsp/zag-lsp.zag $(NATIVE_TARGET_ARGS) \
		-o "$(NATIVE_LSP)" --no-zagd

# ── Test targets ─────────────────────────────────────────────────────────────

test-pure-tree:
	bash tests/check_pure_zag_tree.sh

test-host-selection:
	bash tests/check_native_host_selection.sh

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

test-native-total:
	bash tests/run_native_total.sh

test-native-lint:
	bash tests/run_native_lint.sh

test-database-drivers:
	bash tests/run_database_drivers.sh

test-script-capabilities:
	bash tests/run_script_capabilities.sh

test-script-allocation-accounting:
	bash tests/run_script_allocation_accounting.sh

test-zagscript-install-layout: znc zagd
	bash tests/run_zagscript_install_layout.sh

test-zagd-core:
	bash tests/run_zagd_core.sh

test-zagd-incremental:
	bash tests/run_zagd_incremental.sh

test-zagd-executor:
	bash tests/run_zagd_executor.sh

test-zagd-background-semantics:
	bash tests/run_zagd_background_semantics.sh

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

# Deliberately manual and sequential: this workstation evidence gate requires
# a user cgroup, active earlyoom, the i686 boundary, and 30-run benchmarks. It
# is not a dependency of `test`, CI, or release packaging.
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

test-arm64-cabi-object:
	@echo "── arm64 scalar C ABI ET_REL boundary ──"
	bash tests/run_arm64_cabi_object.sh

test-arm64-memory-offsets:
	@echo "── arm64 scalar memory displacement boundary ──"
	bash tests/run_arm64_memory_offsets.sh

test-arm64-rt-builtins:
	@echo "── arm64 public std/rt and numeric-time parity ──"
	bash tests/run_arm64_rt_builtins.sh

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

test-resource-embed:
	@echo "── deterministic resource embedding gate ──"
	bash tests/run_resource_embed.sh

test-release-package-layout:
	@echo "── release package layout self-test ──"
	bash tests/run_release_package_layout.sh

# Unified pure-Zag driver foundation release gate. This stays separate from
# the broad v1 suite because its six Linux-series/architecture QEMU matrix is
# an explicit support claim and must fail closed when images or module evidence
# are absent.
test-driver-foundation: znc
	@echo "── pure-Zag driver foundation release gate ──"
	bash tests/run_driver_foundation.sh

# Default `make test`: run the release gates that provide native evidence on
# this host. Linux-only ELF, DRM, qemu, and hot-reload gates stay available as
# explicit targets instead of being misreported as Darwin failures.
ifeq ($(HOST_ID),Darwin-arm64)
DEFAULT_TEST_TARGETS = test-host-selection test-pure-tree test-authority test-bootstrap test-semantics \
	test-typed-authority test-diagnostics test-effect-witness test-tooling \
	test-docs-truth test-analyzer test-native-total test-native-lint test-programs test-abi-layout \
	test-database-drivers test-script-capabilities test-script-allocation-accounting \
	test-zagscript-install-layout test-zagd-core test-zagd-incremental \
	test-zagd-executor test-zagd-background-semantics test-zagd-product \
	test-zagd-launchd-service test-macho-debug-writer test-arm64-cabi-object test-arm64-memory-offsets test-arm64-rt-builtins \
	test-resource-embed test-gpu-isolation test-gfx1010-vm test-gpu-std \
	test-std-namespace test-release-package-layout test-macos-arm64-release
else ifneq ($(filter $(HOST_ID),Linux-aarch64 Linux-arm64),)
DEFAULT_TEST_TARGETS = test-host-selection test-pure-tree test-authority test-bootstrap test-arm64 \
	test-arm64-selfhost test-release-package-layout
else ifeq ($(NATIVE_PLATFORM),linux-x86_64)
DEFAULT_TEST_TARGETS = test-host-selection test-pure-tree test-authority test-bootstrap test-semantics \
	test-typed-authority test-diagnostics test-effect-witness test-tooling \
	test-docs-truth test-analyzer test-hot-reload test-dynamic-abi \
	test-resource-embed test-gpu-isolation test-gfx1010-vm test-gpu-std \
	test-gpu-platform test-gpu-compat test-std-namespace test-programs \
	test-native test-abi-layout test-arm64 test-differential-backends \
	test-arm64-selfhost test-release-package-layout
else
$(error internal error: no default test matrix for '$(HOST_ID)')
endif

# The intentionally fail-closed ZagScript 1.0 authority remains
# `make test-zagscript-release`.
test: znc $(DEFAULT_TEST_TARGETS)
	@echo "════ all v1 release gates passed ════"

# ── Install ───────────────────────────────────────────────────────────────────
install: znc zagd zag-lsp
	$(INSTALL) -d "$(DESTDIR)$(BINDIR)" "$(DESTDIR)$(LIBDIR)/zag/std" "$(DESTDIR)$(DATADIR)/zag"
	$(INSTALL) -m755 "$(NATIVE_ZNC)" "$(DESTDIR)$(BINDIR)/znc"
	$(INSTALL) -m755 "$(NATIVE_ZAGD)" "$(DESTDIR)$(BINDIR)/zagd"
	$(INSTALL) -m755 "$(NATIVE_LSP)" "$(DESTDIR)$(BINDIR)/zag-lsp"
	$(INSTALL) -m755 tools/zagd-user-service.sh "$(DESTDIR)$(BINDIR)/zagd-user-service"
	$(INSTALL) -m755 tools/zagd-launchd-service.sh "$(DESTDIR)$(BINDIR)/zagd-launchd-service"
	$(INSTALL) -m644 examples/zagd.conf "$(DESTDIR)$(DATADIR)/zag/zagd.conf.example"
	$(INSTALL) -m644 std/*.zag "$(DESTDIR)$(LIBDIR)/zag/std/"
	$(INSTALL) -m644 selfhost/std/process.zag "$(DESTDIR)$(LIBDIR)/zag/std/process.zag"
	$(INSTALL) -m644 selfhost/std/script_io.zag "$(DESTDIR)$(LIBDIR)/zag/std/script_io.zag"
	$(INSTALL) -m644 selfhost/std/script_input.zag "$(DESTDIR)$(LIBDIR)/zag/std/script_input.zag"
	$(INSTALL) -m644 selfhost/std/script_string_builder.zag "$(DESTDIR)$(LIBDIR)/zag/std/script_string_builder.zag"
	$(INSTALL) -m644 selfhost/std/script_list.zag "$(DESTDIR)$(LIBDIR)/zag/std/script_list.zag"
	$(INSTALL) -m644 selfhost/std/script_string.zag "$(DESTDIR)$(LIBDIR)/zag/std/script_string.zag"
	$(INSTALL) -m644 selfhost/std/script_path.zag "$(DESTDIR)$(LIBDIR)/zag/std/script_path.zag"
	@echo "Installed tools → $(DESTDIR)$(BINDIR), std → $(DESTDIR)$(LIBDIR)/zag/std, policy → $(DESTDIR)$(DATADIR)/zag"

# ── Clean ─────────────────────────────────────────────────────────────────────
# Removes scratch/test artifacts. Does NOT remove native compiler, daemon, or
# LSP seeds, including the platform-qualified ARM host toolchains. On those
# hosts the qualified files may be the only binaries the kernel can execute.
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
	@echo "clean done (native compiler/daemon/LSP seeds preserved)"
