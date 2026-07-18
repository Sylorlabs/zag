#!/usr/bin/env bash
set -euo pipefail

znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_frontend/basic.zag -o "$tmp_dir/basic" --no-analyze >/dev/null
set +e
"$tmp_dir/basic"
basic_status=$?
set -e
test "$basic_status" -eq 7

"$znc_bin" tests/script_frontend/import_root.zag -o "$tmp_dir/import-root" --no-analyze >/dev/null
set +e
"$tmp_dir/import-root"
import_status=$?
set -e
test "$import_status" -eq 9

if "$znc_bin" tests/script_frontend/duplicate.zag -o "$tmp_dir/duplicate" --no-analyze >"$tmp_dir/dup.out" 2>&1; then
    echo "duplicate script declaration unexpectedly compiled" >&2
    exit 1
fi
grep -q 'duplicate `script;` declaration' "$tmp_dir/dup.out"

if "$znc_bin" tests/script_frontend/conflicting_main.zag -o "$tmp_dir/conflict" --no-analyze >"$tmp_dir/conflict.out" 2>&1; then
    echo "script plus user main unexpectedly compiled" >&2
    exit 1
fi
grep -q 'conflicts with user-defined `main`' "$tmp_dir/conflict.out"

echo "script frontend: PASS"
