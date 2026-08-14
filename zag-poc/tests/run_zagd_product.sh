#!/usr/bin/env bash
set -euo pipefail
# This suite intentionally uses `producer | grep -q` as an output assertion.
# With pipefail, grep's early successful close can turn a large producer's
# harmless SIGPIPE into status 141 and hide the real assertion result.  Each
# pipeline's last command is the assertion, so disable pipefail locally for
# this line-oriented test harness only.
set +o pipefail
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

wait_for_mode() {
    expected=$1
    for _ in $(seq 1 500); do
        if [ -s "$tmp/project/.zagd.lock" ] &&
           grep -q "^mode=$expected$" "$tmp/project/.zagd.status" 2>/dev/null &&
           grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null; then
            return 0
        fi
        sleep 0.01
    done
    echo "zagd product: daemon did not publish idle mode=$expected" >&2
    return 1
}

# A source command from a nested directory finds zag.mod and auto-starts.
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" main.zag -o app --no-analyze >/dev/null)
test -f "$tmp/project/.zagd.lock"
wait_for_mode adaptive
first_pid=$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")
test "$first_pid" -gt 1
grep -q '^idle_deep=true$' "$tmp/project/.zagd.status"
grep -q '^difficulty=simple$' "$tmp/project/.zagd.status"
grep -q '^script_optimization=automatic$' "$tmp/project/.zagd.status"
grep -q '^regular_optimization=review$' "$tmp/project/.zagd.status"
grep -q '^objective=runtime$' "$tmp/project/.zagd.status"
grep -q '^trust_mode=stable$' "$tmp/project/.zagd.status"

# Repeated builds are idempotent: the singleton remains the same process.
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
test "$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")" = "$first_pid"

# Every foreground policy field is transported to the daemon. A same-mode
# policy edit replaces the singleton instead of leaving stale active policy.
cat > "$tmp/project/.zagd.conf" <<'EOF'
mode=adaptive
idle_deep=false
difficulty=native
script_optimization=review
regular_optimization=automatic
objective=runtime
trust_mode=autonomous
cpu=native
stability_window_ms=31
max_memory_bytes=1073741824
max_cache_bytes=104857600
max_workers=1
notifications=errors_only
EOF
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
for _ in $(seq 1 500); do
    grep -q '^trust_mode=autonomous$' "$tmp/project/.zagd.status" 2>/dev/null &&
        grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
policy_pid=$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")
test "$policy_pid" != "$first_pid"
first_pid=$policy_pid
grep -q '^idle_deep=false$' "$tmp/project/.zagd.status"
grep -q '^difficulty=native$' "$tmp/project/.zagd.status"
grep -q '^script_optimization=review$' "$tmp/project/.zagd.status"
grep -q '^regular_optimization=automatic$' "$tmp/project/.zagd.status"
grep -q '^objective=runtime$' "$tmp/project/.zagd.status"
grep -q '^trust_mode=autonomous$' "$tmp/project/.zagd.status"
grep -q '^cpu=native$' "$tmp/project/.zagd.status"
grep -q '^stability_window_ms=31$' "$tmp/project/.zagd.status"
grep -q '^max_memory_bytes=1073741824$' "$tmp/project/.zagd.status"
grep -q '^max_cache_bytes=104857600$' "$tmp/project/.zagd.status"
grep -q '^max_workers=1$' "$tmp/project/.zagd.status"
grep -q '^notifications=errors_only$' "$tmp/project/.zagd.status"
grep -q '^trust_mode_scope=policy-only$' "$tmp/project/.zagd.status"
grep -q '^optimizer_generation=unimplemented$' "$tmp/project/.zagd.status"

# With no explicit --mode, watch uses project policy instead of a hidden light
# fallback. Explicit --mode tests below retain higher precedence.
(cd "$tmp/project/src" && "$tmp/bin/znc" watch >/dev/null)
wait_for_mode adaptive
grep -q '^mode=adaptive$' "$tmp/project/.zagd.status"
first_pid=$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")

(cd "$tmp/project/src" && "$tmp/bin/znc" status --format json) | grep -q '"running":true'
status_text=$(cd "$tmp/project/src" && "$tmp/bin/znc" status)
grep -q '^state=idle$' <<<"$status_text"
suggest_json=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
printf '%s\n' "$suggest_json" | grep -q '"advisory":true'
printf '%s\n' "$suggest_json" | grep -q '"source_changes":false'
printf '%s\n' "$suggest_json" | grep -q '"checksum_bound":true'
printf '%s\n' "$suggest_json" | grep -q '"id":"constant-return-fold"'
printf '%s\n' "$suggest_json" | grep -q '"id":"constant-return-fold","supported":false,"automatic":false'
printf '%s\n' "$suggest_json" | grep -q '"evidence_basis":"proven"'
printf '%s\n' "$suggest_json" | grep -q '"rejected_reason":"no planner-owned transformation and equivalence-revalidation pipeline"'
printf '%s\n' "$suggest_json" | grep -q '"automatic":false'
printf '%s\n' "$suggest_json" | grep -q '"supported_count":0'
(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format text) | grep -q 'checksum-bound=true module-graph-current=true source_changes=false'
(cd "$tmp/project/src" && "$tmp/bin/znc" suggest) | grep -q 'checksum-bound=true module-graph-current=true source_changes=false'

# A malformed profile-plan record is never surfaced as a suggestion. Profile
# evidence is advisory-only and must be checksum/current-identity validated
# independently of the healthy semantic snapshot.
printf 'format=zagd-profile-plan-v3\nadvisory=true\nexecutable_authority=false\nforeground_consumption=metadata-only\n' > "$tmp/project/.zag-cache/zagd/profile-plan.record"
bad_profile_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
if printf '%s\n' "$bad_profile_suggest" | grep -q '"id":"profile-guided-hot-regions"'; then
    echo "corrupt profile plan unexpectedly became a suggestion" >&2; exit 1
