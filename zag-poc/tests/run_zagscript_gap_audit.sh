#!/usr/bin/env bash
# Execute the focused authorities behind currently non-green ZagScript 1.0
# matrix rows. This is diagnostic evidence, never a release self-authorizer.
set -u
cd "$(dirname "$0")/.."
. tests/portable.sh

explicit_znc=0
if [ "${ZNC+x}" = x ]; then explicit_znc=1; fi
export ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
export ZAGD=${ZAGD:-"$PWD/zagd-macos-arm64"}
if [ ! -x "$ZNC" ]; then
    if [ "$explicit_znc" -eq 1 ]; then
        echo "gap-audit: explicit ZNC is not executable: $ZNC" >&2
        exit 2
    fi
    export ZNC="$PWD/znc"
fi
if [ ! -x "$ZAGD" ]; then export ZAGD="$PWD/zagd"; fi
zag_prepare_compiler_bundle "$ZNC" "$PWD" || exit 2
export ZNC="$ZAG_COMPILER_BUNDLE_COMPILER"
trap 'zag_cleanup_compiler_bundle' EXIT

pass=0
fail=0
run() {
    local suite=$1
    printf '\n=== gap-audit %s ===\n' "$suite"
    if bash "$suite"; then
        pass=$((pass + 1))
    else
        local rc=$?
        fail=$((fail + 1))
        printf 'gap-audit FAIL rc=%d %s\n' "$rc" "$suite" >&2
    fi
}

common_suites=(
    tests/run_typed_authority.sh
    tests/run_script_lifetime.sh
    tests/run_zagd_benchmark_policy.sh
    tests/run_script_json_csv.sh
    tests/run_network_foundation.sh
    tests/run_http_websocket_foundation.sh
    tests/run_database_drivers.sh
    tests/run_package_resolution.sh
    tests/run_package_lock_generator.sh
)

# Keep target-specific authorities target-specific. The Linux ZIR authority
# deliberately emits and executes ELF x86-64 artifacts, while the dynamic ABI
# suite exercises ELF SONAME/libc contracts. On Apple Silicon, use the native
# view plus Mach-O dylib/object/plugin authorities instead of mis-executing
# foreign artifacts and reporting platform mismatches as language failures.
platform_suites=()
case "$(uname -s):$(uname -m)" in
    Linux:x86_64)
        platform_suites+=(
            tests/run_zir_authority.sh
            tests/run_dynamic_abi.sh
        )
        ;;
    Darwin:arm64)
        platform_suites+=(
            tests/run_zagscript_views.sh
            tests/run_macos_dylib.sh
            tests/run_macos_object.sh
            tests/run_reference_dynamic_plugin_macos.sh
        )
        ;;
    *)
        echo "gap-audit: no target-specific authority set for $(uname -s):$(uname -m)" >&2
        fail=$((fail + 1))
        ;;
esac

for suite in "${common_suites[@]}" "${platform_suites[@]}"; do
    if [ -f "$suite" ]; then run "$suite"; else
        echo "gap-audit missing suite: $suite" >&2
        fail=$((fail + 1))
    fi
done

printf '\nZagScript gap audit: pass=%d fail=%d\n' "$pass" "$fail"
test "$fail" -eq 0
