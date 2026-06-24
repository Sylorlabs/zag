#!/usr/bin/env bash
# End-to-end demonstration of Zag native runtime code patching.
#
# Builds a --hot host, runs it, edits a function's source, compiles a live
# patch, signals the running process, and shows the code swap take effect
# WITHOUT a restart — the loop counter keeps climbing across the swap.
set -euo pipefail

ZAGC="${ZAGC:-$(cd "$(dirname "$0")/.." && pwd)/zig-out/bin/zagc}"
SRC="$(cd "$(dirname "$0")" && pwd)/hot_demo.zag"

WORK="$(mktemp -d)"
cd "$WORK"
cp "$SRC" demo.zag
rm -f zag_hot_stop

echo "### 1. build the host with a swappable dispatch table"
"$ZAGC" build --hot demo.zag 2>/dev/null | grep -E "built|hot|toolchain" || true

echo
echo "### 2. launch it (label() returns 1 → values are 1000,1001,1002,...)"
ZAG_HOT_PATCH="$WORK/demo_patch.so" ./demo > run.log 2>hot.log &
HOST=$!
sleep 1.6

echo "### 3. edit label() in the source: return 1  ->  return 2"
sed -i 's/return 1;/return 2;/' demo.zag

echo "### 4. compile a live patch and signal the running process"
"$ZAGC" hot-patch demo.zag -o demo_patch.so 2>/dev/null | grep -E "built patch" || true
kill -USR1 "$HOST"
sleep 1.6

echo "### 5. stop the loop cleanly"
touch zag_hot_stop
sleep 0.5
kill "$HOST" 2>/dev/null || true
wait "$HOST" 2>/dev/null || true

echo
echo "### program output (note the leading digit flips 1xxx -> 2xxx while the"
echo "### trailing counter keeps climbing — same process, state retained):"
nl -ba run.log | sed 's/^/    /'
echo
echo "### runtime log (the live reload event):"
grep -E "hot|generation" hot.log | sed 's/^/    /' || true

rm -rf "$WORK"
