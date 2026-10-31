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
grep -Eq '^generation[[:space:]]+sandboxed optimizer generation promotion and rollback[[:space:]]+partial[[:space:]]' \
    tests/zagscript_1_0_capabilities.tsv
grep -q 'optimizer_generation","metadata-only"' selfhost/zagd_daemon.zag
# The metadata foundation must be part of the real daemon lifecycle, not only
# a standalone codec test: startup prepares/loads the registry, status exposes
# its fail-closed state, and clean shutdown closes the canary. These assertions
# deliberately do not authorize generation execution.
grep -q '^@import("zagd_generation.zag")' selfhost/zagd_daemon.zag
grep -q 'zagd_generation_load_bound(root,zag_version()' selfhost/zagd_daemon.zag
grep -q 'zagd_generation_prepare_stable_bound(root' selfhost/zagd_daemon.zag
grep -q 'zagd_generation_finish_stable_bound(' selfhost/zagd_daemon.zag
grep -q 'zagd_status_line(out,"generation_execution","disabled")' selfhost/zagd_daemon.zag
grep -q 'zagd_status_line(out,"generation_trust_mode",trust_mode)' selfhost/zagd_daemon.zag
grep -q 'generation_compiler_first' selfhost/zagd_daemon.zag
grep -q 'generation_verifier_first' selfhost/zagd_daemon.zag
grep -q 'generation_policy_first' selfhost/zagd_daemon.zag
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
# The registry gate also carries the bounded admission seam for any future
# generated worker.  Keep this nested so the matrix's single generation
# evidence row exercises both lifecycle metadata and the fail-closed worker
# boundary without implying executable self-modification.
ZNC_GENERATION_WORKER_TEST="$ZNC_BIN" bash tests/run_zagd_generation_worker.sh
echo "zagd generation registry: pass (stable metadata only; synthesis and execution unavailable)"
