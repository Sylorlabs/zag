#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
    echo 'zagd macOS resource stress: skip (requires Darwin arm64)'
    exit 0
fi

tmp=$(mktemp -d /tmp/zagd-macos-resources.XXXXXX)
daemon_pid=
cleanup() {
    if [ -n "${daemon_pid:-}" ] && kill -0 "$daemon_pid" 2>/dev/null; then
        printf stop >"$tmp/project/.zagd.stop" 2>/dev/null || true
        for _ in $(seq 1 200); do
            kill -0 "$daemon_pid" 2>/dev/null || break
            sleep 0.01
        done
        kill "$daemon_pid" 2>/dev/null || true
    fi
    rm -rf "$tmp"
}
trap cleanup EXIT

compiler=${ZNC:-./znc-macos-arm64}
case "$compiler" in
    /*) ;;
    *) compiler="$PWD/${compiler#./}" ;;
esac
test -x "$compiler"

# Keep the production daemon under the ordinary analyzer and make the
# guaranteed string-leak diagnostics release evidence. Other advisory lints
# are allowed to evolve independently of this ownership regression.
analysis_log="$tmp/analyze.log"
"$compiler" selfhost/zagd_macos_daemon.zag --target macos-arm64 --no-zagd \
    -o "$tmp/zagd-analyzed" >"$analysis_log" 2>&1
if grep -Eq 'warning\[L0010\]|warning\[L0012\]' "$analysis_log"; then
    cat "$analysis_log" >&2
    echo 'zagd macOS resource stress: daemon has an analyzed string leak' >&2
    exit 1
fi

# Long stable paths magnify any accidental per-event command/path rebuilding.
# The sibling compiler is a no-allocation test double: this test measures the
# daemon process, while semantic publication is covered by the background test.
long_component=$(printf 'x%.0s' $(seq 1 180))
bin_dir="$tmp/$long_component"
mkdir "$bin_dir" "$tmp/project"
cp "$tmp/zagd-analyzed" "$bin_dir/zagd"
printf '#!/bin/sh\nexit 0\n' >"$bin_dir/znc"
chmod +x "$bin_dir/znc"
source_name="$(printf 's%.0s' $(seq 1 180)).zag"
printf 'fn main() i32 { return 0; }\n' >"$tmp/project/$source_name"
printf '[package]\nname = "resource-stress"\nversion = "0.0.1"\n' >"$tmp/project/zag.mod"

(
    cd "$tmp/project"
    exec "$bin_dir/zagd" --root . --root-source "$source_name" --mode light
) >"$tmp/daemon.out" 2>"$tmp/daemon.err" &
daemon_pid=$!

for _ in $(seq 1 1000); do
    grep -q '^state=idle$' "$tmp/project/.zagd.status" 2>/dev/null && break
    sleep 0.01
done
grep -q '^watcher=kqueue-recursive$' "$tmp/project/.zagd.status"
grep -q '^input_scan_complete=true$' "$tmp/project/.zagd.status"

event=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status")
edit_and_wait() {
    local value=$1
    local want=$((event + 1))
    printf 'fn main() i32 { return %s; }\n' "$value" >"$tmp/project/.next-source"
    mv "$tmp/project/.next-source" "$tmp/project/$source_name"
    for _ in $(seq 1 1000); do
        local seen state
        seen=$(sed -n 's/^events=//p' "$tmp/project/.zagd.status" 2>/dev/null || true)
        state=$(sed -n 's/^state=//p' "$tmp/project/.zagd.status" 2>/dev/null || true)
        if [ "${seen:-0}" -ge "$want" ] && [ "$state" = idle ]; then
            event=$seen
            return 0
        fi
        sleep 0.005
    done
    echo "zagd macOS resource stress: edit $value was not observed" >&2
    return 1
}

# Warm every reusable buffer and libc/kernel path before taking the baseline.
for value in $(seq 1 8); do edit_and_wait "$value"; done
base_alloc=$(sed -n 's/^allocator_allocation_count=//p' "$tmp/project/.zagd.status")
base_live=$(sed -n 's/^allocator_live_bytes=//p' "$tmp/project/.zagd.status")
base_peak=$(sed -n 's/^allocator_peak_live_bytes=//p' "$tmp/project/.zagd.status")
base_rss=$(ps -o rss= -p "$daemon_pid" | tr -d ' ')
test -n "$base_alloc" && test -n "$base_live" && test -n "$base_peak" && test -n "$base_rss"

for value in $(seq 9 264); do edit_and_wait "$value"; done
final_alloc=$(sed -n 's/^allocator_allocation_count=//p' "$tmp/project/.zagd.status")
final_live=$(sed -n 's/^allocator_live_bytes=//p' "$tmp/project/.zagd.status")
final_peak=$(sed -n 's/^allocator_peak_live_bytes=//p' "$tmp/project/.zagd.status")
final_rss=$(ps -o rss= -p "$daemon_pid" | tr -d ' ')

test "$final_alloc" -eq "$base_alloc"
test "$final_live" -eq "$base_live"
test "$final_peak" -eq "$base_peak"
rss_growth=$((final_rss - base_rss))
test "$rss_growth" -le 8192

printf stop >"$tmp/project/.zagd.stop"
wait "$daemon_pid"
daemon_pid=
grep -q '^state=stopped$' "$tmp/project/.zagd.status"
echo "zagd macOS resource stress: pass (256 edits, allocations=$final_alloc, live=$final_live, rss_growth_kib=$rss_growth)"
