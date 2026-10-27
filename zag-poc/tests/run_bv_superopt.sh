#!/usr/bin/env bash
# Independent Z3 proof/search gate for the offline full-width superoptimizer.
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
tool="$root/tools/bv_superopt.sh"
command -v "${Z3:-z3}" >/dev/null 2>&1 || {
    echo 'bv-superopt: Z3 is required for proof tests' >&2
    exit 1
}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-bv-test.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

for bits in 8 16 32 64; do
    "$tool" prove "$bits" 'x 0 +' 'x' > "$tmp/prove"
    grep -qx 'result=unsat' "$tmp/prove"
    grep -qx 'equivalent=yes' "$tmp/prove"
    "$tool" prove "$bits" 'x 2 *' 'x x +' > "$tmp/prove"
    grep -qx 'result=unsat' "$tmp/prove"
    "$tool" prove "$bits" 'x y +' 'y x +' > "$tmp/prove"
    grep -qx 'result=unsat' "$tmp/prove"
    # A tempting rewrite changes wrapping behavior; demand an actual model.
    if "$tool" prove "$bits" 'x 1 +' 'x' > "$tmp/negative"; then
        echo "bv-superopt: invalid rewrite accepted at $bits bits" >&2; exit 1
    fi
    grep -qx 'result=sat' "$tmp/negative"
    grep -q '^counterexample=sat' "$tmp/negative"
done

# A full native-width search picks a simpler candidate and saves the replayable
# SMT-LIB proof. Re-run that proof using Z3, independent of the search output.
for bits in 8 64; do
    "$tool" search "$bits" 'x 0 + y 0 + *' --proof-file "$tmp/selected.smt2" > "$tmp/search"
    grep -Fqx 'selected=x y *' "$tmp/search"
    grep -qx 'original_nodes=7' "$tmp/search"
    grep -qx 'selected_nodes=3' "$tmp/search"
    grep -qx 'proof=unsat' "$tmp/search"
    test "$("${Z3:-z3}" "$tmp/selected.smt2")" = unsat
done
"$tool" search 32 'x x ^' > "$tmp/search"
grep -qx 'selected=0' "$tmp/search"
"$tool" search 16 'x y +' > "$tmp/search"
grep -qx 'selected=x y +' "$tmp/search"
grep -qx 'selection=reference' "$tmp/search"

# Reject malformed expressions, unsupported signed/shift/division operators,
# invalid widths and out-of-range constants without invoking a proof.
for expr in 'x 1 /' 'x 1 >>' 'x + ' 'x 1 + y' 'x (assert true)' '65536'; do
    if "$tool" prove 16 "$expr" x > "$tmp/invalid" 2>&1; then
        echo "bv-superopt: malformed expression accepted: $expr" >&2; exit 1
    fi
done
if "$tool" search 7 'x 1 +' > "$tmp/invalid" 2>&1; then
    echo 'bv-superopt: unsupported width accepted' >&2; exit 1
fi

# An inconclusive solver result must never be treated as a valid proof.
cat > "$tmp/unknown-z3" <<'STUB'
#!/bin/sh
echo unknown
STUB
chmod +x "$tmp/unknown-z3"
if Z3="$tmp/unknown-z3" "$tool" prove 64 'x 0 +' x > "$tmp/invalid" 2>&1; then
    echo 'bv-superopt: unknown accepted as proof' >&2; exit 1
fi
grep -q 'returned unknown' "$tmp/invalid"

echo 'bv-superopt: PASS (4 widths, proven rewrites, counterexamples, search, replay and fail-closed cases)'

