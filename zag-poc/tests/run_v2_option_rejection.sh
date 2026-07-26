#!/usr/bin/env bash
# Recognized but unimplemented v2 driver options must fail closed rather than
# compiling a program while silently ignoring the requested safety contract.
# The native x86-64 `--sanitize=memory` slice is implemented and covered by
# run_v2_edition.sh; this suite therefore exercises the still-unsupported
# sanitizer mode instead.
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
for option in --sanitize=thread --target-feature=avx2 --gpu-runtime=vulkan --edition=2027; do
  out="$tmp/out"
  rm -f "$out"
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

printf 'caller-owned sentinel\n' >"$tmp/existing.out"
if "$ZNC" "$tmp/main.zag" -o "$tmp/existing.out" --sanitize=thread >"$tmp/existing.log" 2>&1 || \
   [ "$(cat "$tmp/existing.out")" != 'caller-owned sentinel' ]; then
  echo "  XX  rejected option preserves existing output"
  sed -n '1,4p' "$tmp/existing.log"
  fail=$((fail + 1))
else
  echo "  ok  rejected option preserves existing output"
  pass=$((pass + 1))
fi

if "$ZNC" check "$tmp/main.zag" --sanitize=thread >"$tmp/check.log" 2>&1; then
  echo "  XX  check rejects unimplemented sanitizer option"
  fail=$((fail + 1))
elif grep -q E0202 "$tmp/check.log"; then
  echo "  ok  check rejects unimplemented sanitizer option"
  pass=$((pass + 1))
else
  echo "  XX  check rejects unimplemented sanitizer option (missing E0202)"
  fail=$((fail + 1))
fi
echo "════ v2-options pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
