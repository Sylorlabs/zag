#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in
    /*) ;;
    *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-tooling.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

check() {
    local name=$1
    shift
    if "$@"; then
        echo "  ok  $name"
        pass=$((pass + 1))
    else
        echo "  XX  $name"
        fail=$((fail + 1))
    fi
}

check_version() { "$ZNC" version | grep -q '^znc 2026\.06\.0-dev (edition 2026)$'; }

check_format() {
    printf 'fn main() i32{let x:i32=40+2;return x;}\n' >"$tmp/input.zag"
    "$ZNC" fmt --in-place "$tmp/input.zag" >/dev/null
    cp "$tmp/input.zag" "$tmp/once.zag"
    "$ZNC" fmt --in-place "$tmp/input.zag" >/dev/null
    cmp -s "$tmp/once.zag" "$tmp/input.zag"
}

check_init() {
    (cd "$tmp" && "$ZNC" init >/dev/null)
    grep -q '^edition = "2026"$' "$tmp/zag.mod"
}

check_dwarf() {
    "$ZNC" "$tmp/once.zag" -o "$tmp/debug-bin" --debug >/dev/null
    readelf -S "$tmp/debug-bin" | grep -q '\.debug_info'
}

check_lsp() {
    "$ZNC" selfhost/lsp/zag-lsp.zag -o "$tmp/zag-lsp" >/dev/null
    ZAG_LSP="$tmp/zag-lsp" bash tests/test_lsp.sh >/dev/null
}

check "version command" check_version
check "formatter idempotence" check_format
check "project initialization" check_init
check "DWARF emission" check_dwarf
check "LSP build and protocol" check_lsp

echo "════ tooling pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
