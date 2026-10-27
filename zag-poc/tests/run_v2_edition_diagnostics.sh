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

mkdir -p "$tmp/commented-edition"
printf 'name = "comment"\n# edition = "2027"\nedition = "2026"\n' >"$tmp/commented-edition/zag.mod"
printf 'fn main() i32 { unsafe { return 42; } }\n' >"$tmp/commented-edition/main.zag"
if (cd "$tmp/commented-edition" && "$ZNC" main.zag --no-zagd --no-foreground-cache -o app) >"$tmp/commented-edition/log" 2>&1 ||
   [ -e "$tmp/commented-edition/app" ]; then
  printf 'v2 edition diagnostic: FAIL: commented-out 2027 enabled v2 in 2026\n' >&2
  sed -n '1,12p' "$tmp/commented-edition/log" >&2
  exit 1
fi
grep -q 'E0200' "$tmp/commented-edition/log" || {
  printf 'v2 edition diagnostic: FAIL: missing E0200 for commented-out edition\n' >&2
  sed -n '1,12p' "$tmp/commented-edition/log" >&2
  exit 1
}

if (cd "$tmp/commented-edition" && "$ZNC" check main.zag --no-zagd --no-foreground-cache) >"$tmp/commented-edition/check.log" 2>&1 ||
   ! grep -q 'E0200' "$tmp/commented-edition/check.log"; then
  printf 'v2 edition diagnostic: FAIL: check accepted commented-out 2027\n' >&2
  sed -n '1,12p' "$tmp/commented-edition/check.log" >&2
  exit 1
fi

mkdir -p "$tmp/real-edition"
printf 'name = "real"\n# edition = "2026"\n  edition = "2027" # actual edition\n' >"$tmp/real-edition/zag.mod"
printf 'fn main() i32 { unsafe { return 42; } }\n' >"$tmp/real-edition/main.zag"
if ! (cd "$tmp/real-edition" && "$ZNC" main.zag --no-zagd --no-foreground-cache -o app) >"$tmp/real-edition/log" 2>&1 ||
   [ ! -x "$tmp/real-edition/app" ]; then
  printf 'v2 edition diagnostic: FAIL: real 2027 edition was rejected\n' >&2
  sed -n '1,12p' "$tmp/real-edition/log" >&2
  exit 1
fi

printf 'v2 edition diagnostic: PASS (path, token, line, manifest edition, no artifact on rejection)\n'
