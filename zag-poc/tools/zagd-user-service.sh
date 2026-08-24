#!/usr/bin/env bash
set -euo pipefail

# This is deliberately a small systemd adapter, not a second planner
# configuration parser. The private run command reads the subset of .zagd.conf
# that maps to zagd's command line every time systemd starts the service. The
# unit itself owns only the cgroup envelope, which systemd cannot change
# without a reload.

usage() {
    cat >&2 <<'EOF'
usage:
  zagd-user-service.sh install <root-source.zag> [light|adaptive|deep]
  zagd-user-service.sh reload <root-source.zag> [light|adaptive|deep]
  zagd-user-service.sh restart <root-source.zag>
  zagd-user-service.sh shutdown <root-source.zag>
  zagd-user-service.sh uninstall <root-source.zag>
  zagd-user-service.sh status <root-source.zag>

restart rereads .zagd.conf. reload also recreates the cgroup MemoryMax from
max_memory_bytes, then restarts the service. Mode in .zagd.conf wins over the
optional fallback mode written by install/reload.
shutdown stops the unit without removing it; uninstall also disables and
removes the generated unit.
EOF
    exit 2
}

if (( $# < 2 )); then usage; fi
command=$1
source_arg=$2
requested_mode=
if (( $# >= 3 )); then requested_mode=$3; fi
if test -n "$requested_mode"; then
    case "$requested_mode" in light|adaptive|deep) ;; *) usage ;; esac
fi

source_path=$(realpath -- "$source_arg")
test -f "$source_path" || { echo "zagd service: root source must be a regular file" >&2; exit 2; }
source_root=$(dirname "$source_path")
project_root=
probe_root=$source_root
while test "$probe_root" != /; do
    if test -f "$probe_root/zag.mod"; then
        project_root=$probe_root
        break
    fi
    probe_root=$(dirname "$probe_root")
done
test -n "$project_root" || project_root=$source_root

repo_root=$(cd "$(dirname "$0")/.." && pwd)
zagd_path="$repo_root/zagd"
script_path=$(realpath -- "$0")
# Repository checkouts place the adapter in tools/ and zagd at the repository
# root. `make install` places both executables side-by-side in /usr/local/bin.
# Resolve only those two explicit layouts; never execute a PATH-selected daemon
# whose bytes may not match the adapter the user invoked.
if test ! -x "$zagd_path"; then
    installed_sibling=$(dirname "$script_path")/zagd
    if test -x "$installed_sibling"; then zagd_path="$installed_sibling"; fi
fi
planner_config="$project_root/.zagd.conf"

validate_config_keys() {
    test -f "$planner_config" || return 0
    awk '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        BEGIN {
            split("mode idle_deep difficulty script_optimization regular_optimization objective trust_mode allocator device layout cpu notifications script_memory_bytes allow_filesystem_read allow_filesystem_write allow_process environment_allow max_workers stability_window_ms max_memory_bytes max_cache_bytes", names, " ")
            for (i in names) { known[names[i]] = 1 }
        }
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*$/ { next }
        {
            line = $0
            sub(/\r$/, "", line)
            equals = index(line, "=")
            key = equals > 0 ? trim(substr(line, 1, equals - 1)) : ""
            if (equals <= 1 || !(key in known) || seen[key]++) { exit 1 }
        }
    ' "$planner_config" || {
        echo "zagd service: invalid .zagd.conf syntax, unknown key, or duplicate key" >&2
        return 1
    }
}

config_value() {
    local key=$1
    test -f "$planner_config" || return 0
    awk -v wanted="$key" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/\r$/, "", line)
            equals = index(line, "=")
            if (equals == 0) { next }
            name = trim(substr(line, 1, equals - 1))
            if (name == wanted) {
                print trim(substr(line, equals + 1))
                exit
            }
        }
    ' "$planner_config"
}

config_key_present() {
    local key=$1
    test -f "$planner_config" || return 1
    awk -v wanted="$key" '
        function trim(value) {
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            return value
        }
        /^[[:space:]]*#/ { next }
        {
            line = $0
            sub(/\r$/, "", line)
            equals = index(line, "=")
            if (equals > 0 && trim(substr(line, 1, equals - 1)) == wanted) {
                found = 1
            }
        }
        END { exit found ? 0 : 1 }
    ' "$planner_config"
}

