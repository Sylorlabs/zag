#!/usr/bin/env bash
# ZagScript closure and bounded-escape authority.
set -euo pipefail

cd "$(dirname "$0")/.."
. tests/portable.sh
ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
test -x "$ZNC"

# ScriptContext-owned values already have a deep escape/foreign-free suite.
bash tests/run_script_lifetime.sh

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-closures.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
target_args=()
if [ "$(uname -s):$(uname -m)" = Darwin:arm64 ]; then
    target_args=(--target macos-arm64)
fi

cat >"$tmp/positive.zag" <<'ZAG'
script;
let factor: i32 = 21;
let twice: fn(i32) i32 = fn[factor](x: i32) i32 { return x + factor; };
return twice(21);
ZAG
"$ZNC" "$tmp/positive.zag" "${target_args[@]}" --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/positive" >/dev/null
set +e
zag_run_bounded 10 "$tmp/positive"
positive_rc=$?
set -e
test "$positive_rc" -eq 42

cat >"$tmp/captureless.zag" <<'ZAG'
script;
let add: fn(i32) i32 = fn[](x: i32) i32 { return x + 40; };
return add(2);
ZAG
"$ZNC" "$tmp/captureless.zag" "${target_args[@]}" --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/captureless" >/dev/null
set +e
zag_run_bounded 10 "$tmp/captureless"
captureless_rc=$?
set -e
test "$captureless_rc" -eq 42

# Returning a closure that retains a defining-frame pointer must fail closed.
cat >"$tmp/escape.zag" <<'ZAG'
fn bad() fn() i32 {
    let local: i32 = 42;
    return fn[&local]() i32 { return local.*; };
}
script;
let f: fn() i32 = bad();
return f();
ZAG
if "$ZNC" "$tmp/escape.zag" "${target_args[@]}" --no-zagd --no-analyze \
    --no-foreground-cache -o "$tmp/escape" >"$tmp/escape.log" 2>&1 ||
   [ -e "$tmp/escape" ]; then
    echo 'ZagScript closure escape unexpectedly compiled' >&2
    exit 1
fi
grep -Eq 'capturing closure escapes function|pointer capture retains a defining-frame address|closure escape' \
    "$tmp/escape.log"

echo 'ZagScript closures: PASS scalar/captureless native closure + pointer escape rejection + ScriptContext lifetime checks'
