#!/usr/bin/env bash
# Bounded, repeatable local compiler comparison for equivalent small programs.
set -euo pipefail
export LC_ALL=C

script_dir=$(CDPATH= cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd)
repo_root=$(CDPATH= cd -- "$script_dir/.." && pwd)
suite_dir="$script_dir/compiler-comparison"
fixtures_dir="$suite_dir/fixtures"
znc_bin="$repo_root/znc"

runs=${RUNS:-7}
nice_level=${NICE_LEVEL:-10}
timeout_seconds=${TIMEOUT_SECONDS:-60}
strict_quiet=${STRICT_QUIET:-0}
quiet_load_per_cpu_max=${QUIET_LOAD_PER_CPU_MAX:-0.25}
swap_used_max_pct=${SWAP_USED_MAX_PCT:-50}

case $runs in *[!0-9]*|'') echo "compiler-comparison: RUNS must be an integer" >&2; exit 2;; esac
case $nice_level in *[!0-9]*|'') echo "compiler-comparison: NICE_LEVEL must be 0..19" >&2; exit 2;; esac
case $timeout_seconds in *[!0-9]*|'') echo "compiler-comparison: TIMEOUT_SECONDS must be an integer" >&2; exit 2;; esac
case $strict_quiet in 0|1) ;; *) echo "compiler-comparison: STRICT_QUIET must be 0 or 1" >&2; exit 2;; esac
if [ "$runs" -lt 3 ]; then echo "compiler-comparison: RUNS must be at least 3" >&2; exit 2; fi
if [ "$nice_level" -gt 19 ]; then echo "compiler-comparison: NICE_LEVEL must be 0..19" >&2; exit 2; fi
if [ "$timeout_seconds" -lt 1 ]; then echo "compiler-comparison: TIMEOUT_SECONDS must be positive" >&2; exit 2; fi
if ! awk -v value="$quiet_load_per_cpu_max" 'BEGIN { exit !(value+0 == value && value >= 0) }'; then
    echo "compiler-comparison: QUIET_LOAD_PER_CPU_MAX must be nonnegative" >&2; exit 2
fi
if ! awk -v value="$swap_used_max_pct" 'BEGIN { exit !(value+0 == value && value >= 0 && value <= 100) }'; then
    echo "compiler-comparison: SWAP_USED_MAX_PCT must be in 0..100" >&2; exit 2
fi

for required in awk basename cp date du file find gcc getconf git grep ldd mkdir nice paste ps readelf readlink sed sha256sum sort stat timeout tr uname wc; do
    if ! command -v "$required" >/dev/null 2>&1; then
        echo "compiler-comparison: required host tool is missing: $required" >&2
        exit 2
    fi
done
if [ ! -x "$znc_bin" ]; then
    echo "compiler-comparison: expected executable compiler at $znc_bin" >&2
    exit 2
fi

stamp=$(date -u +%Y%m%dT%H%M%SZ)
out=${OUT:-/tmp/zag-compiler-comparison-$stamp-$$}
if [ -e "$out" ]; then
    echo "compiler-comparison: refusing to reuse existing OUT: $out" >&2
    exit 2
