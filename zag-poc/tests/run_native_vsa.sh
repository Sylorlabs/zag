#!/usr/bin/env bash
set -eu
export LC_ALL=C
cd "$(dirname "$0")/.."

host_system=$(uname -s)
host_arch=$(uname -m)
native_platform=""
native_target_args=()
native_is_arm64=0
linux_arm_target_args=(--target arm64)
linux_arm_runner=""
linux_arm_mode=""
linux_arm_available=1

case "$host_system:$host_arch" in
    Linux:x86_64|Linux:amd64)
        native_platform=linux-x86_64
        linux_arm_runner=${QEMU_AARCH64:-/usr/bin/qemu-aarch64-static}
        linux_arm_mode="under QEMU on Linux x86-64"
        if [ ! -x "$linux_arm_runner" ]; then linux_arm_available=0; fi
        ;;
    Linux:aarch64|Linux:arm64)
        native_platform=linux-arm64
        native_target_args=(--target arm64)
        native_is_arm64=1
        linux_arm_mode="natively on Linux ARM64"
        ;;
    Darwin:arm64)
        native_platform=macos-arm64
        native_target_args=(--target macos-arm64)
        native_is_arm64=1
        # Linux AArch64 ET_EXEC output is a separate cross-target contract.
        # Never execute it directly merely because Darwin shares the ISA.
        linux_arm_runner=${QEMU_AARCH64:-}
        linux_arm_mode="under an explicit Linux-user runner on macOS"
        if [ -z "$linux_arm_runner" ] || [ ! -x "$linux_arm_runner" ]; then
            linux_arm_available=0
        fi
        ;;
    *)
        echo "native VSA gate: unsupported native host: $host_system $host_arch" >&2
        exit 1
        ;;
esac

# A side-effect-free selector probe used by the host-matrix regression.  It is
# deliberately after the fail-closed case statement so unsupported pairs still
# return non-zero.
if [ "${ZAG_NATIVE_VSA_HOST_SELECTION_ONLY:-0}" = 1 ]; then
    native_args=${native_target_args[*]:-<default>}
    linux_arm_runner_display=${linux_arm_runner:-<native-or-unavailable>}
    printf 'host=%s:%s\n' "$host_system" "$host_arch"
    printf 'native_platform=%s\n' "$native_platform"
    printf 'native_target_args=%s\n' "$native_args"
    printf 'linux_arm_target_args=%s\n' "${linux_arm_target_args[*]}"
    printf 'linux_arm_runner=%s\n' "$linux_arm_runner_display"
    printf 'linux_arm_available=%s\n' "$linux_arm_available"
    exit 0
fi

compiler=${ZNC:-./znc}
work=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-vsa.XXXXXX")
trap 'rm -rf "$work"' EXIT HUP INT TERM
project="$work/project"
mkdir -p "$project"
cp tests/native_vsa*.zag "$project/"
printf 'name = "native_vsa_gate"\nversion = "0"\nedition = "2027"\n' >"$project/zag.mod"
pass=0
fail=0

record_pass() { echo "  ok  $1"; pass=$((pass + 1)); }
record_fail() { echo "  XX  $1"; fail=$((fail + 1)); }
record_skip() { echo "  --  $1"; }

# Zag's minimal ET_EXEC intentionally has no section or symbol table. Isolate
# the executable PT_LOAD payload at its real instruction boundary before using
# objdump, so headers and read-only data cannot satisfy an instruction check.
x86_text_disassemble() {
    local artifact=$1
    local dump=$2
    local phoff phentsize phnum exec_offset_hex exec_filesz_hex
    local exec_offset exec_filesz text_start text_size text_blob
    phoff=$(readelf -hW "$artifact" | awk -F: \
        '/Start of program headers:/ { print $2 + 0; exit }')
    phentsize=$(readelf -hW "$artifact" | awk -F: \
        '/Size of program headers:/ { print $2 + 0; exit }')
    phnum=$(readelf -hW "$artifact" | awk -F: \
        '/Number of program headers:/ { print $2 + 0; exit }')
    exec_offset_hex=$(readelf -lW "$artifact" | awk \
        '$1 == "LOAD" && $0 ~ / R E / { print $2; exit }')
    exec_filesz_hex=$(readelf -lW "$artifact" | awk \
        '$1 == "LOAD" && $0 ~ / R E / { print $5; exit }')
    if [ -z "$phoff" ] || [ -z "$phentsize" ] || [ -z "$phnum" ] ||
       [ -z "$exec_offset_hex" ] || [ -z "$exec_filesz_hex" ]; then
        return 1
    fi
    exec_offset=$((exec_offset_hex))
    exec_filesz=$((exec_filesz_hex))
    text_start=$((phoff + phentsize * phnum))
    text_size=$((exec_filesz - text_start))
    if [ "$exec_offset" -ne 0 ] || [ "$text_start" -le 0 ] ||
       [ "$text_size" -le 0 ]; then
        return 1
    fi
    text_blob="$dump.text"
    dd if="$artifact" of="$text_blob" bs=1 skip="$text_start" \
        count="$text_size" status=none
    objdump -D -b binary -m i386:x86-64 "$text_blob" >"$dump"
}

