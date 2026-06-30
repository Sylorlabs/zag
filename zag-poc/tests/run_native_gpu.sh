#!/usr/bin/env bash
# znc GPU/MLIR backend suite — ports gpu_check patterns from run_selfhost.sh.
set -eu
cd "$(dirname "$0")/.."
pass=0; fail=0

if [ ! -x ./znc ]; then
    echo "  XX  ./znc missing — run ./bootstrap.sh first"
    echo "════ native-gpu pass=0 fail=1 ════"; exit 1
fi
ZNC=./znc

mkdir -p /tmp/zag_gpu
cp examples/gpu_matmul_mx.zag /tmp/zag_gpu/gpu_matmul_mx.zag
cp examples/gpu_vsa_hd.zag    /tmp/zag_gpu/gpu_vsa_hd.zag
cp -f "$ZNC" /tmp/zag_gpu/znc
chmod +x /tmp/zag_gpu/znc
NOSTUB='unsupported|unimplemented|stub|TODO|unhandled|= //|// closure|// unknown|<kernel>'

gpu_check(){ local stem="$1"; shift
    ( cd /tmp/zag_gpu && ./znc "$stem.zag" --target gpu-nvidia >/dev/null 2>&1 )
    local mf="/tmp/zag_gpu/$stem.mlir"; local ok=1
    [ -f "$mf" ] || ok=0
    for pat in "$@"; do grep -q "$pat" "$mf" 2>/dev/null || { ok=0; echo "      missing: $pat"; }; done
    if grep -qE "$NOSTUB" "$mf" 2>/dev/null; then ok=0; echo "      found stub marker(s):"; grep -nE "$NOSTUB" "$mf" | head; fi
    local o c; o=$(tr -cd '{' <"$mf" | wc -c); c=$(tr -cd '}' <"$mf" | wc -c)
    [ "$o" = "$c" ] || { ok=0; echo "      unbalanced braces ($o vs $c)"; }
    echo "$ok"
}

echo "── znc GPU/MLIR backend (selfhost/mlir.zag) ──"
r1=$(gpu_check gpu_matmul_mx 'gpu.module @zag_kernels' 'gpu.func @matmulMxKernel' ' kernel {' 'f8E4M3FN' 'gpu.thread_id' 'gpu.block_id' 'func.func @tileSize' 'gpu.return' 'gpu.launch_func @zag_kernels::@matmulMxKernel')
if [ "$(echo "$r1" | tail -1)" = "1" ]; then
    echo "  ok  gpu mlir matmul (kernels/dialects, real launch_func, no stubs)"; pass=$((pass+1))
else
    echo "  XX  gpu mlir matmul"; echo "$r1"; fail=$((fail+1))
fi

r2=$(gpu_check gpu_vsa_hd 'gpu.module @zag_kernels' 'gpu.func @vsaBindKernel' ' kernel {' 'gpu.barrier' 'gpu.thread_id' 'arith.xori' 'arith.andi' 'func.func private @zag_l32_to_f32' 'gpu.launch_func @zag_kernels::')
if [ "$(echo "$r2" | tail -1)" = "1" ]; then
    echo "  ok  gpu mlir vsa (bind XOR/popcount AND, l32 decls, barrier, no stubs)"; pass=$((pass+1))
else
    echo "  XX  gpu mlir vsa"; echo "$r2"; fail=$((fail+1))
fi

( cd /tmp/zag_gpu && ./znc gpu_matmul_mx.zag --target gpu-amd >/dev/null 2>&1 )
if grep -q 'AMD ROCDL/HIP' /tmp/zag_gpu/gpu_matmul_mx.mlir 2>/dev/null && \
   ( cd /tmp/zag_gpu && ./znc gpu_matmul_mx.zag --target gpu-vulkan >/dev/null 2>&1 ) && \
   grep -q 'Vulkan SPIR-V' /tmp/zag_gpu/gpu_matmul_mx.mlir 2>/dev/null; then
    echo "  ok  gpu mlir target header (amd → ROCDL, vulkan → SPIR-V)"; pass=$((pass+1))
else
    echo "  XX  gpu mlir target header"; fail=$((fail+1))
fi

echo "════ native-gpu pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]