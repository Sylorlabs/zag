#!/usr/bin/env bash
# Shared shell portability helpers for GNU/Linux and macOS test hosts.

zag_native_platform() {
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64) printf '%s\n' macos-arm64 ;;
        Linux:x86_64|Linux:amd64) printf '%s\n' linux-x86_64 ;;
        Linux:aarch64|Linux:arm64) printf '%s\n' linux-arm64 ;;
        *)
            echo "unsupported native Zag host: $(uname -s) $(uname -m)" >&2
            return 1
            ;;
    esac
}

# Resolve a native checkout tool without ever selecting the tracked Linux/x86
# seed on an ARM host. Installed release tools are normalized separately by the
# package/install recipes, so this helper is intentionally checkout-scoped.
zag_native_tool() {
    local zag_tool_name=$1 zag_tool_root=${2:-.} zag_tool_platform
    zag_tool_platform=$(zag_native_platform) || return 1
    zag_tool_root=${zag_tool_root%/}
    [ -n "$zag_tool_root" ] || zag_tool_root=/
    case "$zag_tool_platform" in
        linux-x86_64) printf '%s/%s\n' "$zag_tool_root" "$zag_tool_name" ;;
        *) printf '%s/%s-%s\n' "$zag_tool_root" "$zag_tool_name" "$zag_tool_platform" ;;
    esac
}

zag_native_compiler() { zag_native_tool znc "${1:-.}"; }
zag_native_daemon() { zag_native_tool zagd "${1:-.}"; }
zag_native_lsp() { zag_native_tool zag-lsp "${1:-.}"; }

