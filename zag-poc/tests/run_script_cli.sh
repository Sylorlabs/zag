#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d /tmp/zag-script-cli.XXXXXX)
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" script tests/script_frontend/cli_markerless.zag \
    --cpu generic -o "$tmp_dir/markerless" --no-analyze >/dev/null
set +e
"$tmp_dir/markerless"
markerless_status=$?
set -e
test "$markerless_status" -eq 5

"$znc_bin" script tests/script_frontend/basic.zag \
    -o "$tmp_dir/already-marked" --no-analyze >/dev/null

"$znc_bin" explain tests/script_frontend/basic.zag --format json >"$tmp_dir/explain.json"
grep -q '"profile":{"value":"script","basis":"proven"}' "$tmp_dir/explain.json"
grep -q '"allocator":{"value":"unimplemented","basis":"unknown"}' "$tmp_dir/explain.json"

if "$znc_bin" explain tests/script_frontend/basic.zag --format yaml >/dev/null 2>&1; then
    echo "invalid explain format unexpectedly succeeded" >&2
    exit 1
fi
if "$znc_bin" check tests/script_frontend/basic.zag --strict >/dev/null 2>&1; then
    echo "strict script check unexpectedly succeeded" >&2
    exit 1
fi
if "$znc_bin" --cpu native tests/script_frontend/basic.zag -o "$tmp_dir/native" >/dev/null 2>&1; then
    echo "unimplemented native CPU discovery unexpectedly succeeded" >&2
    exit 1
fi

"$znc_bin" harden tests/script_frontend/basic.zag >"$tmp_dir/harden.txt"
grep -q 'status: unsupported for automatic conversion' "$tmp_dir/harden.txt"
if "$znc_bin" harden tests/script_frontend/basic.zag \
    --output "$tmp_dir/hardened.zag" >/dev/null 2>&1; then
    echo "unsupported harden output unexpectedly succeeded" >&2
    exit 1
fi
test ! -e "$tmp_dir/hardened.zag"

echo "script CLI: PASS"
