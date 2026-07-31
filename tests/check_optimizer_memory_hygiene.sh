#!/usr/bin/env bash
set -euo pipefail

root="$(cd "$(dirname "$0")/.." && pwd)"
opt="$root/selfhost/native/optimize.zag"
ra="$root/selfhost/native/regalloc.zag"
ph="$root/selfhost/native/peephole.zag"
znc="$root/selfhost/native/znc.zag"
nc="$root/selfhost/native/ncodegen.zag"
typed="$root/selfhost/typed.zag"
smf="$root/selfhost/semantic_manifest_format.zag"
smp="$root/selfhost/semantic_manifest_publish.zag"
store="$root/selfhost/zagd_store.zag"

fail() { echo "FAIL optimizer-memory: $*" >&2; exit 1; }

# Breakers are common in compiler-sized programs. Replacing either symbolic
# stack there leaks the old backing allocation and makes retained memory grow
# with control-flow count.
if grep -Eq 'stk[[:space:]]*=[[:space:]]*make\[|ms_(tag|val)[[:space:]]*=[[:space:]]*make\[' "$opt"; then
    fail "control-flow reset allocates a replacement stack"
fi

grep -q 'free\[i32\](&matched)' "$opt" || fail "matched analysis buffer is not released"
grep -q 'free\[Instr\](&folded)' "$opt" || fail "folded instruction generation is not released"
grep -q 'free\[i32\](&cands)' "$ra" || fail "regalloc candidate buffers are not released"
grep -q 'if (owns_cur == 1) { free\[Instr\](&cur); }' "$ph" || fail "peephole fixpoint generations are retained"
grep -q 'free\[Instr\](&prog2)' "$znc" || fail "foreground regalloc generation is retained"
grep -q 'free\[Instr\](&prog3)' "$znc" || fail "foreground optimizer generation is retained"
grep -q 'free\[Instr\](&opt)' "$znc" || fail "foreground peephole generation is retained"

# Native lowering creates many compiler-only containers. These are safe to
# release only after instruction emission is finished; AST nodes and text stay
# borrowed. Keep the static boundary explicit so a future refactor does not
# silently restore per-function/per-call retained backing arrays.
grep -Fq 'fn cg_env_dispose' "$nc" || fail "native lowering environment disposer is missing"
grep -Fq 'free[[]u8](&sc.names)' "$nc" || fail "native scan name map is retained"
grep -Fq 'free[[]u8](&sc.frets)' "$nc" || fail "native scan return map is retained"
grep -Fq 'free[[]u8](&seen)' "$nc" || fail "native scan seen set is retained"
grep -Fq 'cg_env_dispose(&env)' "$nc" || fail "native function environment is retained"
grep -Fq 'free[i32](&arg_slots)' "$nc" || fail "interface-dispatch argument slots are retained"
grep -Fq 'free[i32](&aslot2)' "$nc" || fail "field-call argument slots are retained"
[ "$(grep -Fc 'free[i32](&aslot)' "$nc")" -ge 2 ] || fail "direct or indirect call argument slots are retained"
grep -Fq 'free[*Node](&rargs)' "$nc" || fail "synthetic RNS call arguments are retained"
grep -Fq 'free[*Node](&alloc_args)' "$nc" || fail "synthetic Script allocation arguments are retained"
grep -Fq 'free[*Node](&qargs)' "$nc" || fail "synthetic quire call arguments are retained"
grep -Fq 'free[*Node](&const_args)' "$nc" || fail "synthetic const call arguments are retained"
grep -Fq 'fn cg_release_program_indexes' "$nc" || fail "top-level native index disposer is missing"
[ "$(grep -Fc 'cg_release_program_indexes(&syms,&rt_used,&dynamic_names)' "$nc")" -eq 2 ] || fail "top-level native indexes are not released on both exits"

# Edition-2027 typed ownership analysis repeatedly clones branch-flow state,
# including once per function on every owner-summary fixed-point pass. Joined
# states are fresh arrays: replacing the prior state without freeing it makes
# compiler memory grow with both control-flow size and summary-pass count.
grep -Fq 'fn zt_names_replace' "$typed" ||
    fail "typed name-flow replacement does not release superseded state"
grep -Fq 'fn zt_alias_replace' "$typed" ||
    fail "typed alias-flow replacement does not release superseded state"
grep -Fq 'fn zt_borrow_replace' "$typed" ||
    fail "typed borrow-flow replacement does not release superseded state"
if grep -Eq '(must|may|aliases|borrows|live)\.\*[[:space:]]*=[[:space:]]*zt_(names|alias|borrow)_(clone|agree|intersect)' "$typed"; then
    fail "typed flow overwrites a live backing array"
fi
grep -Fq 'free[[]u8](&must);free[[]u8](&may);free[ZTOwnAlias](&aliases)' "$typed" ||
    fail "owner-summary return analysis retains final flow arrays"
