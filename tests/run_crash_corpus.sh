#!/usr/bin/env bash
# Malformed inputs are compiler input, not a license to crash or emit a usable
# ELF.  Keep each minimized reproducer in crash_corpus and make this gate grow
# when a new parser/sema/codegen failure is reduced.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-crash-corpus.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

for source in tests/crash_corpus/*.zag; do
  name=$(basename "$source" .zag)
  out="$tmp/$name.out"
  log="$tmp/$name.log"
  set +e
  timeout 5 "$ZNC" "$source" -o "$out" >"$log" 2>&1
  status=$?
  set -e
  if [ "$status" -ge 128 ]; then
    echo "  XX  $name (compiler terminated by signal $((status - 128)))"
    sed -n '1,12p' "$log"
    fail=$((fail + 1))
  elif [ "$status" -eq 0 ] || [ "$status" -eq 124 ] || [ -e "$out" ]; then
    echo "  XX  $name (status=$status; output must be rejected without an artifact)"
    sed -n '1,12p' "$log"
    fail=$((fail + 1))
  elif rg -qi 'segmentation fault|assertion failed|panic:|stack overflow' "$log"; then
    echo "  XX  $name (compiler crash diagnostic)"
    sed -n '1,12p' "$log"
    fail=$((fail + 1))
  else
    echo "  ok  $name"
    pass=$((pass + 1))
  fi
done

# Literal terminators are diagnosed by the lexer rather than becoming a parser
# out-of-bounds path.  Keep this explicit so a future recovery change does not
# regress to a crash or silently accept the malformed literal.
for source in unterminated_string unterminated_char; do
  out="$tmp/$source.literal.out"
  set +e
  "$ZNC" "tests/crash_corpus/$source.zag" -o "$out" >"$tmp/$source.literal.log" 2>&1
  status=$?
  set -e
  if [ "$status" -ne 0 ] && [ ! -e "$out" ] && rg -q 'E0002: unterminated' "$tmp/$source.literal.log"; then
    echo "  ok  $source has lexical diagnostic"
    pass=$((pass + 1))
  else
    echo "  XX  $source lacks lexical E0002 diagnostic"
    sed -n '1,12p' "$tmp/$source.literal.log"
    fail=$((fail + 1))
  fi
done

echo "════ crash-corpus pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
