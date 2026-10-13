#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-evidence.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

"$compiler" selfhost/evidence_codec_test.zag -o "$tmp/evidence" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || {
    cat "$tmp/build.log" >&2
    exit 1
}
"$tmp/evidence" | tee "$tmp/run.log"
grep -q '^evidence-codec checks=39 fail=0$' "$tmp/run.log"