grep -Fq 'free[ZTOwnSummary](&sums)' "$typed" ||
    fail "owner-summary fixed-point table is retained"
grep -Fq 'free[ZTOwnAlias](&flow_aliases)' "$typed" ||
    fail "per-owner terminal flow state is retained"
grep -Fq 'free[ZTBind](&env);free[ZTBind](&locals);free[ZTOwnAlias](&aliases)' "$typed" ||
    fail "stack-address analysis retains per-function flow state"
grep -Fq 'free[ZTOwnAlias](&aliases);free[ZTBorrowAlias](&borrows)' "$typed" ||
    fail "borrow analysis retains per-function flow state"
grep -Fq 'fn zt_agg_flow_free' "$typed" ||
    fail "aggregate-provenance flow disposer is missing"
grep -Fq 'free[ZTAggProv](&flow.*.prov)' "$typed" ||
    fail "aggregate-provenance entries are retained"
grep -Fq 'free[[]u8](&flow.*.bindings)' "$typed" ||
    fail "aggregate-provenance local-binding index is retained"
grep -Fq 'free[ZTAggPathNode](&arena)' "$typed" ||
    fail "aggregate-provenance path trie is retained"
grep -Fq 'fn zt_agg_flow_replace' "$typed" ||
    fail "aggregate-provenance join replacement is missing"
grep -Fq 'zt_agg_flow_free(&base);zt_agg_flow_replace(flow,joined)' "$typed" ||
    fail "aggregate-provenance control-flow join retains a predecessor state"
grep -Fq 'free[[]u8](&decls)' "$typed" ||
    fail "typed declaration-name index is retained"

# File helpers allocate a temporary NUL-terminated syscall path. Both success
# and failure paths must release it; zagd exercises these helpers on every
# stable event, so a missing release becomes an event-proportional daemon leak.
grep -Fq 'RT_WRITEF()) == 1)  { cg.*.use_ml = 1; cg.*.use_fr = 1;' "$nc" ||
    fail "write-file runtime does not pull in __free"
grep -Fq 'RT_WRITEX()) == 1)  { cg.*.use_ml = 1; cg.*.use_fr = 1;' "$nc" ||
    fail "write-exec runtime does not pull in __free"
grep -Fq 'RT_FEXISTS()) == 1) { cg.*.use_ml = 1; cg.*.use_fr = 1;' "$nc" ||
    fail "file-exists runtime does not pull in __free"
grep -Fq 'event-proportional daemon leak' "$nc" ||
    fail "write-file path-buffer cleanup boundary is missing"
grep -Fq 'access(2) no longer needs the NUL-terminated bridge' "$nc" ||
    fail "file-exists path-buffer cleanup boundary is missing"

# The daemon cache wraps mkdir(2) and rename(2) with temporary C strings.
# These helpers run for every accepted snapshot and must release every bridge
# on both success and failure.
grep -Fq 'free[u8](&p)' "$store" ||
    fail "zagd mkdir path bridge is retained"
grep -Fq 'free[u8](&b)' "$store" ||
    fail "zagd rename destination bridge is retained"
grep -Fq 'free[u8](&a)' "$store" ||
    fail "zagd rename source bridge is retained"
grep -Fq 'success and cleanup-after-failure have identical lifetime' "$store" ||
    fail "zagd transaction lifetime boundary is missing"

# The daemon computes semantic artifact identities for every stable source
# event. These identities must extend the hash over borrowed manifest slices,
# not build a retained `_zag_str_concat` chain per declaration.
if grep -Fq '_zag_str_concat' "$smf"; then
    fail "semantic manifest identity path still concatenates runtime strings"
fi
grep -Fq 'fn smf_decl_identity_equal' "$smf" || fail "declaration identity comparison still allocates"
grep -Fq 'fn smf_hash_extend_decl_identity' "$smf" || fail "artifact identity does not hash borrowed declaration segments"
grep -Fq 'free[u8](&header)' "$smf" || fail "artifact header backing buffer is retained"
grep -Fq 'free[u8](&encoded)' "$smf" || fail "machine-link encoding buffer is retained"
[ "$(grep -Fc 'free[[]u8](&reached)' "$smf")" -eq 2 ] || fail "semantic graph closure worklists are retained"

# Foreground semantic publication uses the same syscall bridge pattern as the
# daemon store. Compiler invocations may publish more than once in a long-lived
# host, so both mkdir and rename bridges must have explicit lifetime ends.
grep -Fq 'free[u8](&p)' "$smp" ||
    fail "semantic publisher mkdir path bridge is retained"
grep -Fq 'free[u8](&a)' "$smp" ||
    fail "semantic publisher rename source bridge is retained"
grep -Fq 'free[u8](&b)' "$smp" ||
    fail "semantic publisher rename destination bridge is retained"

echo "optimizer memory hygiene: PASS"
