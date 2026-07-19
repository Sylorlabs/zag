#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

product_znc=${ZNC_PRODUCT:-./znc}
product_zagd=${ZAGD_PRODUCT:-./zagd}
test -x "$product_znc"
test -x "$product_zagd"

tmp=$(mktemp -d /tmp/zagd-product.XXXXXX)
trap '"$tmp/bin/znc" shutdown >/dev/null 2>&1 || true; rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project/src/deep"
cp "$product_znc" "$tmp/bin/znc"
cp "$product_zagd" "$tmp/bin/zagd"
printf 'name = "zagd-product-test"\n' > "$tmp/project/zag.mod"
printf 'fn main() i32 { return 0; }\n' > "$tmp/project/src/deep/main.zag"

# A source command from a nested directory finds zag.mod and auto-starts.
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o app --no-analyze >/dev/null)
test -f "$tmp/project/.zagd.lock"
first_pid=$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")
test "$first_pid" -gt 1

# Repeated builds are idempotent: the singleton remains the same process.
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
test "$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")" = "$first_pid"

(cd "$tmp/project/src" && "$tmp/bin/znc" status --format json) | grep -q '"running":true'
suggest_json=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
printf '%s\n' "$suggest_json" | grep -q '"advisory":true'
printf '%s\n' "$suggest_json" | grep -q '"source_changes":false'
printf '%s\n' "$suggest_json" | grep -q '"checksum_bound":true'
printf '%s\n' "$suggest_json" | grep -q '"id":"constant-return-fold"'
printf '%s\n' "$suggest_json" | grep -q '"automatic":false'
(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format text) | grep -q 'checksum-bound=true source_changes=false'

# Script snapshots report supported unspecified defaults as automatic facts;
# they remain reports and never rewrite the source.
printf 'script;\nprintln("planner");\n' > "$tmp/project/src/deep/main.zag"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
script_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
printf '%s\n' "$script_suggest" | grep -q '"profile":"script"'
printf '%s\n' "$script_suggest" | grep -q '"id":"script-default-allocator","automatic":true'
printf '%s\n' "$script_suggest" | grep -q '"id":"script-default-device","automatic":true'
explicit_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json --script-allocator custom --device gpu --layout aos)
if printf '%s\n' "$explicit_suggest" | grep -q '"id":"script-default-'; then
    echo "explicit Script choices did not suppress automatic defaults" >&2; exit 1
fi
test "$(cat "$tmp/project/src/deep/main.zag")" = $'script;\nprintln("planner");'
if (cd "$tmp/project/src" && "$tmp/bin/znc" status --format yaml >/dev/null 2>&1); then
    echo "invalid status format unexpectedly accepted" >&2; exit 1
fi
if (cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format yaml >/dev/null 2>&1); then
    echo "invalid suggest format unexpectedly accepted" >&2; exit 1
fi

# Mode changes replace the singleton cleanly.
(cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode deep >/dev/null)
grep -q '^mode=deep$' "$tmp/project/.zagd.status"
test "$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")" != "$first_pid"

# Invalid control input is rejected without disrupting the healthy singleton.
deep_pid=$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")
if (cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode nonsense >/dev/null 2>&1); then
    echo "invalid watch mode unexpectedly accepted" >&2; exit 1
fi
test "$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")" = "$deep_pid"

(cd "$tmp/project/src" && "$tmp/bin/znc" shutdown)
test ! -e "$tmp/project/.zagd.lock"
set +e
stale_status=$(cd "$tmp/project/src" && "$tmp/bin/znc" status 2>&1)
stale_rc=$?
set -e
test "$stale_rc" -eq 1
printf '%s\n' "$stale_status" | grep -q 'stale record'

# A stale lock is never trusted; daemon-side stale PID recovery owns the fact.
printf '999999999\n' > "$tmp/project/.zagd.lock"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o app2 --no-analyze >/dev/null)
test -f "$tmp/project/.zagd.lock"
test "$(cat "$tmp/project/.zagd.lock")" != 999999999
(cd "$tmp/project" && "$tmp/bin/znc" shutdown >/dev/null)

# Project configuration can disable automatic startup.
printf '# mode=off is only a comment\nmode=light\n' > "$tmp/project/.zagd.conf"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o comment-mode --no-analyze >/dev/null)
test -e "$tmp/project/.zagd.lock"
(cd "$tmp/project" && "$tmp/bin/znc" shutdown >/dev/null)
printf 'mode=off\n' > "$tmp/project/.zagd.conf"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o app3 --no-analyze >/dev/null)
test ! -e "$tmp/project/.zagd.lock"

# Changing configuration to off also stops an existing automatic daemon.
printf 'mode=light\n' > "$tmp/project/.zagd.conf"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o before-off --no-analyze >/dev/null)
test -e "$tmp/project/.zagd.lock"
printf 'mode=off\n' > "$tmp/project/.zagd.conf"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
test ! -e "$tmp/project/.zagd.lock"

# Missing optional sibling warns, but foreground compilation remains correct.
rm "$tmp/bin/zagd"
rm "$tmp/project/.zagd.conf"
set +e
missing_out=$(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o app4 --no-analyze 2>&1)
missing_rc=$?
set -e
test "$missing_rc" -eq 0
test -x "$tmp/project/src/deep/app4"
printf '%s\n' "$missing_out" | grep -q 'foreground compilation continues'

echo "zagd product: pass"
