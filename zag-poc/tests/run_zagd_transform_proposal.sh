#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-transform-proposal.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" tests/zagd_transform_proposal_test.zag -o "$tmp/test" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test" | tee "$tmp/out"
grep -q '^zagd transform proposal: PASS$' "$tmp/out"
"$compiler" tests/zagd_transform_proposal_fixture.zag -o "$tmp/fixture" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
grep -q 'zagd_transform_proposal.zag' tests/run_zagscript_release_gate.sh
if rg -n 'executable_authority[[:space:]]*=[[:space:]]*1|_zag_exec_cmd|zagd_execute_finalist' \
    selfhost/zagd_transform_proposal.zag; then
  echo 'transform proposal unexpectedly gained execution authority' >&2
  exit 1
fi

# Production handoff witness: a present but malformed daemon proposal must
# disable automatic consumption and leave the raw baseline selected. Removing
# the record restores the existing local source-policy transform, proving that
# the optional handoff is an additional fail-closed gate rather than a new
# source of optimizer authority.
mkdir -p "$tmp/project/.zag-cache/zagd"
printf 'name = "proposal-integration"\nedition = "2026"\n' >"$tmp/project/zag.mod"
printf 'mode=off\nregular_optimization=automatic\n' >"$tmp/project/.zagd.conf"
cat >"$tmp/project/main.zag" <<'ZAG'
fn main() i32 {
    let x:i32 = 2147483647 + 1;
    if (x < 0) { return 42; }
    return 1;
}
ZAG
printf 'not-a-transform-proposal\n' >"$tmp/project/.zag-cache/zagd/transform-proposal.record"
"$compiler" view "$tmp/project/main.zag" --level native --no-analyze \
  >"$tmp/invalid-view"
grep -Eq 'semantic-transform-status=(verified_no_transform|verified_raw_ast_bridge_incomplete) rule=none checker=not-run transform_count=0 artifact_transform_consumed=0' \
  "$tmp/invalid-view"
rm -f "$tmp/project/.zag-cache/zagd/transform-proposal.record"
"$compiler" view "$tmp/project/main.zag" --level native --no-analyze \
  >"$tmp/absent-view"
grep -q 'semantic-transform-status=foreground_source_policy_checked rule=const-i32-add-v1 checker=const-i32-add-source-policy-check-v1 transform_count=1 artifact_transform_consumed=1' \
  "$tmp/absent-view"

# A checksummed proposal made for the old source must not become authority
# after a source-only edit that leaves the folded operation's origin ids
# unchanged. This specifically exercises semantic-record freshness rather
# than merely malformed-envelope rejection.
"$compiler" "$tmp/project/main.zag" -o "$tmp/project/old" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/fixture" "$tmp/project/main.zag" \
  "$tmp/project/.zag-cache/zagd/semantic.record" "$PWD/znc" \
  "$tmp/project/.zag-cache/zagd/transform-proposal.record" current
printf '\n// source changed after the semantic snapshot\n' >>"$tmp/project/main.zag"
"$compiler" view "$tmp/project/main.zag" --level native --no-analyze \
  >"$tmp/stale-semantic-view"
grep -Eq 'semantic-transform-status=(verified_no_transform|verified_raw_ast_bridge_incomplete) rule=none checker=not-run transform_count=0 artifact_transform_consumed=0' \
  "$tmp/stale-semantic-view"

# Keep the semantic snapshot current but forge a checksummed proposal whose
# source binding names a different source. The envelope decoder accepts it,
# while the foreground source binding must reject it and retain the baseline.
"$compiler" "$tmp/project/main.zag" -o "$tmp/project/current" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/fixture" "$tmp/project/main.zag" \
  "$tmp/project/.zag-cache/zagd/semantic.record" "$PWD/znc" \
  "$tmp/project/.zag-cache/zagd/transform-proposal.record" stale
"$compiler" view "$tmp/project/main.zag" --level native --no-analyze \
  >"$tmp/stale-proposal-view"
grep -Eq 'semantic-transform-status=(verified_no_transform|verified_raw_ast_bridge_incomplete) rule=none checker=not-run transform_count=0 artifact_transform_consumed=0' \
  "$tmp/stale-proposal-view"
rm -f "$tmp/project/.zag-cache/zagd/transform-proposal.record"
echo 'zagd transform proposal: pass (source-bound checker-only envelope; no executable authority)'
