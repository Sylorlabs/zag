#!/usr/bin/env bash
# Release gate for the supported Zag v1 compiler path.
# Proves that a native self-rebuild and a user build succeed even when common
# C toolchain entry points are poisoned, then checks the outputs are static ELF.
set -eu
cd "$(dirname "$0")/.."

pass=0
fail=0
tmp="${TMPDIR:-/tmp}/zag-native-authority.$$"
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/bin"

for tool in cc gcc clang as ld; do
    printf '#!/bin/sh\necho "forbidden host tool invoked: %s" >&2\nexit 97\n' "$tool" > "$tmp/bin/$tool"
    chmod +x "$tmp/bin/$tool"
done

check_static_elf() {
    artifact=$1
    label=$2
    if file "$artifact" | grep -q 'ELF 64-bit.*statically linked' && \
       ! readelf -l "$artifact" 2>/dev/null | grep -q 'INTERP' && \
       ! readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'; then
        echo "  ok  $label is static ELF with no interpreter or shared libraries"
        pass=$((pass + 1))
    else
        echo "  XX  $label is not a self-contained static ELF"
        fail=$((fail + 1))
    fi
}

echo "── native authority: poison cc/gcc/clang/as/ld ──"
if PATH="$tmp/bin:$PATH" ./znc selfhost/native/znc.zag -o "$tmp/znc-stage2" >"$tmp/rebuild.log" 2>&1; then
    echo "  ok  native seed rebuilt znc without a host C toolchain"
    pass=$((pass + 1))
    check_static_elf "$tmp/znc-stage2" "stage-2 compiler"
else
    echo "  XX  native self-rebuild failed"
    sed -n '1,20p' "$tmp/rebuild.log"
    fail=$((fail + 1))
fi

if command -v strace >/dev/null 2>&1; then
    if PATH="$tmp/bin:$PATH" strace -f -e trace=execve -o "$tmp/exec.log" \
       ./znc selfhost/native/znc.zag -o "$tmp/znc-traced" >"$tmp/traced.log" 2>&1 && \
       [ "$(grep -c 'execve(' "$tmp/exec.log")" -eq 1 ]; then
        echo "  ok  syscall trace shows no child tool execution"
        pass=$((pass + 1))
    elif grep -q 'Operation not permitted' "$tmp/traced.log"; then
        echo "  --  ptrace blocked; PATH poisoning remains enforced"
    else
        echo "  XX  native compiler executed a child process"
        cat "$tmp/exec.log" 2>/dev/null || true
        fail=$((fail + 1))
    fi
else
    echo "  --  strace unavailable; PATH poisoning remains enforced"
fi

printf 'fn main() i32 { print_int(42); return 0; }\n' > "$tmp/smoke.zag"
if PATH="$tmp/bin:$PATH" "$tmp/znc-stage2" "$tmp/smoke.zag" -o "$tmp/smoke" >"$tmp/smoke.log" 2>&1 && \
   [ "$("$tmp/smoke")" = 42 ]; then
    echo "  ok  stage-2 compiler built and ran a Zag program"
    pass=$((pass + 1))
    check_static_elf "$tmp/smoke" "user program"
else
    echo "  XX  stage-2 compiler could not build/run the smoke program"
    sed -n '1,20p' "$tmp/smoke.log"
    fail=$((fail + 1))
fi

if ! rg -n '^[[:space:]]*(cc|gcc|clang|as|ld)[[:space:]]|\./zagc([[:space:]]|$)' \
    bootstrap.sh tests/run_native.sh >"$tmp/refs"; then
    echo "  ok  supported bootstrap and native suite contain no host or legacy compiler invocation"
    pass=$((pass + 1))
else
    echo "  XX  supported workflow names a host compiler command"
    cat "$tmp/refs"
    fail=$((fail + 1))
fi

echo "════ native-authority pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
