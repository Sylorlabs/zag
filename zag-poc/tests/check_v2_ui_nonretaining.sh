#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-v2-ui-nonretaining.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir -p "$tmp/positive" "$tmp/negative"
printf 'name = "v2uinonretaining"\nversion = "0"\nedition = "2027"\n' > "$tmp/positive/zag.mod"
cat > "$tmp/positive/main.zag" <<'ZAG'
fn mutate(value: *i64) i32 {
    value.* = value.* + 1;
    return value.* as i32;
}
fn main() i32 {
    let value: i64 = 1;
    _ = mutate(&value);
    let text: []u8 = _zag_i64_to_str(value);
    _zag_print(text);
    _zag_str_free(text);
    if (value != 2) { return 3; }
    return 0;
}
ZAG
(cd "$tmp/positive" && "$OLDPWD/$ZNC" main.zag --no-zagd --analyze-strict --no-foreground-cache -o out)
output=$("$tmp/positive/out")
[ "$output" = "2" ] || { echo "unexpected positive output: $output"; exit 1; }

printf 'name = "v2uistackescape"\nversion = "0"\nedition = "2027"\n' > "$tmp/negative/zag.mod"
cat > "$tmp/negative/main.zag" <<'ZAG'
struct Escaped { pointer: *i64 }
fn leak() Escaped {
    let value: i64 = 9;
    return Escaped{ .pointer = &value };
}
fn main() i32 { let escaped: Escaped = leak(); return escaped.pointer.* as i32; }
ZAG
if (cd "$tmp/negative" && "$OLDPWD/$ZNC" main.zag --no-zagd --analyze-strict --no-foreground-cache -o out) >"$tmp/negative/log" 2>&1 || [ -e "$tmp/negative/out" ]; then
    echo "stack-address return unexpectedly compiled"
    cat "$tmp/negative/log"
    exit 1
fi
grep -q 'address of local' "$tmp/negative/log" || { cat "$tmp/negative/log"; exit 1; }
echo "v2 UI non-retaining/discard contracts: PASS"
