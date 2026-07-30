#!/usr/bin/env bash
# Runtime GPU tests — runs Zag-emitted kernels on the physical GPU.
#
# This script tests the actual end-to-end path:
#   Zag source → znc encoder → SPIR-V/GLSL binary → real GPU driver → output verification
#
# Targets tested on this machine (AMD RX 5700 XT, Mesa RADV):
#   - vulkan-compat: SPIR-V → Vulkan compute pipeline → fence → readback
#   - opengl-compat: GLSL 430 → EGL context → glDispatchCompute → readback
#
# Targets that CANNOT be tested on this machine:
#   - opencl-compat: No working OpenCL ICD (only nvidia.icd, no NVIDIA GPU)
#   - cuda-compat:   No NVIDIA GPU or driver
#   - metal-compat:  Linux, no Metal framework (run tests/run_metal_mac.sh on macOS)
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-gpu-runtime.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# ── Fill kernel source ──────────────────────────────────────────────────────
cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG

echo "════════════════════════════════════════════════════════════════"
echo "  Zag GPU Runtime Tests — physical GPU verification"
echo "════════════════════════════════════════════════════════════════"

# ── Vulkan runtime test ─────────────────────────────────────────────────────
echo ""
echo "── Vulkan (SPIR-V → RADV) ──"

if ! command -v gcc >/dev/null 2>&1; then
    xx "gcc not found — cannot build Vulkan runtime test"
else
    if "$ZNC" "$tmp/fill.zag" --target vulkan-compat -o "$tmp/fill.spv" >/dev/null 2>&1; then
        ok "znc emits SPIR-V binary for vulkan-compat"
    else
        xx "znc failed to emit SPIR-V"
    fi

    if spirv-val --target-env vulkan1.0 "$tmp/fill.spv" >/dev/null 2>&1; then
        ok "SPIR-V passes spirv-val --target-env vulkan1.0"
    else
        xx "SPIR-V fails spirv-val"
    fi

    if gcc -o "$tmp/vk_test" tests/vulkan_runtime_test.c -lvulkan 2>/dev/null; then
        ok "Vulkan runtime test harness compiled"
    else
        xx "Failed to compile Vulkan runtime test (libvulkan-dev missing?)"
    fi

    if [ -x "$tmp/vk_test" ]; then
        if "$tmp/vk_test" "$tmp/fill.spv" >"$tmp/vk_out.txt" 2>&1; then
            ok "Vulkan kernel ran on GPU and output verified correct"
            grep "VULKAN_RUNTIME_OK" "$tmp/vk_out.txt" >/dev/null && ok "VULKAN_RUNTIME_OK marker present"
            grep "Physical device" "$tmp/vk_out.txt" | head -1
        else
            xx "Vulkan runtime test failed"
            cat "$tmp/vk_out.txt"
        fi
    fi
fi

# ── OpenGL runtime test ─────────────────────────────────────────────────────
echo ""
echo "── OpenGL (GLSL 430 → Mesa) ──"

if "$ZNC" "$tmp/fill.zag" --target opengl-compat -o "$tmp/fill.glsl" >/dev/null 2>&1; then
    ok "znc emits GLSL source for opengl-compat"
else
    xx "znc failed to emit GLSL"
fi

if gcc -o "$tmp/gl_test" tests/opengl_runtime_test.c -lEGL -lGL 2>/dev/null; then
    ok "OpenGL runtime test harness compiled"
else
    xx "Failed to compile OpenGL runtime test (libEGL/libGL missing?)"
fi

if [ -x "$tmp/gl_test" ]; then
    if "$tmp/gl_test" "$tmp/fill.glsl" >"$tmp/gl_out.txt" 2>&1; then
        ok "OpenGL kernel ran on GPU and output verified correct"
        grep "OPENGL_RUNTIME_OK" "$tmp/gl_out.txt" >/dev/null && ok "OPENGL_RUNTIME_OK marker present"
        grep "EGL OpenGL context" "$tmp/gl_out.txt" | head -1
    else
        xx "OpenGL runtime test failed"
        cat "$tmp/gl_out.txt"
    fi
fi

# ── Untestable targets on this machine ──────────────────────────────────────
echo ""
echo "── Untestable on this machine (AMD GPU, Linux) ──"
echo "  --  opencl-compat: No working OpenCL ICD (only nvidia.icd, no NVIDIA GPU)"
echo "  --  cuda-compat:   No NVIDIA GPU or driver"
echo "  --  metal-compat:  Linux, no Metal framework (run tests/run_metal_mac.sh on macOS)"

echo ""
echo "════════════════════════════════════════════════════════════════"
echo "  Runtime GPU tests: pass=$pass fail=$fail"
echo "════════════════════════════════════════════════════════════════"
[ "$fail" -eq 0 ]
