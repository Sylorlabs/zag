#!/usr/bin/env bash
# Paired black-box benchmark runner. The Zag and reference programs are separate
# executables; this harness does not link them together or use a foreign ABI.
set -euo pipefail

usage() {
    echo "usage: RUNS=30 benchmarks/run_pair.sh INPUT ZAG_EXECUTABLE REFERENCE_EXECUTABLE RESULTS.csv" >&2
    exit 2
}
[ "$#" -eq 4 ] || usage

input=$1
zag=$2
reference=$3
out=$4
caller_dir=$PWD
for name in input zag reference out; do
    value=${!name}
    case "$value" in
        /*) ;;
        *) printf -v "$name" '%s/%s' "$caller_dir" "$value" ;;
    esac
done

[ -r "$input" ] || { echo "benchmark: input is not readable: $input" >&2; exit 2; }
[ -x "$zag" ] || { echo "benchmark: Zag executable is not executable: $zag" >&2; exit 2; }
[ -x "$reference" ] || { echo "benchmark: reference executable is not executable: $reference" >&2; exit 2; }
[ ! -e "$out" ] || { echo "benchmark: results file already exists: $out" >&2; exit 2; }

runs=${RUNS:-30}
case "$runs" in
    ''|*[!0-9]*) echo "benchmark: RUNS must be an integer of at least 30" >&2; exit 2 ;;
esac
[ "$runs" -ge 30 ] || { echo "benchmark: RUNS must be at least 30" >&2; exit 2; }

repo_root=$(cd "$(dirname "$0")/.." && pwd)
cd "$repo_root"
mkdir -p "$(dirname "$out")"
meta="$out.meta.txt"
[ ! -e "$meta" ] || { echo "benchmark: metadata file already exists: $meta" >&2; exit 2; }
tmp=$(mktemp -d "$(dirname "$out")/.zag-paired-bench.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
raw="$tmp/results.csv"
summary_tmp="$tmp/summary.csv"
meta_tmp="$tmp/meta.txt"

file_hash() {
    local line
    if command -v sha256sum >/dev/null 2>&1; then
        line=$(sha256sum "$1")
    elif command -v shasum >/dev/null 2>&1; then
        line=$(shasum -a 256 "$1")
    else
        echo "benchmark: need sha256sum or shasum for input identity" >&2
        return 1
    fi
    printf '%s' "${line%% *}"
}

run_one() {
    local exe=$1 tag=$2 status elapsed
    local TIMEFORMAT='%R'
    if { time "$exe" < "$input" >"$tmp/$tag.out" 2>"$tmp/$tag.err"; } 2>"$tmp/$tag.time"; then
        status=0
    else
        status=$?
    fi
    elapsed=$(cat "$tmp/$tag.time")
    case "$elapsed" in
        ''|*[!0-9.]*|*.*.*) echo "benchmark: timer did not return a seconds value" >&2; exit 1 ;;
    esac
    printf '%s\n' "$status" > "$tmp/$tag.status"
    printf '%s\n' "$elapsed"
}

check_witness() {
    local zag_tag=$1 ref_tag=$2 zag_status ref_status
    zag_status=$(cat "$tmp/$zag_tag.status")
    ref_status=$(cat "$tmp/$ref_tag.status")
    if [ "$zag_status" -ne 0 ] || [ "$ref_status" -ne 0 ]; then
        echo "benchmark: both programs must exit successfully (Zag=$zag_status reference=$ref_status)" >&2
        return 1
    fi
    if [ "$(file_hash "$tmp/$zag_tag.out")" != "$(file_hash "$tmp/$ref_tag.out")" ]; then
        echo "benchmark: stdout differs between Zag and reference" >&2
        return 1
    fi
    if [ "$(file_hash "$tmp/$zag_tag.err")" != "$(file_hash "$tmp/$ref_tag.err")" ]; then
        echo "benchmark: stderr differs between Zag and reference" >&2
        return 1
    fi
}

# One untimed correctness/warm-up pair. Timed runs must also retain the same
# witness, so nondeterminism cannot silently enter the results.
run_one "$zag" warm_zag >/dev/null
run_one "$reference" warm_ref >/dev/null
check_witness warm_zag warm_ref || exit 1

cpu=unavailable
if command -v lscpu >/dev/null 2>&1; then
    cpu=$(LC_ALL=C lscpu 2>/dev/null | sed -n 's/^Model name:[[:space:]]*//p' | head -1 || true)
