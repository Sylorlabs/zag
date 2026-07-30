#!/usr/bin/env bash
# OpenGL compatibility-tier tests: GLSL 430 compute shader emission for the fill kernel.
# This is a non-certified fallback backend; tests verify GLSL source structure
# only, not runtime execution (which requires an OpenGL 4.3+ context).
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-compat-opengl.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# ── 1. GLSL source emission for the fill kernel ─────────────────────────────
cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG

if (cd "$tmp" && "$ZNC" fill.zag --target opengl-compat -o fill.glsl >/dev/null 2>&1) && \
   [ -f "$tmp/fill.glsl" ]; then
    ok "opengl-compat emits GLSL source for the fill kernel"
else
    xx "opengl-compat failed to emit GLSL source"
fi

# ── 2. GLSL content validation ──────────────────────────────────────────────
if [ -f "$tmp/fill.glsl" ]; then
    if grep -q '#version 430' "$tmp/fill.glsl"; then
        ok "GLSL uses version 430"
    else
        xx "GLSL missing version 430 directive"
    fi
    if grep -q 'local_size_x' "$tmp/fill.glsl"; then
        ok "GLSL declares local_size_x"
    else
        xx "GLSL missing local_size_x"
    fi
    if grep -q 'gl_GlobalInvocationID' "$tmp/fill.glsl"; then
        ok "GLSL uses gl_GlobalInvocationID for thread index"
    else
        xx "GLSL missing gl_GlobalInvocationID"
    fi
    if grep -q 'buffer OutputBuffer' "$tmp/fill.glsl"; then
        ok "GLSL declares SSBO for output buffer"
    else
        xx "GLSL missing SSBO declaration"
    fi
    if grep -q 'uniform int value' "$tmp/fill.glsl"; then
        ok "GLSL declares uniform for value"
    else
        xx "GLSL missing uniform value"
    fi
fi

# ── 3. Deterministic emission ───────────────────────────────────────────────
if (cd "$tmp" && "$ZNC" fill.zag --target opengl-compat -o fill-a.glsl >/dev/null 2>&1) && \
   (cd "$tmp" && "$ZNC" fill.zag --target opengl-compat -o fill-b.glsl >/dev/null 2>&1) && \
   cmp -s "$tmp/fill-a.glsl" "$tmp/fill-b.glsl"; then
    ok "opengl-compat GLSL emission is deterministic"
else
    xx "opengl-compat GLSL emission is not deterministic"
fi

# ── 4. Reject unsupported kernel forms ─────────────────────────────────────
cat >"$tmp/bad.zag" <<'ZAG'
fn unsafeKernel(out: *i32, value: i32) void @kernel {
    while (value > 0) { out[0] = value; }
}
fn main() void { print_i32(0); }
ZAG
rm -f "$tmp/bad.glsl"
if ! (cd "$tmp" && "$ZNC" bad.zag --target opengl-compat -o bad.glsl >/dev/null 2>&1) && \
   [ ! -e "$tmp/bad.glsl" ]; then
    ok "opengl-compat rejects unsafe pointers, loops, and unsupported kernel forms"
else
    xx "opengl-compat accepted an unsupported kernel"
fi

# ── 5. Default output extension is .glsl ────────────────────────────────────
rm -f "$tmp/fill.glsl"
if (cd "$tmp" && "$ZNC" fill.zag --target opengl-compat >/dev/null 2>&1) && \
   [ -f "$tmp/fill.glsl" ]; then
    ok "opengl-compat default output extension is .glsl"
else
    xx "opengl-compat default output extension is wrong"
fi

echo "════ compat-opengl pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