x86_has_instruction() {
    grep -Eq "[[:space:]]$2[[:space:]]" "$1"
}

run_linux_arm() {
    if [ -n "$linux_arm_runner" ]; then "$linux_arm_runner" "$@"; else "$@"; fi
}

compile_reject() {
    label=$1
    source=$2
    pattern=$3
    if "$compiler" "$source" "${native_target_args[@]}" -o "$work/rejected" --no-zagd --no-analyze \
        --no-foreground-cache >"$work/reject.log" 2>&1; then
        record_fail "$label compiled"
    elif grep -Fq "$pattern" "$work/reject.log"; then
        record_pass "$label rejected before execution"
    else
        record_fail "$label returned the wrong diagnostic"
        sed -n '1,12p' "$work/reject.log"
    fi
}

runtime_reject() {
    label=$1
    source=$2
    pattern=$3
    if ! "$compiler" "$source" "${native_target_args[@]}" -o "$work/runtime-bad" --no-zagd --no-analyze \
        --no-foreground-cache >"$work/runtime-build.log" 2>&1; then
        record_fail "$label did not compile"
        sed -n '1,12p' "$work/runtime-build.log"
        return
    fi
    set +e
    "$work/runtime-bad" >"$work/runtime.out" 2>"$work/runtime.err"
    status=$?
    set -e
    if [ "$status" -ne 0 ] && grep -Fq "$pattern" "$work/runtime.err"; then
        record_pass "$label failed closed"
    else
        record_fail "$label did not fail closed"
    fi
}

echo "── native VSA: strict dimensions, packed layout, and exact operations ──"
if [ "$native_platform" = "linux-x86_64" ]; then
    if "$compiler" "$project/native_vsa.zag" -o "$work/vsa-x86" \
        --no-zagd --no-analyze --no-foreground-cache \
        >"$work/x86-build.log" 2>&1; then
        set +e
        "$work/vsa-x86"
        status=$?
        set -e
        # MOVDQU is also a legal baseline memcpy instruction.  POPCNT and the
        # packed Boolean operations distinguish this VSA specialization.
        if [ "$status" -eq 42 ] &&
           x86_text_disassemble "$work/vsa-x86" "$work/vsa-x86.dump" &&
           ! x86_has_instruction "$work/vsa-x86.dump" popcnt &&
           ! x86_has_instruction "$work/vsa-x86.dump" pxor &&
           ! x86_has_instruction "$work/vsa-x86.dump" pand &&
           ! x86_has_instruction "$work/vsa-x86.dump" por; then
            record_pass "x86-64 scalar authority and feature gate"
        else
            record_fail "x86-64 scalar path, parity, or feature gate"
        fi
    else
        record_fail "x86-64 compilation"
        sed -n '1,20p' "$work/x86-build.log"
    fi

    if grep -Eq '^flags[[:space:]]*:.*[[:space:]]popcnt([[:space:]]|$)' /proc/cpuinfo; then
        if "$compiler" "$project/native_vsa.zag" -o "$work/vsa-x86-native" \
            --cpu=native --no-zagd --no-analyze --no-foreground-cache \
            >"$work/x86-native-build.log" 2>&1; then
            set +e
            "$work/vsa-x86-native"
            status=$?
            set -e
            if [ "$status" -eq 42 ] &&
               x86_text_disassemble "$work/vsa-x86-native" \
                   "$work/vsa-x86-native.dump" &&
               x86_has_instruction "$work/vsa-x86-native.dump" popcnt &&
               x86_has_instruction "$work/vsa-x86-native.dump" movdqu &&
               x86_has_instruction "$work/vsa-x86-native.dump" pxor &&
               x86_has_instruction "$work/vsa-x86-native.dump" pand &&
               x86_has_instruction "$work/vsa-x86-native.dump" por; then
                record_pass "x86-64 SSE2/POPCNT bit-identical path"
            else
                record_fail "x86-64 SSE2/POPCNT path, parity, or feature gate"
            fi
        else
            record_fail "x86-64 native-feature compilation"
            sed -n '1,20p' "$work/x86-native-build.log"
        fi
    else
        record_skip "x86-64 POPCNT path unavailable on this host"
    fi
else
    record_skip "x86-64 scalar target path on native $native_platform host"
    record_skip "x86-64 POPCNT target path on native $native_platform host"
fi

if "$compiler" "$project/native_vsa_generic_list.zag" -o "$work/vsa-list" \
    "${native_target_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache >"$work/list-build.log" 2>&1 &&
    ! grep -Fq 'error[' "$work/list-build.log"; then
    set +e
    "$work/vsa-list"
    status=$?
    set -e
    if [ "$status" -eq 42 ]; then record_pass "generic list VSA typing and copy"; else record_fail "generic list VSA runtime exit $status"; fi
