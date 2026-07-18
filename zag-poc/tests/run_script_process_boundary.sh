#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-process-boundary.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/process_timeout_blocker.zag -o "$tmp_dir/blocker" --no-analyze --no-zagd >/dev/null
"$tmp_dir/blocker"

if "$znc_bin" tests/process_timeout_unavailable.zag -o "$tmp_dir/unsafe" --no-analyze --no-zagd \
    >"$tmp_dir/unavailable.out" 2>&1; then
    echo "unsafe bounded-process convenience unexpectedly compiled" >&2
    exit 1
fi
grep -q 'unknown function' "$tmp_dir/unavailable.out"
echo "script process boundary: PASS (bounded API remains unavailable)"
