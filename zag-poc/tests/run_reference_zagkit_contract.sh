#!/usr/bin/env bash
# Native reference application: a frozen copy of the small compiler/runtime
# contract Zagkit consumes.  This does not import or certify Zagkit GUI code.
set -euo pipefail
cd "$(dirname "$0")/.."
. tests/portable.sh

root=$(pwd)
znc_bin=${ZNC:-./znc}
case "$znc_bin" in /*) ;; *) znc_bin="$root/${znc_bin#./}" ;; esac

source_file="$root/tests/reference_apps/zagkit_contract/main.zag"
fixture_dir="$root/tests/reference_apps/zagkit_contract"
provenance="$fixture_dir/provenance.tsv"
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-zagkit.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
binary="$tmp/zagkit-contract"
relocated="$tmp/zagkit-contract-relocated"
pass=0
expected_pass=6

provenance_value() {
    local key=$1
    awk -F '\t' -v key="$key" '$1 == key { count++; value=$2 } END {
        if (count != 1) exit 1
        print value
    }' "$provenance"
}

test "$(wc -l < "$provenance")" -eq 12
awk -F '\t' 'NF != 2 || $1 == "" || $2 == "" || seen[$1]++ { exit 1 }' \
    "$provenance"
test "$(provenance_value schema_version)" = 1
test "$(provenance_value contract_id)" = zagkit-platform-capabilities-v1
test "$(provenance_value upstream_repository)" = \
    https://github.com/Sylorlabs/zagkit
test "$(provenance_value upstream_contract_path)" = \
    src/platform/capabilities.zag
test "$(provenance_value upstream_test_path)" = \
    tests/platform_capabilities_contract.zag
test "$(provenance_value fixture_contract_path)" = platform_capabilities_v1.zag
test "$(provenance_value fixture_test_path)" = main.zag
test "$(zag_sha256_file "$fixture_dir/platform_capabilities_v1.zag")" = \
    "$(provenance_value fixture_contract_sha256)"
test "$(zag_sha256_file "$source_file")" = \
    "$(provenance_value fixture_test_sha256)"
revision=$(provenance_value upstream_revision)
[[ $revision =~ ^[0-9a-f]{40}$ ]]
for key in upstream_contract_sha256 upstream_test_sha256 \
    fixture_contract_sha256 fixture_test_sha256; do
    value=$(provenance_value "$key")
    [[ $value =~ ^[0-9a-f]{64}$ ]]
done
pass=$((pass + 1))

assert_native_executable() {
    local artifact=$1
    zag_assert_native_executable "$artifact"
}

run_contract() {
    local artifact=$1
    local label=$2
    "$artifact" >"$tmp/$label.out" 2>"$tmp/$label.err"
    printf '%s\n' 'Zagkit capability contract: pass=5 fail=0 schema=1' | \
        cmp -s - "$tmp/$label.out"
    test ! -s "$tmp/$label.err"
}

"$znc_bin" "$source_file" -o "$binary" --no-zagd --no-analyze \
    --no-foreground-cache >"$tmp/build.out" 2>&1
test -x "$binary"
pass=$((pass + 1))

assert_native_executable "$binary"
pass=$((pass + 1))

run_contract "$binary" primary
pass=$((pass + 1))

# The pinned schema is intentionally self-contained: compiling from an
# unrelated working directory must resolve its source-relative import and
# produce byte-identical native output.
(cd "$tmp" && "$znc_bin" "$source_file" -o "$relocated" \
    --no-zagd --no-analyze --no-foreground-cache) >"$tmp/relocated.out" 2>&1
assert_native_executable "$relocated"
cmp -s "$binary" "$relocated"
pass=$((pass + 1))
run_contract "$relocated" relocated
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'Zagkit capability contract reference app: pass=%d fail=0 provenance=checked\n' \
    "$pass"