fi
mkdir -p "$out/artifacts" "$out/logs" "$out/work/source"
out=$(CDPATH= cd -- "$out" && pwd)
work_dir="$out/work"
artifacts_dir="$out/artifacts"
logs_dir="$out/logs"
cp "$fixtures_dir"/* "$work_dir/source/"

measure_bin="$work_dir/measure-command"
gcc -O2 -std=c11 -Wall -Wextra -Werror "$suite_dir/measure.c" -o "$measure_bin"
timeout_bin=$(command -v timeout)
nice_bin=$(command -v nice)

samples="$out/samples.tsv"
tools_file="$out/tools.tsv"
equivalence="$out/equivalence.tsv"
artifacts_file="$out/artifacts.tsv"
components_file="$out/toolchain-components.tsv"
footprints_file="$out/toolchain-footprints.tsv"
metadata="$out/metadata.txt"
summary="$out/summary.tsv"

printf 'kind\ttool\tmode\tfixture\tphase\trun\twall_ns\tuser_us\tsys_us\tcpu_us\tmax_rss_kb\texit_status\tterm_signal\tload1_before\tload1_after\tncpu\tmem_available_kb_before\tswap_used_kb_before\tswap_total_kb\tpswpin_delta\tpswpout_delta\tactive_build_before\tactive_build_after\tcontaminated\treasons\n' > "$samples"
printf 'tool\tmode\tavailable\tcommand\tversion\tfixture_extension\tnotes\n' > "$tools_file"
printf 'tool\tmode\tfixture\texit_status\tstdout_sha256\tstdout_text\tstderr_bytes\tmatch\n' > "$equivalence"
printf 'tool\tmode\tfixture\tpath\tbytes\tsha256\telf_type\tpie\tsection_count\tinterp\tneeded_count\tneeded\tgnu_stack\tgnu_relro\tbuild_id\tfile_description\n' > "$artifacts_file"
printf 'tool\trole\tpath\tbytes\tsha256\tfile_description\n' > "$components_file"
printf 'tool\tcore_unique_file_bytes\tdistribution_tree_bytes\tdistribution_scope\tnotes\n' > "$footprints_file"

current_default_project=
stop_default_project() {
    local project=${1:-}
    if [ -n "$project" ] && [ -d "$project" ]; then
        (cd "$project" && "$znc_bin" shutdown) >"$logs_dir/zag-default-shutdown.$(basename "$project").log" 2>&1 || true
    fi
    current_default_project=
}
cleanup() { stop_default_project "$current_default_project"; }
trap cleanup EXIT
trap 'exit 130' HUP INT TERM

read_conditions() {
    read -r cond_load1 cond_load5 cond_load15 _ < /proc/loadavg
    cond_ncpu=$(getconf _NPROCESSORS_ONLN 2>/dev/null || echo 1)
    cond_mem_available=$(awk '/^MemAvailable:/ {print $2; found=1} END {if(!found) print 0}' /proc/meminfo)
    cond_swap_total=$(awk '/^SwapTotal:/ {print $2; found=1} END {if(!found) print 0}' /proc/meminfo)
    cond_swap_free=$(awk '/^SwapFree:/ {print $2; found=1} END {if(!found) print 0}' /proc/meminfo)
    cond_swap_used=$((cond_swap_total - cond_swap_free))
    cond_pswpin=$(awk '/^pswpin / {print $2; found=1} END {if(!found) print 0}' /proc/vmstat)
    cond_pswpout=$(awk '/^pswpout / {print $2; found=1} END {if(!found) print 0}' /proc/vmstat)
    cond_active_build=$(ps -eo comm= | awk '
        $1=="znc" || $1=="zagd" || $1=="gcc" || $1=="g++" ||
        $1=="clang" || $1=="clang++" || $1=="rustc" || $1=="zig" ||
        $1=="tcc" || $1=="cc1" || $1=="cc1plus" || $1=="ld" ||
        $1=="as" || $1=="ninja" || $1=="make" {count++}
        END {print count+0}')
}

contamination_reasons() {
    local load1=$1 ncpu=$2 swap_used=$3 swap_total=$4 active_before=$5 active_after=$6 pin_delta=$7 pout_delta=$8
    local reasons=
    if awk -v load_value="$load1" -v cpus="$ncpu" -v limit="$quiet_load_per_cpu_max" \
        'BEGIN { exit !((load_value / cpus) > limit) }'; then reasons="high-load;"; fi
    if [ "$swap_total" -gt 0 ] && awk -v used="$swap_used" -v total="$swap_total" -v limit="$swap_used_max_pct" \
        'BEGIN { exit !(((used * 100) / total) > limit) }'; then reasons="${reasons}swap-occupancy;"; fi
    if [ "$active_before" -gt 0 ]; then reasons="${reasons}active-build-before;"; fi
    if [ "$active_after" -gt 0 ]; then reasons="${reasons}active-build-after;"; fi
    if [ "$pin_delta" -gt 0 ]; then reasons="${reasons}swap-in-during-sample;"; fi
    if [ "$pout_delta" -gt 0 ]; then reasons="${reasons}swap-out-during-sample;"; fi
    if [ -z "$reasons" ]; then printf 'none'; else printf '%s' "${reasons%;}"; fi
}

measure_one() {
    local kind=$1 tool=$2 mode=$3 fixture=$4 phase=$5 run=$6 stdout_path=$7 stderr_path=$8
    shift 8
    local measurement="$logs_dir/measure.$kind.$tool.$fixture.$phase.$run.tsv"
    read_conditions
    local load1_before=$cond_load1 ncpu_before=$cond_ncpu mem_before=$cond_mem_available
    local swap_used_before=$cond_swap_used swap_total_before=$cond_swap_total
    local pin_before=$cond_pswpin pout_before=$cond_pswpout active_before=$cond_active_build

    set +e
    "$measure_bin" --output "$measurement" -- \
        "$timeout_bin" --kill-after=5s "${timeout_seconds}s" \
        "$nice_bin" -n "$nice_level" "$@" >"$stdout_path" 2>"$stderr_path"
    local shell_status=$?
    set -e

    read_conditions
    local load1_after=$cond_load1 pin_delta=$((cond_pswpin - pin_before))
    local pout_delta=$((cond_pswpout - pout_before)) active_after=$cond_active_build
    if [ ! -s "$measurement" ]; then
        echo "compiler-comparison: measurement helper produced no result for $tool/$fixture/$phase/$run" >&2
        sed -n '1,80p' "$stderr_path" >&2 || true
        return 1
    fi
    local wall_ns user_us sys_us max_rss_kb reported_status term_signal
    IFS=$'\t' read -r wall_ns user_us sys_us max_rss_kb reported_status term_signal < "$measurement"
    local cpu_us=$((user_us + sys_us)) reasons contaminated=0
    reasons=$(contamination_reasons "$load1_before" "$ncpu_before" "$swap_used_before" "$swap_total_before" \
        "$active_before" "$active_after" "$pin_delta" "$pout_delta")
    if [ "$reasons" != none ]; then contaminated=1; fi
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$kind" "$tool" "$mode" "$fixture" "$phase" "$run" "$wall_ns" "$user_us" "$sys_us" "$cpu_us" \
        "$max_rss_kb" "$reported_status" "$term_signal" "$load1_before" "$load1_after" "$ncpu_before" \
        "$mem_before" "$swap_used_before" "$swap_total_before" "$pin_delta" "$pout_delta" "$active_before" \
        "$active_after" "$contaminated" "$reasons" >> "$samples"
    if [ "$shell_status" -ne 0 ] || [ "$reported_status" -ne 0 ]; then
        echo "compiler-comparison: command failed for $tool/$fixture/$phase/$run (shell=$shell_status measured=$reported_status)" >&2
        sed -n '1,100p' "$stdout_path" >&2 || true
        sed -n '1,100p' "$stderr_path" >&2 || true
        return 1
    fi
}

declare -a peer_tools=()
declare -a all_tools=()
declare -A tool_mode=()
declare -A tool_ext=()
declare -A tool_command=()
declare -A artifact_path=()

one_line() { tr '\t\r\n' '   ' | sed 's/  */ /g; s/^ //; s/ $//'; }
add_tool() {
    local name=$1 mode=$2 command=$3 extension=$4 version=$5 notes=$6
    peer_tools+=("$name")
    tool_mode["$name"]=$mode
    tool_ext["$name"]=$extension
    tool_command["$name"]=$command
    printf '%s\t%s\t1\t%s\t%s\t%s\t%s\n' "$name" "$mode" "$command" "$version" "$extension" "$notes" >> "$tools_file"
}
skip_tool() {
    local name=$1 mode=$2 command=$3 extension=$4 notes=$5
    printf '%s\t%s\t0\t%s\tmissing\t%s\t%s\n' "$name" "$mode" "$command" "$extension" "$notes" >> "$tools_file"
}