choice_config() {
    local key=$1 fallback=$2 value allowed matched=0
    shift 2
    value=$(config_value "$key")
    if test -z "$value"; then
        if config_key_present "$key"; then
            echo "zagd service: $key must not be empty" >&2
            return 1
        fi
        value=$fallback
    fi
    for allowed in "$@"; do
        if test "$value" = "$allowed"; then matched=1; break; fi
    done
    if test "$matched" -ne 1; then
        printf 'zagd service: invalid %s=%s\n' "$key" "$value" >&2
        return 1
    fi
    printf '%s' "$value"
}

decimal_config() {
    local key=$1 minimum=$2 maximum=$3 fallback=$4 value
    value=$(config_value "$key")
    if test -z "$value"; then
        if config_key_present "$key"; then
            echo "zagd service: $key must not be empty" >&2
            return 1
        fi
        printf '%s' "$fallback"
        return 0
    fi
    case "$value" in *[!0-9]*|'')
        echo "zagd service: $key must be a decimal value from $minimum through $maximum" >&2
        return 1
    esac
    if (( value < minimum || value > maximum )); then
        echo "zagd service: $key must be $minimum..$maximum" >&2
        return 1
    fi
    printf '%s' "$value"
}

read_service_config() {
    # $1 is a unit-owned fallback. A project setting deliberately overrides it
    # on the next restart, so toggling mode is not an uninstall/reinstall task.
    validate_config_keys
    service_mode=$1
    local configured_mode
    configured_mode=$(config_value mode)
    if test -n "$configured_mode"; then service_mode=$configured_mode
    elif config_key_present mode; then
        echo "zagd service: mode must not be empty" >&2
        return 1
    fi
    if test "$service_mode" = advisory; then service_mode=light; fi
    case "$service_mode" in off|light|adaptive|deep) ;; *)
        echo "zagd service: mode must be off, light, adaptive, or deep" >&2
        return 1
    esac
    service_memory_bytes=$(decimal_config max_memory_bytes 67108864 2147483648 536870912)
    # Leave a kernel-enforced reclamation/throttling band below MemoryMax so
    # the low-priority advisory service yields before it reaches the hard OOM
    # boundary. Keep at least one 1 MiB page-sized working margin.
    service_memory_high_bytes=$(( service_memory_bytes * 9 / 10 ))
    if (( service_memory_high_bytes < 67108864 )); then service_memory_high_bytes=67108864; fi
    service_window_ms=$(decimal_config stability_window_ms 1 60000 75)
    service_cache_bytes=$(decimal_config max_cache_bytes 1048576 2147483648 2147483648)
    service_notifications=$(choice_config notifications advisory \
        errors_only advisory)
    service_idle_deep=$(choice_config idle_deep true true false)
    service_difficulty=$(choice_config difficulty simple \
        simple explained explicit native)
    service_script_optimization=$(choice_config script_optimization automatic \
        automatic review off)
    service_regular_optimization=$(choice_config regular_optimization review \
        review automatic off)
    service_objective=$(choice_config objective runtime runtime)
    service_trust_mode=$(choice_config trust_mode stable \
        stable reviewed autonomous)
    service_cpu=$(choice_config cpu generic \
        generic native runtime x86-64 x86-64-v1)
    # Validate the foreground-only policy fields too. The service does not
    # transport them to zagd, but it must not activate from a file that `znc`
    # would reject as malformed.
    local ignored environment_allow
    ignored=$(choice_config allocator script_process_arena \
        script_process_arena script_bounded_heap)
    ignored=$(choice_config device cpu cpu)
    ignored=$(choice_config layout compiler_owned compiler_owned)
    ignored=$(decimal_config script_memory_bytes 1048576 2147483648 67108864)
    ignored=$(choice_config allow_filesystem_read true true false)
    ignored=$(choice_config allow_filesystem_write true true false)
    ignored=$(choice_config allow_process true true false)
    ignored=$(choice_config max_workers 1 1)
    environment_allow=$(config_value environment_allow)
    if test -n "$environment_allow" && {
        test "${#environment_allow}" -gt 512 ||
        ! printf '%s' "$environment_allow" | awk -F, '
            {
                for (i = 1; i <= NF; i++) {
                    if (length($i) > 128 || $i !~ /^[A-Za-z_][A-Za-z0-9_]*$/) {
                        exit 1
                    }
                }
            }
        '
    }; then
        echo "zagd service: environment_allow must be comma-separated variable names" >&2
        return 1
    fi
}

