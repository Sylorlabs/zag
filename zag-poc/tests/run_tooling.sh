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

check_version() { "$ZNC" version | grep -q '^znc 2026\.07\.0-dev (edition 2026)$'; }

check_format() {
    printf 'fn main() i32{let x:i32=40+2;return x;}\n' >"$tmp/input.zag"
    "$ZNC" fmt --in-place "$tmp/input.zag" >/dev/null
    cp "$tmp/input.zag" "$tmp/once.zag"
    "$ZNC" fmt --in-place "$tmp/input.zag" >/dev/null
    cmp -s "$tmp/once.zag" "$tmp/input.zag"
}

check_format_prefix_annotations() {
    mkdir "$tmp/annotations-project" || return 1
    printf 'name = "annotation-test"\nversion = "0.0.0"\nedition = "2027"\n' >"$tmp/annotations-project/zag.mod" || return 1
    printf '@hot\npub struct Sensor[T] { value: T, }\n@sealed\n@repr(C)\npub struct CSensor { value: i32, }\npub @hot enum Mode { Idle, Active }\n@photonic\nfn read_sensor(s: Sensor[i32]) i32 { return s.value; }\nextern @ffi fn _zag_unused_probe() i32;\n@hot\nunsafe fn raw_probe() i32 { return 0; }\nfn main() i32 { let s: Sensor[i32] = Sensor[i32]{ .value = 42 }; unsafe { if (read_sensor(s) == 42 && raw_probe() == 0) { return 0; } } return 1; }\n' >"$tmp/annotations-project/main.zag" || return 1
    "$ZNC" fmt --in-place "$tmp/annotations-project/main.zag" >/dev/null || return 1
    cp "$tmp/annotations-project/main.zag" "$tmp/annotations.once.zag" || return 1
    "$ZNC" fmt --in-place "$tmp/annotations-project/main.zag" >/dev/null || return 1
    cmp -s "$tmp/annotations.once.zag" "$tmp/annotations-project/main.zag" || return 1
    [ "$(grep -c '^@hot$' "$tmp/annotations-project/main.zag")" -eq 2 ] || return 1
    grep -q '^pub struct Sensor\[T\]' "$tmp/annotations-project/main.zag" || return 1
    grep -q '^pub @repr(C) struct CSensor' "$tmp/annotations-project/main.zag" || return 1
    grep -q '^pub enum Mode' "$tmp/annotations-project/main.zag" || return 1
    grep -q 'fn read_sensor(s: Sensor\[i32\]) i32 @photonic' "$tmp/annotations-project/main.zag" || return 1
    grep -q 'extern fn _zag_unused_probe() i32 @ffi;' "$tmp/annotations-project/main.zag" || return 1
    grep -q 'unsafe fn raw_probe() i32 @hot' "$tmp/annotations-project/main.zag" || return 1
    "$ZNC" "$tmp/annotations-project/main.zag" -o "$tmp/annotations-program" --no-zagd --no-analyze >/dev/null || return 1
    "$tmp/annotations-program"
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
check "formatter preserves prefix declaration annotations" check_format_prefix_annotations
check "project initialization" check_init
check "DWARF emission" check_dwarf
check "LSP build and protocol" check_lsp

echo "════ tooling pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
