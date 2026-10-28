#!/usr/bin/env bash
# Edition 2027: invalid shift counts reject as literals or trap dynamically in
# both release and checked modes. Edition 2026 keeps native masked counts.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-}
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) target=macos-arm64; ZNC=${ZNC:-"$PWD/znc-macos-arm64"} ;;
  Linux:x86_64|Linux:amd64) target=x86-64; ZNC=${ZNC:-"$PWD/znc"} ;;
  *) echo 'v2 shift-count runtime test: unsupported host' >&2; exit 2 ;;
esac
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then echo "v2 shift-count: missing compiler: $ZNC" >&2; exit 2; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-v2-shift.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0

case_run() {
  local name=$1 edition=$2 mode=$3 expected=$4 source=$5
  mkdir -p "$tmp/$name"
  printf 'name = "shifts"\nversion = "0"\nedition = "%s"\n' "$edition" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  local -a args=()
  if [ "$target" = macos-arm64 ]; then args+=(--target macos-arm64); fi
  if [ "$mode" = checked ]; then args+=(--safety=checked); fi
  if ! (cd "$tmp/$name" && "$ZNC" main.zag "${args[@]}" --no-zagd --no-analyze --no-foreground-cache -o out >build.log 2>&1); then
    if [ "$expected" = reject ] &&
      grep -Fq 'integer shift count out of range' "$tmp/$name/build.log" &&
      [ ! -e "$tmp/$name/out" ]; then
      pass=$((pass + 1)); echo "  ok  $name"; return
    fi
    echo "XX $name compilation failed unexpectedly" >&2
    sed -n '1,15p' "$tmp/$name/build.log" >&2
    exit 1
  fi
  if [ "$expected" = reject ]; then echo "XX $name compiled an invalid literal" >&2; exit 1; fi
  if [ ! -x "$tmp/$name/out" ]; then echo "XX $name missing executable" >&2; exit 1; fi
  local actual
  set +e
  "$tmp/$name/out" >"$tmp/$name/stdout" 2>"$tmp/$name/stderr"
  actual=$?
  set -e
  if [ "$expected" = trap ]; then
    if [ "$actual" -ne 1 ] ||
      ! grep -Fxq 'zag safety: integer shift count out of range' "$tmp/$name/stderr"; then
      echo "XX $name expected shift trap (rc=1), got rc=$actual" >&2
      sed -n '1,15p' "$tmp/$name/stderr" >&2
      exit 1
    fi
  elif [ "$actual" -ne "$expected" ]; then
    echo "XX $name expected exit $expected, got $actual" >&2
    sed -n '1,15p' "$tmp/$name/stderr" >&2
    exit 1
  fi
  pass=$((pass + 1))
  echo "  ok  $name"
}

