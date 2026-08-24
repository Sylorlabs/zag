#!/usr/bin/env bash
# Reproducible local Zag Script/zagd benchmark recorder.
set -eu
cd "$(dirname "$0")/.."
repo_root=$(pwd)

runs=${RUNS:-30}
if [ "$runs" -lt 30 ]; then echo "benchmark: RUNS must be at least 30" >&2; exit 2; fi
out=${OUT:-benchmarks/results}
mkdir -p "$out"
stamp=$(date -u +%Y%m%dT%H%M%SZ)
meta="$out/$stamp.meta.txt"
csv="$out/$stamp.csv"
tmp=$(mktemp -d /tmp/zag-bench.XXXXXX)
trap '(cd "$tmp" && "$repo_root/znc" shutdown >/dev/null 2>&1 || true); find "$tmp" -depth -delete' EXIT HUP INT TERM

cp examples/script_hello.zag "$tmp/app.zag"
# The observer calls are compiler-owned BSS reads and allocate no memory. Keep
# the measured workload identical to script_hello, removing only its early
# return so the two witness values can be printed afterward.
{
    printf '%s\n' \
      'script;' \
      'extern fn _zag_allocator_allocation_count() i64' \
      'extern fn _zag_allocator_peak_live_bytes() i64'
    sed '1d; /^return 0;$/d' examples/script_hello.zag
    printf '%s\n' \
      'println(_zag_allocator_allocation_count());' \
      'println(_zag_allocator_peak_live_bytes());' \
      'return 0;'
} >"$tmp/allocation-probe.zag"
{
    echo "timestamp_utc=$stamp"
    echo "compiler_commit=$(git rev-parse HEAD)"
    echo "compiler_version=$(./znc version)"
    echo "kernel=$(uname -srmo)"
    echo "machine=$(uname -m)"
    echo "cpu=$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1)"
    echo "cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unavailable)"
    echo "memory_bytes=$(awk '/MemTotal:/ {print $2 * 1024}' /proc/meminfo 2>/dev/null || echo unavailable)"
    echo "runs=$runs"
    echo "input_sha256=$(sha256sum "$tmp/app.zag" | awk '{print $1}')"
    echo "allocation_probe_sha256=$(sha256sum "$tmp/allocation-probe.zag" | awk '{print $1}')"
    echo "cold_command=./znc INPUT -o OUTPUT --no-zagd --no-analyze --no-foreground-cache"
    echo "warm_command=./znc INPUT -o OUTPUT --no-zagd --no-analyze --cache-report"
    echo "allocation_command=./znc ALLOCATION_PROBE -o OUTPUT --no-zagd --no-analyze --no-foreground-cache; OUTPUT"
    echo "generic_command=./znc INPUT -o OUTPUT --cpu generic --no-zagd --no-analyze --no-foreground-cache; OUTPUT"
    echo "native_command=./znc INPUT -o OUTPUT --cpu native --no-zagd --no-analyze --no-foreground-cache; OUTPUT"
    echo "change_latency_witness=.zagd.status content_hash_first changes after final stable write"
    echo "equivalence=generic/native stdout stderr and exit status must match"
    echo "allocation_witness=native logical allocation events and peak live payload capacity"
    echo "allocation_excludes=allocator metadata,arena reservation,RSS,explicit raw mmap syscalls"
    echo "peak_rss_source=/usr/bin/time maximum-resident-set-size when available"
} > "$meta"

echo 'metric,run,value,unit' > "$csv"
./znc "$tmp/allocation-probe.zag" -o "$tmp/allocation-probe" --no-zagd --no-analyze --no-foreground-cache >/dev/null
(cd "$tmp" && "$repo_root/znc" app.zag -o generic --cpu generic --no-zagd --no-analyze --no-foreground-cache >/dev/null)
(cd "$tmp" && "$repo_root/znc" app.zag -o native --cpu native --no-zagd --no-analyze --no-foreground-cache >/dev/null)
(cd "$tmp" && set +e; ./generic > generic.out 2>generic.err; echo $? >generic.status; ./native > native.out 2>native.err; echo $? >native.status; set -e)
cmp "$tmp/generic.out" "$tmp/native.out"; cmp "$tmp/generic.err" "$tmp/native.err"; cmp "$tmp/generic.status" "$tmp/native.status"
echo "generic_native_output_equal,1,1,boolean" >> "$csv"

