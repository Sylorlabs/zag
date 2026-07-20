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
cat >"$tmp/foreign_delete.zag" <<'ZAG'
script;
struct Pair { value: i64 }
let pair: *Pair = new(Pair{ .value = 7 });
delete(pair);
ZAG
if (cd "$tmp" && "$ZNC" check foreign_delete.zag --no-zagd --no-analyze >foreign_delete.log 2>&1); then
    echo "Script arena value passed to delete unexpectedly accepted" >&2; exit 1
fi
grep -q '`delete` cannot deallocate a Script-context value' "$tmp/foreign_delete.log"
cat >"$tmp/foreign_raw_free.zag" <<'ZAG'
script;
let bytes: *i8 = script_alloc(8);
_zag_free(bytes);
ZAG
if (cd "$tmp" && "$ZNC" check foreign_raw_free.zag --no-zagd --no-analyze >foreign_raw_free.log 2>&1); then
    echo "Script arena value passed to _zag_free unexpectedly accepted" >&2; exit 1
fi
grep -q '`_zag_free` cannot deallocate a Script-context value' "$tmp/foreign_raw_free.log"
cat >"$tmp/switch_escape.zag" <<'ZAG'
script;
extern fn retain(value: []u8) void
let data = read_file("input.txt");
switch (1) { 1 => { retain(data); } else => {} }
ZAG
if (cd "$tmp" && "$ZNC" check switch_escape.zag --no-zagd --no-analyze >switch_escape.log 2>&1); then
    echo "Script lifetime escape in switch arm unexpectedly accepted" >&2; exit 1
fi
grep -q 'call to `retain`' "$tmp/switch_escape.log"
cat >"$tmp/switch_free.zag" <<'ZAG'
script;
let bytes: *i8 = script_alloc(8);
switch (1) { 1 => { _zag_free(bytes); } else => {} }
ZAG
if (cd "$tmp" && "$ZNC" check switch_free.zag --no-zagd --no-analyze >switch_free.log 2>&1); then
    echo "Script foreign free in switch arm unexpectedly accepted" >&2; exit 1
fi
grep -q '`_zag_free` cannot deallocate a Script-context value' "$tmp/switch_free.log"
cat >"$tmp/switch_make.zag" <<'ZAG'
script;
switch (1) { 1 => { let data = make[u8](16); println(data.len); } else => {} }
ZAG
if (cd "$tmp" && "$ZNC" check switch_make.zag --no-zagd --no-analyze >switch_make.log 2>&1); then
    echo "unaccounted root make in switch arm unexpectedly accepted" >&2; exit 1
fi
grep -q 'root make is not charged to ScriptContext' "$tmp/switch_make.log"
cat >"$tmp/aggregate_escape.zag" <<'ZAG'
script;
struct Payload { bytes: []u8 }
extern fn retain_payload(value: Payload) void
let data = read_file("input.txt");
let payload = Payload{ .bytes = data };
retain_payload(payload);
ZAG
if (cd "$tmp" && "$ZNC" check aggregate_escape.zag --no-zagd --no-analyze >aggregate_escape.log 2>&1); then
    echo "Script lifetime escape nested in aggregate unexpectedly accepted" >&2; exit 1
fi
grep -q 'call to `retain_payload`' "$tmp/aggregate_escape.log"
cat >"$tmp/reassigned_escape.zag" <<'ZAG'
script;
extern fn retain(value: []u8) void
let data = read_file("input.txt");
let forwarded: []u8 = "";
forwarded = data;
retain(forwarded);
ZAG
if (cd "$tmp" && "$ZNC" check reassigned_escape.zag --no-zagd --no-analyze >reassigned_escape.log 2>&1); then
    echo "Script lifetime escape after local reassignment unexpectedly accepted" >&2; exit 1
fi
grep -q 'call to `retain`' "$tmp/reassigned_escape.log"
cat >"$tmp/aggregate_make.zag" <<'ZAG'
script;
struct Payload { bytes: []u8 }
let payload = Payload{ .bytes = make[u8](16) };
println(payload.bytes.len);
ZAG
if (cd "$tmp" && "$ZNC" check aggregate_make.zag --no-zagd --no-analyze >aggregate_make.log 2>&1); then
    echo "unaccounted root make nested in aggregate unexpectedly accepted" >&2; exit 1
fi
grep -q 'root make is not charged to ScriptContext' "$tmp/aggregate_make.log"
echo 'script lifetime: pass=16 fail=0'