znc_version=$($znc_bin --version 2>&1 | one_line)
add_tool zag-compiler-only compiler-only "$znc_bin" zag "$znc_version" 'analyzer,daemon,profile,and foreground cache disabled'
if command -v gcc >/dev/null 2>&1; then
    gcc_bin=$(command -v gcc); gcc_version=$(gcc --version | sed -n '1p' | one_line)
    add_tool gcc-c baseline "$gcc_bin" c "$gcc_version" 'C11,-O0,-g0'
else skip_tool gcc-c baseline gcc c 'not installed'; fi
if command -v g++ >/dev/null 2>&1; then
    gxx_bin=$(command -v g++); gxx_version=$(g++ --version | sed -n '1p' | one_line)
    add_tool gxx-cpp baseline "$gxx_bin" cpp "$gxx_version" 'C++17,-O0,-g0'
else skip_tool gxx-cpp baseline g++ cpp 'not installed'; fi
if command -v clang >/dev/null 2>&1; then
    clang_bin=$(command -v clang); clang_version=$(clang --version | sed -n '1p' | one_line)
    add_tool clang-c baseline "$clang_bin" c "$clang_version" 'C11,-O0,-g0'
else skip_tool clang-c baseline clang c 'not installed'; fi
if command -v clang++ >/dev/null 2>&1; then
    clangxx_bin=$(command -v clang++); clangxx_version=$(clang++ --version | sed -n '1p' | one_line)
    add_tool clangxx-cpp baseline "$clangxx_bin" cpp "$clangxx_version" 'C++17,-O0,-g0'
