#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
QEMU=${QEMU:-qemu-aarch64-static}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac

if ! command -v "$QEMU" >/dev/null 2>&1; then
    echo "arm64 aggregate copy witness requires $QEMU" >&2
    exit 1
fi

tmp=$(mktemp -d /tmp/zag-arm64-aggregate-copy.XXXXXX)
cleanup() { if [ "${KEEP_TMP:-0}" != 1 ]; then rm -rf "$tmp"; else echo "kept $tmp" >&2; fi; }
trap cleanup EXIT

cp tests/x86_aggregate_param_copy.zag "$tmp/main.zag"
printf 'name = "aggregate-param-copy"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"

if ! (cd "$tmp" && "$ZNC" main.zag --target arm64 --no-zagd --no-analyze --no-foreground-cache -o app >build.log 2>&1); then
    echo "arm64 aggregate copy witness did not compile" >&2
    sed -n '1,80p' "$tmp/build.log" >&2
    exit 1
fi
set +e
"$QEMU" "$tmp/app"
rc=$?
set -e

if [ "$rc" -ne 42 ]; then
    echo "arm64 aggregate parameter copy witness returned $rc" >&2
    sed -n '1,80p' "$tmp/build.log" >&2
    exit 1
fi

echo "arm64 aggregate copy: parameter, indexed, and switch-produced nested values pass"
