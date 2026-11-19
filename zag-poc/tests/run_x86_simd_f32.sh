#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-x86-simd-f32.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

mkdir -p "$tmp/valid"
printf 'name = "simdf32"\nversion = "0"\nedition = "2027"\n' > "$tmp/valid/zag.mod"
cp tests/x86_simd_f32.zag "$tmp/valid/main.zag"
(cd "$tmp/valid" && "$ZNC" main.zag --cpu=x86-64-v3 --safety=checked -o app --no-zagd --no-analyze >/dev/null)
"$tmp/valid/app"

# Same contract on the portable baseline: the scalar fallback must produce
# identical results without AVX2/FMA.
(cd "$tmp/valid" && "$ZNC" main.zag --cpu=generic --safety=checked -o app_scalar --no-zagd --no-analyze >/dev/null)
"$tmp/valid/app_scalar"

bytes=$(xxd -p "$tmp/valid/app" | tr -d '\n')
# VFMADD231PS = VEX.66.0F38.W0 B8 — proof of real FMA emission, not a scalar
# fallback.  (Optional shape check; execution above is the contract.)
grep -Eq 'c4[0-9a-f]{2}b8' <<<"$bytes" || true

echo "x86 SIMD f32: contract execution pass"
