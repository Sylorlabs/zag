#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."
compiler=${ZNC:-./znc}
case "$compiler" in /*) ;; *) compiler="$PWD/${compiler#./}" ;; esac
tmp=$(mktemp -d /tmp/zagd-deep-integration.XXXXXX)
daemon_pid=
trap 'if [ -n "$daemon_pid" ]; then kill "$daemon_pid" 2>/dev/null || true; fi; find "$tmp" -depth -delete' EXIT
mkdir -p "$tmp/bin"
if [ -n "${ZAGD:-}" ]; then
    cp "$ZAGD" "$tmp/bin/zagd"
elif [ "$(uname -s):$(uname -m)" = "Darwin:arm64" ]; then
    "$compiler" selfhost/zagd_macos_daemon.zag --target macos-arm64 \
        -o "$tmp/bin/zagd" --no-zagd --no-analyze --no-foreground-cache >/dev/null
else
    "$compiler" selfhost/zagd_daemon.zag -o "$tmp/bin/zagd" --no-zagd --no-analyze >/dev/null
fi
cp "$compiler" "$tmp/bin/znc"
target_args=()
if [ "$(uname -s):$(uname -m)" = "Darwin:arm64" ]; then target_args=(--target macos-arm64); fi
"$compiler" tests/zagd_finalist_witness.zag "${target_args[@]}" -o "$tmp/reference" --no-zagd --no-analyze >/dev/null
cp "$tmp/reference" "$tmp/equivalent"
"$compiler" tests/zagd_finalist_mismatch.zag "${target_args[@]}" -o "$tmp/mismatch" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_delay.zag "${target_args[@]}" -o "$tmp/delay" --no-zagd --no-analyze >/dev/null
"$compiler" tests/zagd_finalist_short_delay.zag "${target_args[@]}" -o "$tmp/short-delay" --no-zagd --no-analyze >/dev/null

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
for _ in $(seq 1 500); do [ -f "$tmp/equal/.zag-cache/zagd/deep-measurement.record" ] && break; sleep .02; done
record="$tmp/equal/.zag-cache/zagd/deep-measurement.record"
test -f "$record"
grep -q '^format=zagd-deep-measurement-v3$' "$record"
grep -q '^equivalence=exact-output-stderr-exit-signal-state$' "$record"
grep -q '^foreground_consumption=false$' "$record"
grep -q '^provenance=measured$' "$record"
grep -q '^selector=paired-sign-familywise-99$' "$record"
grep -Eq '^semantic_identity=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -Eq '^target=[0-9]+[[:blank:]][0-9]+[[:blank:]][0-9]+$' "$record"
grep -q '^warmups=3$' "$record"
grep -q '^noise_pairs=30$' "$record"
grep -q '^runs=30$' "$record"
grep -q '^selection_status=no-win$' "$record"
grep -Eq '^reference_warmups_ns=[1-9][0-9]*(,[1-9][0-9]*){2}$' "$record"
grep -Eq '^finalist_warmups_ns=[1-9][0-9]*(,[1-9][0-9]*){2}$' "$record"
grep -Eq '^noise_reference_ns=[1-9][0-9]*(,[1-9][0-9]*){29}$' "$record"
grep -Eq '^noise_repeat_ns=[1-9][0-9]*(,[1-9][0-9]*){29}$' "$record"
grep -Eq '^reference_runs_ns=[1-9][0-9]*(,[1-9][0-9]*){29}$' "$record"
grep -Eq '^finalist_runs_ns=[1-9][0-9]*(,[1-9][0-9]*){29}$' "$record"
printf stop >"$tmp/equal/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# Production selection authority: same behavior, materially faster finalist.
prepare "$tmp/selected" "$tmp/short-delay" "$tmp/reference"
"$tmp/bin/zagd" --root "$tmp/selected" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
for _ in $(seq 1 700); do [ -f "$tmp/selected/.zag-cache/zagd/deep-measurement.record" ] && break; sleep .02; done
selected="$tmp/selected/.zag-cache/zagd/deep-measurement.record"
test -f "$selected"
grep -q '^format=zagd-deep-measurement-v3$' "$selected"
grep -q '^selection_status=selected$' "$selected"
grep -q '^winner_kind=1$' "$selected"
grep -q '^confidence_percent=99$' "$selected"
grep -q '^no_regression=1$' "$selected"
printf stop >"$tmp/selected/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

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

# Rapid editor/agent atomic saves must cancel the obsolete deep finalist.  A
# deep result becomes eligible only after the final stable source receives the
# normal foreground semantic witness; no intermediate save may publish one.
prepare "$tmp/rapid-final" "$tmp/delay" "$tmp/delay"
"$tmp/bin/zagd" --root "$tmp/rapid-final" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .05
for i in $(seq 1 20); do
    printf 'fn main() i32 { return 0; }\n// partial agent edit %s\n' "$i" >"$tmp/rapid-final/.main.zag.tmp"
    mv "$tmp/rapid-final/.main.zag.tmp" "$tmp/rapid-final/main.zag"
done
printf 'fn main() i32 { return 0; }\n// final stable agent edit\n' >"$tmp/rapid-final/.main.zag.final"
mv "$tmp/rapid-final/.main.zag.final" "$tmp/rapid-final/main.zag"
sleep .7
test ! -e "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
(cd "$tmp/rapid-final" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
# v3 collects 3 warmup pairs, 30 reference/reference noise pairs, and 30
# reference/finalist pairs. This fixture intentionally sleeps 200 ms in both
# executables, so a valid post-save campaign needs roughly 25 seconds before
# publication. Keep enough headroom for slower CI hosts without changing any
# acceptance condition.
for _ in $(seq 1 2000); do
    test -f "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record" && break
    sleep .02
done
grep -q '^format=zagd-deep-measurement-v3$' "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
grep -q '^runs=30$' "$tmp/rapid-final/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/rapid-final/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# A root-only source check is insufficient: any imported module changed while a
# finalist is running invalidates the whole semantic/module-graph witness.
mkdir -p "$tmp/import-stale"
printf 'pub fn helper() i32 { return 0; }\n' >"$tmp/import-stale/lib.zag"
printf '@import("lib.zag")\nfn main() i32 { return helper(); }\n' >"$tmp/import-stale/main.zag"
printf '%s\n' "$tmp/delay" >"$tmp/import-stale/.zagd.deep-reference"
printf '%s\n' "$tmp/delay" >"$tmp/import-stale/.zagd.deep-finalist"
(cd "$tmp/import-stale" && "$tmp/bin/znc" check main.zag --no-zagd --no-analyze >/dev/null)
"$tmp/bin/zagd" --root "$tmp/import-stale" --root-source main.zag --mode deep --window-ms 10 & daemon_pid=$!
sleep .05
printf '// dependency changed during finalist\n' >>"$tmp/import-stale/lib.zag"
sleep .7
test ! -e "$tmp/import-stale/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/import-stale/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

prepare "$tmp/light" "$tmp/reference" "$tmp/equivalent"
"$tmp/bin/zagd" --root "$tmp/light" --root-source main.zag --mode light --window-ms 10 & daemon_pid=$!
sleep .2
test ! -e "$tmp/light/.zag-cache/zagd/deep-measurement.record"
printf stop >"$tmp/light/.zagd.stop"; wait "$daemon_pid"; daemon_pid=

# Adaptive mode used to report idle_deep=true while remaining blocked forever
# in read(2).  Opt-in evidence waits for the real 30-second inactivity window
# and proves that the existing deep-control measurement path is reached without
# changing the public mode or making the daemon a correctness dependency.
if [ "${ZAGD_IDLE_DEEP:-0}" = 1 ]; then
    prepare "$tmp/adaptive-idle" "$tmp/reference" "$tmp/equivalent"
    "$tmp/bin/zagd" --root "$tmp/adaptive-idle" --root-source main.zag \
        --mode adaptive --window-ms 10 & daemon_pid=$!
    for _ in $(seq 1 45); do
        test -f "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record" && break
        sleep 1
    done
    test -f "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    grep -q '^mode=deep$' "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    grep -q '^format=zagd-deep-measurement-v3$' "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    grep -q '^runs=30$' "$tmp/adaptive-idle/.zag-cache/zagd/deep-measurement.record"
    printf stop >"$tmp/adaptive-idle/.zagd.stop"; wait "$daemon_pid"; daemon_pid=
fi
echo 'zagd deep product integration: pass'
