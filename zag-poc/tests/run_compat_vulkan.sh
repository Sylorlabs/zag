#!/usr/bin/env bash
# Vulkan compatibility-tier tests: SPIR-V binary emission for the fill kernel.
# This is a non-certified fallback backend; tests verify binary structure only,
# not runtime execution (which requires a Vulkan loader and physical device).
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-compat-vulkan.XXXXXX)
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

if (cd "$tmp" && "$ZNC" fill.zag --target vulkan-compat -o fill.spv >/dev/null 2>&1) && \
   [ -f "$tmp/fill.spv" ]; then
    ok "vulkan-compat emits a SPIR-V binary for the fill kernel"
else
    xx "vulkan-compat failed to emit a SPIR-V binary"
    cat "$tmp"/*.log 2>/dev/null || true
fi

# ── 2. SPIR-V header validation ─────────────────────────────────────────────
if [ -f "$tmp/fill.spv" ]; then
    magic=$(od -An -tx4 -N4 "$tmp/fill.spv" | tr -d ' \n')
    if [ "$magic" = "07230203" ]; then
        ok "SPIR-V magic number is correct (0x07230203)"
    else
        xx "SPIR-V magic number is wrong: $magic"
    fi

    version=$(od -An -tx4 -j4 -N4 "$tmp/fill.spv" | tr -d ' \n')
    if [ "$version" = "00010000" ]; then
        ok "SPIR-V version is 1.0"
    else
        xx "SPIR-V version is wrong: $version"
    fi

    size=$(wc -c <"$tmp/fill.spv")
    if [ "$size" -gt 100 ] && [ "$((size % 4))" -eq 0 ]; then
        ok "SPIR-V binary size ($size bytes) is reasonable and word-aligned"
    else
        xx "SPIR-V binary size ($size bytes) is wrong or not word-aligned"
    fi
else
    xx "no SPIR-V binary to validate"
fi

# ── 3. Deterministic emission ───────────────────────────────────────────────
if (cd "$tmp" && "$ZNC" fill.zag --target vulkan-compat -o fill-a.spv >/dev/null 2>&1) && \
   (cd "$tmp" && "$ZNC" fill.zag --target vulkan-compat -o fill-b.spv >/dev/null 2>&1) && \
   cmp -s "$tmp/fill-a.spv" "$tmp/fill-b.spv"; then
    ok "vulkan-compat SPIR-V emission is deterministic"
else
    xx "vulkan-compat SPIR-V emission is not deterministic"
fi

# ── 4. Reject unsupported kernel forms ─────────────────────────────────────
cat >"$tmp/bad.zag" <<'ZAG'
fn unsafeKernel(out: *i32, value: i32) void @kernel {
    while (value > 0) { out[0] = value; }
}
fn main() void { print_i32(0); }
ZAG
rm -f "$tmp/bad.spv"
if ! (cd "$tmp" && "$ZNC" bad.zag --target vulkan-compat -o bad.spv >/dev/null 2>&1) && \
   [ ! -e "$tmp/bad.spv" ]; then
    ok "vulkan-compat rejects unsafe pointers, loops, and unsupported kernel forms"
else
    xx "vulkan-compat accepted an unsupported kernel"
fi

# ── 5. Reject host effects in @kernel ──────────────────────────────────────
cat >"$tmp/io_kernel.zag" <<'ZAG'
fn badKernel(out: []i32, value: i32, count: i32) void @kernel {
    print_i32(value);
}
fn main() void { print_i32(0); }
ZAG
rm -f "$tmp/io_kernel.spv"
if ! (cd "$tmp" && "$ZNC" io_kernel.zag --target vulkan-compat -o io.spv >/dev/null 2>&1) && \
   [ ! -e "$tmp/io.spv" ]; then
    ok "vulkan-compat rejects host I/O in @kernel"
else
    xx "vulkan-compat accepted host I/O in @kernel"
fi

# ── 6. Default output extension is .spv ─────────────────────────────────────
rm -f "$tmp/fill.spv"
if (cd "$tmp" && "$ZNC" fill.zag --target vulkan-compat >/dev/null 2>&1) && \
   [ -f "$tmp/fill.spv" ]; then
    ok "vulkan-compat default output extension is .spv"
else
    xx "vulkan-compat default output extension is wrong"
fi

# ── 7. --target=vulkan-compat syntax works ─────────────────────────────────
rm -f "$tmp/fill.spv"
if (cd "$tmp" && "$ZNC" fill.zag --target=vulkan-compat -o fill2.spv >/dev/null 2>&1) && \
   [ -f "$tmp/fill2.spv" ]; then
    ok "vulkan-compat accepts --target=vulkan-compat syntax"
else
    xx "vulkan-compat --target=vulkan-compat syntax failed"
fi

# ── 8. spirv-val validation (if available) ──────────────────────────────────
if command -v spirv-val >/dev/null 2>&1 && [ -f "$tmp/fill2.spv" ]; then
    if spirv-val --target-env vulkan1.0 "$tmp/fill2.spv" >/dev/null 2>&1; then
        ok "SPIR-V binary passes spirv-val --target-env vulkan1.0"
    else
        xx "SPIR-V binary fails spirv-val validation"
        spirv-val --target-env vulkan1.0 "$tmp/fill2.spv" 2>&1 | head -5 || true
    fi
else
    ok "spirv-val not installed — skipping external validation (skipped)"
fi

# ── 9. OpenCL produces different SPIR-V (separate encoders) ─────────────────
if (cd "$tmp" && "$ZNC" fill.zag --target opencl-compat -o fill-cl.spv >/dev/null 2>&1) && \
   [ -f "$tmp/fill-cl.spv" ]; then
    if ! cmp -s "$tmp/fill2.spv" "$tmp/fill-cl.spv"; then
        ok "opencl-compat produces different SPIR-V from vulkan-compat (separate encoders)"
    else
        xx "opencl-compat SPIR-V is identical to vulkan-compat (should differ — Kernel vs Shader)"
    fi
else
    xx "failed to emit opencl-compat SPIR-V for comparison"
fi

echo "════ compat-vulkan pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
