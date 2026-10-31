#!/usr/bin/env bash
# Bounded policy-precedence witness, independent of selfhost/compiler edits.
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-planner-precedence.XXXXXX")
trap 'rm -rf "$tmp"' EXIT
compiler=${ZNC:-./znc}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac

"$compiler" tests/planner_precedence.zag -o "$tmp/planner_precedence" \
  --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/planner_precedence" | tee "$tmp/witness.log"
grep -Fq 'planner precedence: pass=12 fail=0' "$tmp/witness.log"

# Daemon startup is orthogonal to foreground policy consumption.
mkdir -p "$tmp/project"
echo 'name = "planner-precedence"' >"$tmp/project/zag.mod"
echo 'script;' >"$tmp/project/app.zag"
echo 'return 0;' >>"$tmp/project/app.zag"
echo 'mode=off' >"$tmp/project/.zagd.conf"
echo 'allocator=script_process_arena' >>"$tmp/project/.zagd.conf"
echo 'device=cpu' >>"$tmp/project/.zagd.conf"
echo 'layout=compiler_owned' >>"$tmp/project/.zagd.conf"
echo 'cpu=generic' >>"$tmp/project/.zagd.conf"
(cd "$tmp/project" && "$compiler" check app.zag --no-zagd --no-analyze \
  --no-foreground-cache >/dev/null)

# Existing malformed policy is rejected rather than silently replaced by defaults.
echo 'trust_mode=unsafe' >"$tmp/project/.zagd.conf"
if (cd "$tmp/project" && "$compiler" check app.zag --no-zagd --no-analyze \
  --no-foreground-cache >"$tmp/malformed.log" 2>&1); then
  echo 'malformed project policy unexpectedly accepted' >&2
  exit 1
fi
grep -Fq 'invalid .zagd.conf' "$tmp/malformed.log"
grep -Fq 'trust_mode must be stable, reviewed, or autonomous' "$tmp/malformed.log"
echo 'planner precedence gate: PASS (CLI > source > project > defaults; malformed policy fail-closed; --no-zagd independent)'
