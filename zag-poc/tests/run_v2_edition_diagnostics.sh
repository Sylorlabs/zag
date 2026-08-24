#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."
ZNC=${ZNC:-"$PWD/znc"}
case "$ZNC" in
  /*) ;;
  *) ZNC="$PWD/${ZNC#./}" ;;
esac

tmp=$(mktemp -d /tmp/zag-v2-edition-diagnostic.XXXXXX)
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT

"$ZNC" tests/v2_edition_diagnostic_unit.zag --no-zagd --no-foreground-cache -o "$tmp/unit"
"$tmp/unit"

mkdir -p "$tmp/project"
printf 'name = "edition-diagnostic"\nversion = "0"\nedition = "2026"\n' >"$tmp/project/zag.mod"
printf 'fn main() i32 {\n  let value: i32 = 1;\n  let unsafe: i32 = value + 1;\n  return unsafe;\n}\n' >"$tmp/project/main.zag"

if (cd "$tmp/project" && "$ZNC" main.zag --no-zagd -o app) >"$tmp/log" 2>&1 || [ -e "$tmp/project/app" ]; then
  printf 'v2 edition diagnostic: FAIL: reserved identifier compiled or emitted output\n' >&2
  sed -n '1,12p' "$tmp/log" >&2
  exit 1
fi

grep -q 'E0200' "$tmp/log" || {
  printf 'v2 edition diagnostic: FAIL: missing E0200\n' >&2
  exit 1
}
grep -q 'main.zag' "$tmp/log" || {
  printf 'v2 edition diagnostic: FAIL: missing source path\n' >&2
  exit 1
}
grep -q 'reserved token `unsafe` at source line 3' "$tmp/log" || {
  printf 'v2 edition diagnostic: FAIL: missing exact token and line\n' >&2
  sed -n '1,12p' "$tmp/log" >&2
  exit 1
}

printf 'v2 edition diagnostic: PASS (path, token, line, no artifact)\n'
