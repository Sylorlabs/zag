#!/usr/bin/env bash
set -euo pipefail

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
. "$root/tests/portable.sh"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-toolchain-identity.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compiler=${ZNC:-$root/znc}
digest=$(zag_sha256_file "$compiler")
cat >"$tmp/zag.mod" <<EOF
name = "identity-test"
version = "0"
edition = "2026"

[toolchain]
compiler = "sha256:$digest"
EOF

zag_verify_manifest_toolchain "$compiler" "$tmp/zag.mod"
printf '%s\n' 'name = "identity-test"' 'version = "0"' 'edition = "2026"' \
    '[toolchain]' 'compiler = "sha256:0000000000000000000000000000000000000000000000000000000000000000"' \
    >"$tmp/wrong.mod"
if zag_verify_manifest_toolchain "$compiler" "$tmp/wrong.mod"; then
    echo 'toolchain identity: mismatch was accepted' >&2
    exit 1
fi
printf '%s\n' '[toolchain]' 'compiler = "sha256:00"' 'compiler = "sha256:00"' >"$tmp/malformed.mod"
if zag_manifest_toolchain_pin "$tmp/malformed.mod" >/dev/null; then
    echo 'toolchain identity: malformed duplicate pin was accepted' >&2
    exit 1
fi
echo 'toolchain identity: pass (matching, mismatch, and malformed pins fail closed)'
