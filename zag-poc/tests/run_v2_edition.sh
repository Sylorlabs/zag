#!/usr/bin/env bash
# V2 edition boundary: syntax must be rejected before parsing/codegen and must
# never leave an executable behind.  This is intentionally a compiler test, not
# a grep-only documentation test.
set -eu
cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-v2-edition.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

reject() {
  name=$1 edition=$2
  mkdir -p "$tmp/$name"
  printf 'name = "v2test"\nversion = "0"\nedition = "%s"\n' "$edition" >"$tmp/$name/zag.mod"
  printf 'fn main() i32 { unsafe { return 42; } }\n' >"$tmp/$name/main.zag"
  out="$tmp/$name/out"
  if (cd "$tmp/$name" && "$ZNC" main.zag -o "$out") >"$tmp/$name/log" 2>&1 || [ -e "$out" ]; then
    echo "  XX  $name"; sed -n '1,8p' "$tmp/$name/log"; fail=$((fail + 1))
  elif grep -q "$3" "$tmp/$name/log"; then
    echo "  ok  $name"; pass=$((pass + 1))
  else
    echo "  XX  $name (missing diagnostic)"; sed -n '1,8p' "$tmp/$name/log"; fail=$((fail + 1))
  fi
}

reject "v1 rejects v2 unsafe syntax" 2026 E0200
reject "v2 rejects unimplemented unsafe syntax" 2027 E0201
# A source may live under a project directory.  The nearest ancestor manifest
# controls its edition; only consulting the source directory would silently
# turn a v2 project back into v1.
mkdir -p "$tmp/nested/src"
printf 'name = "nested"\nversion = "0"\nedition = "2027"\n' >"$tmp/nested/zag.mod"
printf 'fn main() i32 { unsafe { return 42; } }\n' >"$tmp/nested/src/main.zag"
if (cd "$tmp/nested" && "$ZNC" src/main.zag -o out) >"$tmp/nested/log" 2>&1 || [ -e "$tmp/nested/out" ]; then
  echo "  XX  nested source inherits project edition"; sed -n '1,8p' "$tmp/nested/log"; fail=$((fail + 1))
elif grep -q E0201 "$tmp/nested/log"; then
  echo "  ok  nested source inherits project edition"; pass=$((pass + 1))
else
  echo "  XX  nested source inherits project edition (missing diagnostic)"; fail=$((fail + 1))
fi
mkdir -p "$tmp/v1-asm"
printf 'name = "v1asm"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-asm/zag.mod"
printf 'fn main() i32 { asm { } return 0; }\n' >"$tmp/v1-asm/main.zag"
if (cd "$tmp/v1-asm" && "$ZNC" main.zag -o out) >"$tmp/v1-asm/log" 2>&1 || [ -e "$tmp/v1-asm/out" ]; then
  echo "  XX  v1 rejects v2 inline assembly"; sed -n '1,8p' "$tmp/v1-asm/log"; fail=$((fail + 1))
elif grep -q E0200 "$tmp/v1-asm/log"; then
  echo "  ok  v1 rejects v2 inline assembly"; pass=$((pass + 1))
else
  echo "  XX  v1 rejects v2 inline assembly (missing diagnostic)"; fail=$((fail + 1))
fi
# v1 comments and strings are not syntax and must not accidentally trigger the
# raw source scanner used by the early edition gate.
mkdir -p "$tmp/v1-text"
printf 'name = "v1text"\nversion = "0"\nedition = "2026"\n' >"$tmp/v1-text/zag.mod"
printf 'fn main() i32 { print_str("unsafe"); // volatile atomic asm\n return 42; }\n' >"$tmp/v1-text/main.zag"
if (cd "$tmp/v1-text" && "$ZNC" main.zag -o out) >"$tmp/v1-text/log" 2>&1 && [ -x "$tmp/v1-text/out" ] && [ "$("$tmp/v1-text/out")" = unsafe ]; then
  echo "  ok  v1 text mentioning v2 words still compiles"; pass=$((pass + 1))
else
  echo "  XX  v1 text mentioning v2 words still compiles"; sed -n '1,8p' "$tmp/v1-text/log"; fail=$((fail + 1))
fi
echo "════ v2-edition pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
