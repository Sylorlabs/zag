#!/usr/bin/env bash
# Apple Silicon ZagScript reference-application aggregate. Member gates remain
# independently authoritative; this aggregate proves they coexist against one
# freshly selected native compiler without weakening the Linux release suite.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
. "$root/tests/portable.sh"
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'macOS reference-app aggregate requires Apple Silicon macOS' >&2
    exit 2
fi

caller_dir=$PWD
compiler=${ZNC:-"$root/znc-macos-arm64"}
case "$compiler" in
    /*) ;;
    *) compiler="$caller_dir/${compiler#./}" ;;
esac
test -x "$compiler"
zag_prepare_compiler_bundle "$compiler" "$root" || exit 1
compiler=$ZAG_COMPILER_BUNDLE_COMPILER
trap 'zag_cleanup_compiler_bundle' EXIT
compiler_version=$("$compiler" version) || exit 1
compiler_sha256=$(zag_sha256_file "$compiler") || exit 1
[[ $compiler_sha256 =~ ^[0-9a-f]{64}$ ]] || exit 1

export ZNC="$compiler"
export ZAGSCRIPT_RELEASE_EVIDENCE=1
member_timeout=${ZAGSCRIPT_REFERENCE_MEMBER_TIMEOUT_SECONDS:-900}
case "$member_timeout" in
    ''|*[!0-9]*|0)
        echo "macOS reference-app member timeout must be a positive integer: $member_timeout" >&2
        exit 2
        ;;
esac

logs=$(mktemp -d "${TMPDIR:-/tmp}/zag-reference-apps-macos.XXXXXX")
trap 'rm -rf "$logs"; zag_cleanup_compiler_bundle' EXIT
printf 'macOS reference-app compiler=%s sha256=%s version=%s\n' \
    "$compiler" "$compiler_sha256" "$compiler_version"

pass=0
fail=0
total=0
run_member() {
    local name=$1
    shift
    total=$((total + 1))
    local log="$logs/$total.log"
    printf '── [%d/6] %s\n' "$total" "$name"
    if zag_run_bounded "$member_timeout" "$@" >"$log" 2>&1; then
        pass=$((pass + 1))
        printf '  ok  %s\n' "$name"
        local summary
        summary=$(awk 'NF { line=$0 } END { print line }' "$log")
        [ -z "$summary" ] || printf '      %s\n' "$summary"
    else
        local status=$?
        fail=$((fail + 1))
        printf '  XX  %s (exit=%d)\n' "$name" "$status"
        if [ -s "$log" ]; then sed 's/^/      /' "$log"; fi
    fi
}

run_member 'CLI automation' bash "$root/tests/run_reference_cli_automation.sh"
run_member 'local package consumer' bash "$root/tests/run_package_resolution.sh"
run_member 'Network.framework TLS HTTP service' bash "$root/tests/run_reference_tls_http_service_macos.sh"
run_member 'SQLite-backed HTTP service' bash "$root/tests/run_reference_sqlite_http_service.sh"
run_member 'concurrency services' bash "$root/tests/run_macos_concurrency_services.sh"
run_member 'dynamic plugin' bash "$root/tests/run_reference_dynamic_plugin_macos.sh"

printf 'zagscript-reference-apps-macos pass=%d fail=%d\n' "$pass" "$fail"
[[ $total -eq 6 && $pass -eq 6 && $fail -eq 0 ]]
