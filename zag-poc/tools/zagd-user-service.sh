#!/usr/bin/env bash
set -euo pipefail

usage() {
    echo "usage: $0 install <root-source.zag> [light|adaptive|deep] | uninstall <root-source.zag> | status <root-source.zag>" >&2
    exit 2
}

command=${1:-}
source_arg=${2:-}
mode=${3:-adaptive}
test -n "$command" && test -n "$source_arg" || usage
case "$mode" in light|adaptive|deep) ;; *) usage ;; esac

source_path=$(realpath "$source_arg")
project_root=$(dirname "$source_path")
while test "$project_root" != / && test ! -d "$project_root/.git" && test ! -f "$project_root/zag.mod"; do
    project_root=$(dirname "$project_root")
done
test "$project_root" != / || project_root=$(dirname "$source_path")

repo_root=$(cd "$(dirname "$0")/.." && pwd)
zagd_path="$repo_root/zagd"
test -x "$zagd_path" || { echo "zagd service: build $zagd_path with bootstrap.sh first" >&2; exit 1; }

# Keep the systemd cgroup ceiling and the daemon's RLIMIT_AS ceiling in lock
# step. The compiler owns the full configuration grammar; this installer only
# reads the one decimal resource value it must put into a systemd unit.
planner_memory_bytes=536870912
planner_config="$project_root/.zagd.conf"
if test -f "$planner_config"; then
    configured_memory=$(awk -F= '
        /^[[:space:]]*#/ { next }
        /^[[:space:]]*max_memory_bytes[[:space:]]*=/ {
            value=$2
            sub(/^[[:space:]]+/, "", value)
            sub(/[[:space:]]+$/, "", value)
            print value
            exit
        }
    ' "$planner_config")
    if test -n "$configured_memory"; then
        case "$configured_memory" in
            *[!0-9]*|'')
                echo "zagd service: max_memory_bytes must be a decimal value from 67108864 through 2147483648" >&2
                exit 1
                ;;
        esac
        if (( configured_memory < 67108864 || configured_memory > 2147483648 )); then
            echo "zagd service: max_memory_bytes must be 67108864..2147483648" >&2
            exit 1
        fi
        planner_memory_bytes=$configured_memory
    fi
fi

escaped=$(systemd-escape --path "$project_root")
unit="zagd-${escaped}.service"
config_root=${XDG_CONFIG_HOME:-$HOME/.config}
unit_dir="$config_root/systemd/user"
unit_path="$unit_dir/$unit"

case "$command" in
install)
    install -d -m 700 "$unit_dir"
    service="[Unit]
Description=Zag continuous planner for $project_root
After=default.target

[Service]
Type=simple
WorkingDirectory=$project_root
ExecStart=$zagd_path --root $project_root --root-source $source_path --mode $mode --max-memory-bytes $planner_memory_bytes
Restart=always
RestartSec=1
# A cgroup OOM is a resource-policy stop, not a reason to spin in a restart
# loop and keep competing with the desktop. Ordinary nonzero daemon failures
# remain restartable; znc watch or systemd can explicitly restart after the
# user has freed resources.
RestartPreventExitStatus=SIGKILL
OOMPolicy=stop
Nice=10
MemoryMax=$planner_memory_bytes
MemorySwapMax=0
CPUWeight=25
NoNewPrivileges=true

[Install]
WantedBy=default.target
"
    printf '%s' "$service" >"$unit_path"
    systemctl --user daemon-reload
    systemctl --user enable --now "$unit"
    echo "zagd service installed: $unit"
    echo "configuration remains project-local in $project_root/.zagd.conf; rerun this command to change service mode/root"
    ;;
uninstall)
    systemctl --user disable --now "$unit" 2>/dev/null || true
    if test -f "$unit_path"; then unlink "$unit_path"; fi
    systemctl --user daemon-reload
    echo "zagd service removed: $unit"
    ;;
status)
    systemctl --user status "$unit" --no-pager
    ;;
*) usage ;;
esac
