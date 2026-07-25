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
grep -q 'indent the lines belonging to the statement above' "$tmp/bad.log"

"$compiler" explain "$tmp/program.zs" --format json --no-zagd | grep -q '"profile":{"value":"script"'
"$compiler" check "$tmp/program.zs" --no-zagd --no-analyze >/dev/null

"$compiler" fmt "$tmp/program.zs" >"$tmp/formatted.zag"
grep -q 'script;' "$tmp/formatted.zag"
grep -q 'fn doubled(value:i64) i64' "$tmp/formatted.zag"
"$compiler" check "$tmp/formatted.zag" --no-zagd --no-analyze >/dev/null

"$compiler" harden "$tmp/program.zs" --output "$tmp/hardened.zag" \
    --format json --no-zagd >"$tmp/harden.json"
grep -q '"status":"unsupported"' "$tmp/harden.json"
grep -q '"candidate_compilable":false' "$tmp/harden.json"
test ! -e "$tmp/hardened.zag"
if "$compiler" harden "$tmp/program.zs" --apply \
    --test-command true --no-zagd >"$tmp/apply.log" 2>&1; then
    echo "unsupported harden candidate unexpectedly applied" >&2
    exit 1
fi
grep -q 'apply refused: no semantics-preserving strict candidate is available' "$tmp/apply.log"

echo "python-shaped Zag Script: PASS"
