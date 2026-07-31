#!/usr/bin/env bash
# Native macOS launchd adapter for the advisory Zag planner.
set -euo pipefail

usage() {
    echo "usage: zagd-launchd-service.sh {install|restart|shutdown|uninstall|status} <root-source.zag> [light|adaptive|deep]" >&2
    exit 2
}

(( $# >= 2 )) || usage
action=$1
source_arg=$2
mode=${3:-adaptive}
case "$mode" in light|adaptive|deep) ;; *) usage ;; esac
case "$action" in install|restart|shutdown|uninstall|status) ;; *) usage ;; esac

source_dir=$(cd "$(dirname "$source_arg")" && pwd)
source_path="$source_dir/$(basename "$source_arg")"
test -f "$source_path" || { echo "zagd launchd: root source must be a regular file" >&2; exit 2; }

root=$source_dir
while [[ "$root" != / && ! -d "$root/.git" && ! -f "$root/zag.mod" ]]; do root=$(dirname "$root"); done
[[ "$root" != / ]] || root=$source_dir

script_dir=$(cd "$(dirname "$0")" && pwd)
zagd_path="$script_dir/zagd"
[[ -x "$zagd_path" ]] || zagd_path="$script_dir/../zagd"
test -x "$zagd_path" || { echo "zagd launchd: build zagd first" >&2; exit 1; }

xml_escape() {
    sed -e 's/&/\&amp;/g' -e 's/</\&lt;/g' -e 's/>/\&gt;/g' -e 's/"/\&quot;/g' -e "s/'/\&apos;/g"
}
xml() { printf '%s' "$1" | xml_escape; }
uid=$(id -u)
safe=$(printf '%s' "$root" | shasum -a 256 | cut -c1-16)
label="dev.zag.zagd.$safe"
plist_dir="$HOME/Library/LaunchAgents"
log_dir="$HOME/Library/Logs/Zag"
plist="$plist_dir/$label.plist"
domain="gui/$uid"

write_plist() {
    mkdir -p "$plist_dir"
    mkdir -p "$log_dir"
    local temp
    temp=$(mktemp "$plist_dir/.zagd-launchd.XXXXXX")
    cat >"$temp" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0"><dict>
<key>Label</key><string>$(xml "$label")</string>
<key>ProgramArguments</key><array>
<string>$(xml "$zagd_path")</string><string>--root</string><string>$(xml "$root")</string>
<string>--root-source</string><string>$(xml "$source_path")</string>
<string>--mode</string><string>$(xml "$mode")</string>
</array>
<key>WorkingDirectory</key><string>$(xml "$root")</string>
<key>KeepAlive</key><true/><key>ThrottleInterval</key><integer>1</integer>
<key>ProcessType</key><string>Background</string>
<key>StandardOutPath</key><string>$(xml "$log_dir/$label.out")</string>
<key>StandardErrorPath</key><string>$(xml "$log_dir/$label.err")</string>
</dict></plist>
EOF
    plutil -lint "$temp" >/dev/null
    mv -f "$temp" "$plist"
}

unload() { launchctl bootout "$domain/$label" >/dev/null 2>&1 || true; }

case "$action" in
  install)
    write_plist; unload; launchctl bootstrap "$domain" "$plist"; launchctl kickstart -k "$domain/$label"
    echo "zagd launchd: installed $label"
    ;;
  restart)
    # Refresh the plist before restarting so a requested mode and any moved
    # project path are reflected by launchd, just as the Linux service refresh
    # rewrites its unit before a policy restart.
    write_plist
    unload; launchctl bootstrap "$domain" "$plist"; launchctl kickstart -k "$domain/$label"
    echo "zagd launchd: restarted $label"
    ;;
  shutdown)
    unload; "$zagd_path" --root "$root" --root-source "$source_path" --mode off >/dev/null || true
    echo "zagd launchd: stopped $label"
    ;;
  uninstall)
    unload; rm -f "$plist"; "$zagd_path" --root "$root" --root-source "$source_path" --mode off >/dev/null || true
    echo "zagd launchd: removed $label"
    ;;
  status)
    launchctl print "$domain/$label" 2>/dev/null || { echo "zagd launchd: not loaded"; exit 1; }
    ;;
esac
