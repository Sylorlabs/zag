#!/usr/bin/env bash
# Edition 2027 rejects directly known integer /0 and %0 at compilation.
# Runtime zero divisors still panic in release and checked modes on both
# backends; edition 2026 preserves its established runtime-only diagnostics.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-}
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) target=macos-arm64; ZNC=${ZNC:-"$PWD/znc-macos-arm64"} ;;
  Linux:x86_64|Linux:amd64) target=x86-64; ZNC=${ZNC:-"$PWD/znc"} ;;
  *) echo 'v2 division-zero: unsupported native host' >&2; exit 2 ;;
esac
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then echo "v2 division-zero: missing compiler: $ZNC" >&2; exit 2; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-v2-div0.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
case_run() {
  local name=$1 edition=$2 mode=$3 expected=$4 source=$5
  mkdir -p "$tmp/$name"
  printf 'name = "v2div0"\nversion = "0"\nedition = "%s"\n' "$edition" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  local -a args=()
  if [ "$target" = macos-arm64 ]; then args+=(--target macos-arm64); fi
  if [ "$mode" = checked ]; then args+=(--safety=checked); fi
  if ! (cd "$tmp/$name" && "$ZNC" main.zag "${args[@]}" --no-zagd --no-analyze --no-foreground-cache -o out >build.log 2>&1); then
    if [ "$expected" = reject ] &&
      grep -Fq 'v2: integer division by zero' "$tmp/$name/build.log" &&
      [ ! -e "$tmp/$name/out" ]; then
      pass=$((pass + 1)); echo "  ok  $name"; return
    fi
    echo "XX $name unexpected compilation failure" >&2
    sed -n '1,15p' "$tmp/$name/build.log" >&2
    exit 1
  fi
  if [ "$expected" = reject ]; then echo "XX $name accepted zero literal" >&2; exit 1; fi
  if [ ! -x "$tmp/$name/out" ]; then echo "XX $name produced no executable" >&2; exit 1; fi
  local actual
  set +e
  "$tmp/$name/out" >"$tmp/$name/stdout" 2>"$tmp/$name/stderr"
  actual=$?
  set -e
  if [ "$expected" = trap ]; then
    if [ "$actual" -ne 134 ] ||
      ! grep -Fq 'panic: division by zero' "$tmp/$name/stderr"; then
      echo "XX $name expected division panic status 134, got $actual" >&2
      sed -n '1,12p' "$tmp/$name/stderr" >&2
      exit 1
    fi
  elif [ "$actual" -ne "$expected" ]; then
    echo "XX $name expected exit $expected, got $actual" >&2
    sed -n '1,12p' "$tmp/$name/stderr" >&2
    exit 1
  fi
  pass=$((pass + 1)); echo "  ok  $name"
}
# Large nonzero literals may currently wrap during integer lowering; future
# range diagnostics can reject them. Neither outcome may call their *spelling*
# a zero divisor (the old cg_parse_i64 predicate did so after overflow).
case_nonzero_literal() {
  local name=$1 mode=$2 source=$3
  mkdir -p "$tmp/$name"
  printf 'name = "v2div0"\nversion = "0"\nedition = "2027"\n' >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  local -a args=()
  if [ "$target" = macos-arm64 ]; then args+=(--target macos-arm64); fi
  if [ "$mode" = checked ]; then args+=(--safety=checked); fi
  (cd "$tmp/$name" && "$ZNC" main.zag "${args[@]}" --no-zagd --no-analyze --no-foreground-cache -o out >build.log 2>&1) || true
  if grep -Fq 'v2: integer division by zero' "$tmp/$name/build.log"; then
    echo "XX $name misdiagnosed nonzero literal" >&2
    exit 1
  fi
  pass=$((pass + 1)); echo "  ok  $name"
}
for mode in release checked; do
  case_run "$mode-i64-div-positive" 2027 "$mode" 42 'fn div(x:i64,y:i64) i64 { return x/y; } fn main() i32 { return div(126,3) as i32; }'
  case_run "$mode-i64-mod-positive" 2027 "$mode" 42 'fn rem(x:i64,y:i64) i64 { return x%y; } fn main() i32 { return rem(142,100) as i32; }'
  case_run "$mode-u64-div-positive" 2027 "$mode" 42 'fn div(x:u64,y:u64) u64 { return x/y; } fn main() i32 { return div(126,3) as i32; }'
  case_run "$mode-u64-mod-positive" 2027 "$mode" 42 'fn rem(x:u64,y:u64) u64 { return x%y; } fn main() i32 { return rem(142,100) as i32; }'
  # Values with bit 63 set must use unsigned division/remainder, even though
  # the native register representation would be negative as a signed i64.
  case_run "$mode-u64-high-bit-div-two" 2027 "$mode" 42 'fn div(x:u64,y:u64) u64 { return x/y; } fn main() i32 { if (div(9223372036854775808,2)==4611686018427387904) { return 42; } return 9; }'
  case_run "$mode-u64-max-div-two" 2027 "$mode" 42 'fn div(x:u64,y:u64) u64 { return x/y; } fn main() i32 { if (div(18446744073709551615,2)==9223372036854775807) { return 42; } return 9; }'
  case_run "$mode-u64-high-bit-mod-three" 2027 "$mode" 42 'fn rem(x:u64,y:u64) u64 { return x%y; } fn main() i32 { if (rem(9223372036854775808,3)==2) { return 42; } return 9; }'
  case_run "$mode-u64-max-mod-ten" 2027 "$mode" 42 'fn rem(x:u64,y:u64) u64 { return x%y; } fn main() i32 { if (rem(18446744073709551615,10)==5) { return 42; } return 9; }'
  case_run "$mode-direct-div-zero" 2027 "$mode" reject 'fn main() i32 { return 42 / 0; }'
  case_run "$mode-direct-mod-zero" 2027 "$mode" reject 'fn main() i32 { return 42 % 0; }'
  case_run "$mode-direct-negative-zero" 2027 "$mode" reject 'fn main() i32 { return 42 / -0; }'
  case_run "$mode-direct-hex-zero" 2027 "$mode" reject 'fn main() i32 { return 42 % 0x0000; }'
  case_run "$mode-direct-separated-zero" 2027 "$mode" reject 'fn main() i32 { return 42 / 0_0_0; }'
  case_nonzero_literal "$mode-large-decimal-nonzero" "$mode" 'fn main() i32 { return 42 / 18446744073709551616; }'
  case_nonzero_literal "$mode-large-hex-nonzero" "$mode" 'fn main() i32 { return 42 % 0x10000000000000000; }'
  case_run "$mode-direct-unsigned-zero" 2027 "$mode" reject 'fn main() i32 { let x:u64=42; return (x % 0) as i32; }'
  case_run "$mode-dynamic-i64-div-zero" 2027 "$mode" trap 'fn div(x:i64,y:i64) i64 { return x/y; } fn main() i32 { return div(42,0) as i32; }'
  case_run "$mode-dynamic-i64-mod-zero" 2027 "$mode" trap 'fn rem(x:i64,y:i64) i64 { return x%y; } fn main() i32 { return rem(42,0) as i32; }'
  case_run "$mode-dynamic-u64-div-zero" 2027 "$mode" trap 'fn div(x:u64,y:u64) u64 { return x/y; } fn main() i32 { return div(42,0) as i32; }'
  case_run "$mode-dynamic-u64-mod-zero" 2027 "$mode" trap 'fn rem(x:u64,y:u64) u64 { return x%y; } fn main() i32 { return rem(42,0) as i32; }'
done
case_run 'v1-literal-div-zero' 2026 release trap 'fn main() i32 { return 42/0; }'
case_run 'v1-literal-mod-zero' 2026 release trap 'fn main() i32 { return 42%0; }'
case_run 'v1-positive-division' 2026 release 42 'fn main() i32 { return 126/3; }'
printf 'v2-division-zero pass=%d fail=0\n' "$pass"
