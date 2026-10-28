#!/usr/bin/env bash
# Edition 2027 traps signed i64 min / -1 on native ARM64 and x86-64.
# Edition 2026 retains wrapping semantics; modulo and unsigned division
# are intentionally outside the signed-division overflow trap.
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-}
case "$(uname -s):$(uname -m)" in
  Darwin:arm64) target=macos-arm64; ZNC=${ZNC:-"$PWD/znc-macos-arm64"} ;;
  Linux:x86_64|Linux:amd64) target=x86-64; ZNC=${ZNC:-"$PWD/znc"} ;;
  *) echo 'v2 signed-division overflow: unsupported native host' >&2; exit 2 ;;
esac
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
if [ ! -x "$ZNC" ]; then echo "v2 signed-division overflow: missing compiler: $ZNC" >&2; exit 2; fi
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-v2-divoverflow.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
pass=0
case_run() {
  local name=$1 edition=$2 mode=$3 expected=$4 source=$5
  mkdir -p "$tmp/$name"
  printf 'name = "v2division"\nversion = "0"\nedition = "%s"\n' "$edition" >"$tmp/$name/zag.mod"
  printf '%s\n' "$source" >"$tmp/$name/main.zag"
  local -a args=()
  if [ "$target" = macos-arm64 ]; then args+=(--target macos-arm64); fi
  if [ "$mode" = checked ]; then args+=(--safety=checked); fi
  if ! (cd "$tmp/$name" && "$ZNC" main.zag "${args[@]}" --no-zagd --no-analyze --no-foreground-cache -o out >build.log 2>&1); then
    echo "XX $name unexpected compilation failure" >&2
    sed -n '1,16p' "$tmp/$name/build.log" >&2
    exit 1
  fi
  if [ ! -x "$tmp/$name/out" ]; then echo "XX $name produced no executable" >&2; exit 1; fi
  local actual
  set +e
  "$tmp/$name/out" >"$tmp/$name/stdout" 2>"$tmp/$name/stderr"
  actual=$?
  set -e
  if [ "$expected" = trap ]; then
    if [ "$actual" -ne 1 ] ||
       ! grep -Fxq 'zag safety: signed integer division overflow' "$tmp/$name/stderr"; then
      echo "XX $name expected signed division overflow trap (exit 1), got $actual" >&2
      sed -n '1,12p' "$tmp/$name/stderr" >&2
      exit 1
    fi
  elif [ "$actual" -ne "$expected" ]; then
    echo "XX $name expected exit $expected, got $actual" >&2
    sed -n '1,12p' "$tmp/$name/stderr" >&2
    exit 1
  fi
  pass=$((pass + 1))
  echo "  ok  $name"
}
overflow_src='fn div(x:i64,y:i64) i64 { return x/y; } fn main() i32 { let x:i64=-9223372036854775807-1; let y:i64=div(x,-1); if (y==x) { return 42; } return 9; }'
for mode in release checked; do
  case_run "$mode-i64-min-div-neg-one" 2027 "$mode" trap "$overflow_src"
  case_run "$mode-i64-min-div-one" 2027 "$mode" 42 'fn div(x:i64,y:i64) i64 { return x/y; } fn main() i32 { let x:i64=-9223372036854775807-1; if (div(x,1)==x) { return 42; } return 9; }'
  case_run "$mode-i64-above-min-div-neg-one" 2027 "$mode" 42 'fn div(x:i64,y:i64) i64 { return x/y; } fn main() i32 { if (div(-9223372036854775807,-1)==9223372036854775807) { return 42; } return 9; }'
  case_run "$mode-u64-max-div-max" 2027 "$mode" 42 'fn div(x:u64,y:u64) u64 { return x/y; } fn main() i32 { if (div(18446744073709551615,18446744073709551615)==1) { return 42; } return 9; }'
  case_run "$mode-i64-min-rem-neg-one" 2027 "$mode" 42 'fn rem(x:i64,y:i64) i64 { return x%y; } fn main() i32 { let x:i64=-9223372036854775807-1; if (rem(x,-1)==0) { return 42; } return 9; }'
done
case_run "edition-2026-i64-min-wrap" 2026 release 42 "$overflow_src"
printf 'v2-signed-division-overflow pass=%d fail=0\n' "$pass"
