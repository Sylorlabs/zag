#!/usr/bin/env bash
# Native macOS LaunchAgent adapter regression.  `launchctl` is mocked: this
# proves the generated plist and lifecycle requests without registering a real
# persistent agent for the developer running the suite.
set -euo pipefail

cd "$(dirname "$0")/.."
if [[ "$(uname -s)" != Darwin ]]; then
    echo "zagd launchd service: skipped (requires macOS)"
    exit 0
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zagd-launchd-service.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
project="$tmp/project with spaces & ampersand"
fixture="$tmp/fixture"
mkdir -p "$project" "$fixture/tools" "$tmp/bin" "$tmp/home"
printf '%s\n' 'fn main() i32 { return 0; }' >"$project/main.zag"
cp tools/zagd-launchd-service.sh "$fixture/tools/zagd-launchd-service.sh"
chmod +x "$fixture/tools/zagd-launchd-service.sh"

cat >"$fixture/zagd" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$ZAGD_LOG"
EOF
chmod +x "$fixture/zagd"

cat >"$tmp/bin/launchctl" <<'EOF'
#!/usr/bin/env bash
set -euo pipefail
printf '%s\n' "$*" >>"$LAUNCHCTL_LOG"
if [[ "$1" == print ]]; then
    compgen -G "$HOME/Library/LaunchAgents/dev.zag.zagd.*.plist" >/dev/null || exit 1
fi
EOF
chmod +x "$tmp/bin/launchctl"
export LAUNCHCTL_LOG="$tmp/launchctl.log"
export ZAGD_LOG="$tmp/zagd.log"

run_service() {
    HOME="$tmp/home" PATH="$tmp/bin:$PATH" "$fixture/tools/zagd-launchd-service.sh" "$@"
}

run_service install "$project/main.zag" adaptive >/dev/null
plist=$(find "$tmp/home/Library/LaunchAgents" -name 'dev.zag.zagd.*.plist' -type f)
test -n "$plist"
plutil -lint "$plist" >/dev/null
grep -Fq '<key>KeepAlive</key><true/>' "$plist"
grep -Fq '<key>ProcessType</key><string>Background</string>' "$plist"
grep -Fq '<string>--root-source</string>' "$plist"
grep -Fq 'project with spaces &amp; ampersand' "$plist"
if grep -Fq "$project" "$plist"; then
    echo "raw XML-sensitive path leaked into launchd plist" >&2
    exit 1
fi
grep -Eq '^bootstrap gui/[[:digit:]]+ ' "$tmp/launchctl.log"
grep -Eq '^kickstart -k gui/[[:digit:]]+/dev\.zag\.zagd\.' "$tmp/launchctl.log"

# Installed layouts put both executables in one bin directory, unlike the
# checkout's tools/ + repository-root layout. The adapter must select that
# sibling zagd without depending on PATH or a source checkout.
installed="$tmp/installed/bin"
mkdir -p "$installed" "$tmp/installed-home"
cp tools/zagd-launchd-service.sh "$installed/zagd-launchd-service"
cp "$fixture/zagd" "$installed/zagd"
chmod +x "$installed/zagd-launchd-service" "$installed/zagd"
HOME="$tmp/installed-home" PATH="$tmp/bin:$PATH" \
    "$installed/zagd-launchd-service" install "$project/main.zag" light >/dev/null
installed_plist=$(find "$tmp/installed-home/Library/LaunchAgents" -name 'dev.zag.zagd.*.plist' -type f)
test -n "$installed_plist"
grep -Fq '/installed/bin/zagd</string>' "$installed_plist"

run_service status "$project/main.zag" adaptive >/dev/null
grep -Eq '^print gui/[[:digit:]]+/dev\.zag\.zagd\.' "$tmp/launchctl.log"
run_service restart "$project/main.zag" light >/dev/null
grep -Fq '<string>light</string>' "$plist"
run_service shutdown "$project/main.zag" light >/dev/null
grep -q -- '--mode off' "$ZAGD_LOG"
run_service uninstall "$project/main.zag" light >/dev/null
test ! -e "$plist"
if run_service status "$project/main.zag" light >/dev/null 2>&1; then
    echo "uninstalled LaunchAgent unexpectedly reported status" >&2
    exit 1
fi

echo "zagd launchd service: pass"
