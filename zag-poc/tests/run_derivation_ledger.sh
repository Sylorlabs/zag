#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-derivation-ledger.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# The foreground adapter is deliberately disabled until a source-matched
# native driver proves its ownership path. Keep that boundary executable and
# fail closed if a future edit silently enables it without changing the gate.
grep -q '^fn znc_ledger_runtime_enabled()i32{return 0;}' selfhost/native/znc.zag
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
