#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS Network TLS probe requires native Apple Silicon' >&2
    exit 2
fi

compiler=${ZNC:-/var/folders/kf/5y26484x0571_3cq5b2hfk3w0000gn/T/zag-tls-gen2.MUDsCE/znc-gen2}
case "$compiler" in /*) ;; *) compiler="$PWD/$compiler" ;; esac
test -x "$compiler"

work=$(mktemp -d "${TMPDIR:-/tmp}/zag-network-tls-probe.XXXXXX")
cleanup() {
    local rc=$?
    if [ "$rc" -ne 0 ] || [ "${ZAG_TEST_KEEP_WORK:-0}" = 1 ]; then
        printf 'macOS Network TLS probe: retained artifacts: %s\n' "$work" >&2
    else
        rm -rf "$work"
    fi
}
trap cleanup EXIT

build() {
    zag_run_bounded 240 "$compiler" tests/fixtures/macos_network_tls_probe/main.zag \
        --target macos-arm64 --dynamic -framework Network -framework Security \
        --no-zagd --no-analyze --no-foreground-cache -o "$1"
}

build "$work/first"
build "$work/repeat"
cmp "$work/first" "$work/repeat"
file -b "$work/first" | grep -q 'Mach-O 64-bit executable arm64'
codesign --verify --deep --strict "$work/first"

otool -L "$work/first" >"$work/deps"
grep -Fq '/usr/lib/libSystem.B.dylib' "$work/deps"
grep -Fq '/System/Library/Frameworks/Network.framework/Versions/A/Network' "$work/deps"
grep -Fq '/System/Library/Frameworks/Security.framework/Versions/A/Security' "$work/deps"
if grep -Eq 'libssl|libcrypto|Homebrew|/opt/' "$work/deps"; then
    echo 'macOS Network TLS probe picked up a non-system TLS dependency' >&2
    exit 1
fi

set +e
zag_run_bounded 30 "$work/first"
probe_rc=$?
set -e
if [ "$probe_rc" -ne 42 ]; then
    echo "macOS Network TLS probe failed at runtime (exit=$probe_rc)" >&2
    exit 1
fi

echo 'macOS Network TLS probe: PASS TLS1.3 options + native block callback + system-only frameworks'