release_project_singleton() {
    # Foreground compiler commands may already have auto-started the
    # project singleton before this service was installed or restarted.
    # Ask that owner to shut down through zagd's normal stop protocol before
    # systemd launches its supervised replacement.  The daemon's off path
    # validates the lock identity, waits at most two seconds for a live owner,
    # and removes a stale lock.  The outer timeout also bounds failures before
    # that protocol is reached (for example a corrupt executable).
    test -e "$project_root/.zagd.lock" || return 0
    if ! timeout --foreground --signal=TERM --kill-after=1s 5s \
        "$zagd_path" \
        --root "$project_root" \
        --root-source "$source_path" \
        --mode off \
        --idle-deep "$service_idle_deep" \
        --difficulty "$service_difficulty" \
        --script-optimization "$service_script_optimization" \
        --regular-optimization "$service_regular_optimization" \
        --objective "$service_objective" \
        --trust-mode "$service_trust_mode" \
        --cpu "$service_cpu" \
        --window-ms "$service_window_ms" \
        --max-memory-bytes "$service_memory_bytes" \
        --max-cache-bytes "$service_cache_bytes" \
        --max-workers 1 \
        --notifications "$service_notifications"
    then
        echo "zagd service: existing project daemon did not release ownership" >&2
        return 1
    fi
    if test -e "$project_root/.zagd.lock"; then
        echo "zagd service: project singleton lock remained after graceful shutdown" >&2
        return 1
    fi
}

prepare_service_handoff() {
    # An explicit stop suppresses Restart=always while ownership moves. Use
    # --no-block so an older generated unit without our bounded TimeoutStopSec
    # cannot hold this command for systemd's long default timeout. The daemon
    # protocol above is the authoritative bounded handoff.
    systemctl --user stop "$unit" --no-block >/dev/null 2>&1 || true
    release_project_singleton
}

# systemd unit values are not shell syntax. Encode every byte so a path with
# whitespace, quotes, a semicolon, $, or a newline remains exactly one unit
# argument and cannot alter the unit. The \xNN form is systemd command-line
# escaping. Source paths are ordinary Linux byte paths, so NUL is not
# representable and cannot enter this function.
systemd_escape_argument() {
    local hex
    hex=$(LC_ALL=C printf '%s' "$1" | od -An -v -tx1 | tr -d ' \n')
    test -n "$hex" || { echo "zagd service: empty systemd argument" >&2; return 1; }
    printf '%s' "$hex" | sed 's/\(..\)/\\x\1/g'
}

# WorkingDirectory is path syntax, unlike ExecStart command-line syntax: its
# leading slash must remain literal. Literal separators are inert in a unit
# assignment, while every non-separator byte remains escaped.
systemd_escape_path() {
    systemd_escape_argument "$1" | sed 's/\\x2f/\//g'
}

escaped=$(systemd-escape --path "$project_root")
unit="zagd-$escaped.service"
config_root=$(printenv XDG_CONFIG_HOME || true)
if test -z "$config_root"; then config_root="$HOME/.config"; fi
unit_dir="$config_root/systemd/user"
unit_path="$unit_dir/$unit"

stored_fallback_mode() {
    if test -f "$unit_path"; then
        awk -F= '/^# zagd-fallback-mode=/{ print $2; exit }' "$unit_path"
    fi
}

choose_fallback_mode() {
    if test -n "$requested_mode"; then
        printf '%s' "$requested_mode"
        return 0
    fi
    local stored
    stored=$(stored_fallback_mode)
    case "$stored" in light|adaptive|deep) printf '%s' "$stored" ;; *) printf '%s' adaptive ;; esac
}

