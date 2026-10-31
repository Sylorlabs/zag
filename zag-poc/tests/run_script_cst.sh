#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-cst.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$compiler" selfhost/script_syntax_test.zag -o "$tmp/script_syntax_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/script_syntax_test" >"$tmp/cst.out"
grep -q '^script-cst pass=112 fail=0$' "$tmp/cst.out"
test "$(grep -c '^ok  ' "$tmp/cst.out")" -eq 112
cat "$tmp/cst.out"

bad="$tmp/malformed_parameter.zs"
printf '%s\n' 'script;' 'def broken(value:):' '    pass' >"$bad"
if "$compiler" "$bad" -o "$tmp/malformed_parameter" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/malformed.out" 2>&1; then
    echo "malformed parameter unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/malformed_parameter"
grep -Eq 'function parameters require|unexpected end of input while parsing source|malformed nested or default function parameter|inconsistent indentation layout' "$tmp/malformed.out"
echo "script-cst malformed parameter: PASS"

trailing="$tmp/trailing_operator.zs"
printf '%s\n' 'script;' 'value = 1 +' >"$trailing"
if "$compiler" "$trailing" -o "$tmp/trailing_operator" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/trailing.out" 2>&1; then
    echo "trailing operator unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/trailing_operator"
echo "script-cst trailing operator: PASS"

member="$tmp/trailing_member.zs"
printf '%s\n' 'script;' 'value = item.' >"$member"
if "$compiler" "$member" -o "$tmp/trailing_member" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/trailing_member.out" 2>&1; then
    echo "incomplete member access unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/trailing_member"
echo "script-cst incomplete member access: PASS"

interpolation="$tmp/malformed_interpolation.zs"
printf '%s\n' 'script;' 'value = "hello {name"' >"$interpolation"
if "$compiler" "$interpolation" -o "$tmp/malformed_interpolation" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/malformed_interpolation.out" 2>&1; then
    echo "malformed interpolation unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/malformed_interpolation"
grep -Eq 'inconsistent indentation layout|malformed string interpolation brace|unmatched' "$tmp/malformed_interpolation.out"
echo "script-cst malformed interpolation: PASS"

escape="$tmp/unterminated_escape.zs"
printf '%s' 'script;
value = "unterminated\' >"$escape"
if "$compiler" "$escape" -o "$tmp/unterminated_escape" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/unterminated_escape.out" 2>&1; then
    echo "unterminated string escape unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/unterminated_escape"
grep -Eq 'inconsistent indentation layout|unterminated string escape|unterminated string literal' "$tmp/unterminated_escape.out"
echo "script-cst unterminated string escape: PASS"
