#!/usr/bin/env bash
set -euo pipefail
root="$(cd "$(dirname "$0")/.." && pwd)"
compiler="${ZNC_BIN:?set ZNC_BIN to an absolute pinned native compiler path}"
out_dir="${SENTINEL_OUTPUT:-$(mktemp -d /tmp/sentinel-casts.XXXXXX)}"
mkdir -p "$out_dir"
"$compiler" "$root/tests/fixtures/sentinel_narrow_cast_matrix.zag" --target macos-arm64 --no-zagd -o "$out_dir/matrix" >"$out_dir/compile.stdout" 2>"$out_dir/compile.stderr"
"$out_dir/matrix" >"$out_dir/actual.stdout" 2>"$out_dir/runtime.stderr"
shasum -a 256 "$compiler" "$root/tests/fixtures/sentinel_narrow_cast_matrix.zag" "$out_dir/matrix" "$out_dir/actual.stdout"
diff -u "$root/tests/fixtures/sentinel_narrow_cast_matrix.expected" "$out_dir/actual.stdout"