else skip_tool clangxx-cpp baseline clang++ cpp 'not installed'; fi
if command -v rustc >/dev/null 2>&1; then
    rustc_bin=$(command -v rustc); rustc_version=$(rustc --version --verbose | one_line)
    add_tool rustc baseline "$rustc_bin" rs "$rustc_version" 'edition-2021,opt-level=0,debuginfo=0'
else skip_tool rustc baseline rustc rs 'not installed'; fi
if command -v zig >/dev/null 2>&1; then
    zig_bin=$(command -v zig); zig_version=$(zig version | one_line)
    add_tool zig baseline "$zig_bin" zig "$zig_version" 'Debug,-fstrip,unique local and global cache per compile'
else skip_tool zig baseline zig zig 'not installed'; fi
if command -v tcc >/dev/null 2>&1; then
    tcc_bin=$(command -v tcc); tcc_version=$(tcc -v 2>&1 | sed -n '1p' | one_line)
    add_tool tcc-c baseline "$tcc_bin" c "$tcc_version" 'C,-O0'
else skip_tool tcc-c baseline tcc c 'not installed'; fi

tool_mode[zag-default-user]=default-user
tool_ext[zag-default-user]=zag
tool_command[zag-default-user]=$znc_bin
printf '%s\t%s\t1\t%s\t%s\t%s\t%s\n' zag-default-user default-user "$znc_bin" "$znc_version" zag \
    'unmodified user command; analyzer,foreground cache,and ephemeral project-scoped zagd enabled' >> "$tools_file"
all_tools=("${peer_tools[@]}" zag-default-user)

read_conditions
preflight_reasons=$(contamination_reasons "$cond_load1" "$cond_ncpu" "$cond_swap_used" "$cond_swap_total" \
    "$cond_active_build" "$cond_active_build" 0 0)
if [ "$strict_quiet" -eq 1 ] && [ "$preflight_reasons" != none ]; then
    echo "compiler-comparison: STRICT_QUIET rejected host: $preflight_reasons" >&2
    exit 3
fi

