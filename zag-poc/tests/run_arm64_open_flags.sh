#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-arm64-open-flags.XXXXXX")
trap 'rm -rf -- "$work"' EXIT HUP INT TERM

if [ "$(uname -m)" = aarch64 ]; then
    runner=""
else
    runner=${QEMU:-qemu-aarch64-static}
    if ! command -v "$runner" >/dev/null 2>&1; then
        echo "arm64 open-flags witness requires $runner" >&2
        exit 1
    fi
fi

binary="$work/open-flags"
created="$work/created"
symlink="$work/final-symlink"
ln -s -- "$created" "$symlink"

if ! "$compiler" tests/aarch64_open_flags_runtime.zag --target arm64 \
    -o "$binary" --no-zagd --no-analyze --no-foreground-cache \
    >"$work/build.log" 2>&1; then
    echo "arm64 open-flags witness did not compile" >&2
    sed -n '1,80p' "$work/build.log" >&2
    exit 1
fi
if ! file "$binary" | grep -q 'ARM aarch64'; then
    echo "arm64 open-flags witness is not an AArch64 ELF" >&2
    exit 1
fi

set +e
if [ -n "$runner" ]; then
    "$runner" "$binary" "$created" "$symlink"
else
    "$binary" "$created" "$symlink"
fi
status=$?
set -e

if [ "$status" -ne 42 ] || [ ! -f "$created" ]; then
    echo "arm64 open-flags witness failed: exit=$status created=$([ -f "$created" ] && echo yes || echo no)" >&2
    exit 1
fi

echo "arm64 open flags: syscall-2 create/exclusive and syscall-257 rejection pass"
