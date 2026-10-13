#!/usr/bin/env bash
set -eu

cd "$(dirname "$0")/.."

ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-profile-boundary.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM

cat >"$tmp/strict.zag" <<'ZAG'
fn main() i32 { return 0; }
ZAG

cat >"$tmp/script.zag" <<'ZAG'
script;
let answer: i32 = 40 + 2;
return answer - 42;
ZAG

# Strict Zag is already strict source. The Script expansion path must refuse to
# reinterpret it as a prototype profile.
if "$ZNC" harden "$tmp/strict.zag" --no-zagd >"$tmp/strict-harden.log" 2>&1; then
    echo 'profile separation: strict Zag unexpectedly entered Script hardening' >&2
    exit 1
fi
grep -q 'source is already regular Zag; no script profile to expand' "$tmp/strict-harden.log"

# Both profiles still compile through the shared native backend.
"$ZNC" "$tmp/strict.zag" --no-zagd --no-analyze --no-foreground-cache -o "$tmp/strict.bin" >/dev/null
"$ZNC" "$tmp/script.zag" --no-zagd --no-analyze --no-foreground-cache -o "$tmp/script.bin" >/dev/null
"$tmp/strict.bin"
"$tmp/script.bin"

# Script expansion must produce an explicit candidate without mutating the
# compact source. This is the bridge from prototype ergonomics to strict Zag.
cp "$tmp/script.zag" "$tmp/script.before"
"$ZNC" expand "$tmp/script.zag" --to explicit --output "$tmp/explicit.zag" --no-zagd >/dev/null
cmp "$tmp/script.before" "$tmp/script.zag"
test -s "$tmp/explicit.zag"

# The explicit candidate is ordinary Zag and cannot re-enter Script hardening.
if "$ZNC" harden "$tmp/explicit.zag" --no-zagd >"$tmp/explicit-harden.log" 2>&1; then
    echo 'profile separation: explicit Zag candidate re-entered Script hardening' >&2
    exit 1
fi
grep -q 'source is already regular Zag; no script profile to expand' "$tmp/explicit-harden.log"

echo 'Zag/ZagScript profile separation: PASS'
