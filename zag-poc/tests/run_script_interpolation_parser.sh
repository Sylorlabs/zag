#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-interpolation-parser.XXXXXX)
trap 'rc=$?; if [ "$rc" -ne 0 ]; then for log in "$tmp"/*.err "$tmp"/out.zag; do [ ! -f "$log" ] || cat "$log" >&2; done; fi; if [ "${ZAG_KEEP_TEST_TMP:-0}" = 1 ]; then echo "test artifacts: $tmp" >&2; else rm -rf "$tmp"; fi' EXIT
"$compiler" selfhost/script_interpolation_test.zag --no-zagd --no-analyze -o "$tmp/parser" >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log"; exit 1; }
cat >"$tmp/ok.zag" <<'ZAG'
fn sample(__zag_script_context:*opaque)[]u8 {
    return f"{{λ}} {next(1)} {nested("a'b")} {true} end";
}
ZAG
# Quotes inside a hole belong to its expression, not to the outer literal.
cp "$tmp/ok.zag" "$tmp/nested.zag"
"$tmp/parser" "$tmp/nested.zag" >"$tmp/out.zag"
grep -q 'script_interpolation_finish' "$tmp/out.zag"
grep -q '__zag_script_format(__zag_script_context, next(1))' "$tmp/out.zag"
grep -Fq "nested(\"a'b\")" "$tmp/out.zag"
grep -q '"{λ} "' "$tmp/out.zag"
test "$(grep -o 'next(1)' "$tmp/out.zag" | wc -l | tr -d ' ')" = 1
"$tmp/parser" "$tmp/out.zag" >"$tmp/roundtrip.zag"
cmp "$tmp/out.zag" "$tmp/roundtrip.zag"
pass=2
for literal in 'f"{}"' 'f"{ }"' 'f"x}"' 'f"{x:hex}"' 'f"{x /* comment */}"' 'f"\{x}"' 'f"{x"' 'f"{call(}"' 'f"{items[)}"'; do
    printf 'fn bad()[]u8{return %s;}\n' "$literal" >"$tmp/bad.zag"
    if "$tmp/parser" "$tmp/bad.zag" >"$tmp/bad.err" 2>&1; then echo "unexpected parse success: $literal"; exit 1; fi
    grep -Eq 'E0020|E0002' "$tmp/bad.err"
    pass=$((pass+1))
done
mkdir -p "$tmp/tests" "$tmp/selfhost/std"
printf '%s\n' 'name = "interpolation-runtime"' 'edition = "2027"' >"$tmp/zag.mod"
cp tests/script_interpolation_runtime.zag "$tmp/tests/"
cp selfhost/std/script_interpolate.zag selfhost/std/script_format.zag "$tmp/selfhost/std/"
"$compiler" "$tmp/tests/script_interpolation_runtime.zag" --no-zagd --no-analyze -o "$tmp/runtime" >"$tmp/runtime-build.log" 2>&1 || { cat "$tmp/runtime-build.log"; exit 1; }
"$tmp/runtime"
for mode in budget overflow; do
    if "$tmp/runtime" "$mode" >"$tmp/runtime.out" 2>"$tmp/runtime.err"; then echo "unexpected $mode success"; exit 1; fi
    grep -q 'interpolation: allocation or output limit exceeded' "$tmp/runtime.err"
    test ! -s "$tmp/runtime.out"
    pass=$((pass+1))
done
echo "script interpolation parser/runtime pass=$((pass+1)) fail=0"
