#!/usr/bin/env bash
# Metal compatibility-tier tests: MSL text emission for the fill kernel.
# This is a non-certified fallback backend; tests verify MSL source structure
# only, not runtime execution (which requires Metal.framework on macOS).
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-compat-metal.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# ── 1. MSL source emission for the fill kernel ──────────────────────────────
cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG

if (cd "$tmp" && "$ZNC" fill.zag --target metal-compat -o fill.metal >/dev/null 2>&1) && \
   [ -f "$tmp/fill.metal" ]; then
    ok "metal-compat emits MSL source for the fill kernel"
else
    xx "metal-compat failed to emit MSL source"
fi

# ── 2. MSL content validation ───────────────────────────────────────────────
if [ -f "$tmp/fill.metal" ]; then
    if grep -q '#include <metal_stdlib>' "$tmp/fill.metal"; then
        ok "MSL includes metal_stdlib header"
    else
        xx "MSL missing metal_stdlib header"
    fi
    if grep -q 'kernel void fillKernel' "$tmp/fill.metal"; then
        ok "MSL declares fillKernel as a kernel function"
    else
        xx "MSL missing kernel function declaration"
    fi
    if grep -q 'device int\* out' "$tmp/fill.metal"; then
        ok "MSL uses device address space for output buffer"
    else
        xx "MSL missing device address space for output"
    fi
    if grep -q 'thread_position_in_grid' "$tmp/fill.metal"; then
        ok "MSL uses thread_position_in_grid for thread index"
    else
        xx "MSL missing thread_position_in_grid"
    fi
    if grep -q 'if (gid < count)' "$tmp/fill.metal"; then
        ok "MSL has bounded bounds check"
    else
        xx "MSL missing bounds check"
    fi
fi

# ── 3. Deterministic emission ───────────────────────────────────────────────
if (cd "$tmp" && "$ZNC" fill.zag --target metal-compat -o fill-a.metal >/dev/null 2>&1) && \
   (cd "$tmp" && "$ZNC" fill.zag --target metal-compat -o fill-b.metal >/dev/null 2>&1) && \
   cmp -s "$tmp/fill-a.metal" "$tmp/fill-b.metal"; then
    ok "metal-compat MSL emission is deterministic"
else
    xx "metal-compat MSL emission is not deterministic"
fi

# ── 4. Reject unsupported kernel forms ─────────────────────────────────────
cat >"$tmp/bad.zag" <<'ZAG'
fn unsafeKernel(out: *i32, value: i32) void @kernel {
    while (value > 0) { out[0] = value; }
}
fn main() void { print_i32(0); }
ZAG
rm -f "$tmp/bad.metal"
if ! (cd "$tmp" && "$ZNC" bad.zag --target metal-compat -o bad.metal >/dev/null 2>&1) && \
   [ ! -e "$tmp/bad.metal" ]; then
    ok "metal-compat rejects unsafe pointers, loops, and unsupported kernel forms"
else
    xx "metal-compat accepted an unsupported kernel"
fi

# ── 5. Default output extension is .metal ───────────────────────────────────
rm -f "$tmp/fill.metal"
if (cd "$tmp" && "$ZNC" fill.zag --target metal-compat >/dev/null 2>&1) && \
   [ -f "$tmp/fill.metal" ]; then
    ok "metal-compat default output extension is .metal"
else
    xx "metal-compat default output extension is wrong"
fi

echo "════ compat-metal pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
