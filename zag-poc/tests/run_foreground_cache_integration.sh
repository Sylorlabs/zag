#!/usr/bin/env bash
set -euo pipefail

compiler="${ZNC:-./znc}"
case "$compiler" in /*) ;; *) compiler="$(pwd)/${compiler#./}" ;; esac
work="$(mktemp -d)"
trap 'rm -rf -- "$work"' EXIT

cat >"$work/dep.zag" <<'EOF'
fn cached_value() i32 { return 42; }
EOF
cat >"$work/main.zag" <<'EOF'
@import("dep.zag")
fn main() i32 { return cached_value(); }
EOF

cd "$work"
"$compiler" main.zag -o app --cache-report >cold.log
grep -q 'znc cache: MISS stored machine code and data' cold.log
set +e
./app
rc=$?
set -e
test "$rc" -eq 42

"$compiler" main.zag -o app --cache-report >warm.log
grep -q 'znc cache: HIT revalidated machine code and data; codegen skipped' warm.log

# Payload corruption is a miss and a correct executable is still produced.
printf '\177' >>.zag-cache/foreground/machine.code
"$compiler" main.zag -o app --cache-report >corrupt.log
grep -q 'znc cache: MISS stored machine code and data' corrupt.log

# Imported-module content participates in the dependency key.
sed -i 's/42/41/' dep.zag
"$compiler" main.zag -o app --cache-report >stale.log
grep -q 'znc cache: MISS stored machine code and data' stale.log
set +e
./app
rc=$?
set -e
test "$rc" -eq 41

echo 'foreground cache integration: PASS'
