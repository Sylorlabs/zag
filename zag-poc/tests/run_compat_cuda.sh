#!/usr/bin/env bash
# CUDA compatibility-tier tests: PTX ISA emission for the fill kernel.
# This is a non-certified fallback backend; tests verify PTX source structure
# only, not runtime execution (which requires libcuda.so.1 and an NVIDIA GPU).
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-compat-cuda.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# ── 1. PTX source emission for the fill kernel ──────────────────────────────
cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG

if (cd "$tmp" && "$ZNC" fill.zag --target cuda-compat -o fill.ptx >/dev/null 2>&1) && \
   [ -f "$tmp/fill.ptx" ]; then
    ok "cuda-compat emits PTX source for the fill kernel"
else
    xx "cuda-compat failed to emit PTX source"
fi

# ── 2. PTX content validation ───────────────────────────────────────────────
if [ -f "$tmp/fill.ptx" ]; then
    if grep -q '\.version 6\.5' "$tmp/fill.ptx"; then
        ok "PTX declares version 6.5 (broad driver compatibility)"
    else
        xx "PTX missing or wrong version directive"
    fi
    if grep -q '\.target sm_' "$tmp/fill.ptx"; then
        ok "PTX declares target SM architecture"
    else
        xx "PTX missing target directive"
    fi
    if grep -q '\.visible .entry fillKernel' "$tmp/fill.ptx"; then
        ok "PTX declares visible entry fillKernel"
    else
        xx "PTX missing entry declaration"
    fi
    if grep -q '%ctaid\.x' "$tmp/fill.ptx"; then
        ok "PTX uses %ctaid.x for block index"
    else
        xx "PTX missing %ctaid.x"
    fi
    if grep -q '%tid\.x' "$tmp/fill.ptx"; then
        ok "PTX uses %tid.x for thread index"
    else
        xx "PTX missing %tid.x"
    fi
    if grep -q 'setp\.lt\.s32' "$tmp/fill.ptx"; then
        ok "PTX uses setp.lt.s32 for bounds check"
    else
        xx "PTX missing bounds check predicate"
    fi
    if grep -q 'st\.global\.s32' "$tmp/fill.ptx"; then
        ok "PTX uses st.global.s32 for store"
    else
        xx "PTX missing global store"
    fi
fi

# ── 3. Deterministic emission ───────────────────────────────────────────────
if (cd "$tmp" && "$ZNC" fill.zag --target cuda-compat -o fill-a.ptx >/dev/null 2>&1) && \
   (cd "$tmp" && "$ZNC" fill.zag --target cuda-compat -o fill-b.ptx >/dev/null 2>&1) && \
   cmp -s "$tmp/fill-a.ptx" "$tmp/fill-b.ptx"; then
    ok "cuda-compat PTX emission is deterministic"
else
    xx "cuda-compat PTX emission is not deterministic"
fi

# ── 4. Reject unsupported kernel forms ─────────────────────────────────────
cat >"$tmp/bad.zag" <<'ZAG'
fn unsafeKernel(out: *i32, value: i32) void @kernel {
    while (value > 0) { out[0] = value; }
}
fn main() void { print_i32(0); }
ZAG
rm -f "$tmp/bad.ptx"
if ! (cd "$tmp" && "$ZNC" bad.zag --target cuda-compat -o bad.ptx >/dev/null 2>&1) && \
   [ ! -e "$tmp/bad.ptx" ]; then
    ok "cuda-compat rejects unsafe pointers, loops, and unsupported kernel forms"
else
    xx "cuda-compat accepted an unsupported kernel"
fi

# ── 5. Default output extension is .ptx ─────────────────────────────────────
rm -f "$tmp/fill.ptx"
if (cd "$tmp" && "$ZNC" fill.zag --target cuda-compat >/dev/null 2>&1) && \
   [ -f "$tmp/fill.ptx" ]; then
    ok "cuda-compat default output extension is .ptx"
else
    xx "cuda-compat default output extension is wrong"
fi

echo "════ compat-cuda pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
