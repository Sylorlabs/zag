#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler="${ZNC:-./znc}"
out="${TMPDIR:-/tmp}/zag_foreground_cache_test"
"$compiler" selfhost/native/foreground_cache_test.zag -o "$out" >/dev/null
"$out"
