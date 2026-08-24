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
    zag_started_pgid=$(ps -o pgid= -p "$ZAG_ISOLATED_PID" 2>/dev/null | tr -d '[:space:]')
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
