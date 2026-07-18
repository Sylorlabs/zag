#!/usr/bin/env bash
# Reproducible local Zag Script/zagd benchmark recorder.
set -eu
cd "$(dirname "$0")/.."

runs=${RUNS:-10}
out=${OUT:-benchmarks/results}
mkdir -p "$out"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
meta="$out/$stamp.meta.txt"
csv="$out/$stamp.csv"
tmp=$(mktemp -d /tmp/zag-bench.XXXXXX)
trap './znc shutdown >/dev/null 2>&1 || true; find "$tmp" -depth -delete' EXIT HUP INT TERM

cp examples/script_hello.zag "$tmp/app.zag"
{
    echo "timestamp_utc=$stamp"
    echo "compiler_commit=$(git rev-parse HEAD)"
    echo "compiler_version=$(./znc version)"
    echo "kernel=$(uname -srmo)"
    echo "machine=$(uname -m)"
    echo "cpu=$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "runs=$runs"
    echo "input_sha256=$(sha256sum "$tmp/app.zag" | awk '{print $1}')"
    echo "command=./znc INPUT -o OUTPUT --no-zagd --no-analyze"
} > "$meta"

echo 'metric,run,value,unit' > "$csv"
i=1
while [ "$i" -le "$runs" ]; do
    start=$(date +%s%N)
    ./znc "$tmp/app.zag" -o "$tmp/app" --no-zagd --no-analyze >/dev/null
    end=$(date +%s%N)
    echo "compile_cold,$i,$((end - start)),ns" >> "$csv"
    start=$(date +%s%N)
    "$tmp/app" >/dev/null
    end=$(date +%s%N)
    echo "script_startup,$i,$((end - start)),ns" >> "$csv"
    echo "binary_size,$i,$(stat -c %s "$tmp/app"),bytes" >> "$csv"
    i=$((i + 1))
done

./znc watch --mode light >/dev/null
sleep 1
pid=$(sed -n 's/^pid=//p' .zagd.status)
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    echo "daemon_rss,1,$(awk '/VmRSS:/ {print $2 * 1024}' "/proc/$pid/status"),bytes" >> "$csv"
    ticks_a=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    sleep 2
    ticks_b=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    echo "daemon_idle_cpu_ticks,1,$((ticks_b - ticks_a)),ticks_per_2s" >> "$csv"
fi

echo "metadata: $meta"
echo "results:  $csv"
