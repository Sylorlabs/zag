#!/usr/bin/env bash
# Documentation examples are release artifacts.  Compile them in a disposable
# directory without running file/process examples, so the suite verifies their
# syntax and lowering without depending on local input files or commands.
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
case "$compiler" in
    /*) ;;
    *) compiler="$(pwd)/${compiler#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-script-examples.XXXXXX)
trap 'rm -rf "$tmp"' EXIT

for example in script_hello script_files script_process script_collections script_harden; do
    cp "examples/$example.zag" "$tmp/$example.zag"
    "$compiler" check "$tmp/$example.zag" --no-zagd --no-analyze >/dev/null
done

echo 'Zag Script examples: PASS'
