#!/usr/bin/env bash
# bootstrap.sh — rebuild the supported Zag v1 compiler seeds from source.
#
# Produces the compiler and its automatic, correctness-independent planner:
#   ./znc — native x86-64 compiler with GPU MLIR + WASM backends
#           (selfhost/native/znc.zag)
#
# ./znc reads Zag and writes a static x86-64 ELF, GPU MLIR, or WASM directly.
# No path invokes Python, C, Zig, cc, as, ld, or libc.
#
# Like every self-hosted language, you bootstrap from trusted
# seed binaries — you cannot compile from absolutely nothing.
set -e
set -o pipefail
cd "$(dirname "$0")"

bootstrap_seed=${ZAG_BOOTSTRAP_SEED:-./znc}
if [ ! -x "$bootstrap_seed" ]; then
    echo "bootstrap: native seed is missing or not executable: $bootstrap_seed" >&2
    echo "bootstrap: no non-Zag fallback exists; provide a trusted Zag-built seed." >&2
    exit 1
fi

echo "== native bootstrap: Zag -> x86-64 ELF (no cc/as/ld/libc) =="
echo "   trusted seed: $bootstrap_seed"
bootstrap_tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-bootstrap.XXXXXX")
bootstrap_active_pid=""
bootstrap_active_unit=""
bootstrap_unit_serial=0
bootstrap_tmp_nonce=${bootstrap_tmp##*/}
bootstrap_tmp_nonce=$(printf '%s' "$bootstrap_tmp_nonce" | tr -cd '[:alnum:]')
if [ -z "$bootstrap_tmp_nonce" ]; then
    echo "bootstrap: temporary directory did not provide a safe unit nonce" >&2
    exit 1
fi
bootstrap_unit_marker="zag-bootstrap-owner:${bootstrap_tmp_nonce}"
bootstrap_active_mode=""
bootstrap_active_pid_start=""
bootstrap_active_pgrp=""
bootstrap_active_session=""
bootstrap_active_parent_pid=""
bootstrap_active_parent_start=""
bootstrap_active_identity_captured=0
bootstrap_systemctl() {
    # Every user-manager request is bounded.  A wedged manager must never
    # wedge bootstrap teardown or progress accounting.
    timeout --foreground --kill-after=2s 10 systemctl --user "$@"
}
bootstrap_systemd_unit_owned() {
    local unit=$1 description control_group serial
    case "$unit" in
        zag-bootstrap-${bootstrap_tmp_nonce}-[0-9]*.service)
            serial=${unit#zag-bootstrap-${bootstrap_tmp_nonce}-}
            serial=${serial%.service}
            case "$serial" in ''|*[!0-9]*) return 1 ;; esac
            ;;
        *) return 1 ;;
    esac
    description=$(bootstrap_systemctl show --value --property=Description \
        "$unit" 2>/dev/null || true)
    [ "$description" = "$bootstrap_unit_marker" ] || return 1
    control_group=$(bootstrap_systemctl show --value --property=ControlGroup \
        "$unit" 2>/dev/null || true)
    case "$control_group" in
        /*) return 0 ;;
    esac
    return 1
}
bootstrap_proc_identity() {
    local pid=$1 line rest
    [ -r "/proc/$pid/stat" ] || return 1
    IFS= read -r line <"/proc/$pid/stat" || return 1
    # comm may contain spaces and ')' characters; fields after the final ')'
    # retain the stable /proc ordering.  Return: ppid pgrp session start state.
    rest=${line##*) }
    local -a fields=()
    read -r -a fields <<<"$rest"
    [ "${#fields[@]}" -ge 20 ] || return 1
    printf '%s %s %s %s %s\n' \
        "${fields[1]}" "${fields[2]}" "${fields[3]}" \
        "${fields[19]}" "${fields[0]}"
}
bootstrap_pid_dead_or_zombie() {
    local pid=$1 expected_start=$2 identity ppid pgrp session start state
    [ -n "$pid" ] || return 0
    identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    [ -n "$identity" ] || return 0
    read -r ppid pgrp session start state <<EOF
$identity
EOF
    [ "$start" = "$expected_start" ] || return 2
    [ "$state" = Z ] && return 0
    return 1
}
bootstrap_reap_dead_child() {
    local pid=$1 expected_start=$2 state
    # An empty start time cannot authenticate a /proc entry, and wait(2) has
    # no timeout in bash. Callers must use the dedicated zombie path when
    # capture raced with a fast exit; never let cleanup wait on an
    # unauthenticated or live PID.
    [ -n "$expected_start" ] || return 2
    bootstrap_pid_dead_or_zombie "$pid" "$expected_start"
    state=$?
    case "$state" in
        0)
            bootstrap_reap_status=0
            wait "$pid" 2>/dev/null || bootstrap_reap_status=$?
            return 0
            ;;
        1) return 1 ;;
        *) return 2 ;;
    esac
}
bootstrap_pid_is_stable_zombie() {
    local pid=$1 identity identity_again ppid pgrp session start state
    local ppid_again pgrp_again session_again start_again state_again
    [ -n "$pid" ] || return 1
    identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    identity_again=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    [ -n "$identity" ] && [ "$identity" = "$identity_again" ] || return 1
    read -r ppid pgrp session start state <<EOF
$identity
EOF
    read -r ppid_again pgrp_again session_again start_again state_again <<EOF
$identity_again
EOF
    [ "$start" = "$start_again" ] && [ "$state" = Z ] &&
        [ "$state_again" = Z ]
}
bootstrap_reap_fast_child() {
    local pid=$1 attempt
    # Prefer two stable zombie observations. If the entry has already
    # disappeared, refuse to infer a status from the numeric PID. The caller
    # must take the authenticated bounded cleanup path.
    for attempt in $(seq 1 100); do
        if bootstrap_pid_is_stable_zombie "$pid"; then
            # The stable Z state proves this direct child cannot still make
            # progress, so the builtin wait is immediate and bounded by the
            # kernel's already-completed child state.
            bootstrap_reap_dead_child "$pid" "$(
                bootstrap_proc_identity "$pid" 2>/dev/null | awk '{ print $4; exit }'
            )" || return 1
            bootstrap_fast_wait_status=$bootstrap_reap_status
            return 0
        fi
        if [ ! -r "/proc/$pid/stat" ]; then
            # A vanished entry cannot authenticate a status or a recycled
            # numeric PID. Refuse the wait entirely; the caller takes the
            # bounded authenticated cleanup path instead.
            return 1
        fi
        sleep 0.01
    done
    # A still-live child must go through the authenticated bounded cleanup
    # path; do not try to wait for it from this capture-race branch.
    return 1
}
bootstrap_capture_active_identity() {
    local identity identity_again attempt ppid pgrp session start state
    local parent_identity parent_identity_again parent_start parent_start_again
    if [ "${ZAG_BOOTSTRAP_FORCE_IDENTITY_CAPTURE_FAILURE:-}" = 1 ]; then
        # Keep only the shell's independently checked identity so the abort
        # path can authenticate the freshly launched child without pretending
        # that the child's capture succeeded.
        parent_identity=$(bootstrap_proc_identity "$$" 2>/dev/null || true)
        parent_identity_again=$(bootstrap_proc_identity "$$" 2>/dev/null || true)
        read -r _ _ _ parent_start _ <<EOF
$parent_identity
EOF
        read -r _ _ _ parent_start_again _ <<EOF
$parent_identity_again
EOF
        if [ "$parent_identity" = "$parent_identity_again" ] &&
           [ -n "$parent_start" ] && [ "$parent_start" = "$parent_start_again" ]; then
            bootstrap_active_parent_pid=$$
            bootstrap_active_parent_start=$parent_start
        fi
        bootstrap_active_pid_start=""
        bootstrap_active_pgrp=""
        bootstrap_active_session=""
        bootstrap_active_identity_captured=0
        return 1
    fi
    for attempt in $(seq 1 50); do
        identity=$(bootstrap_proc_identity "$bootstrap_active_pid" 2>/dev/null || true)
        identity_again=$(bootstrap_proc_identity "$bootstrap_active_pid" 2>/dev/null || true)
        if [ -n "$identity" ] && [ "$identity" = "$identity_again" ]; then
            read -r ppid bootstrap_active_pgrp bootstrap_active_session \
                bootstrap_active_pid_start state <<EOF
$identity
EOF
            if [ "$ppid" = "$$" ] && [ "$state" != Z ] &&
               [ -n "$bootstrap_active_pid_start" ]; then
                bootstrap_active_parent_pid=$ppid
                parent_identity=$(bootstrap_proc_identity "$$" 2>/dev/null || true)
                parent_identity_again=$(bootstrap_proc_identity "$$" 2>/dev/null || true)
                read -r _ _ _ parent_start _ <<EOF
$parent_identity
EOF
                read -r _ _ _ parent_start_again _ <<EOF
$parent_identity_again
EOF
                bootstrap_active_parent_start=$parent_start
                if [ "$parent_identity" = "$parent_identity_again" ] &&
                   [ -n "$bootstrap_active_parent_start" ] &&
                   [ "$parent_start" = "$parent_start_again" ]; then
                    bootstrap_active_identity_captured=1
                    return 0
                fi
            fi
        fi
        sleep 0.01
    done
    bootstrap_active_pid_start=""
    bootstrap_active_pgrp=""
    bootstrap_active_session=""
    bootstrap_active_parent_pid=""
    bootstrap_active_parent_start=""
    bootstrap_active_identity_captured=0
    [ -r "/proc/$bootstrap_active_pid/stat" ] || return 2
    return 1
}
bootstrap_wait_captured_pid() {
    local pid=$1 expected_start=$2 seconds=$3 attempt limit identity \
        ppid pgrp session start state
    case "$seconds" in ''|*[!0-9]*) return 2 ;; esac
    [ -n "$expected_start" ] || return 0
    limit=$((seconds * 20))
    for attempt in $(seq 1 "$limit"); do
        identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
        read -r ppid pgrp session start state <<EOF
$identity
EOF
        [ "$start" = "$expected_start" ] || return 0
        [ "$state" != Z ] || return 0
        sleep 0.05
    done
    return 1
}
bootstrap_signal_captured_wrapper() {
    local pid=$bootstrap_active_pid expected_start=$bootstrap_active_pid_start
    local identity identity_again ppid pgrp session start state
    local ppid_again pgrp_again session_again start_again state_again
    [ -n "$pid" ] || return 0
    [ -n "$expected_start" ] || return 0
    identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    read -r ppid pgrp session start state <<EOF
$identity
EOF
    [ "$start" = "$expected_start" ] || return 0
    [ "$state" != Z ] || return 0
    identity_again=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    read -r ppid_again pgrp_again session_again start_again state_again <<EOF
$identity_again
EOF
    [ "$start" = "$start_again" ] || return 0
    [ "$state_again" != Z ] || return 0
    # This is deliberately a positive-PID fallback. It can stop the
    # systemd-run client, but cannot certify that an unauthenticated unit's
    # compiler was stopped; cleanup reports that boundary explicitly.
    kill -TERM "$pid" 2>/dev/null || true
    if ! bootstrap_wait_captured_pid "$pid" "$expected_start" 2; then
        identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
        read -r ppid pgrp session start state <<EOF
$identity
EOF
        if [ "$start" = "$expected_start" ] && [ "$state" != Z ]; then
            kill -KILL "$pid" 2>/dev/null || true
        fi
        bootstrap_wait_captured_pid "$pid" "$expected_start" 5 ||
            echo "bootstrap: authenticated systemd-run wrapper did not exit within cleanup bound" >&2
    fi
    if ! bootstrap_reap_dead_child "$pid" "$expected_start"; then
        echo "bootstrap: authenticated systemd-run wrapper is still live; retaining PID for a later cleanup retry" >&2
        return 1
    fi
}
bootstrap_abort_uncaptured_process() {
    local pid=$bootstrap_active_pid identity identity_again identity_parent identity_parent_again
    local ppid pgrp session start state expected_start child
    local child_identity child_identity_again child_ppid child_pgrp child_session child_start child_state
    local child_ppid_again child_pgrp_again child_session_again child_start_again child_state_again
    local -a captured_children=()
    local child_index child_parent_is_owned parent_pid
    [ -n "$pid" ] || return 0
    # Although the normal capture failed, the shell still owns this freshly
    # launched child.  Revalidate that fact before using the positive PID;
    # never guess at a negative process-group PID in this failure path.
    identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    identity_again=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    identity_parent=$(bootstrap_proc_identity "$$" 2>/dev/null || true)
    identity_parent_again=$(bootstrap_proc_identity "$$" 2>/dev/null || true)
    read -r ppid pgrp session start state <<EOF
$identity
EOF
    read -r _ _ _ parent_start _ <<EOF
$identity_parent
EOF
    read -r _ _ _ parent_start_again _ <<EOF
$identity_parent_again
EOF
    if [ "$identity" != "$identity_again" ] || [ "$ppid" != "$$" ] ||
       [ "$bootstrap_active_parent_pid" != "$$" ] ||
       [ "$parent_start" != "$bootstrap_active_parent_start" ] ||
       [ "$parent_start" != "$parent_start_again" ] ||
       [ -z "$start" ] || [ "$state" = Z ]; then
        echo "bootstrap: could not authenticate the just-launched wrapper after identity capture failure; refusing unsafe signal" >&2
        return 1
    fi
    expected_start=$start
    bootstrap_report_pids=""
    bootstrap_descendant_nodes=0
    bootstrap_descendant_truncated=0
    bootstrap_collect_descendants "$pid"
    # /proc/$pid/task/$pid/children can disappear during the short handoff
    # between setsid and timeout.  Recover only by a bounded parent-identity
    # walk; a reparented process is not considered owned.
    if [ -z "$bootstrap_report_pids" ]; then
        bootstrap_collect_descendants_by_ppid "$pid"
    fi
    captured_children=($bootstrap_report_pids)
    # Signal deepest discovered descendants first so killing the wrapper does
    # not turn a still-running child into an orphan.  Membership in the
    # authenticated /proc children walk, plus two start-time reads, is the
    # ownership proof here; the wrapper and its children need not share a
    # process group because setsid/timeout may add an intermediate parent.
    for ((child_index=${#captured_children[@]} - 1; child_index >= 0; child_index--)); do
        child=${captured_children[$child_index]}
        child_identity=$(bootstrap_proc_identity "$child" 2>/dev/null || true)
        read -r child_ppid child_pgrp child_session child_start child_state <<EOF
$child_identity
EOF
        child_identity_again=$(bootstrap_proc_identity "$child" 2>/dev/null || true)
        read -r child_ppid_again child_pgrp_again child_session_again child_start_again child_state_again <<EOF
$child_identity_again
EOF
        [ -n "$child_start" ] && [ "$child_start" = "$child_start_again" ] || continue
        [ "$child_ppid" = "$child_ppid_again" ] || continue
        child_parent_is_owned=0
        [ "$child_ppid" = "$pid" ] && child_parent_is_owned=1
        for parent_pid in "${captured_children[@]}"; do
            [ "$child_ppid" = "$parent_pid" ] && child_parent_is_owned=1
        done
        [ "$child_parent_is_owned" -eq 1 ] || continue
        [ "$child_state" != Z ] && [ "$child_state_again" != Z ] || continue
        kill -KILL "$child" 2>/dev/null || true
    done
    identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
    read -r ppid pgrp session start state <<EOF
$identity
EOF
    if [ "$ppid" = "$$" ] && [ "$start" = "$expected_start" ] && [ "$state" != Z ]; then
        kill -KILL "$pid" 2>/dev/null || true
    fi
    bootstrap_wait_captured_pid "$pid" "$expected_start" 5 ||
        echo "bootstrap: unauthenticated-capture wrapper did not exit within cleanup bound" >&2
    bootstrap_reap_dead_child "$pid" "$expected_start" || {
        echo "bootstrap: unauthenticated-capture wrapper remains live; retaining PID for a later cleanup retry" >&2
        return 1
    }
}
bootstrap_pid_running() {
    local pid=$1 state
    [ -r "/proc/$pid/stat" ] || return 1
    state=$(bootstrap_proc_identity "$pid" 2>/dev/null | awk '{ print $5; exit }' || true)
    [ -n "$state" ] && [ "$state" != Z ]
}
bootstrap_wait_bounded() {
    local pid=$1 seconds=$2 attempt limit
    case "$seconds" in ''|*[!0-9]*) return 2 ;; esac
    limit=$((seconds * 20))
    for attempt in $(seq 1 "$limit"); do
        bootstrap_pid_running "$pid" || return 0
        sleep 0.05
    done
    return 1
}
bootstrap_signal_owned_processes() {
    local signal=$1 identity identity_again ppid pgrp session start state pid
    local ppid_again pgrp_again session_again start_again state_again
    [ "$bootstrap_active_mode" = process ] || return 0
    [ -n "$bootstrap_active_pid_start" ] || return 0
    # Read the leader twice immediately before considering a process-group
    # signal. A vanished or changing leader cannot authenticate a recycled
    # numeric PGID; in that case recover only individually identified members.
    identity=$(bootstrap_proc_identity "$bootstrap_active_pid" 2>/dev/null || true)
    identity_again=$(bootstrap_proc_identity "$bootstrap_active_pid" 2>/dev/null || true)
    read -r ppid pgrp session start state <<EOF
$identity
EOF
    bootstrap_report_pids=""
    bootstrap_descendant_nodes=0
    bootstrap_descendant_truncated=0
    # setsid makes the active wrapper a new session and process-group leader.
    # Revalidate both identity and ownership before using a negative-PID kill;
    # if anything changed, only individually validated descendants are tried.
    if [ "$identity" = "$identity_again" ] &&
       [ "$start" = "$bootstrap_active_pid_start" ] &&
       [ "$pgrp" = "$bootstrap_active_pgrp" ] &&
       [ "$session" = "$bootstrap_active_session" ] &&
       [ "$pgrp" = "$bootstrap_active_pid" ] &&
       [ "$session" = "$bootstrap_active_pid" ]; then
        kill "-$signal" -- "-$pgrp" 2>/dev/null || true
    else
        # The leader may already have been reaped by bootstrap_compile.  The
        # bounded group-member scan below can still find and authenticate
        # descendants without trusting a recycled numeric PID.
        bootstrap_collect_owned_group_members
    fi
    bootstrap_add_pid "$bootstrap_active_pid"
    bootstrap_collect_descendants "$bootstrap_active_pid"
    for pid in $bootstrap_report_pids; do
        [ "$pid" = "$bootstrap_active_pid" ] && continue
        identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
        read -r ppid pgrp session start state <<EOF
$identity
EOF
        [ -n "$start" ] || continue
        # Read the identity twice immediately before signaling.  This closes
        # the practical /proc disappearance/PID-reuse window without making
        # teardown depend on a proc entry remaining readable.
        identity_again=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
        read -r ppid_again pgrp_again session_again start_again state_again <<EOF
$identity_again
EOF
        [ "$start" = "$start_again" ] || continue
        [ "$pgrp" = "$pgrp_again" ] || continue
        [ "$session" = "$session_again" ] || continue
        [ "$pgrp" = "$bootstrap_active_pgrp" ] || continue
        [ "$session" = "$bootstrap_active_session" ] || continue
        case "$signal" in
            TERM|KILL) kill -"$signal" "$pid" 2>/dev/null || true ;;
        esac
    done
    [ "$bootstrap_descendant_truncated" -eq 0 ] ||
        echo "bootstrap: owned process cleanup scan truncated at ${bootstrap_descendant_limit} processes/${bootstrap_descendant_depth_limit} levels; no-orphan status is uncertified" >&2
}
bootstrap_cleanup() {
    local unit_owned=0 unit_stopped=0 reap_status
    # systemd-run is only a client for the transient service. Killing the
    # client alone can leave the compiler alive in its user manager cgroup,
    # so stop the named unit before removing the tree it is writing.
    if [ -n "$bootstrap_active_unit" ]; then
        if bootstrap_systemd_unit_owned "$bootstrap_active_unit"; then
            unit_owned=1
            bootstrap_systemctl kill --kill-who=all --signal=TERM \
                "$bootstrap_active_unit" >/dev/null 2>&1 || true
            if ! bootstrap_systemctl stop "$bootstrap_active_unit" >/dev/null 2>&1; then
                bootstrap_systemctl kill --kill-who=all --signal=KILL \
                    "$bootstrap_active_unit" >/dev/null 2>&1 || true
                if bootstrap_systemctl stop "$bootstrap_active_unit" >/dev/null 2>&1; then
                    unit_stopped=1
                fi
            else
                unit_stopped=1
            fi
            bootstrap_systemctl reset-failed "$bootstrap_active_unit" >/dev/null 2>&1 || true
        else
            echo "bootstrap: systemd unit $bootstrap_active_unit is unauthenticated; refusing unit cleanup and certifying no-orphan status as unavailable" >&2
        fi
        if [ "$unit_owned" -eq 1 ] && [ "$unit_stopped" -eq 1 ]; then
            bootstrap_active_unit=""
        else
            echo "bootstrap: retaining active systemd unit state for a bounded cleanup retry: $bootstrap_active_unit" >&2
        fi
    fi
    if [ -n "$bootstrap_active_pid" ]; then
        if [ "$bootstrap_active_mode" = systemd ]; then
            # Cleanup is best-effort. A failed signal/reap attempt must not
            # let set -e skip the subsequent identity check and retry.
            bootstrap_signal_captured_wrapper || true
        else
            bootstrap_signal_owned_processes KILL
            bootstrap_wait_bounded "$bootstrap_active_pid" 5 ||
                echo "bootstrap: owned stage leader did not exit within cleanup bound" >&2
        fi
        if bootstrap_reap_dead_child "$bootstrap_active_pid" \
                "$bootstrap_active_pid_start"; then
            bootstrap_active_pid=""
            bootstrap_active_mode=""
            bootstrap_active_pid_start=""
            bootstrap_active_pgrp=""
            bootstrap_active_session=""
            bootstrap_active_parent_pid=""
            bootstrap_active_parent_start=""
            bootstrap_active_identity_captured=0
        else
            reap_status=$?
            if [ "$reap_status" -eq 2 ]; then
                echo "bootstrap: stage PID identity changed; refusing wait or state reuse" >&2
            else
                echo "bootstrap: stage leader is still live; retaining PID for a bounded cleanup retry" >&2
            fi
        fi
    fi
    if [ -z "$bootstrap_active_pid" ] && [ -z "$bootstrap_active_unit" ]; then
        rm -rf "$bootstrap_tmp"
    else
        echo "bootstrap: retaining stage tree because process/unit ownership remains unresolved: $bootstrap_tmp" >&2
    fi
}
bootstrap_signal() {
    # Do not let a second signal interrupt teardown halfway through.  EXIT is
    # disabled after the explicit cleanup so the handler is single-shot.
    trap ':' HUP INT TERM
    bootstrap_cleanup
    trap - EXIT HUP INT TERM
    exit 130
}
trap bootstrap_cleanup EXIT
trap bootstrap_signal HUP INT TERM

# Protect an interactive Linux workstation before starting any compiler stage.
# The guard is optional infrastructure, not a build dependency: hosts without a
# usable user cgroup still take the ordinary pure-Zag path. An explicit byte
# limit is fail-closed, while `ZAG_BOOTSTRAP_MEMORY_GUARD=off` disables the
# automatic 60%-of-RAM / 2-GiB-reserve policy.
bootstrap_memory_limit=${ZAG_BOOTSTRAP_MEMORY_MAX_BYTES:-}
bootstrap_swap_limit=${ZAG_BOOTSTRAP_SWAP_MAX_BYTES:-0}
bootstrap_guard=${ZAG_BOOTSTRAP_MEMORY_GUARD:-auto}
bootstrap_stage_timeout=${ZAG_BOOTSTRAP_STAGE_TIMEOUT_SECONDS:-3600}
case "$bootstrap_stage_timeout" in
    ''|*[!0-9]*|0)
        echo "bootstrap: invalid stage timeout: $bootstrap_stage_timeout" >&2
        exit 1
        ;;
esac
bootstrap_heartbeat=${ZAG_BOOTSTRAP_HEARTBEAT_SECONDS:-30}
case "$bootstrap_heartbeat" in
    ''|*[!0-9]*|0)
        echo "bootstrap: invalid heartbeat interval: $bootstrap_heartbeat" >&2
        exit 1
        ;;
esac
if ! command -v timeout >/dev/null 2>&1; then
    echo "bootstrap: timeout(1) is required for bounded compiler stages" >&2
    exit 1
fi
if ! command -v setsid >/dev/null 2>&1; then
    echo "bootstrap: setsid(1) is required for an owned no-systemd stage session" >&2
    exit 1
fi
bootstrap_cgroup=0
case "$bootstrap_swap_limit" in
    ''|*[!0-9]*) echo "bootstrap: invalid swap limit: $bootstrap_swap_limit" >&2; exit 1 ;;
esac
if [ "$bootstrap_guard" != off ] && command -v systemd-run >/dev/null 2>&1 &&
   bootstrap_systemctl is-system-running >/dev/null 2>&1; then
    if [ -z "$bootstrap_memory_limit" ]; then
        bootstrap_total_kib=$(awk '/^MemTotal:/ { print $2; exit }' /proc/meminfo)
        bootstrap_available_kib=$(awk '/^MemAvailable:/ { print $2; exit }' /proc/meminfo)
        bootstrap_physical_limit=$((bootstrap_total_kib * 1024 * 60 / 100))
        bootstrap_available_limit=$(((bootstrap_available_kib - 2097152) * 1024))
        bootstrap_memory_limit=$bootstrap_physical_limit
        if [ "$bootstrap_memory_limit" -gt "$bootstrap_available_limit" ]; then
            bootstrap_memory_limit=$bootstrap_available_limit
        fi
    fi
    case "$bootstrap_memory_limit" in
        ''|*[!0-9]*) echo "bootstrap: invalid memory limit: $bootstrap_memory_limit" >&2; exit 1 ;;
    esac
    if [ "$bootstrap_memory_limit" -lt 1073741824 ]; then
        echo "bootstrap: less than 1 GiB remains after the workstation reserve" >&2
        exit 1
    fi
    bootstrap_cgroup=1
    echo "   memory guard: cgroup memory max=$bootstrap_memory_limit bytes, swap max=$bootstrap_swap_limit bytes"
elif [ -n "$bootstrap_memory_limit" ] || [ "$bootstrap_swap_limit" -ne 0 ]; then
    echo "bootstrap: an explicit memory or swap limit requires a usable user systemd manager" >&2
    exit 1
else
    echo "   memory guard: unavailable; continuing without an OS cgroup"
fi

# Read the process accounting files directly.  The PID owned by the shell is
# the `timeout(1)` wrapper; its VmRSS is usually tiny and is not a useful
# indication of the compiler's footprint.  Keep the accounting best-effort so
# /proc and cgroup implementations that are unavailable or disappear during
# teardown never change bootstrap semantics.
bootstrap_proc_value() {
    local pid=$1 key=$2
    [ -r "/proc/$pid/status" ] || return 1
    awk -v key="$key" '$1 == key ":" { print $2; exit }' "/proc/$pid/status"
}
bootstrap_proc_name() {
    local pid=$1
    bootstrap_proc_value "$pid" Name 2>/dev/null || printf '%s' unavailable
}
bootstrap_proc_rss_kib() {
    local pid=$1 rss
    rss=$(bootstrap_proc_value "$pid" VmRSS 2>/dev/null || true)
    case "$rss" in
        ''|*[!0-9]*) return 1 ;;
        *) printf '%s' "$rss" ;;
    esac
}
bootstrap_add_pid() {
    local pid=$1
    case "$pid" in ''|*[!0-9]*) return ;; esac
    case " $bootstrap_report_pids " in
        *" $pid "*) return ;;
    esac
    bootstrap_report_pids="$bootstrap_report_pids $pid"
}
bootstrap_descendant_limit=${ZAG_BOOTSTRAP_DESCENDANT_LIMIT:-4096}
bootstrap_descendant_depth_limit=${ZAG_BOOTSTRAP_DESCENDANT_DEPTH_LIMIT:-64}
case "$bootstrap_descendant_limit:$bootstrap_descendant_depth_limit" in
    ''|*[!0-9:]*|*:0|0:*)
        echo "bootstrap: invalid descendant traversal limits" >&2
        exit 1
        ;;
esac
bootstrap_add_compiler_pid() {
    local pid=$1
    case "$pid" in ''|*[!0-9]*) return ;; esac
    case " $bootstrap_compiler_pids " in
        *" $pid "*) return ;;
    esac
    if [ "${bootstrap_descendant_nodes:-0}" -ge "$bootstrap_descendant_limit" ]; then
        bootstrap_descendant_truncated=1
        return
    fi
    bootstrap_compiler_pids="$bootstrap_compiler_pids $pid"
    bootstrap_descendant_nodes=$((bootstrap_descendant_nodes + 1))
}
bootstrap_collect_descendants() {
    local parent=$1 depth=${2:-0} child
    [ "$depth" -lt "$bootstrap_descendant_depth_limit" ] || {
        bootstrap_descendant_truncated=1
        return 0
    }
    [ -r "/proc/$parent/task/$parent/children" ] || return 0
    while read -r child; do
        [ -n "$child" ] || continue
        if [ "$bootstrap_descendant_nodes" -ge "$bootstrap_descendant_limit" ]; then
            bootstrap_descendant_truncated=1
            return 0
        fi
        bootstrap_add_pid "$child"
        bootstrap_descendant_nodes=$((bootstrap_descendant_nodes + 1))
        bootstrap_collect_descendants "$child" $((depth + 1))
    done <"/proc/$parent/task/$parent/children"
}
bootstrap_collect_descendants_by_ppid() {
    local root=$1 stat_file pid identity ppid pgrp session start state
    local parent known_pid found changed round scanned=0
    local -a known=()
    known=("$root")
    for round in $(seq 1 "$bootstrap_descendant_depth_limit"); do
        changed=0
        for stat_file in /proc/[0-9]*/stat; do
            [ "$scanned" -lt "$bootstrap_descendant_limit" ] || {
                bootstrap_descendant_truncated=1
                return 0
            }
            scanned=$((scanned + 1))
            pid=${stat_file#/proc/}
            pid=${pid%/stat}
            [ "$pid" != "$root" ] || continue
            identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
            read -r ppid pgrp session start state <<EOF
$identity
EOF
            [ -n "$start" ] || continue
            found=0
            for known_pid in "${known[@]}"; do
                [ "$ppid" = "$known_pid" ] && found=1
            done
            [ "$found" -eq 1 ] || continue
            bootstrap_add_pid "$pid"
            known+=("$pid")
            changed=1
        done
        [ "$changed" -eq 1 ] || break
    done
}
bootstrap_collect_owned_group_members() {
    local stat_file pid identity identity_again ppid pgrp session start state scanned=0
    local ppid_again pgrp_again session_again start_again state_again
    [ "$bootstrap_active_mode" = process ] || return 0
    [ -n "$bootstrap_active_pgrp" ] || return 0
    [ -n "$bootstrap_active_session" ] || return 0
    # A failed stage may have had its setsid leader reaped before EXIT cleanup.
    # Recover only bounded, independently identified members of its original
    # process group; do not trust a recycled numeric group on its own.
    for stat_file in /proc/[0-9]*/stat; do
        [ "$scanned" -lt "$bootstrap_descendant_limit" ] || {
            bootstrap_descendant_truncated=1
            break
        }
        scanned=$((scanned + 1))
        pid=${stat_file#/proc/}
        pid=${pid%/stat}
        identity=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
        identity_again=$(bootstrap_proc_identity "$pid" 2>/dev/null || true)
        read -r ppid pgrp session start state <<EOF
$identity
EOF
        read -r ppid_again pgrp_again session_again start_again state_again <<EOF
$identity_again
EOF
        [ -n "$start" ] || continue
        [ "$identity" = "$identity_again" ] || continue
        [ "$pgrp" = "$bootstrap_active_pgrp" ] || continue
        [ "$session" = "$bootstrap_active_session" ] || continue
        bootstrap_add_pid "$pid"
    done
}
bootstrap_cgroup_path_for() {
    local pid=$1 unit=$2 path attempt
    if [ -n "$unit" ] && command -v systemctl >/dev/null 2>&1; then
        bootstrap_systemd_unit_owned "$unit" || return 1
        # A systemd stage must use only the unit-owned ControlGroup.  The
        # timeout/retry is deliberately best-effort; falling back to the
        # timeout wrapper's cgroup could kill unrelated work.
        for attempt in 1 2 3; do
            path=$(bootstrap_systemctl show --value --property=ControlGroup \
                "$unit" 2>/dev/null || true)
            case "$path" in
                /*) printf '%s' "$path"; return 0 ;;
            esac
            sleep 0.05
        done
        return 1
    fi
    if [ -r "/proc/$pid/cgroup" ]; then
        path=$(awk -F: '$1 == "0" { print $3; exit }' "/proc/$pid/cgroup")
        case "$path" in
            /*) printf '%s' "$path"; return 0 ;;
        esac
    fi
    return 1
}
bootstrap_collect_cgroup_pids() {
    local pid=$1 unit=$2 path cgroup_file child
    [ -n "$unit" ] || return 1
    path=${bootstrap_stage_cgroup_path:-}
    [ -n "$path" ] || path=$(bootstrap_cgroup_path_for "$pid" "$unit" 2>/dev/null || true)
    case "$path" in
        /*) ;;
        *) return 1 ;;
    esac
    cgroup_file="/sys/fs/cgroup$path/cgroup.procs"
    [ -r "$cgroup_file" ] || return 1
    while read -r child; do
        [ "$bootstrap_descendant_nodes" -lt "$bootstrap_descendant_limit" ] || {
            bootstrap_descendant_truncated=1
            break
        }
        bootstrap_add_compiler_pid "$child"
    done <"$cgroup_file"
    return 0
}
bootstrap_progress_memory() {
    local wrapper_pid=$1 unit=$2 wrapper_rss descendants_rss=0 compiler_rss=0
    local compiler_pids="" pid rss cgroup_seen=0 rss_samples=0
    bootstrap_report_pids=""
    bootstrap_compiler_pids=""
    bootstrap_descendant_nodes=0
    bootstrap_descendant_truncated=0
    if [ -z "${bootstrap_stage_cgroup_path:-}" ]; then
        bootstrap_stage_cgroup_path=$(bootstrap_cgroup_path_for "$wrapper_pid" "$unit" 2>/dev/null || true)
    fi
    bootstrap_collect_descendants "$wrapper_pid"
    if bootstrap_collect_cgroup_pids "$wrapper_pid" "$unit"; then
        cgroup_seen=1
    fi
    wrapper_rss=$(bootstrap_proc_rss_kib "$wrapper_pid" 2>/dev/null || true)
    [ -n "$wrapper_rss" ] || wrapper_rss=unavailable

    for pid in $bootstrap_report_pids; do
        rss=$(bootstrap_proc_rss_kib "$pid" 2>/dev/null || true)
        case "$rss" in
            ''|*[!0-9]*) continue ;;
        esac
        descendants_rss=$((descendants_rss + rss))
        rss_samples=$((rss_samples + 1))
    done
    if [ "$cgroup_seen" -eq 0 ]; then
        compiler_rss=$descendants_rss
        compiler_pids="$bootstrap_report_pids"
    else
        for pid in $bootstrap_compiler_pids; do
            rss=$(bootstrap_proc_rss_kib "$pid" 2>/dev/null || true)
            case "$rss" in
                ''|*[!0-9]*) continue ;;
            esac
            compiler_rss=$((compiler_rss + rss))
        done
        compiler_pids="$bootstrap_compiler_pids"
    fi
    compiler_pids=${compiler_pids# }
    [ -n "$compiler_pids" ] || compiler_pids=unavailable
    if [ "$cgroup_seen" -eq 1 ]; then
        # Recount cgroup samples separately: descendants_rss can include the
        # timeout wrapper when no unit cgroup is available, while compiler_rss
        # must remain unavailable until a compiler member was sampled.
        compiler_rss=0
        local compiler_rss_samples=0
        for pid in $bootstrap_compiler_pids; do
            rss=$(bootstrap_proc_rss_kib "$pid" 2>/dev/null || true)
            case "$rss" in
                ''|*[!0-9]*) continue ;;
            esac
            compiler_rss=$((compiler_rss + rss))
            compiler_rss_samples=$((compiler_rss_samples + 1))
        done
        [ "$compiler_rss_samples" -gt 0 ] || compiler_rss=unavailable
    elif [ "$rss_samples" -eq 0 ]; then
        compiler_rss=unavailable
    fi
    [ "$bootstrap_descendant_truncated" -eq 0 ] || \
        echo "   compiler progress: process accounting truncated at ${bootstrap_descendant_limit} processes/${bootstrap_descendant_depth_limit} levels" >&2
    echo "   compiler progress: elapsed=$((SECONDS - bootstrap_stage_started))s wrapper_pid=$wrapper_pid wrapper=$(bootstrap_proc_name "$wrapper_pid") wrapper_rss=${wrapper_rss} KiB compiler_pids=$compiler_pids compiler_rss=${compiler_rss} KiB"
}
bootstrap_report_stage_failure() {
    local stage_rc=$1 pid=$2 unit=$3 path=${4:-} available swap event_file
    case "$stage_rc" in
        124) echo "bootstrap: status 124 is timeout(1)'s conventional deadline result (a child can also return 124; cause is not established)" >&2 ;;
        137) echo "bootstrap: status 137 is a SIGKILL-style status (128+9); an enforced limit, external action, or cleanup may be involved; cause is not established" >&2 ;;
        143) echo "bootstrap: status 143 is a SIGTERM-style status (128+15); cancellation, external action, or cleanup may be involved; cause is not established" >&2 ;;
        *) echo "bootstrap: status $stage_rc has no special bootstrap interpretation" >&2 ;;
    esac
    available=$(awk '/^MemAvailable:/ { print $2 " KiB"; exit }' /proc/meminfo 2>/dev/null || true)
    swap=$(awk '/^SwapFree:/ { print $2 " KiB"; exit }' /proc/meminfo 2>/dev/null || true)
    [ -n "$available" ] || available=unavailable
    [ -n "$swap" ] || swap=unavailable
    echo "bootstrap: host memory snapshot: MemAvailable=$available SwapFree=$swap" >&2
    [ -n "$path" ] || path=$(bootstrap_cgroup_path_for "$pid" "$unit" 2>/dev/null || true)
    case "$path" in
        /*) event_file="/sys/fs/cgroup$path/memory.events" ;;
        *) event_file="" ;;
    esac
    if [ -n "$event_file" ] && [ -r "$event_file" ]; then
        echo "bootstrap: cgroup memory.events ($event_file):" >&2
        sed 's/^/  /' "$event_file" >&2 || true
    else
        echo "bootstrap: cgroup memory.events: unavailable" >&2
    fi
}

bootstrap_compile() {
    echo "   compiler stage: $* (timeout=${bootstrap_stage_timeout}s)"
    if [ "$bootstrap_cgroup" -eq 1 ]; then
        bootstrap_unit_serial=$((bootstrap_unit_serial + 1))
        bootstrap_active_unit="zag-bootstrap-${bootstrap_tmp_nonce}-${bootstrap_unit_serial}.service"
        bootstrap_active_mode=systemd
        timeout --foreground --kill-after=30s "$bootstrap_stage_timeout" \
        systemd-run --user --unit="$bootstrap_active_unit" --quiet --wait --collect --pipe \
            -p Type=exec -p "Description=$bootstrap_unit_marker" \
            -p "WorkingDirectory=$PWD" \
            -p KillMode=control-group -p TimeoutStopSec=5s \
            -p "MemoryMax=$bootstrap_memory_limit" \
            -p "MemorySwapMax=$bootstrap_swap_limit" \
            -p CPUWeight=1 -p IOWeight=1 -p Nice=10 \
            "$@" &
    else
        bootstrap_active_unit=""
        bootstrap_active_mode=process
        # Give the timeout wrapper its own session/process group.  The group
        # is validated against /proc identity before cleanup signals it.
        setsid --wait timeout --kill-after=30s \
            "$bootstrap_stage_timeout" "$@" &
    fi
    bootstrap_active_pid=$!
    bootstrap_capture_rc=0
    bootstrap_capture_active_identity || bootstrap_capture_rc=$?
    if [ "$bootstrap_capture_rc" -ne 0 ]; then
        # A very short stage can become a zombie before two stable identity
        # reads. Reap that direct child and preserve its actual exit status.
        # If /proc has already disappeared, fail closed rather than turning
        # the race into an unbounded shell wait or a stale status.
        bootstrap_fast_wait_status=1
        if bootstrap_reap_fast_child "$bootstrap_active_pid"; then
            bootstrap_capture_rc=$bootstrap_fast_wait_status
            bootstrap_report_stage_failure "$bootstrap_capture_rc" \
                "$bootstrap_active_pid" "$bootstrap_active_unit"
            echo "bootstrap: compiler stage exited with status $bootstrap_capture_rc" >&2
            bootstrap_active_pid=""
            bootstrap_active_unit=""
            bootstrap_active_mode=""
            return "$bootstrap_capture_rc"
        fi
        echo "bootstrap: failed to capture stage wrapper identity; aborting before compiler execution" >&2
        if [ "$bootstrap_active_mode" = process ]; then
            if bootstrap_abort_uncaptured_process; then
                # The abort helper authenticated, killed, and reaped the
                # direct child using its locally captured start time. Clear
                # the global state so EXIT cleanup does not retry an
                # unauthenticated empty-start wait or retain the stage tree.
                bootstrap_active_pid=""
                bootstrap_active_mode=""
            fi
        fi
        return 1
    fi
    bootstrap_stage_started=$SECONDS
    bootstrap_stage_cgroup_path=$(bootstrap_cgroup_path_for \
        "$bootstrap_active_pid" "$bootstrap_active_unit" 2>/dev/null || true)
    local started=$SECONDS
    bootstrap_process_running() {
        [ -r "/proc/$bootstrap_active_pid/stat" ] || return 1
        local state
        state=$(awk '{ print $3; exit }' "/proc/$bootstrap_active_pid/stat")
        [ "$state" != Z ]
    }
    while bootstrap_process_running; do
        sleep "$bootstrap_heartbeat"
        if bootstrap_process_running; then
            bootstrap_stage_started=$started
            bootstrap_progress_memory "$bootstrap_active_pid" "$bootstrap_active_unit"
        fi
    done
    if ! bootstrap_pid_dead_or_zombie "$bootstrap_active_pid" \
            "$bootstrap_active_pid_start"; then
        echo "bootstrap: stage wrapper remained live after its bounded monitor; refusing an unbounded wait" >&2
        return 1
    fi
    # The monitor proved that this exact wrapper is already dead or a stable
    # zombie. Reap only through the identity-checked helper; never issue an
    # unbounded wait on a live or unauthenticated stage PID.
    if bootstrap_reap_dead_child "$bootstrap_active_pid" \
            "$bootstrap_active_pid_start"; then
        stage_rc=$bootstrap_reap_status
        if [ "$stage_rc" -ne 0 ]; then
            failed_pid=$bootstrap_active_pid
            failed_unit=$bootstrap_active_unit
            bootstrap_report_stage_failure "$stage_rc" "$failed_pid" "$failed_unit" \
                "$bootstrap_stage_cgroup_path"
            echo "bootstrap: compiler stage exited with status $stage_rc" >&2
            return "$stage_rc"
        fi
        bootstrap_active_pid=""
        bootstrap_active_unit=""
    else
        stage_rc=$?
        failed_pid=$bootstrap_active_pid
        failed_unit=$bootstrap_active_unit
        bootstrap_report_stage_failure "$stage_rc" "$failed_pid" "$failed_unit" \
            "$bootstrap_stage_cgroup_path"
        echo "bootstrap: compiler stage exited with status $stage_rc" >&2
        # Keep both identities for the EXIT trap. The wrapper can already be
        # reaped while a descendant still owns the captured process group.
        return "$stage_rc"
    fi
}

# A fixed-point comparison is meaningful only when every generation compiles
# the same source graph. Editors and parallel agents may legitimately change
# the checkout while a long bootstrap is running; detect that race explicitly
# instead of reporting it as compiler nondeterminism. This hashes source bytes
# only at the tooling boundary and does not participate in compilation.
bootstrap_source_fingerprint() {
    {
        printf '%s\0' zag.mod
        find selfhost std -type f -name '*.zag' -print0
    } | LC_ALL=C sort -z | xargs -0 sha256sum | sha256sum | awk '{ print $1 }'
}

bootstrap_source_start=$(bootstrap_source_fingerprint)
bootstrap_assert_source_stable() {
    bootstrap_source_now=$(bootstrap_source_fingerprint)
    if [ "$bootstrap_source_now" != "$bootstrap_source_start" ]; then
        echo "bootstrap: source changed during bootstrap; discard mixed-snapshot stages and rerun" >&2
        exit 1
    fi
}

# A compiler process exiting zero is not itself bootstrap evidence.  In
# particular, a transient service wrapper can report success after its payload
# was externally terminated.  Require the exact stage artifact before another
# generation is allowed to consume it, so a missing/empty/non-executable output
# is diagnosed at the stage that failed rather than surfacing later as a
# misleading fixed-point or "command not found" error.
bootstrap_require_executable_artifact() {
    local artifact=$1 stage_label=$2
    if [ -L "$artifact" ] || [ ! -f "$artifact" ] || [ ! -s "$artifact" ] ||
       [ ! -x "$artifact" ]; then
        echo "bootstrap: $stage_label reported success without a nonempty executable artifact: $artifact" >&2
        return 1
    fi
}

# A backend edit changes the compiler that performs the next rebuild. Build at
# least through two generated compilers, then continue for a bounded number of
# generations until two successive outputs are byte-identical. Semantic fixes
# can legitimately take an extra generation when the compiler source itself
# contains the construct being repaired. The bound keeps nondeterminism and
# non-converging miscompilations fail-closed.
bootstrap_compile "$bootstrap_seed" selfhost/native/znc.zag -o "$bootstrap_tmp/znc-stage1" \
    --no-analyze --no-foreground-cache --no-zagd
bootstrap_require_executable_artifact "$bootstrap_tmp/znc-stage1" "compiler stage 1"
bootstrap_assert_source_stable
bootstrap_compile "$bootstrap_tmp/znc-stage1" selfhost/native/znc.zag \
    -o "$bootstrap_tmp/znc-stage2" --no-analyze --no-foreground-cache --no-zagd
bootstrap_require_executable_artifact "$bootstrap_tmp/znc-stage2" "compiler stage 2"
bootstrap_assert_source_stable
bootstrap_prev="$bootstrap_tmp/znc-stage2"
bootstrap_fixed=""
bootstrap_stage=3
while [ "$bootstrap_stage" -le 6 ]; do
    bootstrap_next="$bootstrap_tmp/znc-stage$bootstrap_stage"
    bootstrap_compile "$bootstrap_prev" selfhost/native/znc.zag \
        -o "$bootstrap_next" --no-analyze --no-foreground-cache --no-zagd
    bootstrap_require_executable_artifact "$bootstrap_next" "compiler stage $bootstrap_stage"
    bootstrap_assert_source_stable
    if cmp -s "$bootstrap_prev" "$bootstrap_next"; then
        bootstrap_fixed="$bootstrap_next"
        break
    fi
    echo "   stage $((bootstrap_stage - 1)) and stage $bootstrap_stage differ; continuing toward fixpoint"
    bootstrap_prev="$bootstrap_next"
    bootstrap_stage=$((bootstrap_stage + 1))
done
if [ -z "$bootstrap_fixed" ]; then
    echo "bootstrap: self-hosting did not reach a byte-identical fixpoint" >&2
    exit 1
fi
# Build the daemon from the candidate fixed-point compiler before installing
# either generated artifact. A daemon failure must not leave a new compiler
# silently installed without its matching planner.
bootstrap_compile "$bootstrap_fixed" selfhost/zagd_daemon.zag -o "$bootstrap_tmp/zagd" \
    --no-analyze --no-zagd --no-foreground-cache
bootstrap_assert_source_stable
chmod +x "$bootstrap_tmp/zagd"
bootstrap_require_executable_artifact "$bootstrap_tmp/zagd" "zagd stage"
mv -f "$bootstrap_fixed" znc
echo "   ./znc rebuilt itself and reached a byte-identical fixpoint at stage $bootstrap_stage"
mv -f "$bootstrap_tmp/zagd" zagd
echo "   ./zagd built from selfhost/zagd_daemon.zag with the fixed-point compiler"

echo "== done. Supported compiler: ./znc; automatic planner: ./zagd =="
echo "   retired bootstrap implementations are available only through Git history."
