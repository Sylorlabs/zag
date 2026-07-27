#!/usr/bin/env bash
# Kernel effects are a semantic boundary: GPU source may be emitted, but no
# implemented host effect may cross into an @kernel declaration.
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-v2-kernel-effects.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

project() {
    mkdir -p "$tmp/$1"
    printf 'name = "%s"\nversion = "0"\nedition = "2027"\n' "$1" > "$tmp/$1/zag.mod"
}

expect_reject() {
    local name=$1
    local source=$2
    project "$name"
    printf '%s\n' "$source" > "$tmp/$name/main.zag"
    if (cd "$tmp/$name" && "$ZNC" check main.zag --no-zagd --no-analyze) >"$tmp/$name/log" 2>&1; then
        echo "  XX  @kernel accepted $name effect"
        fail=$((fail + 1))
    elif grep -q 'E0002' "$tmp/$name/log"; then
        echo "  ok  @kernel rejects $name effect"
        pass=$((pass + 1))
    else
        echo "  XX  @kernel $name rejection lacked E0002"
        sed -n '1,12p' "$tmp/$name/log"
        fail=$((fail + 1))
    fi
}

project pure_kernel
printf 'fn fill(out: []i32) void @kernel { let i:i32=@gpuThreadIdx(0); if(i<1){out[i]=7;} } fn main() void {}\n' > "$tmp/pure_kernel/main.zag"
if (cd "$tmp/pure_kernel" && "$ZNC" main.zag --target gpu-amd --no-zagd --no-analyze) >"$tmp/pure_kernel/log" 2>&1 &&
   grep -q 'gpu.func @fill' "$tmp/pure_kernel/main.mlir"; then
    echo "  ok  effect-free @kernel emits GPU frontend output"
    pass=$((pass + 1))
else
    echo "  XX  effect-free @kernel frontend emission"
    sed -n '1,12p' "$tmp/pure_kernel/log"
    fail=$((fail + 1))
fi

expect_reject io 'fn bad() void @kernel { print_i32(1); } fn main() void {}'
expect_reject atomic 'fn bad() void @kernel { unsafe { let x:i64=0; @atomicStore64((&x) as *mut i64,1); } } fn main() void {}'
expect_reject cabi 'extern fn getpid() i64 @cabi; fn bad() void @kernel { unsafe { let x:i64=getpid(); } } fn main() void {}'

echo "──── v2 kernel effects: pass=$pass fail=$fail ────"
[ "$fail" -eq 0 ]