# A freshly rebuilt compiler can live outside the checkout (for example under
# /tmp), while Script imports are resolved relative to the compiler layout.
# Give such a compiler the same sibling std/selfhost layout as an installed or
# checkout compiler without copying either tree. Callers may use the exported
# ZAG_COMPILER_BUNDLE_COMPILER and invoke zag_cleanup_compiler_bundle on exit.
zag_prepare_compiler_bundle() {
    local zag_bundle_compiler=$1 zag_bundle_root=${2:-.}
    local zag_bundle_compiler_dir zag_bundle_abs
    ZAG_COMPILER_BUNDLE_DIR=
    ZAG_COMPILER_BUNDLE_COMPILER=
    [ -x "$zag_bundle_compiler" ] || {
        echo "compiler bundle: compiler is not executable: $zag_bundle_compiler" >&2
        return 1
    }
    case "$zag_bundle_compiler" in
        /*) zag_bundle_abs=$zag_bundle_compiler ;;
        *)
            zag_bundle_abs=$(cd "$(dirname "$zag_bundle_compiler")" && pwd)/$(basename "$zag_bundle_compiler") || return 1
            ;;
    esac
    zag_bundle_compiler_dir=$(dirname "$zag_bundle_abs")
    if [ -e "$zag_bundle_compiler_dir/std" ] && [ -e "$zag_bundle_compiler_dir/selfhost" ]; then
        ZAG_COMPILER_BUNDLE_COMPILER=$zag_bundle_abs
        return 0
    fi
    [ -d "$zag_bundle_root/std" ] && [ -d "$zag_bundle_root/selfhost" ] || {
        echo "compiler bundle: checkout std/selfhost missing under: $zag_bundle_root" >&2
        return 1
    }
    ZAG_COMPILER_BUNDLE_DIR=$(mktemp -d "${TMPDIR:-/tmp}/zag-compiler-bundle.XXXXXX") || return 1
    if ! ln -s "$zag_bundle_abs" "$ZAG_COMPILER_BUNDLE_DIR/znc" ||
       ! ln -s "$(cd "$zag_bundle_root/std" && pwd)" "$ZAG_COMPILER_BUNDLE_DIR/std" ||
       ! ln -s "$(cd "$zag_bundle_root/selfhost" && pwd)" "$ZAG_COMPILER_BUNDLE_DIR/selfhost"; then
        rm -rf "$ZAG_COMPILER_BUNDLE_DIR"
        ZAG_COMPILER_BUNDLE_DIR=
        return 1
    fi
    ZAG_COMPILER_BUNDLE_COMPILER="$ZAG_COMPILER_BUNDLE_DIR/znc"
}

zag_cleanup_compiler_bundle() {
    if [ -n "${ZAG_COMPILER_BUNDLE_DIR:-}" ] && [ -d "$ZAG_COMPILER_BUNDLE_DIR" ]; then
        rm -rf "$ZAG_COMPILER_BUNDLE_DIR"
    fi
    ZAG_COMPILER_BUNDLE_DIR=
    ZAG_COMPILER_BUNDLE_COMPILER=
}

zag_sha256_file() {
    local zag_hash_output zag_hash_digest
    if command -v sha256sum >/dev/null 2>&1; then
        zag_hash_output=$(sha256sum "$1") || return 1
        zag_hash_digest=${zag_hash_output%%[[:space:]]*}
    elif command -v shasum >/dev/null 2>&1; then
        zag_hash_output=$(shasum -a 256 "$1") || return 1
        zag_hash_digest=${zag_hash_output%%[[:space:]]*}
    elif command -v openssl >/dev/null 2>&1; then
        zag_hash_output=$(openssl dgst -sha256 "$1") || return 1
        zag_hash_digest=${zag_hash_output##*[[:space:]]}
    else
        echo "SHA-256 tool unavailable (need sha256sum, shasum, or openssl)" >&2
        return 1
    fi
    case "$zag_hash_digest" in
        *[!0-9A-Fa-f]*|'')
            echo "SHA-256 tool returned an invalid digest for: $1" >&2
            return 1
            ;;
    esac
    [ "${#zag_hash_digest}" -eq 64 ] || {
        echo "SHA-256 tool returned an invalid digest for: $1" >&2
        return 1
    }
    printf '%s\n' "$zag_hash_digest" | tr 'A-F' 'a-f'
}

zag_sha256_stream() {
    local zag_hash_output zag_hash_digest
    if command -v sha256sum >/dev/null 2>&1; then
        zag_hash_output=$(sha256sum) || return 1
        zag_hash_digest=${zag_hash_output%%[[:space:]]*}
    elif command -v shasum >/dev/null 2>&1; then
        zag_hash_output=$(shasum -a 256) || return 1
        zag_hash_digest=${zag_hash_output%%[[:space:]]*}
    elif command -v openssl >/dev/null 2>&1; then
        zag_hash_output=$(openssl dgst -sha256) || return 1
        zag_hash_digest=${zag_hash_output##*[[:space:]]}
    else
        echo "SHA-256 tool unavailable (need sha256sum, shasum, or openssl)" >&2
        return 1
    fi
    case "$zag_hash_digest" in
        *[!0-9A-Fa-f]*|'') return 1 ;;
    esac
    [ "${#zag_hash_digest}" -eq 64 ] || return 1
    printf '%s\n' "$zag_hash_digest" | tr 'A-F' 'a-f'
}

# A [toolchain] pin is an authority input for bootstrap/release, not a banner.
# Empty output means the manifest has no pin; malformed or duplicate pin
# declarations return failure so callers cannot accidentally treat them as
# unpinned.
zag_manifest_toolchain_pin() {
    local zag_manifest=$1
    awk '
        BEGIN { section = ""; count = 0; bad = 0 }
        /^[[:space:]]*#/ || /^[[:space:]]*$/ { next }
        /^[[:space:]]*\[/ {
            line=$0; sub(/^[[:space:]]*\[/, "", line); sub(/\][[:space:]]*$/, "", line)
            section=line; next
        }
        section == "toolchain" {
            if ($0 !~ /^[[:space:]]*compiler[[:space:]]*=[[:space:]]*"sha256:[0-9A-Fa-f]{64}"[[:space:]]*$/) { bad=1; next }
            value=$0; sub(/^[^\"]*\"/, "", value); sub(/\"[^\"]*$/, "", value)
            count++
            if (count == 1) pin=value
        }
        END {
            if (bad || count > 1) exit 1
            if (count == 1) print pin
        }
    ' "$zag_manifest"
}

zag_verify_manifest_toolchain() {
    local zag_image=$1 zag_manifest=$2 zag_pin zag_digest
    zag_pin=$(zag_manifest_toolchain_pin "$zag_manifest") || {
        echo "toolchain identity: malformed [toolchain] compiler pin in $zag_manifest" >&2
        return 1
    }
    [ -n "$zag_pin" ] || return 0
    zag_digest=$(zag_sha256_file "$zag_image") || return 1
    if [ "$zag_pin" != "sha256:$zag_digest" ]; then
        echo "toolchain identity: $zag_image does not match the compiler pin in $zag_manifest" >&2
        return 1
    fi
    return 0
}

# BSD sort lacks -z. Keep path inventories NUL-delimited and byte-sorted by
# preferring GNU sort, with ubiquitous scripting runtimes as bounded fallbacks.
zag_sort_nul() {
    if LC_ALL=C sort -z </dev/null >/dev/null 2>&1; then
        LC_ALL=C sort -z
    elif command -v perl >/dev/null 2>&1; then
        LC_ALL=C perl -0e 'use bytes; print sort <STDIN>'
    elif command -v python3 >/dev/null 2>&1; then
        python3 -c 'import sys; d=sys.stdin.buffer.read().split(b"\0"); d=d[:-1] if d and d[-1] == b"" else d; sys.stdout.buffer.write(b"".join(x+b"\0" for x in sorted(d)))'
    else
        echo "NUL-safe sort unavailable (need sort -z, perl, or python3)" >&2
        return 1
    fi
}

zag_sed_in_place() {
    sed -i.bak "$1" "$2"
    rm -f "$2.bak"
}

zag_swap_lines_2_3() {
    awk 'NR == 2 { second = $0; next }
         NR == 3 { print; print second; next }
         { print }' "$1" >"$1.tmp.$$"
    mv "$1.tmp.$$" "$1"
}

zag_file_size() {
    if stat -c %s "$1" >/dev/null 2>&1; then
        stat -c %s "$1"
    else
        stat -f %z "$1"
    fi
}

# macOS does not ship GNU truncate. Keep sparse-file and torn-record fixtures
# available on both hosts without materializing their zero-filled contents.
zag_truncate_file() {
    local zag_truncate_size=$1 zag_truncate_path=$2
    case "$zag_truncate_size" in ''|*[!0-9]*) return 2 ;; esac
    if command -v truncate >/dev/null 2>&1; then
        truncate -s "$zag_truncate_size" "$zag_truncate_path"
    elif command -v perl >/dev/null 2>&1; then
        perl -e 'truncate($ARGV[0], $ARGV[1]) or die "truncate: $!\n"' \
            "$zag_truncate_path" "$zag_truncate_size"
    else
        echo 'file truncation unavailable (need truncate or perl)' >&2
        return 1
    fi
}

zag_direct_children() {
    local zag_parent_pid=$1
    if command -v pgrep >/dev/null 2>&1; then
        pgrep -P "$zag_parent_pid" 2>/dev/null || true
    else
        ps -axo pid=,ppid= | awk -v parent="$zag_parent_pid" '$2 == parent { print $1 }'
    fi
}

zag_collect_process_tree() {
    local zag_tree_pid=$1 zag_tree_child
    for zag_tree_child in $(zag_direct_children "$zag_tree_pid"); do
        zag_collect_process_tree "$zag_tree_child"
    done
    ZAG_TREE_PIDS+=("$zag_tree_pid")
}

# Start a background command in its own process group when Bash job control can
# do so. Callers read ZAG_ISOLATED_PID/ZAG_ISOLATED_PGID after this returns.
zag_start_isolated() {
    local zag_monitor_was_on=0 zag_started_pgid
    case $- in *m*) zag_monitor_was_on=1 ;; esac
    set -m
    "$@" &
    ZAG_ISOLATED_PID=$!
    [ "$zag_monitor_was_on" -eq 1 ] || set +m
    # A successful command may exit before ps observes it. Treat that as an
    # already-finished child, not as a harness failure under set -e/pipefail.
    zag_started_pgid=$(ps -o pgid= -p "$ZAG_ISOLATED_PID" 2>/dev/null | tr -d '[:space:]' || true)
    if [ "$zag_started_pgid" = "$ZAG_ISOLATED_PID" ]; then
        ZAG_ISOLATED_PGID=$zag_started_pgid
    else
        ZAG_ISOLATED_PGID=
    fi
}

zag_terminate_process_tree() {
    local zag_tree_pid=$1 zag_tree_pgid=${2:-} zag_tree_round zag_tree_member
    local -a ZAG_TREE_PIDS=()

    # Retain the original descendants even if the root exits and they are
    # reparented. Re-snapshot during TERM grace to catch late children.
    zag_collect_process_tree "$zag_tree_pid"
    if [ -n "$zag_tree_pgid" ]; then
        kill -TERM -- "-$zag_tree_pgid" 2>/dev/null || true
    fi
    for zag_tree_member in "${ZAG_TREE_PIDS[@]}"; do
        kill -TERM "$zag_tree_member" 2>/dev/null || true
    done
    for zag_tree_round in 1 2 3 4 5; do
        sleep 1
        if zag_process_running "$zag_tree_pid"; then
            ZAG_TREE_PIDS=()
            zag_collect_process_tree "$zag_tree_pid"
            for zag_tree_member in "${ZAG_TREE_PIDS[@]}"; do
                kill -TERM "$zag_tree_member" 2>/dev/null || true
            done
        fi
    done

    # KILL the process group and every retained/new descendant, not merely the
    # original parent. This closes the orphan-survivor hole in portable timeout.
    if [ -n "$zag_tree_pgid" ]; then
        kill -KILL -- "-$zag_tree_pgid" 2>/dev/null || true
    fi
    if zag_process_running "$zag_tree_pid"; then
        ZAG_TREE_PIDS=()
        zag_collect_process_tree "$zag_tree_pid"
    fi
    for zag_tree_member in "${ZAG_TREE_PIDS[@]}"; do
        kill -KILL "$zag_tree_member" 2>/dev/null || true
    done
    kill -KILL "$zag_tree_pid" 2>/dev/null || true
}

zag_process_running() {
    local zag_process_state
    zag_process_state=$(ps -o stat= -p "$1" 2>/dev/null | awk 'NF { print $1; exit }')
    [ -n "$zag_process_state" ] && [ "${zag_process_state#Z}" = "$zag_process_state" ]
}

zag_run_bounded() {
    local zag_bound_seconds=$1
    local zag_bound_pid zag_bound_pgid zag_bound_started
    shift
    zag_start_isolated "$@"
    zag_bound_pid=$ZAG_ISOLATED_PID
    zag_bound_pgid=$ZAG_ISOLATED_PGID
    zag_bound_started=$SECONDS
    while zag_process_running "$zag_bound_pid"; do
        if [ "$((SECONDS - zag_bound_started))" -ge "$zag_bound_seconds" ]; then
            zag_terminate_process_tree "$zag_bound_pid" "$zag_bound_pgid"
            wait "$zag_bound_pid" 2>/dev/null || true
            return 124
        fi
        sleep 1
    done
    wait "$zag_bound_pid"
}

# The public CLI prints a banner, not a bare version. Parse exactly that
# contract so release checks neither reject valid compilers nor accept a
# warning, multi-line output, or a filename masquerading as a version.
zag_compiler_version() {
    local zag_version_banner zag_version_pattern
    zag_version_banner=$(zag_run_bounded 30 "$1" version) || return 1
    zag_version_pattern='^znc ([0-9][0-9A-Za-z._-]*) \(edition [0-9]+\)$'
    if [[ $zag_version_banner =~ $zag_version_pattern ]]; then
        printf '%s\n' "${BASH_REMATCH[1]}"
    else
        echo 'compiler version: expected one znc VERSION (edition YEAR) banner' >&2
        return 1
    fi
}

zag_assert_native_executable() {
    local zag_native_artifact=$1 zag_native_file
    test -x "$zag_native_artifact" || return 1
    zag_native_file=$(LC_ALL=C file -b "$zag_native_artifact" 2>/dev/null) || return 1
    case "$(uname -s):$(uname -m)" in
        Darwin:arm64)
            [ "$zag_native_file" = 'Mach-O 64-bit executable arm64' ] &&
            codesign --verify --deep --strict "$zag_native_artifact" >/dev/null 2>&1
            ;;
        Linux:x86_64|Linux:amd64)
            printf '%s\n' "$zag_native_file" | grep -Eq '^ELF 64-bit.*x86-64.*statically linked' &&
            readelf -h "$zag_native_artifact" | grep -Eq 'Class:[[:space:]]+ELF64' &&
            readelf -h "$zag_native_artifact" | grep -Eq 'Type:[[:space:]]+EXEC' &&
            readelf -h "$zag_native_artifact" | grep -Eq 'Machine:[[:space:]]+Advanced Micro Devices X86-64' &&
            ! readelf -l "$zag_native_artifact" 2>/dev/null | grep -q 'INTERP' &&
            ! readelf -d "$zag_native_artifact" 2>/dev/null | grep -q 'NEEDED'
            ;;
        Linux:aarch64|Linux:arm64)
            printf '%s\n' "$zag_native_file" | grep -Eq '^ELF 64-bit.*ARM aarch64.*statically linked' &&
            readelf -h "$zag_native_artifact" | grep -Eq 'Class:[[:space:]]+ELF64' &&
            readelf -h "$zag_native_artifact" | grep -Eq 'Type:[[:space:]]+EXEC' &&
            readelf -h "$zag_native_artifact" | grep -Eq 'Machine:[[:space:]]+AArch64' &&
            ! readelf -l "$zag_native_artifact" 2>/dev/null | grep -q 'INTERP' &&
            ! readelf -d "$zag_native_artifact" 2>/dev/null | grep -q 'NEEDED'
            ;;
        *) return 1 ;;
    esac
}
