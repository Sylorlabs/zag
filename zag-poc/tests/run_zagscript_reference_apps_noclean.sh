#!/usr/bin/env bash
# Frozen ZagScript 1.0 Linux x86-64 native reference-application suite.
# This is application-row evidence only; it is not a matrix, release, or master
# gate and does not broaden any component gate's documented support boundary.
set -uo pipefail

root=$(cd "$(dirname "$0")/.." && pwd)
caller_dir=$PWD
compiler=${ZNC:-"$root/znc"}
case "$compiler" in
    /*) ;;
    *) compiler="$caller_dir/$compiler" ;;
esac
if [[ ! -x $compiler ]]; then
    printf 'reference-app compiler is not executable: %s\n' "$compiler" >&2
    exit 1
fi
compiler_version=$("$compiler" version) || {
    printf 'reference-app compiler version probe failed: %s\n' "$compiler" >&2
    exit 1
}
if [[ ! $compiler_version =~ [^[:space:]] ]]; then
    printf 'reference-app compiler returned an empty version: %s\n' \
        "$compiler" >&2
    exit 1
fi
if ! compiler_sha256=$(sha256sum "$compiler" | awk '{ print $1 }') ||
   [[ ! $compiler_sha256 =~ ^[0-9a-f]{64}$ ]]; then
    printf 'reference-app compiler checksum failed: %s\n' "$compiler" >&2
    exit 1
fi
export ZNC="$compiler"
# Member gates stay portable when run directly.  The frozen aggregate is the
# release-evidence surface, so kernel/network tracing must be available rather
# than being reported as an unearned pass.
export ZAGSCRIPT_RELEASE_EVIDENCE=1
printf 'reference-app compiler=%s sha256=%s version=%s\n' \
    "$compiler" "$compiler_sha256" "$compiler_version"

logs=$(mktemp -d /tmp/zag-reference-apps.XXXXXX)
pass=0
fail=0
total=0

validate_package_workspace_inventory() {
    local workspace="$root/tests/package_resolution/workspace"
    local inventory="$root/tests/package_resolution/workspace.inventory.tsv"
    local generated="$logs/package-workspace.inventory.generated.tsv"
    if [[ ! -d $workspace || ! -f $inventory ]]; then
        printf 'package workspace inventory input is missing: %s\n' \
            "$inventory" >&2
        return 1
    fi

    local unsupported
    unsupported=$(find "$workspace" -mindepth 1 \
        ! -type d ! -type f ! -type l -print -quit)
    if [[ -n $unsupported ]]; then
        printf 'package workspace contains an unsupported entry: %s\n' \
            "$unsupported" >&2
        return 1
    fi

    {
        printf 'format\tzag-package-workspace-inventory-v1\n'
        local relative target
        while IFS= read -r -d '' relative; do
            if [[ $relative == *$'\t'* || $relative == *$'\n'* ]]; then
                printf 'package workspace path is not TSV-safe: %q\n' \
                    "$relative" >&2
                return 1
            fi
            if [[ -L $workspace/$relative ]]; then
                target=$(readlink -- "$workspace/$relative") || return 1
                if [[ $target == *$'\t'* || $target == *$'\n'* ]]; then
                    printf 'package workspace link target is not TSV-safe: %q\n' \
                        "$relative" >&2
                    return 1
                fi
                printf 'link\t%s\t%s\n' "$relative" "$target"
            else
                printf 'file\t%s\n' "$relative"
            fi
        done < <(LC_ALL=C find "$workspace" -mindepth 1 \
            \( -type f -o -type l \) -printf '%P\0' | LC_ALL=C sort -z)
    } >"$generated" || return 1

    if ! cmp -s "$inventory" "$generated"; then
        echo 'package workspace inventory is missing, stale, or malformed' >&2
        diff -u "$inventory" "$generated" >&2 || true
        return 1
    fi
}

if ! validate_package_workspace_inventory; then
    exit 1
fi
printf 'package-workspace-inventory=checked\n'

run_member() {
    local name=$1
    shift
    total=$((total + 1))
    local log="$logs/$total.log"
    printf '── [%d/9] %s\n' "$total" "$name"
    if "$@" >"$log" 2>&1; then
        pass=$((pass + 1))
        printf '  ok  %s\n' "$name"
        local summary
        summary=$(awk 'NF { line=$0 } END { print line }' "$log")
        if [[ -n $summary ]]; then printf '      %s\n' "$summary"; fi
    else
        local status=$?
        fail=$((fail + 1))
        printf '  XX  %s (exit=%d)\n' "$name" "$status"
        if [[ -s $log ]]; then sed 's/^/      /' "$log"; else
            echo '      member produced no diagnostic output'
        fi
    fi
}

run_member 'CLI automation' bash "$root/tests/run_reference_cli_automation.sh"
run_member 'concurrent file indexer' bash "$root/tests/run_reference_concurrent_file_indexer.sh"
run_member 'local package consumer' bash "$root/tests/run_package_resolution.sh"
run_member 'TLS HTTP client/server' bash "$root/tests/run_reference_tls_http_service.sh"
run_member 'WebSocket service' bash "$root/tests/run_reference_websocket_service.sh"
run_member 'SQLite-backed HTTP service' bash "$root/tests/run_reference_sqlite_http_service.sh"
run_member 'async worker' bash "$root/tests/run_linux_concurrency_services.sh"
run_member 'dynamic plugin' bash "$root/tests/run_reference_dynamic_plugin.sh"
run_member 'pinned Zagkit contract fixture' \
    bash "$root/tests/run_reference_zagkit_contract.sh"

printf 'zagscript-reference-apps pass=%d fail=%d\n' "$pass" "$fail"
[[ $total -eq 9 && $pass -eq 9 && $fail -eq 0 ]]
