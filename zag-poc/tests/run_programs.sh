#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in
    /*) ;;
    *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-programs.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

for name in arena csv_parser hash_map json_parser sort_bench state_machine; do
    if "$ZNC" "programs/$name.zag" -o "$tmp/$name" >/dev/null 2>&1 && \
       "$tmp/$name" >/dev/null 2>&1; then
        echo "  ok  $name"
        pass=$((pass + 1))
    else
        echo "  XX  $name"
        fail=$((fail + 1))
    fi
done

echo "════ programs pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
