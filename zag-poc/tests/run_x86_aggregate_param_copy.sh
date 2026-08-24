#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac

tmp=$(mktemp -d /tmp/zag-x86-aggregate-copy.XXXXXX)
cleanup() { if [ "${KEEP_TMP:-0}" != 1 ]; then rm -rf "$tmp"; else echo "kept $tmp" >&2; fi; }
trap cleanup EXIT

cp tests/x86_aggregate_param_copy.zag "$tmp/main.zag"
printf 'name = "aggregate-param-copy"\nversion = "0"\nedition = "2027"\n' >"$tmp/zag.mod"

if ! (cd "$tmp" && "$ZNC" main.zag --no-zagd --no-analyze --no-foreground-cache -o app >build.log 2>&1); then
    echo "aggregate copy witness did not compile" >&2
    sed -n '1,80p' "$tmp/build.log" >&2
    exit 1
fi
set +e
"$tmp/app"
rc=$?
set -e

if [ "$rc" -ne 42 ]; then
    echo "aggregate parameter copy witness returned $rc" >&2
    sed -n '1,80p' "$tmp/build.log" >&2
    exit 1
fi

echo "x86 aggregate copy: parameter, indexed, and switch-produced nested values pass"
