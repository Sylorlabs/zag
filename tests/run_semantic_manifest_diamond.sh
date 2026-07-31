#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zag-semantic-diamond.XXXXXX)
trap 'if [ -n "${daemon_pid:-}" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; rm -rf "$tmp"' EXIT
compiler=${ZNC_SEMANTIC_TEST:-"$(pwd)/znc"}

"$compiler" selfhost/zagd_daemon.zag -o "$tmp/zagd" --no-zagd --no-analyze >/dev/null
mkdir "$tmp/project"
printf '[package]\nname = "semantic-diamond"\nversion = "0.0.1"\n' > "$tmp/project/zag.mod"
printf 'pub fn shared(x:i32) i32 { return x; }\n' > "$tmp/project/core.zag"
printf '@import("core.zag")\npub fn left(x:i32) i32 { return shared(x); }\n' > "$tmp/project/left.zag"
printf '@import("core.zag")\npub fn right(x:i32) i32 { return shared(x); }\n' > "$tmp/project/right.zag"
printf '@import("left.zag")\n@import("right.zag")\nfn main() i32 { return left(right(0)); }\n' > "$tmp/project/app.zag"
(cd "$tmp/project" && "$compiler" check app.zag --no-zagd --no-analyze >/dev/null)
grep -q $'^import_edge=left.zag\tcore.zag$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^import_edge=right.zag\tcore.zag$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^import_edge=app.zag\tleft.zag$' "$tmp/project/.zag-cache/zagd/semantic.record"
grep -q $'^import_edge=app.zag\tright.zag$' "$tmp/project/.zag-cache/zagd/semantic.record"

"$tmp/zagd" --root "$tmp/project" --mode light --window-ms 20 &
daemon_pid=$!
for _ in $(seq 1 100); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^semantic_manifest=true$' "$tmp/project/.zagd.status"

# A public root of the diamond invalidates each path and the root once.
printf 'pub fn shared(x:i64) i64 { return x; }\n' > "$tmp/project/core.zag"
for _ in $(seq 1 200); do
    grep -q '^affected_dependents=3$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^last_change=public-shape$' "$tmp/project/.zagd.status"
grep -q '^affected_dependents=3$' "$tmp/project/.zagd.status"

printf stop > "$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
echo 'semantic manifest diamond: pass'
