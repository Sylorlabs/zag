#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zag-semantic-e2e.XXXXXX)
trap 'if [ -n "${daemon_pid:-}" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
compiler=${ZNC_SEMANTIC_TEST:-"$(pwd)/znc"}
"$compiler" selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-zagd --no-analyze >/dev/null
mkdir "$tmp/project"
printf '[package]\nname = "semantic-test"\nversion = "0.0.1"\n' > "$tmp/project/zag.mod"
printf 'pub fn helper(x:i32) i32 { return x; }\n' > "$tmp/project/lib.zag"
printf '@import("lib.zag")\npub struct Point { x:i32, y:i32 }\npub fn api(x:i32) i32 { return helper(x); }\nfn main() i32 { return api(0); }\n' > "$tmp/project/app.zag"
(cd "$tmp/project" && "$compiler" check app.zag --no-zagd --no-analyze >/dev/null)
test -f "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^complete=true$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q '^executable_authority=false$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^module_node=app.zag\t' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^module_node=lib.zag\t' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^import_edge=app.zag\tlib.zag$' "$tmp/project/.zag-cache/zagd/semantic.record"
"$tmp/zagd" --root "$tmp/project" --mode light --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"
printf 'pub fn helper(x:i64) i64 { return x; }\n' > "$tmp/project/lib.zag"
for _ in $(seq 1 100); do
    grep -q '^affected_dependents=1$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^semantic_manifest=false$' "$tmp/project/.zagd.status"
grep -q '^last_change=public-shape$' "$tmp/project/.zagd.status"
grep -q '^affected_dependents=1$' "$tmp/project/.zagd.status" || { sed -n '1,30p' "$tmp/project/.zagd.status"; exit 1; }
printf stop > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
echo "semantic manifest e2e: pass"
