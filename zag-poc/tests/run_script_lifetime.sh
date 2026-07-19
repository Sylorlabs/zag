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
grep -q 'Script-context value may escape through extern or unknown call to `retain`' "$tmp/escape.log"
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
cat >"$tmp/ordinary_make.zag" <<'ZAG'
script;
let data = make[u8](16);
println(data.len);
ZAG
strict=$(cd "$tmp" && "$ZNC" check ordinary_make.zag --strict --no-zagd --no-analyze 2>&1 || true)
printf '%s\n' "$strict" | grep -q 'ordinary make allocation is not charged to the Script context'
echo 'script lifetime: pass=4 fail=0'
