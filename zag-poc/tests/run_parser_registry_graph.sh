#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC_BIN=${ZNC:-./znc}
case "$ZNC_BIN" in
    /*) ;;
    *) ZNC_BIN="$PWD/${ZNC_BIN#./}" ;;
esac

fixture=/tmp/zag-parser-registry-graph-fixture
rm -rf "$fixture"
trap 'rm -rf "$fixture"' EXIT HUP INT TERM
mkdir -p "$fixture/root/nested" "$fixture/malformed"

cat >"$fixture/root/zag.mod" <<'ZAGMOD'
name = "root-package"
version = "0.0.0"
edition = "2026"

[deps]
dep = { path = "registry/index.zag", mode = "registry", version = "^1.0.0" }
ZAGMOD
mkdir -p "$fixture/root/registry/src"
mkdir -p "$fixture/root/vendor"
cat >"$fixture/root/registry/src/root.zag" <<'ZAG'
pub fn answer() i32 { return 42; }
ZAG
raw_checksum() {
    od -An -tu1 -v "$1" | awk 'BEGIN{a=216613626;b=131542391;n=0}
    {for(i=1;i<=NF;i++){a=(a*257+$i+1)%1000000007;
    b=(b*263+$i+1)%1000000009;n++}}
    END{printf "%d,%d,%d",a,b,n}'
}
source_sum=$(raw_checksum "$fixture/root/registry/src/root.zag")
printf '%s\n' \
    'format=zag-registry-index-v1' \
    'authority=local-file-v1' \
    'signature=none' \
    "entry=dep$(printf '\t')1.0.0$(printf '\t')src/root.zag$(printf '\t')$source_sum" \
    >"$fixture/root/registry/index.body"
registry_sum=$(raw_checksum "$fixture/root/registry/index.body")
printf 'checksum=%s\n' "$registry_sum" >>"$fixture/root/registry/index.body"
mv "$fixture/root/registry/index.body" "$fixture/root/registry/index.zag"
cat >"$fixture/root/nested/zag.mod" <<'ZAGMOD'
name = "nested-package"
version = "0.0.0"
edition = "2026"

[deps]
dep = { path = "registry/index.zag", mode = "registry", version = "~1.2.0", registry_lock = "nested.graph.lock" }
ZAGMOD
printf '%s\n' 'format=zag-registry-graph-lock-v1' >"$fixture/root/nested/nested.graph.lock"
cat >"$fixture/root/vendor/zag.mod" <<'ZAGMOD'
name = "vendor-package"
version = "0.0.0"
edition = "2026"

[deps]
dep = { path = "vendor/dep", mode = "vendor" }
ZAGMOD
cat >"$fixture/malformed/zag.mod" <<'ZAGMOD'
name = "malformed-package"
name = "duplicate-package"
version = "0.0.0"
edition = "2026"

[deps]
dep = { path = "registry/index.zag", mode = "registry", version = "^1.0.0" }
ZAGMOD

tmp=$(mktemp -d /tmp/zag-parser-registry-graph-run.XXXXXX)
trap 'rm -rf "$fixture" "$tmp"' EXIT HUP INT TERM

"$ZNC_BIN" check selfhost/parse.zag \
    --no-zagd --no-foreground-cache >"$tmp/check.log" 2>&1
grep -q 'znc: OK — all capability claims proven' "$tmp/check.log"

"$ZNC_BIN" selfhost/parser_registry_graph_test.zag -o "$tmp/test" \
    --no-zagd --no-analyze --no-foreground-cache >"$tmp/build.log" 2>&1
test -x "$tmp/test"
    "$tmp/test" >"$tmp/out"
grep -qx 'parser registry graph: 10/10' "$tmp/out"

echo 'parser registry graph: pass=10 fail=0 (manifest-owned graph construction and parser retention)'
