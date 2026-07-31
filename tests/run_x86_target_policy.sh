#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-x86-target.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

if "$ZNC" tests/x86/x86_profile_abi.zag --cpu generic -o "$tmp/generic" --no-analyze >/dev/null &&
   "$tmp/generic"; then ok "generic profile executes integer and floating ABI paths"; else bad "generic ABI execution"; fi

if "$ZNC" tests/x86/x86_profile_abi.zag --cpu native -o "$tmp/native" --no-analyze >/dev/null &&
   "$tmp/native"; then ok "native profile resolves and executes on this Linux host"; else bad "native profile execution"; fi

if cmp -s "$tmp/generic" "$tmp/native"; then
    ok "generic and native output match while permitted feature sets are both SSE2"
else
    bad "generic/native deterministic permission intersection"
fi

# ELF e_ident class=2 (ELF64), e_machine=62 (x86-64, little endian).
class=$(od -An -tu1 -j4 -N1 "$tmp/generic" | tr -d ' ')
machine=$(od -An -tu1 -j18 -N2 "$tmp/generic" | xargs)
if [ "$class" = 2 ] && [ "$machine" = "62 0" ]; then ok "native artifact is explicitly ELF64 x86-64"; else bad "ELF class/machine"; fi

if ! "$ZNC" tests/x86/x86_profile_abi.zag --cpu=unknown -o "$tmp/badcpu" --no-analyze >"$tmp/badcpu.log" 2>&1 &&
   grep -q "unknown x86 cpu profile" "$tmp/badcpu.log" && [ ! -e "$tmp/badcpu" ]; then
    ok "unknown CPU profile fails before artifact output"
else bad "unknown CPU profile rejection"; fi

if "$ZNC" tests/i686/i686_literal.zag --target i686 -o "$tmp/i686" --no-analyze >/dev/null &&
   [ "$(od -An -tu1 -j4 -N1 "$tmp/i686" | tr -d ' ')" = 1 ] &&
   [ "$(od -An -tu1 -j18 -N2 "$tmp/i686" | xargs)" = "3 0" ]; then
    ok "i686 selects a distinct ELF32 EM_386 artifact"
else bad "i686 ELF32 target selection"; fi

if "$ZNC" tests/x86/x86_profile_abi.zag --target linux-x86_64 -o "$tmp/explicit" --no-analyze >/dev/null &&
   "$tmp/explicit"; then ok "explicit Linux x86-64 target works"; else bad "explicit x86-64 target"; fi

echo "x86 target policy: pass=$pass fail=$fail"
test "$fail" -eq 0
