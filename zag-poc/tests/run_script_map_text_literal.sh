#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-map-text-literal.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

"$compiler" tests/script_map_text_literal.zag -o "$tmp/map" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/map"
"$tmp/map"

cat >"$tmp/bad-mixed.zs" <<'ZAG'
script;
let values = {"alpha": 1};
return 0;
ZAG
if "$compiler" "$tmp/bad-mixed.zs" -o "$tmp/bad-mixed" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-mixed.out" 2>&1; then
    echo 'mixed text map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-mixed"
grep -q 'map literal requires one or more homogeneous literal entries' "$tmp/bad-mixed.out"

cat >"$tmp/bad-identifier.zs" <<'ZAG'
script;
let key = "alpha";
let values = {key: "one"};
return 0;
ZAG
if "$compiler" "$tmp/bad-identifier.zs" -o "$tmp/bad-identifier" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-identifier.out" 2>&1; then
    echo 'identifier text map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-identifier"
grep -q 'map literal requires one or more homogeneous literal entries' "$tmp/bad-identifier.out"

cat >"$tmp/bad-trailing.zs" <<'ZAG'
script;
let values = {"alpha": "one",};
return 0;
ZAG
if "$compiler" "$tmp/bad-trailing.zs" -o "$tmp/bad-trailing" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-trailing.out" 2>&1; then
    echo 'trailing text map literal comma unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-trailing"
grep -q 'map literal requires one or more homogeneous literal entries' "$tmp/bad-trailing.out"

cat >"$tmp/bad-annotated.zs" <<'ZAG'
script;
let values: ScriptMapText = {"alpha": "one"};
return 0;
ZAG
if "$compiler" "$tmp/bad-annotated.zs" -o "$tmp/bad-annotated" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-annotated.out" 2>&1; then
    echo 'annotated text map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-annotated"
grep -q 'map literals require a simple unannotated binding' "$tmp/bad-annotated.out"

cat >"$tmp/multiline.zs" <<'ZAG'
script;
let values = {
    "alpha": "one"
};
if (text_map_len(values) != 1 || !text_map_has(values, "alpha") ||
    !@strEq(text_map_get(values, "alpha"), "one")) { return 1; }
return 0;
ZAG
"$compiler" "$tmp/multiline.zs" -o "$tmp/multiline" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -x "$tmp/multiline"
"$tmp/multiline"

cat >"$tmp/bad-nested.zs" <<'ZAG'
script;
let values = {"outer": {"inner": "value"}};
return 0;
ZAG
if "$compiler" "$tmp/bad-nested.zs" -o "$tmp/bad-nested" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-nested.out" 2>&1; then
    echo 'nested text map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-nested"
grep -q 'map literal requires one or more homogeneous literal entries' "$tmp/bad-nested.out"

cat >"$tmp/bad-nested-inline.zs" <<'ZAG'
script;
if (true) { let values = {"outer": {"inner": "value"}}; return 0; }
return 1;
ZAG
if "$compiler" "$tmp/bad-nested-inline.zs" -o "$tmp/bad-nested-inline" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-nested-inline.out" 2>&1; then
    echo 'same-line nested text map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-nested-inline"
grep -q 'map literal requires one or more homogeneous literal entries' "$tmp/bad-nested-inline.out"

cat >"$tmp/bad-call.zs" <<'ZAG'
script;
let values = {make_key(): "value"};
return 0;
ZAG
if "$compiler" "$tmp/bad-call.zs" -o "$tmp/bad-call" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-call.out" 2>&1; then
    echo 'call text map literal unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/bad-call"
grep -q 'map literal requires one or more homogeneous literal entries' "$tmp/bad-call.out"

for bad_name in key-interpolation value-interpolation empty duplicate-colon \
    missing-colon double-comma; do
    case "$bad_name" in
        key-interpolation) bad_source='script; let values = {"bad {key}": "value"}; return 0;' ;;
        value-interpolation) bad_source='script; let values = {"key": "bad {value}"}; return 0;' ;;
        empty) bad_source='script; let values = {}; return 0;' ;;
        duplicate-colon) bad_source='script; let values = {"key":: "value"}; return 0;' ;;
        missing-colon) bad_source='script; let values = {"key" "value"}; return 0;' ;;
        double-comma) bad_source='script; let values = {"key": "value",, "other": "two"}; return 0;' ;;
    esac
    printf '%s\n' "$bad_source" >"$tmp/bad-$bad_name.zs"
    if "$compiler" "$tmp/bad-$bad_name.zs" -o "$tmp/bad-$bad_name" \
        --no-zagd --no-analyze --no-foreground-cache >"$tmp/bad-$bad_name.out" 2>&1; then
        echo "malformed text map literal $bad_name unexpectedly compiled" >&2
        exit 1
    fi
    test ! -e "$tmp/bad-$bad_name"
    grep -q 'map literal requires one or more homogeneous literal entries without a trailing comma' \
        "$tmp/bad-$bad_name.out"
done

echo 'script text map literal: PASS (CST lowering, escapes, growth, overwrite, delete, clear, negatives)'
