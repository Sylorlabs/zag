#!/usr/bin/env bash
# OpenCL compatibility-tier tests: OpenCL-specific SPIR-V binary emission.
# OpenCL uses a separate SPIR-V encoder from Vulkan:
#   - OpCapability Kernel (not Shader), plus Addresses and Int64
#   - OpMemoryModel Physical64 OpenCL (not Logical GLSL450)
#   - OpEntryPoint Kernel (not GLCompute), named after the kernel function
#   - Kernel parameters are OpFunctionParameter (not descriptor sets/push constants)
#   - All OpTypeInt have Signedness=0 (OpenCL convention)
# This is a non-certified fallback backend; tests verify binary structure only,
# not runtime execution (which requires an OpenCL loader and physical device).
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-compat-opencl.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# ── 1. SPIR-V binary emission for the fill kernel ───────────────────────────
cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG

if (cd "$tmp" && "$ZNC" fill.zag --target opencl-compat -o fill.spv >/dev/null 2>&1) && \
   [ -f "$tmp/fill.spv" ]; then
    ok "opencl-compat emits a SPIR-V binary for the fill kernel"
else
    xx "opencl-compat failed to emit a SPIR-V binary"
fi

# ── 2. SPIR-V header validation ─────────────────────────────────────────────
if [ -f "$tmp/fill.spv" ]; then
    magic=$(od -An -tx4 -N4 "$tmp/fill.spv" | tr -d ' \n')
    if [ "$magic" = "07230203" ]; then
        ok "SPIR-V magic number is correct (0x07230203)"
    else
        xx "SPIR-V magic number is wrong: $magic"
    fi
    size=$(wc -c <"$tmp/fill.spv")
    if [ "$size" -gt 100 ] && [ "$((size % 4))" -eq 0 ]; then
        ok "SPIR-V binary size ($size bytes) is reasonable and word-aligned"
    else
        xx "SPIR-V binary size ($size bytes) is wrong or not word-aligned"
    fi
fi

# ── 3. Deterministic emission ───────────────────────────────────────────────
if (cd "$tmp" && "$ZNC" fill.zag --target opencl-compat -o fill-a.spv >/dev/null 2>&1) && \
   (cd "$tmp" && "$ZNC" fill.zag --target opencl-compat -o fill-b.spv >/dev/null 2>&1) && \
   cmp -s "$tmp/fill-a.spv" "$tmp/fill-b.spv"; then
    ok "opencl-compat SPIR-V emission is deterministic"
else
    xx "opencl-compat SPIR-V emission is not deterministic"
fi

# ── 4. OpenCL SPIR-V differs from Vulkan SPIR-V (separate encoders) ─────────
if (cd "$tmp" && "$ZNC" fill.zag --target vulkan-compat -o fill-vk.spv >/dev/null 2>&1) && \
   [ -f "$tmp/fill.spv" ] && [ -f "$tmp/fill-vk.spv" ]; then
    if ! cmp -s "$tmp/fill.spv" "$tmp/fill-vk.spv"; then
        ok "opencl-compat and vulkan-compat produce different SPIR-V (separate encoders)"
    else
        xx "opencl-compat and vulkan-compat produce identical SPIR-V (should differ)"
    fi
else
    xx "failed to emit both opencl and vulkan SPIR-V for comparison"
fi

# ── 5. spirv-val validation for OpenCL environment ──────────────────────────
if command -v spirv-val >/dev/null 2>&1 && [ -f "$tmp/fill.spv" ]; then
    if spirv-val --target-env opencl2.0 "$tmp/fill.spv" >/dev/null 2>&1; then
        ok "SPIR-V binary passes spirv-val --target-env opencl2.0"
    else
        xx "SPIR-V binary fails spirv-val opencl2.0 validation"
        spirv-val --target-env opencl2.0 "$tmp/fill.spv" 2>&1 | head -5 || true
    fi
else
    ok "spirv-val not installed — skipping OpenCL validation (skipped)"
fi

# ── 6. Reject unsupported kernel forms ─────────────────────────────────────
cat >"$tmp/bad.zag" <<'ZAG'
fn unsafeKernel(out: *i32, value: i32) void @kernel {
    while (value > 0) { out[0] = value; }
}
fn main() void { print_i32(0); }
ZAG
rm -f "$tmp/bad.spv"
if ! (cd "$tmp" && "$ZNC" bad.zag --target opencl-compat -o bad.spv >/dev/null 2>&1) && \
   [ ! -e "$tmp/bad.spv" ]; then
    ok "opencl-compat rejects unsafe pointers, loops, and unsupported kernel forms"
else
    xx "opencl-compat accepted an unsupported kernel"
fi

# ── 7. Default output extension is .spv ─────────────────────────────────────
rm -f "$tmp/fill.spv"
if (cd "$tmp" && "$ZNC" fill.zag --target opencl-compat >/dev/null 2>&1) && \
   [ -f "$tmp/fill.spv" ]; then
    ok "opencl-compat default output extension is .spv"
else
    xx "opencl-compat default output extension is wrong"
fi

# ── 8. Entry point name matches kernel function name ────────────────────────
if command -v spirv-dis >/dev/null 2>&1 && [ -f "$tmp/fill.spv" ]; then
    if spirv-dis "$tmp/fill.spv" 2>/dev/null | grep -q 'OpEntryPoint.*Kernel.*"fillKernel"'; then
        ok "OpenCL entry point uses kernel function name (fillKernel)"
    else
        xx "OpenCL entry point name does not match kernel function name"
        spirv-dis "$tmp/fill.spv" 2>/dev/null | grep OpEntryPoint || true
    fi
else
    ok "spirv-dis not installed — skipping entry point name check (skipped)"
fi

echo "════ compat-opencl pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
