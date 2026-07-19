#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=$(realpath "${ZNC:-./znc}")
tmp=$(mktemp -d /tmp/zag-script-lifetime.XXXXXX)
trap 'find "$tmp" -depth -delete' EXIT
printf 'payload' >"$tmp/input.txt"
cat >"$tmp/escape.zag" <<'ZAG'
script;
extern fn retain(value: []u8) void
let data = read_file("input.txt");
retain(data);
ZAG
if (cd "$tmp" && "$ZNC" check escape.zag --no-zagd --no-analyze >escape.log 2>&1); then
    echo "Script lifetime escape unexpectedly accepted" >&2; exit 1
fi
grep -q 'Script-context value may escape through helper, extern, or unknown call to `retain`' "$tmp/escape.log"
cat >"$tmp/safe.zag" <<'ZAG'
script;
let data = read_file("input.txt");
println(data);
ZAG
(cd "$tmp" && "$ZNC" check safe.zag --no-zagd --no-analyze >/dev/null)
cat >"$tmp/helper.zag" <<'ZAG'
script;
fn show(value: []u8) void { println(value); }
let data = read_file("input.txt");
show(data);
ZAG
(cd "$tmp" && "$ZNC" check helper.zag --no-zagd --no-analyze >/dev/null)
cat >"$tmp/helper_return.zag" <<'ZAG'
script;
extern fn retain(value: []u8) void
fn relay(value: []u8) []u8 { return value; }
let data = read_file("input.txt");
retain(relay(data));
ZAG
if (cd "$tmp" && "$ZNC" check helper_return.zag --no-zagd --no-analyze >helper_return.log 2>&1); then
    echo "helper-return escape unexpectedly accepted" >&2; exit 1
fi
grep -q 'call to `retain`' "$tmp/helper_return.log"
cat >"$tmp/helper_sink.zag" <<'ZAG'
script;
extern fn retain(value: []u8) void
fn sink(value: []u8) void { retain(value); }
fn relay(value: []u8) void { sink(value); }
let data = read_file("input.txt");
relay(data);
ZAG
if (cd "$tmp" && "$ZNC" check helper_sink.zag --no-zagd --no-analyze >helper_sink.log 2>&1); then
    echo "transitive helper escape unexpectedly accepted" >&2; exit 1
fi
grep -q 'call to `relay`' "$tmp/helper_sink.log"
cat >"$tmp/lib.zag" <<'ZAG'
extern fn retain(value: []u8) void
fn imported_sink(value: []u8) void { retain(value); }
ZAG
cat >"$tmp/imported_sink.zag" <<'ZAG'
script;
@import("lib.zag")
let data = read_file("input.txt");
imported_sink(data);
ZAG
if (cd "$tmp" && "$ZNC" check imported_sink.zag --no-zagd --no-analyze >imported_sink.log 2>&1); then
    echo "imported helper escape unexpectedly accepted" >&2; exit 1
fi
grep -q 'call to `imported_sink`' "$tmp/imported_sink.log"
cat >"$tmp/ordinary_make.zag" <<'ZAG'
script;
let data = make[u8](16);
println(data.len);
ZAG
if (cd "$tmp" && "$ZNC" check ordinary_make.zag --no-zagd --no-analyze >ordinary_make.log 2>&1); then
    echo "unaccounted root make unexpectedly accepted" >&2; exit 1
fi
grep -q 'root make is not charged to ScriptContext' "$tmp/ordinary_make.log"
echo 'script lifetime: pass=8 fail=0'
