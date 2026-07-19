#!/usr/bin/env bash
# Every target shares declared-type resolution and fails before artifact output.
set -eu
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac
tmp=$(mktemp -d /tmp/zag-typed.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0 fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
bad() { echo "  XX  $1"; fail=$((fail + 1)); }

cat >"$tmp/good.zag" <<'ZAG'
struct Box[T] { value: T }
fn take(b: Box[i32]) i32 { return b.value; }
fn main() i32 { return take(Box[i32]{ .value = 42 }); }
ZAG
if "$ZNC" "$tmp/good.zag" -o "$tmp/good" >"$tmp/good.log" 2>&1 && [ -x "$tmp/good" ]; then
    set +e
    "$tmp/good"
    good_rc=$?
    set -e
    if [ "$good_rc" -eq 42 ]; then ok "named and generic declared types compile"; else bad "generic program exit=$good_rc"; fi
else
    bad "named and generic declared types"
    sed -n '1,12p' "$tmp/good.log"
fi

cat >"$tmp/generic-optional.zag" <<'ZAG'
fn present[V](value: V) ?V { return value; }
fn main() i32 {
    let got: ?i32 = present[i32](42);
    return got orelse 1;
}
ZAG
if "$ZNC" "$tmp/generic-optional.zag" -o "$tmp/generic-optional" >"$tmp/generic-optional.log" 2>&1 &&
   [ -x "$tmp/generic-optional" ]; then
    set +e
    "$tmp/generic-optional"
    generic_optional_rc=$?
    set -e
    if [ "$generic_optional_rc" -eq 42 ]; then
        ok "explicit generic arguments substitute through optional results"
    else
        bad "generic optional program exit=$generic_optional_rc"
    fi
else
    bad "generic optional result substitution"
    sed -n '1,12p' "$tmp/generic-optional.log"
fi

cat >"$tmp/bad.zag" <<'ZAG'
fn ghost(x: Missing) Missing { return x; }
fn main() i32 { return 0; }
ZAG

reject() {
    name=$1; shift
    out="$tmp/$name.out"
    log="$tmp/$name.log"
    rm -f "$out" "$tmp/bad.mlir"
    if ! "$ZNC" "$tmp/bad.zag" -o "$out" "$@" >"$log" 2>&1 &&
       [ ! -e "$out" ] && [ ! -e "$tmp/bad.mlir" ] &&
       grep -q "error\[E0202\]: unknown type 'Missing'" "$log"; then
        ok "$name rejects unknown declared type without artifact"
    else
        bad "$name unknown-type rejection"
        sed -n '1,12p' "$log"
    fi
}

reject native
reject arm64 --target arm64
reject wasm --target wasm
reject gpu-mlir --target gpu-amd
reject gfx1010 --target amdgpu-gfx1010

cat >"$tmp/bad-local.zag" <<'ZAG'
fn main() i32 { let x: Missing = 1; return 0; }
ZAG
if ! "$ZNC" "$tmp/bad-local.zag" -o "$tmp/bad-local" >"$tmp/bad-local.log" 2>&1 &&
   [ ! -e "$tmp/bad-local" ] && grep -q "unknown type 'Missing'" "$tmp/bad-local.log"; then
    ok "explicit local type uses shared authority"
else
    bad "explicit local unknown type"
    sed -n '1,12p' "$tmp/bad-local.log"
fi

reject_expr() {
    name=$1; source=$2
    printf '%s\n' "$source" >"$tmp/$name.zag"
    rm -f "$tmp/$name.out"
    if ! "$ZNC" "$tmp/$name.zag" -o "$tmp/$name.out" >"$tmp/$name.log" 2>&1 &&
       [ ! -e "$tmp/$name.out" ] && grep -q 'error\[E0203\]' "$tmp/$name.log"; then
        ok "$name rejects expression type mismatch without artifact"
    else
        bad "$name expression type mismatch"
        sed -n '1,12p' "$tmp/$name.log"
    fi
}

reject_expr return-mismatch 'fn main() i32 { return "wrong"; }'
reject_expr argument-mismatch 'fn take(x:i32) i32 { return x; } fn main() i32 { return take("wrong"); }'
reject_expr assignment-mismatch 'fn main() i32 { let x:i32=1; x="wrong"; return x; }'
reject_expr operator-mismatch 'fn main() i32 { let x:bool=true; return x + 1; }'

echo "════ typed-authority pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
