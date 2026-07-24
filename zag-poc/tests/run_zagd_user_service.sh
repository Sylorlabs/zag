#!/usr/bin/env bash
set -euo pipefail

cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-service.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/bin" "$tmp/project"
printf 'fn main() i32 { return 0; }\n' >"$tmp/project/main.zag"
printf 'max_memory_bytes=134217728\n' >"$tmp/project/.zagd.conf"
ln -s "$PWD/zagd" "$tmp/project/zagd"
cat >"$tmp/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
printf '%s\n' "$*" >>"$SYSTEMCTL_LOG"
EOF
chmod +x "$tmp/bin/systemctl"
export SYSTEMCTL_LOG="$tmp/systemctl.log"
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh install "$tmp/project/main.zag" adaptive >/dev/null
unit=$(find "$tmp/config/systemd/user" -type f -name 'zagd-*.service')
grep -q '^Type=simple$' "$unit"
grep -q '^Restart=always$' "$unit"
grep -q '^Nice=10$' "$unit"
grep -q -- '--mode adaptive --max-memory-bytes 134217728$' "$unit"
grep -q '^MemoryMax=134217728$' "$unit"
grep -q '^--user daemon-reload$' "$tmp/systemctl.log"
grep -q '^--user enable --now zagd-' "$tmp/systemctl.log"
XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh uninstall "$tmp/project/main.zag" >/dev/null
test ! -e "$unit"
printf 'max_memory_bytes=not-a-number\n' >"$tmp/project/.zagd.conf"
if XDG_CONFIG_HOME="$tmp/config" PATH="$tmp/bin:$PATH" tools/zagd-user-service.sh install "$tmp/project/main.zag" adaptive >/dev/null 2>&1; then
    echo "invalid service memory config unexpectedly accepted" >&2
    exit 1
fi
echo "zagd user service: pass"