fi

# Script snapshots report supported unspecified defaults as automatic facts;
# they remain reports and never rewrite the source.
printf 'script;\nprintln("planner");\n' > "$tmp/project/src/deep/main.zag"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
script_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
printf '%s\n' "$script_suggest" | grep -q '"profile":"script"'
printf '%s\n' "$script_suggest" | grep -q '"id":"script-default-allocator","supported":true,"automatic":true'
printf '%s\n' "$script_suggest" | grep -q '"id":"script-default-device","supported":true,"automatic":true'
printf '%s\n' "$script_suggest" | grep -q '"id":"script-default-layout","supported":true,"automatic":true'
printf '%s\n' "$script_suggest" | grep -q '"id":"script-default-cpu","supported":true,"automatic":true'

# Arbitrary comments or string contents are not structured planner authority.
# Mentioning field-like text must not suppress a documented Script default.
printf 'script;\n// .allocator .device .layout\nprintln(".allocator .device .layout");\n' > "$tmp/project/src/deep/main.zag"
(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze >/dev/null)
text_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
printf '%s\n' "$text_suggest" | grep -q '"id":"script-default-allocator","supported":true,"automatic":true'
printf '%s\n' "$text_suggest" | grep -q '"id":"script-default-device","supported":true,"automatic":true'
printf '%s\n' "$text_suggest" | grep -q '"id":"script-default-layout","supported":true,"automatic":true'
explicit_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json --script-allocator custom --device gpu --layout aos)
if printf '%s\n' "$explicit_suggest" | grep -Eq '"id":"script-default-(allocator|device|layout)"'; then
    echo "explicit Script choices did not suppress matching automatic defaults" >&2; exit 1
fi
printf '%s\n' "$explicit_suggest" | grep -q '"id":"script-default-cpu","supported":true,"automatic":true'
test "$(cat "$tmp/project/src/deep/main.zag")" = $'script;\n// .allocator .device .layout\nprintln(".allocator .device .layout");'
if (cd "$tmp/project/src" && "$tmp/bin/znc" status --format yaml >/dev/null 2>&1); then
    echo "invalid status format unexpectedly accepted" >&2; exit 1
fi
if (cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format yaml >/dev/null 2>&1); then
    echo "invalid suggest format unexpectedly accepted" >&2; exit 1
fi

# Normal Zag notifications default to a supported human advisory. Unsupported
# constant-fold/inline scaffolding stays quiet, and errors_only remains an easy
# project override.
printf 'fn main() i32 { return 0; }\n' > "$tmp/project/src/deep/main.zag"
printf 'mode=light\n' > "$tmp/project/.zagd.conf"
constant_notice=$(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze 2>&1)
if printf '%s\n' "$constant_notice" | grep -q '^znc: advisory:'; then
    echo "unsupported planner scaffolding emitted a normal-Zag warning" >&2; exit 1
fi
printf 'extern fn _zag_malloc(n:i64) *u8\nfn allocate() i32 { let p:*u8 = _zag_malloc(8); return 0; }\nfn main() i32 { return allocate(); }\n' > "$tmp/project/src/deep/main.zag"
allocation_notice=$(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze 2>&1)
printf '%s\n' "$allocation_notice" | grep -q '^znc: advisory: [1-9][0-9]* allocation-effect declaration(s) available for review;'
allocation_suggest=$(cd "$tmp/project/src" && "$tmp/bin/znc" suggest --format json)
printf '%s\n' "$allocation_suggest" | grep -q '"id":"allocation-review","supported":true,"automatic":false'
printf '%s\n' "$allocation_suggest" | grep -q 'no lifetime or byte-size inference'
printf 'mode=light\nnotifications=errors_only\n' > "$tmp/project/.zagd.conf"
quiet_notice=$(cd "$tmp/project/src/deep" && "$tmp/bin/znc" check main.zag --no-analyze 2>&1)
if printf '%s\n' "$quiet_notice" | grep -q '^znc: advisory:'; then
    echo "errors_only unexpectedly emitted an advisory notification" >&2; exit 1
fi

# Every documented watch form is a real foreground control surface. This
# fixture has selected light in project policy; each explicit mode replaces the
# singleton cleanly, and off never makes later builds depend on daemon state.
(cd "$tmp/project/src" && "$tmp/bin/znc" watch >/dev/null)
wait_for_mode light
grep -q '^mode=light$' "$tmp/project/.zagd.status"
(cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode light >/dev/null)
wait_for_mode light
grep -q '^mode=light$' "$tmp/project/.zagd.status"
(cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode adaptive >/dev/null)
wait_for_mode adaptive
grep -q '^mode=adaptive$' "$tmp/project/.zagd.status"
(cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode deep >/dev/null)
wait_for_mode deep
grep -q '^mode=deep$' "$tmp/project/.zagd.status"
test "$(sed -n 's/^pid=//p' "$tmp/project/.zagd.status")" != "$first_pid"
(cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode off >/dev/null)
test ! -e "$tmp/project/.zagd.lock"
(cd "$tmp/project/src" && "$tmp/bin/znc" watch --mode deep >/dev/null)
wait_for_mode deep
grep -q '^mode=deep$' "$tmp/project/.zagd.status"

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
# Shutdown is intentionally immediate after auto-start. The daemonize parent
# returns after singleton publication, which may precede inotify setup; the
# child must observe an already-created stop file before its first blocking read.
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
