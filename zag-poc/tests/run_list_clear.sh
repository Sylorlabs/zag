#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zag-list-clear.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC_LIST_CLEAR_TEST:-./znc}
printf '%s\n' 'name = "list-clear"' 'version = "0.0.0"' 'edition = "2027"' > "$tmp/zag.mod"
"$compiler" tests/list_clear.zag -o "$tmp/clear" --no-zagd --no-analyze >/dev/null
"$tmp/clear"
cp tests/list_clear_resource_bad.zag "$tmp/resource_bad.zag"
if "$compiler" "$tmp/resource_bad.zag" -o "$tmp/resource" --no-zagd --analyze-strict >"$tmp/resource.log" 2>&1; then
    echo 'resource-valued list clear unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp/resource"
grep -q 'resource-valued ArrayList element operation requires explicit move semantics' "$tmp/resource.log"
echo 'list clear: PASS (scalar reuse; resource clear fail-closed)'