write_unit() {
    local fallback=$1 tmp escaped_script escaped_source escaped_root
    test -x "$zagd_path" || { echo "zagd service: build $zagd_path with bootstrap.sh first" >&2; return 1; }
    read_service_config "$fallback"
    if test "$service_mode" = off; then
        echo "zagd service: mode=off disables the persistent service; set mode=light, adaptive, or deep first" >&2
        return 1
    fi
    install -d -m 700 "$unit_dir"
    escaped_script=$(systemd_escape_argument "$script_path")
    escaped_source=$(systemd_escape_argument "$source_path")
    escaped_root=$(systemd_escape_path "$project_root")
    tmp=$(mktemp "$unit_dir/.zagd-service.XXXXXX")
    cat >"$tmp" <<EOF
[Unit]
Description=Zag continuous planner
After=default.target
StartLimitIntervalSec=60
StartLimitBurst=5

[Service]
Type=simple
WorkingDirectory=$escaped_root
# zagd-fallback-mode=$fallback
ExecStart=$escaped_script run $escaped_source $fallback
Restart=always
RestartSec=1
TimeoutStopSec=5s
# A cgroup OOM is a resource-policy stop, not a restart loop competing with
# the desktop. Exit 75 is a deliberate mode=off stop from the service runner.
RestartPreventExitStatus=SIGKILL 75
OOMPolicy=stop
Nice=10
MemoryMax=$service_memory_bytes
MemoryHigh=$service_memory_high_bytes
MemorySwapMax=0
CPUWeight=25
TasksMax=64
NoNewPrivileges=true
# The daemon is local-only. These are enforced by systemd as a second line of
# defense; the daemon policy also leaves network and background GPU disabled.
PrivateNetwork=true
PrivateDevices=true

[Install]
WantedBy=default.target
EOF
    chmod 600 "$tmp"
    mv -f "$tmp" "$unit_path"
}

run_service() {
    local fallback=$1
    case "$fallback" in light|adaptive|deep) ;; *)
        echo "zagd service: invalid unit fallback mode" >&2
        return 1
    esac
    read_service_config "$fallback"
    if test "$service_mode" = off; then
        echo "zagd service: mode=off; service intentionally stopped" >&2
        return 75
    fi
    test -x "$zagd_path" || { echo "zagd service: build $zagd_path with bootstrap.sh first" >&2; return 1; }
    # Repeat the handoff inside the service runner. This closes the window in
    # which an ordinary foreground command can auto-start zagd after the
    # public install/restart command released the old owner but before systemd
    # executes this process. A supervised service therefore self-recovers from
    # singleton exit 6 instead of entering a restart/backoff loop.
    release_project_singleton
    exec "$zagd_path" \
        --root "$project_root" \
        --root-source "$source_path" \
        --mode "$service_mode" \
        --idle-deep "$service_idle_deep" \
        --difficulty "$service_difficulty" \
        --script-optimization "$service_script_optimization" \
        --regular-optimization "$service_regular_optimization" \
        --objective "$service_objective" \
        --trust-mode "$service_trust_mode" \
        --cpu "$service_cpu" \
        --window-ms "$service_window_ms" \
        --max-memory-bytes "$service_memory_bytes" \
        --max-cache-bytes "$service_cache_bytes" \
        --max-workers 1 \
        --notifications "$service_notifications"
}

case "$command" in
install)
    fallback=$(choose_fallback_mode)
    write_unit "$fallback"
    systemctl --user daemon-reload
    prepare_service_handoff
    systemctl --user enable --now "$unit"
    echo "zagd service installed: $unit"
    echo "edit $planner_config, then use '$0 restart $source_path'; use reload after max_memory_bytes changes"
    ;;
reload)
    fallback=$(choose_fallback_mode)
    write_unit "$fallback"
    systemctl --user daemon-reload
    prepare_service_handoff
    systemctl --user restart "$unit"
    echo "zagd service reloaded: $unit"
    ;;
restart)
    test -f "$unit_path" || { echo "zagd service: not installed: $unit" >&2; exit 3; }
    fallback=$(choose_fallback_mode)
    read_service_config "$fallback"
    prepare_service_handoff
    systemctl --user restart "$unit"
    echo "zagd service restarted: $unit"
    ;;
shutdown)
    test -f "$unit_path" || { echo "zagd service: not installed: $unit" >&2; exit 3; }
    systemctl --user stop "$unit"
    echo "zagd service stopped: $unit"
    ;;
uninstall)
    systemctl --user disable --now "$unit" 2>/dev/null || true
    if test -f "$unit_path"; then unlink "$unit_path"; fi
    systemctl --user daemon-reload
    echo "zagd service removed: $unit"
    ;;
status)
    test -f "$unit_path" || { echo "zagd service: not installed: $unit" >&2; exit 3; }
    systemctl --user status "$unit" --no-pager
    ;;
run)
    # Systemd invokes this private command. Callers should use the public
    # install, restart, and reload commands instead.
    run_service "$requested_mode"
    ;;
*) usage ;;
esac