fi
if [ -z "$cpu" ] || [ "$cpu" = unavailable ]; then
    if command -v sysctl >/dev/null 2>&1; then
        cpu=$(sysctl -n machdep.cpu.brand_string 2>/dev/null || sysctl -n hw.model 2>/dev/null || echo unavailable)
    fi
fi
[ -n "$cpu" ] || cpu=unavailable
{
    echo "compiler_commit=$(git rev-parse HEAD)"
    echo "kernel=$(uname -srm)"
    echo "machine=$(uname -m)"
    echo "cpu=$cpu"
    echo "cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo unavailable)"
    echo "runs=$runs"
    echo "input_sha256=$(file_hash "$input")"
    echo "zag_executable_sha256=$(file_hash "$zag")"
    echo "reference_executable_sha256=$(file_hash "$reference")"
    echo "execution=separate processes; no shared library, FFI, or C ABI"
    echo "timing=Bash elapsed-seconds timer; includes process startup and captured output"
    echo "timer_display_resolution=platform dependent; use workloads lasting well over 10 ms"
    echo "comparison=stdout, stderr, and successful exit status must match on every pair"
    echo "order=alternates Zag-first and reference-first"
    echo "note=timing includes process launch; keep output to a small correctness witness"
} > "$meta_tmp"

echo 'run,order,zag_seconds,reference_seconds,reference_over_zag' > "$raw"
i=1
while [ "$i" -le "$runs" ]; do
    if [ $((i % 2)) -eq 1 ]; then
        order=zag-first
        zag_seconds=$(run_one "$zag" zag)
        ref_seconds=$(run_one "$reference" ref)
    else
        order=reference-first
        ref_seconds=$(run_one "$reference" ref)
        zag_seconds=$(run_one "$zag" zag)
    fi
    check_witness zag ref || { echo "benchmark: correctness witness failed on run $i" >&2; exit 1; }
    if ! awk -v t="$zag_seconds" 'BEGIN { exit !(t > 0) }' ||
       ! awk -v t="$ref_seconds" 'BEGIN { exit !(t > 0) }'; then
        echo "benchmark: workload is below the timer's display resolution; increase its work" >&2
        exit 1
    fi
    speedup=$(awk -v r="$ref_seconds" -v z="$zag_seconds" 'BEGIN { printf "%.6f", r / z }')
    printf '%s,%s,%s,%s,%s\n' "$i" "$order" "$zag_seconds" "$ref_seconds" "$speedup" >> "$raw"
    i=$((i + 1))
done

summary="$out.summary.csv"
echo 'metric,runs,min,median,max,mean,stddev,unit' > "$summary_tmp"
awk -F, '
    NR > 1 { n++; z[n]=$3+0; r[n]=$4+0; s[n]=$5+0; sz+=$3; sr+=$4; ss+=$5; qz+=$3*$3; qr+=$4*$4; qs+=$5*$5 }
    END {
        if (n == 0) exit 1
        for (i=1;i<=n;i++) for (j=i+1;j<=n;j++) {
            if (z[j]<z[i]) { t=z[i];z[i]=z[j];z[j]=t }
            if (r[j]<r[i]) { t=r[i];r[i]=r[j];r[j]=t }
            if (s[j]<s[i]) { t=s[i];s[i]=s[j];s[j]=t }
        }
        mz=(n%2?z[(n+1)/2]:(z[n/2]+z[n/2+1])/2)
        mr=(n%2?r[(n+1)/2]:(r[n/2]+r[n/2+1])/2)
        ms=(n%2?s[(n+1)/2]:(s[n/2]+s[n/2+1])/2)
        vz=qz/n-(sz/n)*(sz/n); if(vz<0) vz=0
        vr=qr/n-(sr/n)*(sr/n); if(vr<0) vr=0
        vs=qs/n-(ss/n)*(ss/n); if(vs<0) vs=0
        printf "zag_seconds,%d,%.6f,%.6f,%.6f,%.6f,%.6f,seconds\n", n,z[1],mz,z[n],sz/n,sqrt(vz)
        printf "reference_seconds,%d,%.6f,%.6f,%.6f,%.6f,%.6f,seconds\n", n,r[1],mr,r[n],sr/n,sqrt(vr)
        printf "reference_over_zag,%d,%.6f,%.6f,%.6f,%.6f,%.6f,ratio\n", n,s[1],ms,s[n],ss/n,sqrt(vs)
    }
' "$raw" >> "$summary_tmp"

mv "$meta_tmp" "$meta"
mv "$summary_tmp" "$summary"
mv "$raw" "$out"
echo "results:  $out"
echo "summary:  $summary"
echo "metadata: $meta"
