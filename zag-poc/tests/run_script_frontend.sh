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

# A top-level return exits only the hidden body; the generated wrapper still
# owns deterministic shutdown and preserves the requested process status.
"$znc_bin" tests/script_frontend/top_level_return.zag -o "$tmp_dir/top-return" --no-analyze >/dev/null
set +e
"$tmp_dir/top-return"
return_status=$?
set -e
test "$return_status" -eq 23

# An uncaught top-level error is caught by the generated process wrapper and
# becomes a deterministic nonzero status. Error-name witnesses are not yet
# available here, so the compiler deliberately does not fabricate one.
"$znc_bin" tests/script_frontend/uncaught_error.zag -o "$tmp_dir/uncaught" --no-analyze >/dev/null
set +e
"$tmp_dir/uncaught"
uncaught_status=$?
set -e
test "$uncaught_status" -eq 1

"$znc_bin" tests/script_frontend/import_root.zag -o "$tmp_dir/import-root" --no-analyze >/dev/null
set +e
"$tmp_dir/import-root"
import_status=$?
set -e
test "$import_status" -eq 9

"$znc_bin" tests/script_frontend/materialized_args.zag -o "$tmp_dir/materialized-args" --no-analyze >/dev/null
"$tmp_dir/materialized-args" alpha beta

"$znc_bin" tests/script_frontend/path_helpers.zag -o "$tmp_dir/path-helpers" --no-analyze >/dev/null
"$tmp_dir/path-helpers"

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

if "$znc_bin" tests/script_frontend/reserved_symbol.zag -o "$tmp_dir/reserved" --no-analyze >"$tmp_dir/reserved.out" 2>&1; then
    echo "compiler-owned script symbol unexpectedly accepted" >&2
    exit 1
fi
grep -q 'compiler-owned script symbol' "$tmp_dir/reserved.out"

echo "script frontend: PASS"
