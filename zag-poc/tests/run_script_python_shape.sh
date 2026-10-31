#!/usr/bin/env bash
set -euo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
compiler=${ZNC:-"$root/znc"}
tmp=$(mktemp -d /tmp/zag-script-python-shape.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

cp "$root/tests/script_frontend/python_shape.zag" "$tmp/program.zs"
"$compiler" "$tmp/program.zs" -o "$tmp/program" --no-zagd --no-analyze >/dev/null
if [ "$("$tmp/program")" != "6" ]; then
    echo "python-shaped Script produced the wrong result" >&2
    exit 1
fi

cat >"$tmp/input.zs" <<'ZAG'
name = input("Name: ")
print(name)
ZAG
"$compiler" "$tmp/input.zs" -o "$tmp/input" --no-zagd --no-analyze >/dev/null
if [ "$(printf 'Micah\n' | "$tmp/input")" != "Name: Micah" ]; then
    echo "python-shaped Script input produced the wrong result" >&2
    exit 1
fi

cat >"$tmp/bad-indent.zs" <<'ZAG'
if true:
print("missing indentation")
ZAG
if "$compiler" "$tmp/bad-indent.zs" -o "$tmp/bad" --no-zagd --no-analyze >"$tmp/bad.log" 2>&1; then
    echo "missing indentation unexpectedly compiled" >&2
    exit 1
fi
grep -q 'inconsistent indentation layout' "$tmp/bad.log"

cat >"$tmp/bad-control.zs" <<'ZAG'
break
ZAG
if "$compiler" "$tmp/bad-control.zs" -o "$tmp/bad-control" --no-zagd --no-analyze >"$tmp/bad-control.log" 2>&1; then
    echo "top-level break unexpectedly compiled" >&2
    exit 1
fi
grep -q 'break outside loop' "$tmp/bad-control.log"

cat >"$tmp/bad-continue.zs" <<'ZAG'
continue
ZAG
if "$compiler" "$tmp/bad-continue.zs" -o "$tmp/bad-continue" --no-zagd --no-analyze >"$tmp/bad-continue.log" 2>&1; then
    echo "top-level continue unexpectedly compiled" >&2
    exit 1
fi
grep -q 'continue outside loop' "$tmp/bad-continue.log"

"$compiler" explain "$tmp/program.zs" --format json --no-zagd | grep -q '"profile":{"value":"script"'
"$compiler" check "$tmp/program.zs" --no-zagd --no-analyze >/dev/null

"$compiler" fmt "$tmp/program.zs" >"$tmp/formatted.zag"
grep -q 'script;' "$tmp/formatted.zag"
grep -q 'fn doubled(value:i64) i64' "$tmp/formatted.zag"
"$compiler" check "$tmp/formatted.zag" --no-zagd --no-analyze >/dev/null

"$compiler" harden "$tmp/program.zs" --output "$tmp/hardened.zag" \
    --format json --no-zagd >"$tmp/harden.json"
grep -q '"status":"preview"' "$tmp/harden.json"
grep -q '"candidate_compilable":true' "$tmp/harden.json"
grep -q '"source_modified":false' "$tmp/harden.json"
test -s "$tmp/hardened.zag"
"$compiler" "$tmp/hardened.zag" -o "$tmp/hardened" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
if [ "$("$tmp/hardened")" != "6" ]; then
    echo "python-shaped explicit candidate produced the wrong result" >&2
    exit 1
fi
cmp -s "$tmp/program.zs" "$root/tests/script_frontend/python_shape.zag"
if "$compiler" harden "$tmp/program.zs" --apply \
    --test-command true --no-zagd >"$tmp/apply.log" 2>&1; then
    echo "removed harden --apply mode unexpectedly succeeded" >&2
    exit 1
fi
grep -q 'harden: --apply is no longer supported' "$tmp/apply.log"
test ! -e "$tmp/program.zs.harden.bak"

echo "python-shaped Zag Script: PASS"
