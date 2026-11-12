#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/../.."
root=$PWD
out="$root/research/nexus/evidence"
mkdir -p "$out"
znc=${ZNC:-/Users/Shared/micah/Documents/TNN/.bin/znc}
bin="$root/research/nexus/nexus-bin"

"$znc" --target macos-arm64 --no-zagd --no-analyze --no-foreground-cache \
  research/nexus/nexus.zag -o "$bin" >"$out/compile.log" 2>&1

shasum -a 256 research/nexus/nexus.zag "$znc" "$bin" >"$out/hashes.sha256"
file "$znc" "$bin" >"$out/formats.txt"

for mode in unified no-cross knowledge-erased investigation-erased no-compose fresh modular \
  development dev-no-pred dev-no-investigation dev-no-learning dev-all dev-modular; do
  "$bin" "$mode" >"$out/$mode.txt"
done
rm -f "$out/state.bin"
"$bin" persist-write "$out/state.bin" >"$out/persist-write.txt"
"$bin" persist-read "$out/state.bin" >"$out/persist-read.txt"
rm -f "$out/dev-state.bin"
"$bin" dev-persist-write "$out/dev-state.bin" >"$out/dev-persist-write.txt"
"$bin" dev-persist-read "$out/dev-state.bin" >"$out/dev-persist-read.txt"

echo "NEXUS experiment complete: $out"
