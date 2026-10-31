#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-derivation-ledger.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

# The foreground adapter is enabled only for the source-matched native driver
# path; this gate exercises the codec and the integrated prepared-evidence
# binding rather than accepting a stale disabled marker.
# Keep this source witness resilient to the formatter: the function may be
# emitted on one line or as a conventional multiline declaration, but its
# release adapter must explicitly return enabled.  Do not replace this with a
# broad repository grep, which could authorize a stale/disabled implementation.
awk '
    /^[[:space:]]*fn[[:space:]]+znc_ledger_runtime_enabled[[:space:]]*\(/ { in_fn=1 }
    in_fn && /return[[:space:]]+1[[:space:]]*;/ { ok=1; exit 0 }
    in_fn && /^}/ { exit 1 }
    END { if (!ok) exit 1 }
' selfhost/native/znc.zag
grep -q 'module_graph_checksum' selfhost/derivation_ledger.zag
grep -q 'ast_origin_count' selfhost/derivation_ledger.zag
grep -q 'choice_scope' selfhost/derivation_ledger.zag
grep -q 'formal_proof_certificate' selfhost/derivation_ledger.zag
# The prepared adapter must bind the semantic-manifest bytes and decoded graph
# from the same snapshot; a raw module hash or empty placeholder is not enough
# to authorize a future runtime enablement.
grep -Eq 'let[[:space:]]+semantic_manifest[[:space:]]*:[[:space:]]*\[\]u8[[:space:]]*=[[:space:]]*smp_bounded_manifest' selfhost/native/znc.zag
grep -Eq '\.semantic_graph[[:space:]]*=[[:space:]]*semantic_view\.graph_identity' selfhost/native/znc.zag
grep -Eq 'semantic_view\.graph_complete[[:space:]]*==[[:space:]]*0' selfhost/native/znc.zag
if rg -q '\.semantic_manifest=""' selfhost/native/znc.zag; then
    echo 'derivation ledger adapter still publishes an empty semantic manifest' >&2
    exit 1
fi

"$compiler" selfhost/derivation_ledger_test.zag -o "$tmp/derivation_ledger_test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/derivation_ledger_test"
