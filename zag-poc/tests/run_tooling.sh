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
    mkdir "$tmp/project"
    (cd "$tmp/project" && "$ZNC" init --name tooling-example >"$tmp/init.out")
    grep -q 'Run:  znc src/main.zag -o app --run' "$tmp/init.out"
    grep -q 'Note: early systems language' "$tmp/init.out"
    grep -q '^name = "tooling-example"$' "$tmp/project/zag.mod"
    grep -q '^edition = "2026"$' "$tmp/project/zag.mod"
    grep -q '^script;$' "$tmp/project/src/main.zag"
    grep -q '^script;$' "$tmp/project/tests/smoke.zag"
    grep -q 'no package registry' "$tmp/project/deps/README.md"
    grep -q 'znc src/main.zag -o app --run' "$tmp/project/README.md"
    grep -q 'Early systems language' "$tmp/project/README.md"
    grep -q 'RAII/destructors, async/await, and full' "$tmp/project/README.md"
    grep -q 'docs/SUPPORT.md' "$tmp/project/README.md"
    (cd "$tmp/project" && "$ZNC" src/main.zag -o app --run --no-zagd >"$tmp/init-run.out" 2>"$tmp/init-run.err")
    grep -q '^Hello from Zag$' "$tmp/init-run.out"
    [ ! -s "$tmp/init-run.err" ]
    (cd "$tmp/project" && "$ZNC" tests/smoke.zag -o smoke --run --no-zagd >"$tmp/init-test.out" 2>"$tmp/init-test.err")
    grep -q '^smoke: ok$' "$tmp/init-test.out"
    [ ! -s "$tmp/init-test.err" ]
    cp tests/tooling/vendor_math.zag "$tmp/project/deps/math.zag"
    cp tests/tooling/vendor_main.zag "$tmp/project/src/vendor_main.zag"
    (cd "$tmp/project" && "$ZNC" src/vendor_main.zag -o vendor-check --run --no-zagd >"$tmp/vendor.out" 2>"$tmp/vendor.err")
    [ ! -s "$tmp/vendor.err" ]
}

check_help() {
    "$ZNC" --help >"$tmp/help.out" 2>"$tmp/help.err"
    grep -q 'znc init \[--name project-name\]' "$tmp/help.out"
    grep -q 'start: znc init' "$tmp/help.out"
    grep -q 'no package registry or network resolver' "$tmp/help.out"
    [ ! -s "$tmp/help.err" ]
}

check_no_args_help() {
    "$ZNC" >"$tmp/no-args.out" 2>"$tmp/no-args.err"
    grep -q '^usage: znc ' "$tmp/no-args.out"
    [ ! -s "$tmp/no-args.err" ]
}

check_script_analyzer_clean() {
    "$ZNC" script examples/script_hello.zag -o "$tmp/script-hello" --no-zagd >"$tmp/script.out" 2>"$tmp/script.err"
    [ ! -s "$tmp/script.err" ]
}

check_whitespace_line() {
    "$ZNC" tests/tooling/whitespace_line.zag -o "$tmp/whitespace" --no-zagd --no-analyze >/dev/null
    "$tmp/whitespace" || [ "$?" -eq 42 ]
}

check_lsp_clean() {
    "$ZNC" selfhost/lsp/zag-lsp.zag -o "$tmp/zag-lsp-clean" --no-zagd >"$tmp/lsp-build.out" 2>"$tmp/lsp-build.err"
    [ ! -s "$tmp/lsp-build.err" ]
}

check_dwarf() {
    "$ZNC" "$tmp/once.zag" -o "$tmp/debug-bin" --debug --no-zagd >/dev/null
    readelf -S "$tmp/debug-bin" | grep -q '\.debug_info'
}

check_lsp() {
    "$ZNC" selfhost/lsp/zag-lsp.zag -o "$tmp/zag-lsp" --no-zagd >/dev/null
    ZAG_LSP="$tmp/zag-lsp" bash tests/test_lsp.sh >/dev/null
}

check "version command" check_version
check "formatter idempotence" check_format
check "formatter preserves prefix declaration annotations" check_format_prefix_annotations
check "project initialization" check_init
check "global help" check_help
check "no-argument help" check_no_args_help
check "script analyzer ignores generated wrappers" check_script_analyzer_clean
check "whitespace-only source line" check_whitespace_line
check "LSP build has clean diagnostics" check_lsp_clean
check "DWARF emission" check_dwarf
check "LSP build and protocol" check_lsp

echo "════ tooling pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