i=1
while [ "$i" -le "$runs" ]; do
    start=$(date +%s%N)
    ./znc "$tmp/app.zag" -o "$tmp/app" --no-zagd --no-analyze --no-foreground-cache >/dev/null
    end=$(date +%s%N)
    echo "compile_cold,$i,$((end - start)),ns" >> "$csv"
    # Prime once outside the timed interval, then require the timed invocation
    # to prove that it reused checksum-validated machine code.
    ./znc "$tmp/app.zag" -o "$tmp/app-warm" --no-zagd --no-analyze >/dev/null
    warm_log="$tmp/warm.$i.log"
    start=$(date +%s%N)
    ./znc "$tmp/app.zag" -o "$tmp/app-warm" --no-zagd --no-analyze --cache-report >"$warm_log"
    end=$(date +%s%N)
    grep -q 'HIT revalidated machine code and data; codegen skipped' "$warm_log"
    echo "compile_warm,$i,$((end - start)),ns" >> "$csv"
    echo "foreground_cache_hit,$i,1,boolean" >> "$csv"
    start=$(date +%s%N)
    "$tmp/app" >/dev/null
    end=$(date +%s%N)
    echo "script_startup,$i,$((end - start)),ns" >> "$csv"
    start=$(date +%s%N)
    "$tmp/generic" >/dev/null
    end=$(date +%s%N)
    echo "generic_runtime,$i,$((end - start)),ns" >> "$csv"
    start=$(date +%s%N)
    "$tmp/native" >/dev/null
    end=$(date +%s%N)
    echo "native_runtime,$i,$((end - start)),ns" >> "$csv"
    echo "binary_size,$i,$(stat -c %s "$tmp/app"),bytes" >> "$csv"
    allocation_output=$("$tmp/allocation-probe")
    allocation_count=$(printf '%s\n' "$allocation_output" | tail -n 2 | head -n 1)
    allocation_peak=$(printf '%s\n' "$allocation_output" | tail -n 1)
    case "$allocation_count:$allocation_peak" in
      *[!0-9:]*|:*|*:) echo "benchmark: invalid native allocation witness" >&2; exit 1 ;;
    esac
    echo "allocation_count,$i,$allocation_count,allocations" >> "$csv"
    echo "peak_live_allocation,$i,$allocation_peak,bytes" >> "$csv"
    if [ -x /usr/bin/time ]; then
        rss_file="$tmp/rss.$i"
        /usr/bin/time -f '%M' -o "$rss_file" ./znc "$tmp/app.zag" -o "$tmp/rss-app" --no-zagd --no-analyze --no-foreground-cache >/dev/null
        echo "compiler_peak_rss,$i,$(($(cat "$rss_file") * 1024)),bytes" >> "$csv"
    fi
    i=$((i + 1))
done

(cd "$tmp" && "$repo_root/znc" watch --mode light >/dev/null)
sleep 1
pid=$(sed -n 's/^pid=//p' "$tmp/.zagd.status")
if [ -n "$pid" ] && [ -r "/proc/$pid/stat" ]; then
    i=1
    while [ "$i" -le "$runs" ]; do
        echo "daemon_rss,$i,$(awk '/VmRSS:/ {print $2 * 1024}' "/proc/$pid/status"),bytes" >> "$csv"
        ticks_a=$(awk '{print $14 + $15}' "/proc/$pid/stat"); sleep 0.1; ticks_b=$(awk '{print $14 + $15}' "/proc/$pid/stat")
        echo "daemon_idle_cpu_ticks,$i,$((ticks_b - ticks_a)),ticks_per_100ms" >> "$csv"; i=$((i + 1))
    done
fi

i=1
while [ "$i" -le "$runs" ]; do
    before=$(sed -n 's/^content_hash_first=//p' "$tmp/.zagd.status")
    start=$(date +%s%N); printf '\n// stable benchmark edit %s\n' "$i" >> "$tmp/app.zag"; deadline=$((start + 5000000000))
    while :; do
        after=$(sed -n 's/^content_hash_first=//p' "$tmp/.zagd.status" 2>/dev/null || true)
        state=$(sed -n 's/^planner_state=//p' "$tmp/.zagd.status" 2>/dev/null || true)
        if [ -n "$after" ] && [ "$after" != "$before" ] && [ "$state" = complete ]; then break; fi
        now=$(date +%s%N); if [ "$now" -ge "$deadline" ]; then echo "benchmark: daemon did not publish a stable plan witness" >&2; exit 1; fi
        sleep 0.005
    done
    end=$(date +%s%N)
    echo "stable_change_to_plan,$i,$((end - start)),ns" >> "$csv"
    # Cache usage is sampled at every stable snapshot, not reported as a
    # single attractive endpoint. This makes growth and variance visible in
    # the same 30-run distribution as the latency measurements.
    cache_bytes=$(du -sb "$tmp/.zag-cache" | awk '{print $1}')
    case $cache_bytes in
      *[!0-9]*|'') echo "benchmark: invalid cache-size witness" >&2; exit 1 ;;
    esac
    echo "cache_size,$i,$cache_bytes,bytes" >> "$csv"
    i=$((i + 1))
done

summary="$out/$stamp.summary.csv"
echo 'metric,runs,min,median,max,mean,stddev,unit' > "$summary"
for metric in compile_cold compile_warm script_startup generic_runtime native_runtime binary_size allocation_count peak_live_allocation compiler_peak_rss daemon_rss daemon_idle_cpu_ticks stable_change_to_plan cache_size foreground_cache_hit; do
    awk -F, -v wanted="$metric" '
      NR>1 && $1==wanted { n++; v[n]=$3+0; unit=$4; sum+=$3; sumsq+=($3*$3) }
      END { if(n==0) exit; for(i=1;i<=n;i++)for(j=i+1;j<=n;j++)if(v[j]<v[i]){t=v[i];v[i]=v[j];v[j]=t}
        med=(n%2?v[(n+1)/2]:(v[n/2]+v[n/2+1])/2); mean=sum/n; var=(sumsq/n)-(mean*mean); if(var<0)var=0;
        printf "%s,%d,%.0f,%.1f,%.0f,%.1f,%.1f,%s\n",wanted,n,v[1],med,v[n],mean,sqrt(var),unit }' "$csv" >> "$summary"
done

echo "metadata: $meta"
echo "results:  $csv"
echo "summary:  $summary"
