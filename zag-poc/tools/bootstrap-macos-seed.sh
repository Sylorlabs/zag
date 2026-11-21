#!/usr/bin/env bash
# Safely introduce a downloaded, full-native-gate macOS compiler into a clean
# source checkout, then replace it with a fixed-point compiler built from the
# checkout's own source. This script never downloads or chooses trust for the
# user: both the seed and its independently reviewed checksum are explicit.
set -euo pipefail

usage() {
    cat >&2 <<'USAGE'
usage: tools/bootstrap-macos-seed.sh [--verify-only] SEED SHA256_FILE

SEED must be `znc-macos-arm64` from a native-gate-verified CI artifact, or
`znc` from a verified macos-arm64 release archive. SHA256_FILE must contain its
published 64-hex-digit SHA-256 record. Review the workflow run/SOURCE_COMMIT or
the signed release tag before treating that artifact as trusted.
USAGE
}

verify_only=0
case "${1:-}" in
    -h|--help)
        usage
        exit 0
        ;;
    --verify-only)
        verify_only=1
        shift
        ;;
esac
if [ "$#" -ne 2 ]; then
    usage
    exit 2
fi

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd -P)
. "$root/tests/portable.sh"

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo "macOS seed bootstrap requires native Apple Silicon (got $(uname -s) $(uname -m))." >&2
    exit 2
fi

seed_input=$1
checksum_input=$2
if [ ! -f "$seed_input" ]; then
    echo "macOS seed bootstrap: seed is not a regular file: $seed_input" >&2
    exit 1
fi
if [ ! -f "$checksum_input" ]; then
    echo "macOS seed bootstrap: checksum is not a regular file: $checksum_input" >&2
    exit 1
fi
checksum_records=$(awk 'NF { count += 1 } END { print count + 0 }' "$checksum_input")
if [ "$checksum_records" -ne 1 ]; then
    echo "macOS seed bootstrap: checksum file must contain exactly one non-empty record." >&2
    exit 1
fi
checksum_line=$(awk 'NF { print; exit }' "$checksum_input")
expected_digest=${checksum_line%%[[:space:]]*}
expected_digest=$(printf '%s\n' "$expected_digest" | tr 'A-F' 'a-f')
case "$expected_digest" in
    *[!0-9a-f]*|'')
        echo "macOS seed bootstrap: checksum file does not start with a SHA-256 digest." >&2
        exit 1
        ;;
esac
if [ "${#expected_digest}" -ne 64 ]; then
    echo "macOS seed bootstrap: checksum digest must contain exactly 64 hex digits." >&2
    exit 1
fi

actual_digest=$(zag_sha256_file "$seed_input")
if [ "$actual_digest" != "$expected_digest" ]; then
    echo "macOS seed bootstrap: seed checksum mismatch." >&2
    echo "  expected: $expected_digest" >&2
    echo "  actual:   $actual_digest" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-macos-seed.XXXXXX")
cleanup() { rm -rf "$tmp"; }
trap cleanup EXIT HUP INT TERM

# Do not carry Finder quarantine, provenance xattrs, or executable-mode loss
# from the downloaded ZIP into the ephemeral seed copy. Byte identity was
# checked immediately above; Mach-O identity and its embedded signature are
# checked immediately below before the first execution.
COPYFILE_DISABLE=1 cp "$seed_input" "$tmp/znc-macos-arm64"
chmod 755 "$tmp/znc-macos-arm64"
if ! zag_assert_native_executable "$tmp/znc-macos-arm64"; then
    echo "macOS seed bootstrap: seed is not a valid signed ARM64 Mach-O executable." >&2
    exit 1
fi

echo "== verified macOS seed sha256=$actual_digest =="
if [ "$verify_only" -eq 1 ]; then
    echo "   verification only; checkout tools were not changed"
    exit 0
fi

ZAG_BOOTSTRAP_SEED="$tmp/znc-macos-arm64" \
ZAG_BOOTSTRAP_OUTPUT="$root/znc-macos-arm64" \
ZAG_BOOTSTRAP_DAEMON_OUTPUT="$root/zagd-macos-arm64" \
    bash "$root/bootstrap.sh"

# Bootstrap already converges before installation. This independent empty-PATH
# proof additionally binds the installed compiler bytes to the current source
# snapshot and rejects a seed/source mismatch or a non-reproducible generation.
ZNC_SEED="$root/znc-macos-arm64" \
    bash "$root/tests/check_native_bootstrap_repro.sh"

"$root/znc-macos-arm64" "$root/selfhost/lsp/zag-lsp.zag" \
    --target macos-arm64 --no-zagd -o "$root/zag-lsp-macos-arm64"
if ! zag_assert_native_executable "$root/zag-lsp-macos-arm64"; then
    echo "macOS seed bootstrap: generated LSP is not a valid signed ARM64 Mach-O executable." >&2
    exit 1
fi

echo "== Apple-Silicon checkout tools are ready =="
echo "   compiler: $root/znc-macos-arm64"
echo "   planner:  $root/zagd-macos-arm64"
echo "   LSP:      $root/zag-lsp-macos-arm64"
echo "   install:  sudo make -C '$root' install"
echo "   full gate: ZNC='$root/znc-macos-arm64' bash '$root/tests/run_macos_arm64_release.sh'"
