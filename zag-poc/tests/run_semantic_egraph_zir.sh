#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d /tmp/zag-semantic-egraph-zir.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
# The executable PASS line alone is not sufficient evidence for this focused
# contract: a stale extraction-only fixture could retain it after dropping the
# source-only proposal/checker seam. Keep the fixture's required witnesses
# fail-closed at the source boundary before compiling it.
for witness in \
    'arith.negsi' \
    'arith.xori' \
    'arith.orsi' \
    'arith.shli' \
    'arith.shrsi' \
    'ze_egraph_check_eval_shift' \
    'ze_zir_extract_function_i64' \
    'ze_zir_extract_function_bool' \
    'ze_egraph_propose_const_i64_fold' \
    'i64 proposal accepted' \
    'reject checksum-valid i64 candidate mutation' \
    'ze_egraph_propose_const_bool_cmp_fold' \
    'bool comparison proposal accepted' \
    'bool comparison ne folds to one' \
    'reviewed foreground bool handoff accepted' \
    'unreviewed bool handoff falls back' \
    'reviewed bool handoff rejects mutated candidate' \
    'reviewed bool handoff rejects other domain' \
    'reject checksum-valid bool candidate mutation' \
    'reject non-eq-ne bool comparison' \
    'reject effectful bool comparison' \
    'ze_egraph_propose_const_i32_fold' \
    'ze_egraph_check_proposal' \
    'reject checksum-valid candidate mutation' \
    'reject checksum-valid unchanged-op mutation' \
    'reject non-i32 return domain' \
    'addi overflow rejected' \
    'subi overflow rejected' \
    'muli overflow rejected' \
    'i32 negsi constant fold' \
    'i32 negsi MIN rejected' \
    'i32 negsi/xor/and/or checker bounds' \
    'i32 integer XOR extraction' \
    'i32 integer AND extraction' \
    'i32 integer OR extraction' \
    'i32 integer OR wrong result type rejected' \
    'i64 add overflow rejected' \
    'i64 sub overflow rejected' \
    'i64 mul overflow rejected' \
    'i64 negsi constant fold' \
    'i64 negsi MIN rejected' \
    'i64 negsi/xor/and/or checker bounds' \
    'i64 integer XOR extraction' \
    'i64 integer AND extraction' \
    'i64 integer OR extraction' \
    'i64 integer OR wrong result type rejected' \
    'i32 shli 3<<4' \
    'i32 arithmetic shrsi negative' \
    'i32 shli overflow rejected' \
    'i32 shift count==width rejected' \
    'i32 negative shift count rejected' \
    'i32 malformed shift width rejected' \
    'i32 mismatched shift type rejected' \
    'i64 shrsi 128>>3' \
    'i64 arithmetic shrsi negative' \
    'i64 shift count==width rejected' \
    'i64 shli overflow rejected' \
    'i64 malformed shift width rejected' \
    'i64 mismatched shift type rejected' \
    'independent shift checker bounds' \
    'reject shift in bool domain' \
    'i64 divsi min/-1 rejected' \
    'i64 remsi min/-1 rejected' \
    'i64 inexact origin rejected' \
    'bool region valid and non-authoritative' \
    'bool malformed literal rejected' \
    'bool inexact origin rejected' \
    'bool effect rejected' \
    'bool return type rejected' \
    'bool predicate region valid and non-authoritative' \
    'bool predicate ops accepted' \
    'bool predicate values folded' \
    'bool standalone/bridge differential' \
    'bool short-circuit rejected' \
    'bool non-bool operation rejected' \
    'bool comparison predicate rejected' \
    'bool predicate origin rejected' \
    'bool predicate effect rejected' \
    'bool predicate duplicate attrs rejected' \
    'i32 21&1 is not 21' \
    'reject bool-only op in integer graph' \
    'reject integer-only op in bool graph' \
    'i32 zero-operand return rejected' \
    'i32 post-return operation rejected' \
    'i32 return-earlier result rejected' \
    'i64 zero-operand return rejected' \
    'i64 post-return operation rejected' \
    'i64 return-earlier result rejected' \
    'bool zero-operand return rejected' \
    'bool post-return operation rejected' \
    'bool return-earlier result rejected' \
    'i32 equivalent earlier return rejected' \
    'i32 duplicate constant attrs rejected' \
    'i32 arithmetic attrs rejected' \
    'i64 arithmetic attrs rejected' \
    'i64 return attrs rejected' \
    'bool return attrs rejected' \
    'independent i32 overflow/div/rem checker bounds' \
    'independent i64 overflow/div/rem checker bounds' \
    'i64 shift count beyond i32 rejected' \
    'i64 INT64_MAX shift count rejected' \
    'i32 MIN shrsi boundary' \
    'i32 MIN shli zero boundary' \
    'i32 MAX shrsi zero boundary' \
    'i64 MIN shrsi boundary' \
    'i64 MIN shli zero boundary' \
    'i64 MAX shrsi zero boundary' \
    'independent i64 count beyond i32 checker' \
    'independent INT64_MAX count checker' \
    'independent i32 MIN shrsi boundary' \
    'independent i32 MIN shli zero boundary' \
    'independent i32 MAX shrsi zero boundary' \
    'independent i64 MIN shrsi boundary' \
    'independent i64 MIN shli zero boundary' \
    'independent i64 MAX shrsi zero boundary'
do
    grep -Fq "$witness" tests/semantic_egraph_zir_test.zag
done
grep -Fq 'fn ze_op_neg' selfhost/semantic_egraph.zag
grep -Fq 'fn ze_op_shl' selfhost/semantic_egraph.zag
grep -Fq 'fn ze_op_shr' selfhost/semantic_egraph.zag
grep -Fq 'fn ze_egraph_propose_const_bool_cmp_fold' selfhost/semantic_egraph_zir.zag
grep -Fq 'fn ze_egraph_check_bool_proposal' selfhost/semantic_egraph_zir.zag
"$compiler" tests/semantic_egraph_zir_test.zag -o "$tmp/egraph-zir" --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/egraph-zir" | tee "$tmp/out"
grep -q '^semantic egraph ZIR bridge: PASS$' "$tmp/out"
echo "semantic egraph ZIR bridge: pass (pure i32/i64 arithmetic including exact-width checked shifts, exact bool predicate extraction, closed attributes/latest-SSA returns, independent reference checkers, and reviewed foreground handoff with short-circuit/effect/type/origin rejection; executable authority remains disabled)"
