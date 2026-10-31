#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-range.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_range.zag -o "$tmp_dir/range" --no-zagd --no-analyze >/dev/null
"$tmp_dir/range"

cat >"$tmp_dir/bad.zag" <<'EOF'
script;
let values = range(0, 3);
return 0;
EOF
if "$znc_bin" "$tmp_dir/bad.zag" -o "$tmp_dir/bad" --no-zagd --no-analyze >"$tmp_dir/bad.log" 2>&1; then
    echo 'range arity negative unexpectedly compiled' >&2
    exit 1
fi
grep -q 'range expects start, end, and step' "$tmp_dir/bad.log"

echo 'script range: PASS'
