#!/usr/bin/env bash
set -euo pipefail

script_dir="$(cd "$(dirname "$0")" && pwd)"
root_dir="$(cd "$script_dir/.." && pwd)"
cd "$root_dir"
znc_bin=${ZNC:-./znc}
tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/zag-script-set.XXXXXX")
trap 'rm -rf "$tmp_dir"' EXIT

"$znc_bin" tests/script_set.zag -o "$tmp_dir/set" --no-zagd --no-analyze >/dev/null
"$tmp_dir/set"

cat >"$tmp_dir/set-null-context.zag" <<'EOF'
@import("std:script_set")
fn main() i32 {
    unsafe {
    let context: *opaque = null as *opaque;
    let values: ScriptSetI32 = script_set_new(context);
    if (values.failed != 1 || values.context != null as *opaque ||
        values.keys != null as *i32 || values.used != null as *u8) { return 1; }
    return 0;
    }
}
EOF
"$znc_bin" "$tmp_dir/set-null-context.zag" -o "$tmp_dir/set-null-context" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/set-null-context"

cat >"$tmp_dir/set-mutation-null.zag" <<'EOF'
@import("std:script_set")
fn main() i32 {
    unsafe {
    let nothing: *ScriptSetI32 = null as *ScriptSetI32;
    if (script_set_add(nothing, 1) != 1) { return 1; }
    if (script_set_del(nothing, 1) != 1) { return 2; }
    if (script_set_rehash(nothing, 16) != 1) { return 3; }
    return 0;
    }
}
EOF
"$znc_bin" "$tmp_dir/set-mutation-null.zag" -o "$tmp_dir/set-mutation-null" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/set-mutation-null"

cat >"$tmp_dir/set-rehash-adversarial.zag" <<'EOF'
@import("std:script_set")
script;
let valid = set();
valid.keys[0] = 123;
unsafe {

let bad_next = valid;
if (script_set_rehash(&bad_next, 10) != 1 || bad_next.failed != 1 ||
    bad_next.cap != 8 || bad_next.count != 0 || bad_next.keys[0] != 123) { return 1; }

let bad_keys = valid;
bad_keys.failed = 0;
bad_keys.keys = null as *i32;
if (script_set_rehash(&bad_keys, 16) != 1 || bad_keys.failed != 1 ||
    bad_keys.cap != 8 || bad_keys.count != 0) { return 2; }

let bad_used = valid;
bad_used.failed = 0;
bad_used.used = null as *u8;
if (script_set_rehash(&bad_used, 16) != 1 || bad_used.failed != 1) { return 3; }

let bad_context = valid;
bad_context.failed = 0;
bad_context.context = null as *opaque;
if (script_set_rehash(&bad_context, 16) != 1 || bad_context.failed != 1) { return 4; }

let bad_cap = valid;
bad_cap.failed = 0;
bad_cap.cap = 10;
if (script_set_rehash(&bad_cap, 16) != 1 || bad_cap.failed != 1 ||
    bad_cap.cap != 10 || bad_cap.keys[0] != 123) { return 5; }

let inconsistent = valid;
inconsistent.failed = 0;
inconsistent.count = 1;
if (script_set_rehash(&inconsistent, 16) != 1 || inconsistent.failed != 1 ||
    inconsistent.cap != 8 || inconsistent.keys[0] != 123) { return 6; }

let bad_tombstones = valid;
bad_tombstones.failed = 0;
bad_tombstones.tombstones = bad_tombstones.cap + 1;
if (script_set_rehash(&bad_tombstones, 16) != 1 || bad_tombstones.failed != 1 ||
    bad_tombstones.cap != 8 || bad_tombstones.keys[0] != 123) { return 7; }
}
return 0;
EOF
"$znc_bin" "$tmp_dir/set-rehash-adversarial.zag" \
    -o "$tmp_dir/set-rehash-adversarial" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp_dir/set-rehash-adversarial"

cat >"$tmp_dir/bad.zag" <<'EOF'
script;
let values = set();
set_add(values);
return 0;
EOF
if "$znc_bin" "$tmp_dir/bad.zag" -o "$tmp_dir/bad" --no-zagd --no-analyze >"$tmp_dir/bad.log" 2>&1; then
    echo 'set_add arity negative unexpectedly compiled' >&2
    exit 1
fi
grep -q 'set_add expects a set and key' "$tmp_dir/bad.log"

