#!/usr/bin/env bash
set -euo pipefail
root=$(cd "$(dirname "$0")/.." && pwd)
source "$root/tests/portable.sh"
compiler=${ZNC:-$(zag_native_compiler "$root")}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-saturation.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
"$compiler" "$root/selfhost/zagd_saturation_test.zag" -o "$tmp/test" --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1 || { cat "$tmp/build.log" >&2; exit 1; }
"$tmp/test"
ZNC="$compiler" bash "$root/tests/run_script_auto.sh"
echo 'zagd typed semantic region extraction + bounded equality saturation: PASS'
