#!/usr/bin/env bash
set -euo pipefail
export LC_ALL=C
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-generation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/state"

"$ZNC_BIN" selfhost/zagd_generation_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/test" "$tmp/state"

# This is a metadata-only stable-mode foundation. It must not silently broaden
# the unavailable generational-self-modification capability or gain an executor.
grep -Eq '^generation[[:space:]]+sandboxed optimizer generation promotion and rollback[[:space:]]+unavailable[[:space:]]' \
    tests/zagscript_1_0_capabilities.tsv
grep -q 'optimizer_generation","unimplemented"' selfhost/zagd_daemon.zag
if grep -Eq '_zag_exec_cmd|zagd_execute_finalist|execution_enabled[[:space:]]*=[[:space:]]*1' \
    selfhost/zagd_generation.zag; then
    echo "zagd generation registry unexpectedly gained execution authority" >&2
    exit 1
fi
if find "$tmp/state/.zag-cache/zagd" -mindepth 1 -type d -print -quit | grep -q .; then
    echo "zagd generation registry violated the flat cache contract" >&2
    exit 1
fi
grep -q '^generation_execution=disabled$' \
    "$tmp/state/.zag-cache/zagd/generation-pointers.record"
echo "zagd generation registry: pass (stable metadata only; synthesis and execution unavailable)"
