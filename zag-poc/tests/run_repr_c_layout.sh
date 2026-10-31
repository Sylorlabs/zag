#!/usr/bin/env bash
set -euo pipefail

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
ZNC=${ZNC:-"$ROOT/znc"}
TMP=$(mktemp -d "${TMPDIR:-/tmp}/zag-repr-c.XXXXXX")
trap 'rm -rf "$TMP"' EXIT
pass=0
fail=0

ok() { printf 'ok - %s\n' "$1"; pass=$((pass + 1)); }
bad() { printf 'not ok - %s\n' "$1" >&2; fail=$((fail + 1)); }

printf 'name = "repr-c-layout"\nversion = "0"\nedition = "2027"\n' >"$TMP/zag.mod"
cp "$ROOT/tests/fixtures/repr_c_xbutton_event.zag" "$TMP/main.zag"
cp "$TMP/main.zag" "$TMP/formatted.zag"
if "$ZNC" fmt --in-place "$TMP/formatted.zag" >"$TMP/fmt.log" 2>&1 &&
   grep -q '^@repr(C) struct XButtonEvent' "$TMP/formatted.zag"; then
    ok "formatter preserves explicit C representation"
else
    bad "formatter preserves @repr(C)"
fi
if "$ZNC" "$TMP/main.zag" -o "$TMP/repr-c" --no-zagd --no-foreground-cache >"$TMP/build.log" 2>&1; then
    set +e
    "$TMP/repr-c"
    rc=$?
    set -e
    if [ "$rc" = 42 ]; then ok "XButtonEvent C offsets, 96-byte stride, and narrow real-byte access execute"; else bad "XButtonEvent native exit=$rc"; fi
else
    sed -n '1,120p' "$TMP/build.log" >&2
    bad "XButtonEvent @repr(C) compiles"
fi

cat >"$TMP/ordinary.zag" <<'ZAG'
struct Ordinary { a:i32, b:i64, c:i32, p:*u8 }
fn main() i32 { return @sizeOf[Ordinary](); }
ZAG
if "$ZNC" "$TMP/ordinary.zag" -o "$TMP/ordinary" --no-zagd --no-foreground-cache >"$TMP/ordinary.log" 2>&1; then
    set +e; "$TMP/ordinary"; rc=$?; set -e
    if [ "$rc" = 32 ]; then ok "ordinary Zag struct layout remains word-oriented"; else bad "ordinary struct size/exit=$rc"; fi
else
    bad "ordinary struct control compiles"
fi

mkdir "$TMP/imported"
cat >"$TMP/imported/event.zag" <<'ZAG'
pub @repr(C) struct Event { kind:i32, serial:i64, flag:i32 }
ZAG
cat >"$TMP/imported/main.zag" <<'ZAG'
@import("event.zag") as event
fn main() i32 { return @sizeOf[event.Event](); }
ZAG
cp "$TMP/zag.mod" "$TMP/imported/zag.mod"
if "$ZNC" "$TMP/imported/main.zag" -o "$TMP/imported/app" --no-zagd --no-foreground-cache >"$TMP/import.log" 2>&1; then
    set +e; "$TMP/imported/app"; rc=$?; set -e
    if [ "$rc" = 24 ]; then ok "qualified import preserves explicit C representation"; else bad "qualified repr(C) size/exit=$rc"; fi
else
    sed -n '1,80p' "$TMP/import.log" >&2
    bad "qualified @repr(C) import compiles"
fi

mkdir "$TMP/v1"
printf 'name = "repr-c-v1"\nversion = "0"\nedition = "2026"\n' >"$TMP/v1/zag.mod"
cp "$ROOT/tests/fixtures/repr_c_xbutton_event.zag" "$TMP/v1/main.zag"
if "$ZNC" "$TMP/v1/main.zag" -o "$TMP/v1/app" --no-zagd --no-foreground-cache >"$TMP/v1.log" 2>&1; then
    bad "edition 2026 rejects @repr(C)"
elif grep -q 'E0200' "$TMP/v1.log" && [ ! -e "$TMP/v1/app" ]; then
    ok "edition gate rejects @repr(C) without an artifact"
else
    bad "edition rejection is precise and artifact-free"
fi

cat >"$TMP/packed.zag" <<'ZAG'
@repr(packed) struct Bad { x:u8, y:u16 }
fn main() i32 { return 0; }
ZAG
if "$ZNC" "$TMP/packed.zag" -o "$TMP/packed" --no-zagd --no-foreground-cache >"$TMP/packed.log" 2>&1; then
    bad "unaligned packed layout rejects"
elif grep -Eq 'unaligned field|unsupported representation|E0018' "$TMP/packed.log" && [ ! -e "$TMP/packed" ]; then
    ok "unaligned packed layout fails closed without an artifact"
else
    bad "unsupported representation diagnostic"
fi

cat >"$TMP/unsupported-field.zag" <<'ZAG'
@repr(C) struct Bad { value:[]u8 }
fn main() i32 { return 0; }
ZAG
if "$ZNC" "$TMP/unsupported-field.zag" -o "$TMP/unsupported-field" --no-zagd --no-foreground-cache >"$TMP/unsupported-field.log" 2>&1; then
    bad "unsupported C-layout field rejects"
elif grep -Eq '@repr\(C\) fields require target-supported scalar/pointer C leaves|@repr\(C\) fields require scalar/pointer C leaves' "$TMP/unsupported-field.log" && [ ! -e "$TMP/unsupported-field" ]; then
    ok "unsupported C-layout field fails closed"
else
    bad "unsupported C-layout field diagnostic"
fi

cat >"$TMP/by-value.zag" <<'ZAG'
@repr(C) struct Pair { left:i32, right:i32 }
fn consume(value: Pair) i32 { return value.left + value.right; }
fn main() i32 { return 0; }
ZAG
if "$ZNC" "$TMP/by-value.zag" -o "$TMP/by-value" --no-zagd --no-foreground-cache >"$TMP/by-value.log" 2>&1; then
    bad "unsupported by-value C-layout aggregate rejects"
elif grep -q '@repr(C) aggregates are pointer-only' "$TMP/by-value.log" && [ ! -e "$TMP/by-value" ]; then
    ok "unsupported by-value C-layout aggregate fails closed"
else
    sed -n '1,80p' "$TMP/by-value.log" >&2
    bad "by-value C-layout aggregate diagnostic"
fi

printf 'repr-c-layout pass=%d fail=%d\n' "$pass" "$fail"
[ "$fail" = 0 ]