git_dirty=0
if [ -n "$(git -C "$repo_root" status --porcelain)" ]; then git_dirty=1; fi
{
    echo "schema=zag-compiler-comparison-v1"
    echo "timestamp_utc=$stamp"
    echo "repo_root=$repo_root"
    echo "compiler_commit=$(git -C "$repo_root" rev-parse HEAD)"
    echo "compiler_dirty=$git_dirty"
    echo "znc_sha256=$(sha256sum "$znc_bin" | awk '{print $1}')"
    echo "kernel=$(uname -srmo)"
    echo "machine=$(uname -m)"
    echo "cpu_model=$(awk -F: '/model name/ {sub(/^[ \t]+/,"",$2); print $2; exit}' /proc/cpuinfo)"
    echo "cpu_count=$cond_ncpu"
    echo "memory_total_kb=$(awk '/^MemTotal:/ {print $2}' /proc/meminfo)"
    echo "swap_total_kb=$cond_swap_total"
    echo "swap_used_kb_at_start=$cond_swap_used"
    echo "load_at_start=$cond_load1 $cond_load5 $cond_load15"
    echo "active_build_processes_at_start=$cond_active_build"
    echo "preflight_contamination_reasons=$preflight_reasons"
    echo "strict_quiet=$strict_quiet"
    echo "runs=$runs"
    echo "nice_level=$nice_level"
    echo "timeout_seconds=$timeout_seconds"
    echo "quiet_load_per_cpu_max=$quiet_load_per_cpu_max"
    echo "swap_used_max_pct=$swap_used_max_pct"
    echo "expected_checksum=115663923"
    echo "clean_definition=fresh output and compiler cache disabled or isolated; OS page cache is uncontrolled"
    echo "repeat_definition=fresh compiler process after the clean sample; compiler-only modes remain cache-disabled"
    echo "zag_compiler_only_command=znc INPUT -o OUTPUT --no-analyze --no-zagd --no-zagd-profile --no-foreground-cache"
    echo "zag_default_user_command=znc INPUT -o OUTPUT"
    echo "gcc_command=gcc -std=c11 -O0 -g0 INPUT -o OUTPUT"
    echo "gxx_command=g++ -std=c++17 -O0 -g0 INPUT -o OUTPUT"
    echo "rustc_command=rustc --edition=2021 -C opt-level=0 -C debuginfo=0 INPUT -o OUTPUT"
    echo "zig_command=zig build-exe INPUT -O Debug -fstrip --cache-dir UNIQUE --global-cache-dir UNIQUE -femit-bin=OUTPUT"
    for source in "$work_dir"/source/*; do
        echo "fixture_sha256.$(basename "$source")=$(sha256sum "$source" | awk '{print $1}')"
    done
} > "$metadata"
ps -eo pid=,etimes=,pcpu=,rss=,stat=,comm= | awk \
    '$6=="znc" || $6=="zagd" || $6=="gcc" || $6=="g++" || $6=="clang" ||
     $6=="clang++" || $6=="rustc" || $6=="zig" || $6=="tcc" || $6=="cc1" ||
     $6=="cc1plus" || $6=="ld" || $6=="as" || $6=="ninja" || $6=="make"' \
    > "$out/active-build-processes.start.tsv"

declare -a compile_command=()
compile_output=
prepare_compile() {
    local tool=$1 fixture=$2 phase=$3 run=$4
    local extension=${tool_ext[$tool]}
    local source="$work_dir/source/$fixture.$extension"
    compile_output="$artifacts_dir/$tool.$fixture"
    compile_command=()
    case $tool in
        zag-compiler-only)
            compile_command=("${tool_command[$tool]}" "$source" -o "$compile_output" \
                --no-analyze --no-zagd --no-zagd-profile --no-foreground-cache)
            ;;
        zag-default-user)
            source="$current_default_project/$fixture.zag"
            compile_command=("${tool_command[$tool]}" "$source" -o "$compile_output")
            ;;
        gcc-c)
            compile_command=("${tool_command[$tool]}" -std=c11 -O0 -g0 "$source" -o "$compile_output")
            ;;
        gxx-cpp)
            compile_command=("${tool_command[$tool]}" -std=c++17 -O0 -g0 "$source" -o "$compile_output")
            ;;
        clang-c)
            compile_command=("${tool_command[$tool]}" -std=c11 -O0 -g0 "$source" -o "$compile_output")
            ;;
        clangxx-cpp)
            compile_command=("${tool_command[$tool]}" -std=c++17 -O0 -g0 "$source" -o "$compile_output")
            ;;
        rustc)
            compile_command=("${tool_command[$tool]}" --edition=2021 -C opt-level=0 -C debuginfo=0 "$source" -o "$compile_output")
            ;;
        zig)
            local zig_cache="$work_dir/zig-cache/$fixture/$phase-$run"
            mkdir -p "$zig_cache/local" "$zig_cache/global"
            compile_command=("${tool_command[$tool]}" build-exe "$source" -O Debug -fstrip \
                --cache-dir "$zig_cache/local" --global-cache-dir "$zig_cache/global" -femit-bin="$compile_output")
            ;;
        tcc-c)
            compile_command=("${tool_command[$tool]}" -O0 "$source" -o "$compile_output")
            ;;
        *) echo "compiler-comparison: internal unknown tool: $tool" >&2; return 2;;
    esac
    artifact_path["$tool|$fixture"]=$compile_output
}

run_compile_sample() {
    local tool=$1 fixture=$2 phase=$3 run=$4
    local mode=${tool_mode[$tool]}
    prepare_compile "$tool" "$fixture" "$phase" "$run"
    local prefix="$logs_dir/compile.$tool.$fixture.$phase.$run"
    measure_one compile "$tool" "$mode" "$fixture" "$phase" "$run" "$prefix.stdout" "$prefix.stderr" \
        "${compile_command[@]}"
}

benchmark_default_fixture() {
    local fixture=$1 run
    current_default_project="$work_dir/zag-default-$fixture"
    mkdir -p "$current_default_project"
    cp "$work_dir/source/$fixture.zag" "$current_default_project/$fixture.zag"
    run_compile_sample zag-default-user "$fixture" clean 0
    run=1
    while [ "$run" -le "$runs" ]; do
        run_compile_sample zag-default-user "$fixture" repeat "$run"
        run=$((run + 1))
    done
    stop_default_project "$current_default_project"
}

echo "compiler-comparison: output=$out"
echo "compiler-comparison: preflight=$preflight_reasons"
for fixture in tiny checksum; do
    for tool in "${peer_tools[@]}"; do run_compile_sample "$tool" "$fixture" clean 0; done
    run=1
    while [ "$run" -le "$runs" ]; do
        if [ $((run % 2)) -eq 1 ]; then
            for tool in "${peer_tools[@]}"; do run_compile_sample "$tool" "$fixture" repeat "$run"; done
        else
            for ((index=${#peer_tools[@]} - 1; index >= 0; index--)); do
                run_compile_sample "${peer_tools[$index]}" "$fixture" repeat "$run"
            done
        fi
        run=$((run + 1))
    done
    benchmark_default_fixture "$fixture"
done

expected_checksum=115663923
run=1
while [ "$run" -le "$runs" ]; do
    if [ $((run % 2)) -eq 1 ]; then runtime_order=("${all_tools[@]}");
    else
        runtime_order=()
        for ((index=${#all_tools[@]} - 1; index >= 0; index--)); do runtime_order+=("${all_tools[$index]}"); done
    fi
    for tool in "${runtime_order[@]}"; do
        mode=${tool_mode[$tool]}
        binary=${artifact_path["$tool|checksum"]}
        prefix="$logs_dir/runtime.$tool.checksum.repeat.$run"
        measure_one runtime "$tool" "$mode" checksum repeat "$run" "$prefix.stdout" "$prefix.stderr" "$binary"
        output_text=$(sed -n '1p' "$prefix.stdout")
        output_lines=$(wc -l < "$prefix.stdout")
        stderr_bytes=$(stat -Lc %s "$prefix.stderr")
        if [ "$output_text" != "$expected_checksum" ] || [ "$output_lines" -ne 1 ] || [ "$stderr_bytes" -ne 0 ]; then
            echo "compiler-comparison: runtime equivalence failed for $tool run $run" >&2
            exit 1
        fi
        if [ "$run" -eq 1 ]; then
            printf '%s\t%s\tchecksum\t0\t%s\t%s\t%s\t1\n' "$tool" "$mode" \
                "$(sha256sum "$prefix.stdout" | awk '{print $1}')" "$output_text" "$stderr_bytes" >> "$equivalence"
        fi
    done
    run=$((run + 1))
done

inspect_artifact() {
    local tool=$1 fixture=$2 path=$3
    local mode=${tool_mode[$tool]}
    local bytes sha header program dynamic notes elf_type sections interp needed needed_count stack relro build_id pie=0
    bytes=$(stat -Lc %s "$path")
    sha=$(sha256sum "$path" | awk '{print $1}')
    header=$(readelf -h "$path" 2>/dev/null || true)
    program=$(readelf -l "$path" 2>/dev/null || true)
    dynamic=$(readelf -d "$path" 2>/dev/null || true)
    notes=$(readelf -n "$path" 2>/dev/null || true)
    elf_type=$(printf '%s\n' "$header" | awk -F: '/^[[:space:]]*Type:/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}')
    sections=$(printf '%s\n' "$header" | awk -F: '/Number of section headers:/ {sub(/^[[:space:]]*/,"",$2); print $2; exit}')
    if printf '%s\n' "$program" | grep -q ' INTERP '; then interp=1; else interp=0; fi
    needed=$(printf '%s\n' "$dynamic" | awk -F'[][]' '/\(NEEDED\)/ {print $2}' | paste -sd';' -)
    needed_count=$(printf '%s\n' "$dynamic" | awk '/\(NEEDED\)/ {count++} END {print count+0}')
    if printf '%s\n' "$program" | grep -q 'GNU_STACK'; then stack=1; else stack=0; fi
    if printf '%s\n' "$program" | grep -q 'GNU_RELRO'; then relro=1; else relro=0; fi
    build_id=$(printf '%s\n' "$notes" | awk '/Build ID:/ {print $3; exit}')
    case $elf_type in DYN*) pie=1;; esac
    file_description=$(file -b -L "$path" | one_line)
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
        "$tool" "$mode" "$fixture" "$path" "$bytes" "$sha" "${elf_type:-NA}" "$pie" "${sections:-NA}" \
        "$interp" "$needed_count" "${needed:-none}" "$stack" "$relro" "${build_id:-none}" "$file_description" >> "$artifacts_file"
}
for tool in "${all_tools[@]}"; do
    inspect_artifact "$tool" tiny "${artifact_path["$tool|tiny"]}"
    inspect_artifact "$tool" checksum "${artifact_path["$tool|checksum"]}"
