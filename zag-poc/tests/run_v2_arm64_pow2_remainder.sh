#!/usr/bin/env bash
# Differential proof at the executable boundary for ARM64 unsigned remainder
# strength reduction. Both compilers must agree with the independent oracle.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
  echo 'v2 arm64 pow2 remainder: SKIP (requires macOS ARM64)'
  exit 0
fi
ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
POW2_BASELINE=${POW2_BASELINE:-}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
case "$POW2_BASELINE" in ''|/*) ;; *) POW2_BASELINE="$PWD/${POW2_BASELINE#./}" ;; esac
if [ ! -x "$ZNC" ]; then echo "missing compiler $ZNC" >&2; exit 2; fi
if [ -n "$POW2_BASELINE" ] && [ ! -x "$POW2_BASELINE" ]; then
  echo "missing baseline compiler $POW2_BASELINE" >&2; exit 2
fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-pow2-rem.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
distinct=0
run_case() {
  local name=$1 expected=$2 source=$3
  mkdir -p "$tmp/$name"
  printf 'name = "pow2rem"\nversion = "0"\nedition = "2027"\n' > "$tmp/$name/zag.mod"
  printf '%s\n' "$source" > "$tmp/$name/main.zag"
  if ! (cd "$tmp/$name" && "$ZNC" main.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o optimized >opt.log 2>&1); then
    echo "XX $name: optimized compilation failed" >&2
    sed -n '1,25p' "$tmp/$name/opt.log" >&2
    exit 1
  fi
  local actual
  set +e
  "$tmp/$name/optimized" >"$tmp/$name/out" 2>"$tmp/$name/err"
  actual=$?
  set -e
  if [ "$actual" -ne "$expected" ] || [ -s "$tmp/$name/out" ] || [ -s "$tmp/$name/err" ]; then
    echo "XX $name: expected clean exit $expected; got $actual" >&2
    cat "$tmp/$name/err" >&2
    exit 1
  fi
  if [ -n "$POW2_BASELINE" ]; then
    if ! (cd "$tmp/$name" && "$POW2_BASELINE" main.zag --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache -o baseline >base.log 2>&1); then
      echo "XX $name: baseline compilation failed" >&2
      sed -n '1,25p' "$tmp/$name/base.log" >&2
      exit 1
    fi
    set +e
    "$tmp/$name/baseline" >"$tmp/$name/base-out" 2>"$tmp/$name/base-err"
    local base_status=$?
    set -e
    if [ "$base_status" -ne "$actual" ] || ! cmp -s "$tmp/$name/out" "$tmp/$name/base-out" || ! cmp -s "$tmp/$name/err" "$tmp/$name/base-err"; then
      echo "XX $name: baseline/optimized observable difference" >&2
      exit 1
    fi
    if ! cmp -s "$tmp/$name/optimized" "$tmp/$name/baseline"; then
      distinct=$((distinct + 1))
    fi
  fi
  pass=$((pass + 1))
  echo "  ok $name"
}

# Known power-of-two divisors, including high-bit u64 inputs and both small
# and large masks. A divisor of one must always produce zero.
run_case one 42 'fn rem(x:u64) u64 { return x % 1; } fn main() i32 { if (rem(18446744073709551615)==0) { return 42; } return 9; }'
run_case two 42 'fn rem(x:u64) u64 { return x % 2; } fn main() i32 { if (rem(18446744073709551615)==1) { return 42; } return 9; }'
run_case eight 42 'fn rem(x:u64) u64 { return x % 8; } fn main() i32 { if (rem(9223372036854775808)==0 && rem(18446744073709551615)==7) { return 42; } return 9; }'
run_case u32 42 'fn rem(x:u32) u32 { return x % 256; } fn main() i32 { if (rem(4294967295)==255) { return 42; } return 9; }'
run_case u8 42 'fn rem(x:u8) u8 { return x % 4; } fn main() i32 { if (rem(255)==3) { return 42; } return 9; }'
run_case million 42 'fn rem(x:u64) u64 { return x % 1048576; } fn main() i32 { if (rem(18446744073709551615)==1048575) { return 42; } return 9; }'
run_case large_literal 42 'fn rem(x:u64) u64 { return x % 288230376151711744; } fn main() i32 { if (rem(18446744073709551615)==288230376151711743) { return 42; } return 9; }'
# Negative signed remainder, dynamic divisors, and non-pow2/hex literal paths
# must retain the established lowering.
run_case signed_negative 42 'fn rem(x:i64) i64 { return x % 8; } fn main() i32 { if (rem(-9)==-1) { return 42; } return 9; }'
run_case dynamic 42 'fn rem(x:u64,y:u64) u64 { return x % y; } fn main() i32 { if (rem(18446744073709551615,8)==7) { return 42; } return 9; }'
run_case nonpow2 42 'fn rem(x:u64) u64 { return x % 10; } fn main() i32 { if (rem(18446744073709551615)==5) { return 42; } return 9; }'
run_case hex_literal 42 'fn rem(x:u64) u64 { return x % 0x100; } fn main() i32 { if (rem(18446744073709551615)==255) { return 42; } return 9; }'

if [ -n "$POW2_BASELINE" ] && [ "$distinct" -lt 1 ]; then
  echo 'XX optimizer produced no changed executable images against baseline' >&2
  exit 1
fi
echo "v2 arm64 pow2 remainder pass=$pass fail=0 changed_images=$distinct"
