#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-planner-authority.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compiler=${ZNC_PLANNER_AUTHORITY_TEST:-./znc}
"$compiler" selfhost/planner_authority_test.zag \
    -o "$tmp/planner_authority_test" --no-zagd --no-analyze >/dev/null
"$tmp/planner_authority_test"

echo "planner authority: pass"