for mode in release checked; do
  # Valid boundaries: 0, width-1, and both signed and unsigned right shifts.
  case_run "$mode-u32-zero" 2027 "$mode" 42 'fn shift(x:u32,n:i32) u32 { return x << n; } fn main() i32 { if (shift(42,0)==42) { return 42; } return 9; }'
  case_run "$mode-u32-max" 2027 "$mode" 42 'fn shift(x:u32,n:i32) u32 { return x << n; } fn main() i32 { if (shift(1,31)==2147483648) { return 42; } return 9; }'
  case_run "$mode-i32-right" 2027 "$mode" 42 'fn shift(x:i32,n:i32) i32 { return x >> n; } fn main() i32 { if (shift(-64,5)==-2) { return 42; } return 9; }'
  case_run "$mode-u32-right" 2027 "$mode" 42 'fn shift(x:u32,n:i32) u32 { return x >> n; } fn main() i32 { if (shift(2147483648,31)==1) { return 42; } return 9; }'
  case_run "$mode-u64-max" 2027 "$mode" 42 'fn shift(x:u64,n:i32) u64 { return x << n; } fn main() i32 { if (shift(1,63) > 0) { return 42; } return 9; }'
  case_run "$mode-i64-right-max" 2027 "$mode" 42 'fn shift(x:i64,n:i64) i64 { return x >> n; } fn main() i32 { if (shift(-1,63)==-1) { return 42; } return 9; }'
  # Logical right shift must fill with zero for unsigned values whose high
  # bit is set; arithmetic right shift would produce a different result.
  case_run "$mode-u64-right-high-bit" 2027 "$mode" 42 'fn shift(x:u64,n:i64) u64 { return x >> n; } fn main() i32 { if (shift(9223372036854775808,63)==1) { return 42; } return 9; }'
  case_run "$mode-u64-right-top-two" 2027 "$mode" 42 'fn shift(x:u64,n:i64) u64 { return x >> n; } fn main() i32 { if (shift(13835058055282163712,62)==3) { return 42; } return 9; }'
  case_run "$mode-u16-max" 2027 "$mode" 42 'fn shift(x:u16,n:i32) u16 { return x << n; } fn main() i32 { if (shift(1,15)==32768) { return 42; } return 9; }'
  # Parameter values are unknown at compile time and must trap at runtime.
  case_run "$mode-i32-width" 2027 "$mode" trap 'fn shift(x:i32,n:i32) i32 { return x << n; } fn main() i32 { return shift(1,32); }'
  case_run "$mode-u32-negative" 2027 "$mode" trap 'fn shift(x:u32,n:i32) u32 { return x >> n; } fn main() i32 { return shift(1,-1) as i32; }'
  case_run "$mode-i64-width" 2027 "$mode" trap 'fn shift(x:i64,n:i64) i64 { return x >> n; } fn main() i32 { return shift(-1,64) as i32; }'
  case_run "$mode-u64-huge" 2027 "$mode" trap 'fn shift(x:u64,n:u64) u64 { return x << n; } fn main() i32 { return shift(1,9223372036854775808) as i32; }'
  case_run "$mode-u8-width" 2027 "$mode" trap 'fn shift(x:u8,n:i32) u8 { return x << n; } fn main() i32 { return shift(1,8) as i32; }'
  case_run "$mode-i16-width" 2027 "$mode" trap 'fn shift(x:i16,n:i32) i16 { return x >> n; } fn main() i32 { return shift(-1,16) as i32; }'
  case_run "$mode-i8-negative" 2027 "$mode" trap 'fn shift(x:i8,n:i32) i8 { return x >> n; } fn main() i32 { return shift(-1,-8) as i32; }'
  # A directly invalid count must fail compilation without an output file.
  case_run "$mode-literal-i32-width" 2027 "$mode" reject 'fn main() i32 { let x:i32=1; return x << 32; }'
  case_run "$mode-literal-i64-negative" 2027 "$mode" reject 'fn main() i32 { let x:i64=1; return (x >> -1) as i32; }'
  case_run "$mode-literal-u8-width" 2027 "$mode" reject 'fn main() i32 { let x:u8=1; return (x << 8) as i32; }'
  case_run "$mode-literal-u64-width" 2027 "$mode" reject 'fn main() i32 { let x:u64=1; return (x << 64) as i32; }'
done

# Edition 2026 is release-only (--safety=checked is edition-2027 syntax).
# Preserve its historical masked-count semantics, including negative counts.
case_run 'v1-i64-masked' 2026 release 42 'fn shift(x:i64,n:i64) i64 { return x << n; } fn main() i32 { if (shift(42,64)==42) { return 42; } return 9; }'
case_run 'v1-u64-masked' 2026 release 42 'fn shift(x:u64,n:i64) u64 { return x >> n; } fn main() i32 { if (shift(128,64)==128) { return 42; } return 9; }'
case_run 'v1-negative' 2026 release 42 'fn shift(x:i64,n:i64) i64 { return x >> n; } fn main() i32 { if (shift(-1,-1)==-1) { return 42; } return 9; }'
case_run 'v1-literal-masked' 2026 release 42 'fn main() i32 { let x:i64=42; if ((x << 64)==42) { return 42; } return 9; }'
printf 'v2-shift-counts pass=%d fail=0\n' "$pass"
