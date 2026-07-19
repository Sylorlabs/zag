#!/usr/bin/env bash
# Reproducible local Zag Script/zagd benchmark recorder.
set -eu
cd "$(dirname "$0")/.."
repo_root=$(pwd)

runs=${RUNS:-10}
out=${OUT:-benchmarks/results}
mkdir -p "$out"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
meta="$out/$stamp.meta.txt"
csv="$out/$stamp.csv"
tmp=$(mktemp -d /tmp/zag-bench.XXXXXX)
trap '(cd "$tmp" && "$repo_root/znc" shutdown >/dev/null 2>&1 || true); find "$tmp" -depth -delete' EXIT HUP INT TERM

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
    echo "native_command=./znc INPUT -o OUTPUT --cpu native --no-zagd --no-analyze"
    echo "change_latency_witness=.zagd.status content_hash_first changes after final stable write"
} > "$meta"

echo 'metric,run,value,unit' > "$csv"
i=1
while [ "$i" -le "$runs" ]; do
    start=$(date +%s%N)
    ./znc "$tmp/app.zag" -o "$tmp/app" --no-zagd --no-analyze >/dev/null
    end=$(date +%s%N)
    echo "compile_cold,$i,$((end - start)),ns" >> "$csv"
    start=$(date +%s%N)
    ./znc "$tmp/app.zag" -o "$tmp/app-warm" --no-zagd --no-analyze >/dev/null
    end=$(date +%s%N)
    echo "compile_warm,$i,$((end - start)),ns" >> "$csv"
    start=$(date +%s%N)
    "$tmp/app" >/dev/null
    end=$(date +%s%N)
    echo "script_startup,$i,$((end - start)),ns" >> "$csv"
    echo "binary_size,$i,$(stat -c %s "$tmp/app"),bytes" >> "$csv"
    i=$((i + 1))
done

(cd "$tmp" && "$repo_root/znc" app.zag -o generic --cpu generic --no-zagd --no-analyze >/dev/null)
(cd "$tmp" && "$repo_root/znc" app.zag -o native --cpu native --no-zagd --no-analyze >/dev/null)
(cd "$tmp" && ./generic > generic.out && ./native > native.out)
cmp "$tmp/generic.out" "$tmp/native.out"
echo "generic_native_output_equal,1,1,boolean" >> "$csv"

(cd "$tmp" && "$repo_root/znc" watch --mode light >/dev/null)
sleep 1
pid=$(sed -n 's/^pid=//p' "$tmp/.zagd.status")
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    echo "daemon_rss,1,$(awk '/VmRSS:/ {print $2 * 1024}' "/proc/$pid/status"),bytes" >> "$csv"
    ticks_a=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    sleep 2
    ticks_b=$(awk '{print $14 + $15}' "/proc/$pid/stat")
    echo "daemon_idle_cpu_ticks,1,$((ticks_b - ticks_a)),ticks_per_2s" >> "$csv"
fi

before=$(sed -n 's/^content_hash_first=//p' "$tmp/.zagd.status")
start=$(date +%s%N)
printf '\n// stable benchmark edit\n' >> "$tmp/app.zag"
deadline=$((start + 5000000000))
while :; do
    after=$(sed -n 's/^content_hash_first=//p' "$tmp/.zagd.status" 2>/dev/null || true)
    if [ -n "$after" ] && [ "$after" != "$before" ]; then break; fi
    now=$(date +%s%N)
    if [ "$now" -ge "$deadline" ]; then
        echo "benchmark: daemon did not publish a stable-change witness" >&2
        exit 1
    fi
    sleep 0.01
done
end=$(date +%s%N)
echo "file_change_to_snapshot,$((1)),$((end - start)),ns" >> "$csv"
if [ -d "$tmp/.zag-cache" ]; then
    echo "cache_size,1,$(du -sb "$tmp/.zag-cache" | awk '{print $1}'),bytes" >> "$csv"
fi

echo "metadata: $meta"
echo "results:  $csv"