else
    record_fail "generic list VSA compilation"
    sed -n '1,20p' "$work/list-build.log"
fi

compile_reject "zero dimension" "$project/native_vsa_dim_zero_bad.zag" "invalid vsa_b<N> dimension"
compile_reject "noncanonical dimension" "$project/native_vsa_dim_leading_zero_bad.zag" "invalid vsa_b<N> dimension"
compile_reject "over-limit dimension" "$project/native_vsa_dim_large_bad.zag" "invalid vsa_b<N> dimension"
compile_reject "dimension mismatch" "$project/native_vsa_mismatch_bad.zag" "expected vsa_b<64>, found vsa_b<65>"
compile_reject "unsupported VSA operator" "$project/native_vsa_operator_bad.zag" "supports only ^, &, and |"
runtime_reject "word-count mismatch" "$project/native_vsa_word_count_bad.zag" "imported word count does not match dimension"
runtime_reject "word index bounds" "$project/native_vsa_word_index_bad.zag" "word index out of bounds"

if "$compiler" tests/aarch64_vsa_neon_encoder.zag "${native_target_args[@]}" \
    -o "$work/aarch64-vsa-neon-encoder" --no-zagd --no-analyze \
    --no-foreground-cache >"$work/neon-encoder-build.log" 2>&1; then
    set +e
    "$work/aarch64-vsa-neon-encoder"
    status=$?
    set -e
    if [ "$status" -eq 42 ]; then
        record_pass "AArch64 Advanced SIMD encoder authority"
    else
        record_fail "AArch64 Advanced SIMD encoder exit $status"
    fi
else
    record_fail "AArch64 Advanced SIMD encoder compilation"
    sed -n '1,20p' "$work/neon-encoder-build.log"
fi

# The native ARM64 row exercises the host runtime: Mach-O/Darwin on Apple
# Silicon and ELF/Linux on Linux ARM64.  It is intentionally not evidence for
# the distinct Linux ARM cross-target rows below.
if [ "$native_is_arm64" -eq 1 ]; then
    if "$compiler" "$project/native_vsa.zag" "${native_target_args[@]}" \
        -o "$work/vsa-native-arm64" --no-zagd --no-analyze \
        --no-foreground-cache >"$work/native-arm-build.log" 2>&1; then
        set +e
        "$work/vsa-native-arm64"
        status=$?
        set -e
        if [ "$status" -eq 42 ]; then
            record_pass "$native_platform VSA semantics and native runtime"
        else
            record_fail "$native_platform VSA runtime exit $status"
        fi
    else
        record_fail "$native_platform VSA compilation"
        sed -n '1,20p' "$work/native-arm-build.log"
    fi
fi

if [ "$linux_arm_available" -eq 1 ]; then
    if "$compiler" tests/aarch64_vsa_neon_runtime.zag \
        "${native_target_args[@]}" \
        -o "$work/aarch64-vsa-neon-runtime-generator" --no-zagd \
        --no-analyze --no-foreground-cache >"$work/neon-runtime-build.log" 2>&1; then
        set +e
        "$work/aarch64-vsa-neon-runtime-generator" "$work/neon-runtime"
        generated=$?
        run_linux_arm "$work/neon-runtime"
        neon_status=$?
        set -e
        if [ "$generated" -eq 42 ] && [ "$neon_status" -eq 42 ]; then
            record_pass "Linux AArch64 Advanced SIMD execution $linux_arm_mode"
        else
            record_fail "AArch64 Advanced SIMD execution generator=$generated runtime=$neon_status"
        fi
    else
        record_fail "AArch64 Advanced SIMD runtime generator compilation"
        sed -n '1,20p' "$work/neon-runtime-build.log"
    fi
    if "$compiler" "$project/native_vsa.zag" "${linux_arm_target_args[@]}" -o "$work/vsa-arm64" \
        --no-zagd --no-analyze --no-foreground-cache >"$work/arm-build.log" 2>&1; then
        set +e
        run_linux_arm "$work/vsa-arm64"
        status=$?
        set -e
        if [ "$status" -eq 42 ]; then
            record_pass "Linux AArch64 NEON prefix and scalar-tail compiler path $linux_arm_mode"
        else
            record_fail "AArch64 runtime exit $status"
        fi
    else
        record_fail "AArch64 compilation"
        sed -n '1,20p' "$work/arm-build.log"
    fi
else
    record_fail "Linux AArch64 Advanced SIMD runner is unavailable: ${linux_arm_runner:-not configured}"
    record_fail "Linux AArch64 VSA compiler runner is unavailable: ${linux_arm_runner:-not configured}"
fi

echo "════ native-vsa pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
