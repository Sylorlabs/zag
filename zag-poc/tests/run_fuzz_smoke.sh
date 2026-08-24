#!/usr/bin/env bash
# Deterministic malformed-input smoke fuzzing.  This is intentionally tiny and
# dependency-free: it protects the self-hosted default path from obvious lexer
# and parser crashes without pretending to be coverage-guided fuzzing.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-fuzz-smoke.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

case_file() {
  name=$1
  source=$2
  out="$tmp/$name.out"
  log="$tmp/$name.log"
  printf '%s' "$source" >"$tmp/$name.zag"
  set +e
  timeout 5 "$ZNC" "$tmp/$name.zag" -o "$out" >"$log" 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ] || [ "$status" -eq 124 ] || [ "$status" -ge 128 ] || [ -e "$out" ]; then
    echo "  XX  $name (status=$status)"
    sed -n '1,8p' "$log"
    fail=$((fail + 1))
  else
    echo "  ok  $name"
    pass=$((pass + 1))
  fi
}

case_file empty ''
case_file delimiters '([{{(([[,,;;))}}]])'
case_file punctuation '!@#$%^&*+=|\\~`'
case_file unterminated_escape 'fn main() i32 { print_str("\") }'
case_file nested_prefix 'pub extern fn (([[]]))'

# Invalid UTF-8 and an embedded NUL exercise byte-oriented lexer boundaries.
printf '\377fn main() i32 {}' >"$tmp/invalid_utf8.zag"
printf 'fn main() i32 {\000' >"$tmp/nul_byte.zag"
for name in invalid_utf8 nul_byte; do
  out="$tmp/$name.out"
  log="$tmp/$name.log"
  set +e
  timeout 5 "$ZNC" "$tmp/$name.zag" -o "$out" >"$log" 2>&1
  status=$?
  set -e
  if [ "$status" -eq 0 ] || [ "$status" -eq 124 ] || [ "$status" -ge 128 ] || [ -e "$out" ]; then
    echo "  XX  $name (status=$status)"
    sed -n '1,8p' "$log"
    fail=$((fail + 1))
  else
    echo "  ok  $name"
    pass=$((pass + 1))
  fi
done

echo "════ fuzz-smoke pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
