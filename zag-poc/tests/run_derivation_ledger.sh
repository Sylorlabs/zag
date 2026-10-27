#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-derivation-ledger.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# Promotion/unexpand are release-enabled only when the foreground compiler
# produces and validates the same prepared semantic evidence encoded by the
# portable v2 ledger. Keep the enablement explicit and executable.
grep -q '^fn znc_ledger_runtime_enabled()i32{return 1;}' selfhost/native/znc.zag
grep -q 'module_graph_checksum' selfhost/derivation_ledger.zag
grep -q 'ast_origin_count' selfhost/derivation_ledger.zag
grep -q 'choice_scope' selfhost/derivation_ledger.zag
grep -q 'formal_proof_certificate' selfhost/derivation_ledger.zag
# The prepared adapter must bind the semantic-manifest bytes and decoded graph
# from the same snapshot; a raw module hash or empty placeholder is not enough
# to authorize a future runtime enablement.
grep -q 'let semantic_manifest:\[\]u8=smp_bounded_manifest' selfhost/native/znc.zag
grep -q '.semantic_graph=semantic_view.graph_identity' selfhost/native/znc.zag
grep -q 'semantic_view.graph_complete==0' selfhost/native/znc.zag
if rg -q '\.semantic_manifest=""' selfhost/native/znc.zag; then
    echo 'derivation ledger adapter still publishes an empty semantic manifest' >&2
    exit 1
fi

"$compiler" selfhost/derivation_ledger_test.zag -o "$tmp/derivation_ledger_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/derivation_ledger_test"

# End-to-end authority: an unchanged promoted artifact must carry a bounded v2
# ledger and restore the exact compact bytes. Any edit to the promoted source
# invalidates that exact-reversal contract and must publish nothing.
mkdir -p "$tmp/project"
cat >"$tmp/project/app.zag" <<'ZAG'
script;
let answer: i32 = 40 + 2;
println("ledger-roundtrip");
return 0;
ZAG
"$compiler" promote "$tmp/project/app.zag" --to explicit \
    --output "$tmp/project/promoted.zag" \
    --test-command "test -s '$tmp/project/promoted.zag'" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
test -s "$tmp/project/promoted.zag.zsledger"
grep -q '^format=zagscript-derivation-v2$' "$tmp/project/promoted.zag.zsledger"
grep -q '^complete=true$' "$tmp/project/promoted.zag.zsledger"
grep -q '^semantic_graph_complete=1$' "$tmp/project/promoted.zag.zsledger"
"$compiler" unexpand "$tmp/project/promoted.zag" \
    --output "$tmp/project/restored.zag" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
cmp "$tmp/project/app.zag" "$tmp/project/restored.zag"

cp "$tmp/project/promoted.zag" "$tmp/project/edited.zag"
cp "$tmp/project/promoted.zag.zsledger" "$tmp/project/edited.zag.zsledger"
printf '\n// human edit\n' >>"$tmp/project/edited.zag"
if "$compiler" unexpand "$tmp/project/edited.zag" \
    --output "$tmp/project/edited-restored.zag" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/edited.log" 2>&1; then
    echo 'derivation ledger accepted edited promoted source for exact reversal' >&2
    exit 1
fi
grep -q 'znc unexpand: structural projection conflict at derived bytes' "$tmp/edited.log"
test ! -e "$tmp/project/edited-restored.zag"

echo 'derivation ledger: PASS codec + prepared semantic evidence + exact promote/unexpand + tamper rejection'
