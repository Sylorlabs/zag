#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-process-boundary.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/process_timeout_blocker.zag -o "$tmp_dir/blocker" --no-analyze --no-zagd >/dev/null
"$tmp_dir/blocker"

echo "script process boundary: PASS (legacy capture remains characterized as unbounded)"
