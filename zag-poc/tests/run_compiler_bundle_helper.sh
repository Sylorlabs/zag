#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-compiler-bundle-test.XXXXXX")
trap 'zag_cleanup_compiler_bundle; rm -rf "$tmp"' EXIT

mkdir -p "$tmp/checkout/std" "$tmp/checkout/selfhost" "$tmp/external"
cat >"$tmp/external/compiler" <<'EOF'
#!/usr/bin/env bash
exit 0
EOF
chmod +x "$tmp/external/compiler"

zag_prepare_compiler_bundle "$tmp/external/compiler" "$tmp/checkout"
test -x "$ZAG_COMPILER_BUNDLE_COMPILER"
test -L "$ZAG_COMPILER_BUNDLE_DIR/std"
test -L "$ZAG_COMPILER_BUNDLE_DIR/selfhost"
expected_std=$(cd "$tmp/checkout/std" && pwd)
expected_selfhost=$(cd "$tmp/checkout/selfhost" && pwd)
test "$(readlink "$ZAG_COMPILER_BUNDLE_DIR/std")" = "$expected_std"
test "$(readlink "$ZAG_COMPILER_BUNDLE_DIR/selfhost")" = "$expected_selfhost"
created_bundle=$ZAG_COMPILER_BUNDLE_DIR
zag_cleanup_compiler_bundle
test ! -e "$created_bundle"

mkdir -p "$tmp/complete/std" "$tmp/complete/selfhost"
cp "$tmp/external/compiler" "$tmp/complete/znc"
zag_prepare_compiler_bundle "$tmp/complete/znc" "$tmp/checkout"
test -z "$ZAG_COMPILER_BUNDLE_DIR"
test "$ZAG_COMPILER_BUNDLE_COMPILER" = "$tmp/complete/znc"

if zag_prepare_compiler_bundle "$tmp/missing" "$tmp/checkout" >/dev/null 2>&1; then
    echo 'compiler bundle unexpectedly accepted a missing compiler' >&2
    exit 1
fi

echo 'compiler bundle helper: PASS'
