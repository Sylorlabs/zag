#!/usr/bin/env bash
# Native reference application: a frozen copy of the small compiler/runtime
# contract Zagkit consumes.  This does not import or certify Zagkit GUI code.
set -euo pipefail
cd "$(dirname "$0")/.."

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
test "$(sha256sum "$fixture_dir/platform_capabilities_v1.zag" | awk '{print $1}')" = \
    "$(provenance_value fixture_contract_sha256)"
test "$(sha256sum "$source_file" | awk '{print $1}')" = \
    "$(provenance_value fixture_test_sha256)"
revision=$(provenance_value upstream_revision)
[[ $revision =~ ^[0-9a-f]{40}$ ]]
for key in upstream_contract_sha256 upstream_test_sha256 \
    fixture_contract_sha256 fixture_test_sha256; do
    value=$(provenance_value "$key")
    [[ $value =~ ^[0-9a-f]{64}$ ]]
done
pass=$((pass + 1))

assert_static_x86_64() {
    local artifact=$1
    test -x "$artifact"
    file "$artifact" | grep -q 'ELF 64-bit LSB executable, x86-64'
    file "$artifact" | grep -q 'statically linked'
    readelf -h "$artifact" | grep -q 'Class:.*ELF64'
    readelf -h "$artifact" | \
        grep -q 'Machine:.*Advanced Micro Devices X86-64'
    readelf -h "$artifact" | grep -q 'Type:.*EXEC'
    if readelf -l "$artifact" | grep -q 'INTERP'; then
        echo 'Zagkit contract fixture unexpectedly requires a dynamic interpreter' >&2
        return 1
    fi
    if readelf -d "$artifact" 2>/dev/null | grep -q 'NEEDED'; then
        echo 'Zagkit contract fixture unexpectedly has a dynamic dependency' >&2
        return 1
    fi
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

assert_static_x86_64 "$binary"
pass=$((pass + 1))

run_contract "$binary" primary
pass=$((pass + 1))

# The pinned schema is intentionally self-contained: compiling from an
# unrelated working directory must resolve its source-relative import and
# produce byte-identical native output.
(cd "$tmp" && "$znc_bin" "$source_file" -o "$relocated" \
    --no-zagd --no-analyze --no-foreground-cache) >"$tmp/relocated.out" 2>&1
assert_static_x86_64 "$relocated"
cmp -s "$binary" "$relocated"
pass=$((pass + 1))
run_contract "$relocated" relocated
pass=$((pass + 1))

test "$pass" -eq "$expected_pass"
printf 'Zagkit capability contract reference app: pass=%d fail=0 provenance=checked\n' \
    "$pass"