cat >"$tmp_dir/bad-clear.zag" <<'EOF'
script;
let values = set();
set_clear(values, values);
return 0;
EOF
if "$znc_bin" "$tmp_dir/bad-clear.zag" -o "$tmp_dir/bad-clear" --no-zagd --no-analyze >"$tmp_dir/bad-clear.log" 2>&1; then
    echo 'set_clear arity negative unexpectedly compiled' >&2
    exit 1
fi
grep -q 'set_clear expects one set' "$tmp_dir/bad-clear.log"
test ! -e "$tmp_dir/bad-clear"

cat >"$tmp_dir/set-clear-null.zag" <<'EOF'
@import("std:script_set")
script;
let nothing: *ScriptSetI32 = null as *ScriptSetI32;
return script_set_clear(nothing);
EOF
"$znc_bin" "$tmp_dir/set-clear-null.zag" -o "$tmp_dir/set-clear-null" --no-zagd --no-analyze >/dev/null
set +e
"$tmp_dir/set-clear-null" >"$tmp_dir/set-clear-null.out" 2>&1
status=$?
set -e
test "$status" -eq 1

cat >"$tmp_dir/direct-text-set.zag" <<'EOF'
@import("std:script_set")
fn main() i32 {
    let context: *opaque = null as *opaque;
    let values: ScriptSetText = script_set_text_new(context);
    return script_set_text_failed(values);
}
EOF
"$znc_bin" "$tmp_dir/direct-text-set.zag" -o "$tmp_dir/direct-text-set" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
set +e
"$tmp_dir/direct-text-set" >"$tmp_dir/direct-text-set.out" 2>&1
status=$?
set -e
test "$status" -eq 1

cat >"$tmp_dir/user-clear.zag" <<'EOF'
fn set_clear(value: i32) i32 { return value + 1; }
script;
if (set_clear(41) != 42) { return 1; }
return 0;
EOF
"$znc_bin" "$tmp_dir/user-clear.zag" -o "$tmp_dir/user-clear" --no-zagd --no-analyze >/dev/null
"$tmp_dir/user-clear"

# Module discovery is based on actual convenience calls, not just the
# constructor names: user `set` and `text_set` declarations cannot hide the
# independent root `set_clear` binding or its standard-library import.
cat >"$tmp_dir/user-names-auto-import.zag" <<'EOF'
fn set(seed: i32) ScriptSetI32 {
    return ScriptSetI32{.keys = null, .used = null, .cap = 0, .count = 0,
        .tombstones = 0, .context = null, .failed = 0};
}
fn text_set(seed: i32) i32 { return seed; }
script;
let values = set(0);
if (set_clear(values) != 1 || values.failed != 1) { return 1; }
return 0;
EOF
"$znc_bin" "$tmp_dir/user-names-auto-import.zag" -o "$tmp_dir/user-names-auto-import" --no-zagd --no-analyze >/dev/null
"$tmp_dir/user-names-auto-import"

# A project module may use the same basename and producer names as a
# compiler-owned Script module, but its resolver origin is different. It must
# not inherit the context-producer exemption or launder the opaque parameter
# into a returned pointer-bearing descriptor.
mkdir -p "$tmp_dir/origin-spoof/std"
cat >"$tmp_dir/origin-spoof/std/script_set.zag" <<'EOF'
struct FakeScriptSetText { context: *opaque }
fn script_set_text_new(context: *opaque) FakeScriptSetText {
    return FakeScriptSetText{.context = context};
}
fn script_set_text_failed(values: FakeScriptSetText) i32 { return 0; }
EOF
cat >"$tmp_dir/origin-spoof/main.zag" <<'EOF'
@import("std/script_set.zag")
fn main() i32 {
    let context: *opaque = null as *opaque;
    let values: FakeScriptSetText = script_set_text_new(context);
    return script_set_text_failed(values);
}
EOF
if "$znc_bin" "$tmp_dir/origin-spoof/main.zag" -o "$tmp_dir/origin-spoof/spoof" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp_dir/origin-spoof/out" 2>&1; then
    echo 'origin-spoof context producer unexpectedly compiled' >&2
    exit 1
fi
test ! -e "$tmp_dir/origin-spoof/spoof"
grep -Eq 'borrow|retained|lifetime|provenance' "$tmp_dir/origin-spoof/out"

echo 'script set: PASS'
