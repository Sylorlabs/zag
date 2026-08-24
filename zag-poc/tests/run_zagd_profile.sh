#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler="${ZNC:-./znc}"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-profile.XXXXXX")
trap 'find "$tmp" -depth -delete' EXIT
out="$tmp/zagd_profile_test"
"$compiler" selfhost/zagd_profile_test.zag -o "$out" --no-zagd >/dev/null
"$out"

# The build path consumes profile data automatically but reports an ordinary
# fail-closed miss when no exact current v3 plan exists. Opt-out remains an
# explicit, painless one-shot choice and neither path changes executable truth.
mkdir -p "$tmp/project"
printf 'name = "foreground-profile-fixture"\n' >"$tmp/project/zag.mod"
printf 'fn main() i32 { return 17; }\n' >"$tmp/project/main.zag"
"$compiler" "$tmp/project/main.zag" -o "$tmp/project/app" --profile-report \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/miss.log"
grep -q '^znc profile: METADATA-MISS .* codegen_effect=none cache_key_effect=none$' "$tmp/miss.log"
set +e
"$tmp/project/app"
rc=$?
set -e
test "$rc" -eq 17
"$compiler" "$tmp/project/main.zag" -o "$tmp/project/app-disabled" --profile-report \
    --no-zagd-profile --no-zagd --no-analyze --no-foreground-cache >"$tmp/disabled.log"
grep -q '^znc profile: METADATA-MISS reason=disabled-by-command codegen_effect=none cache_key_effect=none$' "$tmp/disabled.log"
cmp "$tmp/project/app" "$tmp/project/app-disabled"
echo 'zagd foreground profile integration: PASS'
