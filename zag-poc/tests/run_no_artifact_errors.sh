#!/usr/bin/env bash
# A hard parse, semantic, or native-lowering failure must not leave an output
# executable behind.  These are execution-path checks, not diagnostic greps.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-no-artifact.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

check() {
  name=$1
  source=$2
  printf '%s\n' "$source" >"$tmp/$name.zag"
  out="$tmp/$name.out"
  set +e
  timeout 5 "$ZNC" "$tmp/$name.zag" -o "$out" >"$tmp/$name.log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ "$status" -ne 124 ] && [ "$status" -lt 128 ] && [ ! -e "$out" ]; then
    echo "  ok  $name"
    pass=$((pass + 1))
  else
    echo "  XX  $name (status=$status; hard failure emitted an artifact or crashed)"
    sed -n '1,10p' "$tmp/$name.log"
    fail=$((fail + 1))
  fi
}

check arity 'fn f(x: i32) i32 { return x; }
fn main() i32 { return f(); }'
check duplicate 'fn main() i32 { return 1; }
fn main() i32 { return 2; }'
check missing_main 'fn helper() i32 { return 1; }'
check unknown_identifier 'fn main() i32 { return does_not_exist; }'

echo "════ no-artifact-errors pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