done

declare -A component_seen=()
record_component_raw() {
    local tool=$1 role=$2 path=$3 canonical bytes sha description key
    [ -e "$path" ] || return 0
    canonical=$(readlink -f "$path")
    key="$tool|$canonical"
    [ -z "${component_seen[$key]:-}" ] || return 0
    component_seen[$key]=1
    bytes=$(stat -Lc %s "$canonical")
    sha=$(sha256sum "$canonical" | awk '{print $1}')
    description=$(file -b -L "$canonical" | one_line)
    printf '%s\t%s\t%s\t%s\t%s\t%s\n' "$tool" "$role" "$canonical" "$bytes" "$sha" "$description" >> "$components_file"
}
record_component_tree() {
    local tool=$1 role=$2 path=$3 dep
    record_component_raw "$tool" "$role" "$path"
    while IFS= read -r dep; do
        [ -n "$dep" ] && record_component_raw "$tool" dynamic-dependency "$dep"
    done < <(ldd "$path" 2>/dev/null | awk '$2=="=>" && $3 ~ /^\// {print $3} $1 ~ /^\// {print $1}' || true)
}
resolve_program() {
    local candidate=$1
    if [[ $candidate == */* ]] && [ -e "$candidate" ]; then readlink -f "$candidate"
    else command -v "$candidate" 2>/dev/null || true
    fi
}

record_component_tree zag-compiler-only compiler "$znc_bin"
record_component_tree zag-default-user compiler "$znc_bin"
if [ -n "${tool_command[gcc-c]:-}" ]; then
    record_component_tree gcc-c driver "${tool_command[gcc-c]}"
    for part in cc1 collect2 as ld; do candidate=$(resolve_program "$(gcc -print-prog-name=$part)"); [ -n "$candidate" ] && record_component_tree gcc-c "$part" "$candidate"; done
fi
if [ -n "${tool_command[gxx-cpp]:-}" ]; then
    record_component_tree gxx-cpp driver "${tool_command[gxx-cpp]}"
    for part in cc1plus collect2 as ld; do candidate=$(resolve_program "$(g++ -print-prog-name=$part)"); [ -n "$candidate" ] && record_component_tree gxx-cpp "$part" "$candidate"; done
fi
if [ -n "${tool_command[clang-c]:-}" ]; then record_component_tree clang-c driver "${tool_command[clang-c]}"; fi
if [ -n "${tool_command[clangxx-cpp]:-}" ]; then record_component_tree clangxx-cpp driver "${tool_command[clangxx-cpp]}"; fi
rust_sysroot=
if [ -n "${tool_command[rustc]:-}" ]; then
    record_component_tree rustc invoked-command "${tool_command[rustc]}"
    rust_sysroot=$(rustc --print sysroot)
    record_component_tree rustc compiler "$rust_sysroot/bin/rustc"
    rust_driver=$(find "$rust_sysroot/lib" -maxdepth 1 -type f -name 'librustc_driver-*.so' -print -quit)
    rust_llvm=$(find "$rust_sysroot/lib" -maxdepth 1 -type f -name 'libLLVM*.so*' -print -quit)
    [ -n "$rust_driver" ] && record_component_tree rustc rustc-driver "$rust_driver"
    [ -n "$rust_llvm" ] && record_component_tree rustc llvm "$rust_llvm"
fi
zig_lib_dir=
if [ -n "${tool_command[zig]:-}" ]; then
    record_component_tree zig compiler "${tool_command[zig]}"
    zig_lib_dir=$(zig env | sed -n 's/^[[:space:]]*"lib_dir": "\(.*\)",/\1/p')
fi
if [ -n "${tool_command[tcc-c]:-}" ]; then record_component_tree tcc-c compiler "${tool_command[tcc-c]}"; fi

awk -F'\t' 'NR>1 {sum[$1]+=$4} END {for(tool in sum) print tool "\t" sum[tool]}' "$components_file" | sort > "$work_dir/core-footprints.tsv"
while IFS=$'\t' read -r tool core_bytes; do
    tree_bytes=NA; scope='core executable and ldd closure only'; note='system headers,libraries,and package metadata excluded'
    case $tool in
        zag-compiler-only|zag-default-user)
            tree_bytes=$(stat -Lc %s "$znc_bin"); scope='single compiler executable'; note='fixture uses compiler-builtin runtime only'
            ;;
        rustc)
            tree_bytes=$(du -sb "$rust_sysroot/bin" "$rust_sysroot/lib" | awk '{sum+=$1} END {print sum+0}')
            scope='rust sysroot bin plus lib'; note='rustup downloads,docs,and non-host targets excluded'
            ;;
        zig)
            if [ -n "$zig_lib_dir" ] && [ -d "$zig_lib_dir" ]; then
                tree_bytes=$(du -sb "$zig_lib_dir" | awk '{print $1}')
                tree_bytes=$((tree_bytes + $(stat -Lc %s "${tool_command[zig]}")))
            fi
            scope='zig executable plus reported lib_dir'; note='global cache excluded'
            ;;
    esac
    printf '%s\t%s\t%s\t%s\t%s\n' "$tool" "$core_bytes" "$tree_bytes" "$scope" "$note" >> "$footprints_file"
done < "$work_dir/core-footprints.tsv"

awk -F'\t' '
    NR==1 {next}
    {
        key=$1 SUBSEP $2 SUBSEP $3 SUBSEP $4 SUBSEP $5
        n[key]++; sample_index=n[key]
        wall[key SUBSEP sample_index]=$7+0; user[key SUBSEP sample_index]=$8+0
        sys[key SUBSEP sample_index]=$9+0; cpu[key SUBSEP sample_index]=$10+0
        rss[key SUBSEP sample_index]=$11+0; contaminated[key]+=$24+0
        if(sample_index==1 || $7+0<wall_min[key]) wall_min[key]=$7+0
        if(sample_index==1 || $7+0>wall_max[key]) wall_max[key]=$7+0
    }
    function median(values, key, count,    i,j,tmp,result) {
        for(i=1;i<=count;i++) scratch[i]=values[key SUBSEP i]
        for(i=1;i<=count;i++) for(j=i+1;j<=count;j++) if(scratch[j]<scratch[i]) {tmp=scratch[i];scratch[i]=scratch[j];scratch[j]=tmp}
        if(count%2) result=scratch[(count+1)/2]; else result=(scratch[count/2]+scratch[count/2+1])/2
        for(i=1;i<=count;i++) delete scratch[i]
        return result
    }
    END {
        print "kind\ttool\tmode\tfixture\tphase\tsamples\twall_min_ns\twall_median_ns\twall_max_ns\tuser_median_us\tsys_median_us\tcpu_median_us\tmax_rss_median_kb\tcontaminated_samples"
        for(key in n) {
            split(key, parts, SUBSEP); count=n[key]
            printf "%s\t%s\t%s\t%s\t%s\t%d\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%.0f\t%d\n",
                parts[1],parts[2],parts[3],parts[4],parts[5],count,wall_min[key],median(wall,key,count),wall_max[key],
                median(user,key,count),median(sys,key,count),median(cpu,key,count),median(rss,key,count),contaminated[key]
        }
    }' "$samples" > "$work_dir/summary.unsorted.tsv"
{
    sed -n '1p' "$work_dir/summary.unsorted.tsv"
    sed -n '2,$p' "$work_dir/summary.unsorted.tsv" | sort -t $'\t' -k1,1 -k2,2 -k4,4 -k5,5
} > "$summary"

read_conditions
sample_count=$(awk -F'\t' 'NR>1 {count++} END {print count+0}' "$samples")
contaminated_count=$(awk -F'\t' 'NR>1 && $24==1 {count++} END {print count+0}' "$samples")
{
    echo "sample_count=$sample_count"
    echo "contaminated_sample_count=$contaminated_count"
    if [ "$contaminated_count" -eq 0 ]; then echo "result_class=controlled-candidate"; else echo "result_class=directional-contaminated"; fi
    echo "load_at_end=$cond_load1 $cond_load5 $cond_load15"
    echo "swap_used_kb_at_end=$cond_swap_used"
    echo "active_build_processes_at_end=$cond_active_build"
    echo "measurement_clock=CLOCK_MONOTONIC"
    echo "cpu_rss_source=getrusage(RUSAGE_CHILDREN) around each fresh command process tree"
    echo "max_rss_unit=Linux ru_maxrss KiB"
} >> "$metadata"
ps -eo pid=,etimes=,pcpu=,rss=,stat=,comm= | awk \
    '$6=="znc" || $6=="zagd" || $6=="gcc" || $6=="g++" || $6=="clang" ||
     $6=="clang++" || $6=="rustc" || $6=="zig" || $6=="tcc" || $6=="cc1" ||
     $6=="cc1plus" || $6=="ld" || $6=="as" || $6=="ninja" || $6=="make"' \
    > "$out/active-build-processes.end.tsv"

echo "compiler-comparison: samples=$samples"
echo "compiler-comparison: summary=$summary"
echo "compiler-comparison: artifacts=$artifacts_file"
echo "compiler-comparison: footprints=$footprints_file"
echo "compiler-comparison: metadata=$metadata"
echo "compiler-comparison: result=$(if [ "$contaminated_count" -eq 0 ]; then echo controlled-candidate; else echo directional-contaminated; fi)"
