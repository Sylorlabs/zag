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
# Member gates stay portable when run directly.  The frozen aggregate is the
# release-evidence surface, so kernel/network tracing must be available rather
# than being reported as an unearned pass.
logs=$(mktemp -d /tmp/zag-reference-apps.XXXXXX)
trap 'rm -rf "$logs"' EXIT

# A compiler built outside the checkout has no way to discover the source-only
# Script prelude modules (`selfhost/std/script_*.zag`) from its executable
# directory.  Stage a read-only layout beside such a compiler so relocated
# temporary/fixpoint products exercise the same resolver contract as the
# checked-in and installed layouts.  This does not alter the compiler image or
# source tree; it only supplies the immutable module roots expected by
# `std:script_*` resolution.
compiler_dir=$(cd "$(dirname "$compiler")" && pwd)
compiler_dir_name=${compiler_dir##*/}
if [[ ! -f $compiler_dir/selfhost/std/script_io.zag &&
      ! -f $compiler_dir/std/script_io.zag &&
      ! -f $compiler_dir/../lib/zag/std/script_io.zag &&
      $compiler_dir_name != bin ]]; then
    compiler_stage="$logs/compiler-layout"
    mkdir -p "$compiler_stage"
    ln -s "$compiler" "$compiler_stage/znc"
    ln -s "$root/selfhost" "$compiler_stage/selfhost"
    ln -s "$root/std" "$compiler_stage/std"
    compiler="$compiler_stage/znc"
fi
export ZNC="$compiler"
export ZAGSCRIPT_RELEASE_EVIDENCE=1
# The package-consumer member includes several self-hosted compiler builds;
# 180s was shorter than the measured bounded fixture on the checked-in seed and
# made the aggregate report a timeout despite a passing 41/41 package gate.
# Keep the bound explicit and overridable, but make the release authority's
# default large enough to cover that measured native compile.
reference_member_timeout=${ZAGSCRIPT_REFERENCE_MEMBER_TIMEOUT_SECONDS:-900}
case "$reference_member_timeout" in
    ''|*[!0-9]*|0)
        printf 'reference-app member timeout must be a positive integer: %s\n' \
            "$reference_member_timeout" >&2
        exit 2
        ;;
esac
if ! command -v timeout >/dev/null 2>&1; then
    printf 'reference-app release evidence requires timeout(1) for bounded members\n' \
        >&2
    exit 2
fi
printf 'reference-app compiler=%s sha256=%s version=%s\n' \
    "$compiler" "$compiler_sha256" "$compiler_version"

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
    # Keep timeout's process-group supervision enabled.  `--foreground` only
    # protects interactive terminal jobs; here it would let a timed-out shell
    # leave a compiler child running after the member is recorded as failed.
    if timeout "$reference_member_timeout" "$@" >"$log" 2>&1; then
        pass=$((pass + 1))
        printf '  ok  %s\n' "$name"
        local summary
        summary=$(awk 'NF { line=$0 } END { print line }' "$log")
        if [[ -n $summary ]]; then printf '      %s\n' "$summary"; fi
    else
        local status=$?
        fail=$((fail + 1))
        printf '  XX  %s (exit=%d)\n' "$name" "$status"
        if [[ $status -eq 124 ]]; then
            printf '      member timeout after %ss\n' "$reference_member_timeout"
        fi
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
