#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
case "$compiler" in
    /*) compiler_abs=$compiler ;;
    *) compiler_abs="$PWD/${compiler#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-auto-transform.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

mkdir -p "$tmp/automatic" "$tmp/regular" "$tmp/off" "$tmp/review" "$tmp/nomatch"
for profile in automatic off review; do
    printf 'name = "script-auto-%s"\nedition = "2026"\n' "$profile" >"$tmp/$profile/zag.mod"
done
printf 'script_optimization=automatic\n' >"$tmp/automatic/.zagd.conf"
printf 'script_optimization=off\n' >"$tmp/off/.zagd.conf"
printf 'script_optimization=review\n' >"$tmp/review/.zagd.conf"
cat >"$tmp/automatic/main.zag" <<'ZAG'
script;
let x:i32 = 2147483647 + 1;
if (x < 0) { return 42; }
return 1;
ZAG
cp "$tmp/automatic/main.zag" "$tmp/off/main.zag"
cp "$tmp/automatic/main.zag" "$tmp/review/main.zag"
cat >"$tmp/regular/zag.mod" <<'ZAGMOD'
name = "regular-auto"
edition = "2026"
ZAGMOD
printf 'regular_optimization=automatic\n' >"$tmp/regular/.zagd.conf"
cat >"$tmp/regular/main.zag" <<'ZAG'
fn main() i32 {
    let x:i32 = 2147483647 + 1;
    if (x < 0) { return 42; }
    return 1;
}
ZAG
cat >"$tmp/nomatch/zag.mod" <<'ZAGMOD'
name = "script-auto-nomatch"
edition = "2026"
ZAGMOD
printf 'script_optimization=automatic\n' >"$tmp/nomatch/.zagd.conf"
cat >"$tmp/nomatch/main.zag" <<'ZAG'
script;
let x:i32 = 1;
if (x == 1) { return 42; }
return 1;
ZAG

build_and_run() {
    local profile=$1
    local output=$2
    (cd "$tmp/$profile" && "$compiler_abs" main.zag -o "$output" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null)
    set +e
    "$output"
    local rc=$?
    set -e
    test "$rc" -eq 42
}

build_and_run automatic "$tmp/automatic/app"
"$compiler_abs" view "$tmp/automatic/main.zag" --level native --no-zagd \
    >"$tmp/automatic/view"
grep -q '^// semantic-transform-status=verified_raw_ast_bridge_incomplete rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/automatic/view"

build_and_run regular "$tmp/regular/app"
"$compiler_abs" view "$tmp/regular/main.zag" --level native --no-zagd \
    >"$tmp/regular/view"
grep -q '^// semantic-transform-status=foreground_source_policy_checked rule=const-i32-add-v1 checker=const-i32-add-source-policy-check-v1 transform_count=1 artifact_transform_consumed=1$' \
    "$tmp/regular/view"

build_and_run off "$tmp/off/app"
"$compiler_abs" view "$tmp/off/main.zag" --level native --no-zagd \
    >"$tmp/off/view"
grep -q '^// semantic-transform-status=verified_raw_ast_bridge_incomplete rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/off/view"

build_and_run review "$tmp/review/app"
"$compiler_abs" view "$tmp/review/main.zag" --level native --no-zagd \
    >"$tmp/review/view"
grep -q '^// semantic-transform-status=verified_raw_ast_bridge_incomplete rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/review/view"

build_and_run nomatch "$tmp/nomatch/app"
"$compiler_abs" view "$tmp/nomatch/main.zag" --level native --no-zagd \
    >"$tmp/nomatch/view"
grep -q '^// semantic-transform-status=verified_raw_ast_bridge_incomplete rule=none checker=not-run transform_count=0 artifact_transform_consumed=0$' \
    "$tmp/nomatch/view"

# Automatic Script selection is evidence-gated. Keep these source-level
# assertions beside the no-daemon baseline cases so a compiler rebuild cannot
# silently restore local transform selection without the current measured
# winner envelope and foreground revalidation.
grep -q 'fn znc_script_zagd_winner_current' selfhost/native/znc.zag
grep -q 'fn znc_script_zagd_automatic_authority' selfhost/native/znc.zag
grep -q 'verified_best_measured' selfhost/native/znc.zag
grep -q 'zagd_benchmark_evidence_payloads_current' selfhost/native/znc.zag
grep -q 'znc_optimize_zagd_selector_current' selfhost/native/znc.zag
grep -q 'authority.certificate.valid' selfhost/native/znc.zag
# The metadata dispatcher is intentionally limited to the independent
# foreground rules. Keep each spelling asserted so a new daemon label cannot
# silently become executable Script authority without a matching certificate.
for rule in const-i32-add-v1 const-i32-neg-v1 const-i64-add-v1 const-bool-cmp-v1; do
    grep -Fq "@strEq(record.transform, \"$rule\")" selfhost/native/znc.zag
done
grep -Fq 'znc_script_zagd_winner_current(path, source, unit, selected)' selfhost/native/znc.zag

echo 'Planner automatic transform: regular checked candidate, Script raw fallback, and policy off/review pass'
