#!/usr/bin/env bash
# Recognized but unimplemented v2 driver options must fail closed rather than
# compiling a program while silently ignoring the requested safety contract.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-v2-options.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf 'fn main() i32 { return 0; }\n' >"$tmp/main.zag"
pass=0 fail=0
for option in --safety=checked --sanitize=memory --target-feature=avx2 --gpu-runtime=vulkan --edition=2027; do
  out="$tmp/out"
  if "$ZNC" "$tmp/main.zag" -o "$out" "$option" >"$tmp/log" 2>&1 || [ -e "$out" ]; then
    echo "  XX  $option"
    sed -n '1,4p' "$tmp/log"
    fail=$((fail + 1))
  elif grep -q E0202 "$tmp/log"; then
    echo "  ok  $option"
    pass=$((pass + 1))
  else
    echo "  XX  $option (missing E0202)"
    fail=$((fail + 1))
  fi
done
echo "════ v2-options pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
