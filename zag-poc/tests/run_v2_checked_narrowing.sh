#!/usr/bin/env bash
# Edition-2027 signed/unsigned 64 -> 32-bit casts must trap on value loss,
# including without --safety=checked. Edition 2026 retains wrapping casts.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-}
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) target=macos-arm64; ZNC=${ZNC:-"$PWD/znc-macos-arm64"} ;;
  Linux:x86_64|Linux:amd64) target=x86-64; ZNC=${ZNC:-"$PWD/znc"} ;;
  *) echo 'v2 narrowing runtime test: unsupported host' >&2; exit 2 ;;
esac
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then echo "v2 narrowing: missing compiler: $ZNC" >&2; exit 2; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-v2-narrow.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0

case_run() {
  local name=$1 edition=$2 expected=$3 source=$4 mode=$5
  mkdir -p "$tmp/$name"
  printf 'name = "narrow"\nversion = "0"\nedition = "%s"\n' "$edition" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  local -a args=()
  if [ "$target" = macos-arm64 ]; then args+=(--target macos-arm64); fi
  if [ "$mode" = checked ]; then args+=(--safety=checked); fi
  if ! (cd "$tmp/$name" && "$ZNC" main.zag "${args[@]}" --no-zagd --no-analyze --no-foreground-cache -o out >build.log 2>&1); then
    echo "XX $name failed to compile" >&2
    sed -n '1,12p' "$tmp/$name/build.log" >&2
    exit 1
  fi
  if [ ! -x "$tmp/$name/out" ]; then echo "XX $name has no executable" >&2; exit 1; fi
  set +e
  "$tmp/$name/out" >"$tmp/$name/stdout" 2>"$tmp/$name/stderr"
  local actual=$?
  set -e
  if [ "$expected" = trap ]; then
    if [ "$actual" -eq 0 ] || ! grep -Fq 'zag safety: integer narrowing conversion out of range' "$tmp/$name/stderr"; then
      echo "XX $name expected narrowing trap; exit=$actual" >&2
      sed -n '1,12p' "$tmp/$name/stderr" >&2
      exit 1
    fi
  elif [ "$actual" -ne "$expected" ]; then
    echo "XX $name expected exit $expected, got $actual" >&2
    sed -n '1,12p' "$tmp/$name/stderr" >&2
    exit 1
  fi
  pass=$((pass+1))
  echo "  ok  $name"
}

for mode in release checked; do
  case_run "${mode}-signed-max" 2027 42 'fn narrow(x:i64) i32 { return x as i32; } fn main() i32 { if (narrow(2147483647) == 2147483647) { return 42; } return 9; }' "$mode"
  case_run "${mode}-signed-min" 2027 42 'fn narrow(x:i64) i32 { return x as i32; } fn main() i32 { if (narrow(-2147483648) < 0) { return 42; } return 9; }' "$mode"
  case_run "${mode}-unsigned-max" 2027 42 'fn narrow(x:u64) u32 { return x as u32; } fn main() i32 { if (narrow(4294967295) == 4294967295) { return 42; } return 9; }' "$mode"
  case_run "${mode}-signed-over-max" 2027 trap 'fn narrow(x:i64) i32 { return x as i32; } fn main() i32 { return narrow(2147483648); }' "$mode"
  case_run "${mode}-signed-under-min" 2027 trap 'fn narrow(x:i64) i32 { return x as i32; } fn main() i32 { return narrow(-2147483649); }' "$mode"
  case_run "${mode}-unsigned-over-max" 2027 trap 'fn narrow(x:u64) u32 { return x as u32; } fn main() i32 { let x:u32=narrow(4294967296); return x as i32; }' "$mode"
done
case_run 'v1-signed-wrap' 2026 42 'fn narrow(x:i64) i32 { return x as i32; } fn main() i32 { if (narrow(2147483648) < 0) { return 42; } return 9; }' release
case_run 'v1-unsigned-wrap' 2026 42 'fn narrow(x:u64) u32 { return x as u32; } fn main() i32 { if (narrow(4294967296) == 0) { return 42; } return 9; }' release
printf 'v2-narrowing pass=%d fail=0\n' "$pass"
