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

# Check observable behavior as well as compiler acceptance. A nonzero exit
# status matters: the migration contract covers errors and application status,
# not merely programs that happen to print the same successful output.
assert_runtime_parity() {
    local label=$1 script_bin=$2 zag_bin=$3
    local script_rc zag_rc
    set +e
    "$script_bin" >"$tmp/$label.script.out" 2>"$tmp/$label.script.err"
    script_rc=$?
    "$zag_bin" >"$tmp/$label.zag.out" 2>"$tmp/$label.zag.err"
    zag_rc=$?
    set -e
    if [ "$script_rc" -ne "$zag_rc" ] || \
       ! cmp -s "$tmp/$label.script.out" "$tmp/$label.zag.out" || \
       ! cmp -s "$tmp/$label.script.err" "$tmp/$label.zag.err"; then
        echo "ZagScript-to-Zag behavior mismatch: $label (script=$script_rc zag=$zag_rc)" >&2
        diff -u "$tmp/$label.script.out" "$tmp/$label.zag.out" >&2 || true
        diff -u "$tmp/$label.script.err" "$tmp/$label.zag.err" >&2 || true
        exit 1
    fi
}

# Script expansion must produce an explicit candidate without mutating the
# compact source. This is the bridge from prototype ergonomics to strict Zag.
cp "$tmp/script.zag" "$tmp/script.before"
"$ZNC" expand "$tmp/script.zag" --to explicit --output "$tmp/explicit.zag" --no-zagd >/dev/null
cmp "$tmp/script.before" "$tmp/script.zag"
test -s "$tmp/explicit.zag"
"$ZNC" "$tmp/explicit.zag" --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/explicit.bin" >/dev/null
assert_runtime_parity basic "$tmp/script.bin" "$tmp/explicit.bin"

# The explicit candidate is ordinary Zag and cannot re-enter Script hardening.
if "$ZNC" harden "$tmp/explicit.zag" --no-zagd >"$tmp/explicit-harden.log" 2>&1; then
    echo 'profile separation: explicit Zag candidate re-entered Script hardening' >&2
    exit 1
fi
grep -q 'source is already regular Zag; no script profile to expand' "$tmp/explicit-harden.log"

# End-to-end migration with Script-only conveniences: indentation syntax,
# inferred argument/result types, a function call and Script's say() helper.
# This program deliberately returns 2, proving nonzero exit parity as well.
cat >"$tmp/inferred.zag" <<'ZAG'
script;
def affine(x):
    return x * 3 + 2
let result = affine(13)
if result != 41:
    return 1
say("sibling-pass")
return 2
ZAG
cp "$tmp/inferred.zag" "$tmp/inferred.before"
"$ZNC" expand "$tmp/inferred.zag" --to explicit \
    --output "$tmp/inferred.explicit.zag" --no-zagd >/dev/null
cmp "$tmp/inferred.before" "$tmp/inferred.zag"
test -s "$tmp/inferred.explicit.zag"
"$ZNC" "$tmp/inferred.zag" --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/inferred.script.bin" >/dev/null
"$ZNC" "$tmp/inferred.explicit.zag" --no-zagd --no-analyze --no-foreground-cache \
    -o "$tmp/inferred.zag.bin" >/dev/null
assert_runtime_parity inferred "$tmp/inferred.script.bin" "$tmp/inferred.zag.bin"
set +e
"$tmp/inferred.zag.bin" >"$tmp/inferred.check" 2>/dev/null
check_rc=$?
set -e
[ "$check_rc" -eq 2 ]
[ "$(cat "$tmp/inferred.check")" = sibling-pass ]
if "$ZNC" harden "$tmp/inferred.explicit.zag" --no-zagd >"$tmp/inferred-harden.log" 2>&1; then
    echo 'profile separation: inferred explicit Zag unexpectedly entered Script hardening' >&2
    exit 1
fi
grep -q 'source is already regular Zag; no script profile to expand' "$tmp/inferred-harden.log"

echo 'Zag/ZagScript profile separation and migration parity: PASS'
