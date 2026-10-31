#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-semantic-egraph.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
"$compiler" tests/semantic_egraph_test.zag -o "$tmp/egraph" --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/egraph" | tee "$tmp/out"
grep -q '^semantic egraph: PASS$' "$tmp/out"
grep -q 'semantic_egraph.zag' tests/run_zagscript_release_gate.sh
grep -q 'ze_graph_new_i64' tests/semantic_egraph_test.zag
grep -q 'ze_graph_new_bool' tests/semantic_egraph_test.zag
grep -q 'ze_add_unary' tests/semantic_egraph_test.zag
grep -q 'ze_op_eq' tests/semantic_egraph_test.zag
grep -q 'ze_op_ne' tests/semantic_egraph_test.zag
echo "semantic egraph: pass (bounded pure i32/i64 arithmetic and exact bool not/and/or/eq/ne equality saturation with fail-closed domain checks; production candidate authority remains fail-closed)"
