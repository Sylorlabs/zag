#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
out="${TMPDIR:-/tmp}/zagd_profile_test"
"${ZNC:-./znc}" selfhost/zagd_profile_test.zag -o "$out" >/dev/null
"$out"
