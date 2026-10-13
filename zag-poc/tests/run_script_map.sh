#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
source tests/portable.sh
compiler=${ZNC:-$(zag_native_compiler .)}
tmp=$(mktemp -d /tmp/zag-script-map.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
printf '%s\n' 'name = "script-map-test"' 'edition = "2027"' >"$tmp/zag.mod"
mkdir -p "$tmp/tests" "$tmp/selfhost/std"
cp tests/script_map.zag "$tmp/tests/"
cp selfhost/std/script_map.zag "$tmp/selfhost/std/"
"$compiler" "$tmp/tests/script_map.zag" -o "$tmp/script_map" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/compile.log" 2>&1 || {
    cat "$tmp/compile.log" >&2
    exit 1
}
"$tmp/script_map"
cp tests/script_map_mixed_bad.zag "$tmp/tests/"
if "$compiler" "$tmp/tests/script_map_mixed_bad.zag" -o "$tmp/mixed_bad" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/mixed_bad.log" 2>&1; then
    echo "mixed Script map values unexpectedly compiled" >&2
    exit 1
fi
test ! -e "$tmp/mixed_bad"
cp tests/script_map_checked.zag "$tmp/tests/"
"$compiler" "$tmp/tests/script_map_checked.zag" -o "$tmp/checked" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/checked.log" 2>&1 || {
    cat "$tmp/checked.log" >&2
    exit 1
}
"$tmp/checked" success
for mode in constructor insert missing set set_heap; do
    set +e
    "$tmp/checked" "$mode" >"$tmp/$mode.out" 2>"$tmp/$mode.err"
    status=$?
    set -e
    test "$status" -eq 1
    case "$mode" in
        missing) grep -q 'Zag Script map key was not found' "$tmp/$mode.err" ;;
        *) grep -q 'Zag Script map allocation failed' "$tmp/$mode.err" ;;
    esac
done
echo "script typed map: PASS"
