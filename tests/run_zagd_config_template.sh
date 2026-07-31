#!/usr/bin/env bash
# The shipped policy example is part of the product surface: it must remain a
# real, fail-closed .zagd.conf accepted by the same foreground parser that
# applies Script defaults.  --no-zagd keeps this fixture from starting a
# background process while still exercising configuration consumption.
set -euo pipefail
cd "$(dirname "$0")/.."

znc_bin=${ZNC:-./znc}
case "$znc_bin" in /*) ;; *) znc_bin="$(pwd)/${znc_bin#./}" ;; esac

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-zagd-config-template.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
mkdir -p "$tmp/project"
printf 'name = "zagd-config-template"\n' >"$tmp/project/zag.mod"
cp examples/zagd.conf "$tmp/project/.zagd.conf"
cat >"$tmp/project/app.zag" <<'EOF'
script;
return 0;
EOF

(cd "$tmp/project" && "$znc_bin" explain app.zag --format json --no-zagd) \
    >"$tmp/explain.json"
grep -q '"allocator":{"value":"script_process_arena","basis":"derived"}' "$tmp/explain.json"
grep -q '"script_memory_bytes":{"value":67108864' "$tmp/explain.json"
grep -q '"execution_plan":{"cpu":"generic","device":"cpu","layout":"compiler_owned","basis":"derived"}' "$tmp/explain.json"

echo "zagd config template: PASS"
