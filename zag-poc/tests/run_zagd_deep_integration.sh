#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
tmp=$(mktemp -d /tmp/zagd-deep-integration.XXXXXX)
daemon_pid=
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; find "$tmp" -depth -delete' EXIT
mkdir -p "$tmp/bin"
if [ -n "${ZAGD:-}" ]; then
    cp "$ZAGD" "$tmp/bin/zagd"
else
    ./znc selfhost/zagd_daemon.zag -o "$tmp/bin/zagd" --no-zagd --no-analyze >/dev/null
fi
cp ./znc "$tmp/bin/znc"
./znc tests/zagd_finalist_witness.zag -o "$tmp/reference" --no-zagd --no-analyze >/dev/null
cp "$tmp/reference" "$tmp/equivalent"
./znc tests/zagd_finalist_mismatch.zag -o "$tmp/mismatch" --no-zagd --no-analyze >/dev/null
./znc tests/zagd_finalist_delay.zag -o "$tmp/delay" --no-zagd --no-analyze >/dev/null

prepare() {
    project=$1 reference=$2 finalist=$3
    mkdir -p "$project"
    printf 'fn main() i32 { return 0; }\n' >"$project/main.zag"
    printf '%s\n' "$reference" >"$project/.zagd.deep-reference"
    printf '%s\n' "$finalist" >"$project/.zagd.deep-finalist"
    (cd "$project" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
}

prepare "$tmp/equal" "$tmp/reference" "$tmp/equivalent"
"$tmp/bin/zagd" --root "$tmp/equal" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
for _ in $(seq 1 150); do [ -f "$tmp/equal/.zag-cache/zagd/deep-measurement.record" ] && break; sleep .02; done
record="$tmp/equal/.zag-cache/zagd/deep-measurement.record"
test -f "$record"
grep -q '^equivalence=exact-output-stderr-exit-signal-state$' "$record"
grep -q '^runs=3$' "$record"
printf stop >"$tmp/equal/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

prepare "$tmp/mismatch-project" "$tmp/reference" "$tmp/mismatch"
"$tmp/bin/zagd" --root "$tmp/mismatch-project" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .3
test ! -e "$tmp/mismatch-project/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/mismatch-project/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

prepare "$tmp/stale" "$tmp/delay" "$tmp/delay"
"$tmp/bin/zagd" --root "$tmp/stale" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .05; printf '// invalidates finalist snapshot\n' >>"$tmp/stale/main.zag"
sleep .7
test ! -e "$tmp/stale/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/stale/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

prepare "$tmp/light" "$tmp/reference" "$tmp/equivalent"
"$tmp/bin/zagd" --root "$tmp/light" --root-source main.zag --mode light --window-ms 10 & daemon_pid=$!
sleep .2
test ! -e "$tmp/light/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/light/.zagd.stop"; wait "$daemon_pid"; daemon_pid=
echo 'zagd deep product integration: pass'
