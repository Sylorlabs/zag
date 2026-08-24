#!/usr/bin/env bash
# Focused public std/rt.zag parity gate for the AArch64 native backend.
# Runs as a signed Mach-O on Darwin ARM64, as a native ELF on Linux ARM64, or
# through qemu-aarch64 when explicitly exercised from an x86-64 Linux host.
set -euo pipefail

cd "$(dirname "$0")/.."
repo_root=$PWD
host_system=$(uname -s)
host_machine=$(uname -m)
tmpdir=$(mktemp -d "${TMPDIR:-/tmp}/zag-arm64-rt-builtins.XXXXXX")
trap 'rm -rf "$tmpdir"' EXIT

target_args=()
compiler_target_args=()
run_prefix=()
case "$host_system:$host_machine" in
    Darwin:arm64)
        target_args=(--target macos-arm64)
        compiler_target_args=(--target macos-arm64)
        ;;
    Linux:aarch64|Linux:arm64)
        target_args=(--target arm64)
        compiler_target_args=(--target arm64)
        ;;
    Linux:x86_64|Linux:amd64)
        target_args=(--target arm64)
        qemu=${QEMU:-qemu-aarch64-static}
        if ! command -v "$qemu" >/dev/null 2>&1; then
            echo "XX  Linux x86-64 ARM64 parity run requires $qemu" >&2
            exit 2
        fi
        run_prefix=("$qemu")
        ;;
    *)
        echo "XX  ARM64 runtime parity requires Darwin/Linux ARM64 or Linux qemu-user (got $host_system $host_machine)" >&2
        exit 2
        ;;
esac

test_compiler=${ZNC:-}
if [ -z "$test_compiler" ]; then
    seed=${ZAG_ARM64_RT_SEED:-}
    if [ -z "$seed" ]; then
        for candidate in ./znc-macos-arm64 ./znc-linux-arm64 ./znc; do
            if [ -x "$candidate" ] && "$candidate" --version >/dev/null 2>&1; then
                seed=$candidate
                break
            fi
        done
    fi
    if [ -z "$seed" ] || [ ! -x "$seed" ]; then
        echo "XX  no executable native seed; set ZAG_ARM64_RT_SEED or ZNC" >&2
        exit 2
    fi
    "$seed" selfhost/native/znc.zag "${compiler_target_args[@]}" \
        --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/znc-isolated"
    test_compiler=$tmpdir/znc-isolated
fi

echo "── ARM64 public std/rt builtin parity ($host_system $host_machine) ──"
"$test_compiler" tests/arm64_rt_builtins.zag "${target_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/rt-builtins"

if [ "$host_system" = Darwin ]; then
    file "$tmpdir/rt-builtins" | grep -q 'Mach-O 64-bit executable arm64'
    codesign --verify --deep --strict "$tmpdir/rt-builtins"
else
    file "$tmpdir/rt-builtins" | grep -q 'ELF 64-bit LSB executable, ARM aarch64'
fi

set +e
if [ "${#run_prefix[@]}" -eq 0 ]; then
    env ZAG_ARM64_RT_VALUE='arm64=value' ZAG_ARM64_RT_EMPTY='' \
        "$tmpdir/rt-builtins" \
        >"$tmpdir/runtime.stdout" 2>"$tmpdir/runtime.stderr"
else
    env ZAG_ARM64_RT_VALUE='arm64=value' ZAG_ARM64_RT_EMPTY='' \
        "${run_prefix[@]}" "$tmpdir/rt-builtins" \
        >"$tmpdir/runtime.stdout" 2>"$tmpdir/runtime.stderr"
fi
runtime_status=$?
set -e
if [ "$runtime_status" -ne 42 ]; then
    echo "XX  runtime parity fixture exited $runtime_status" >&2
    sed -n '1,20p' "$tmpdir/runtime.stdout" >&2
    sed -n '1,20p' "$tmpdir/runtime.stderr" >&2
    exit 1
fi
if [ -s "$tmpdir/runtime.stdout" ] || [ -s "$tmpdir/runtime.stderr" ]; then
    echo "XX  runtime parity fixture emitted unexpected output" >&2
    sed -n '1,20p' "$tmpdir/runtime.stdout" >&2
    sed -n '1,20p' "$tmpdir/runtime.stderr" >&2
    exit 1
fi
echo "  ok  memcpy/memcmp boundaries, slice aliases, ordering, duplication, u64 parity, getenv, capture growth"

"$test_compiler" tests/arm64_numeric_time.zag "${target_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/numeric-time"
if [ "$host_system" = Darwin ]; then
    file "$tmpdir/numeric-time" | grep -q 'Mach-O 64-bit executable arm64'
    codesign --verify --deep --strict "$tmpdir/numeric-time"
else
    file "$tmpdir/numeric-time" | grep -q 'ELF 64-bit LSB executable, ARM aarch64'
fi
set +e
if [ "${#run_prefix[@]}" -eq 0 ]; then
    "$tmpdir/numeric-time" >"$tmpdir/numeric-time.stdout" 2>"$tmpdir/numeric-time.stderr"
else
    "${run_prefix[@]}" "$tmpdir/numeric-time" >"$tmpdir/numeric-time.stdout" 2>"$tmpdir/numeric-time.stderr"
fi
numeric_status=$?
set -e
if [ "$numeric_status" -ne 42 ]; then
    echo "XX  numeric/monotonic fixture exited $numeric_status" >&2
    sed -n '1,20p' "$tmpdir/numeric-time.stdout" >&2
    sed -n '1,20p' "$tmpdir/numeric-time.stderr" >&2
    exit 1
fi
if [ -s "$tmpdir/numeric-time.stdout" ] || [ -s "$tmpdir/numeric-time.stderr" ]; then
    echo "XX  numeric/monotonic fixture emitted unexpected output" >&2
    sed -n '1,20p' "$tmpdir/numeric-time.stdout" >&2
    sed -n '1,20p' "$tmpdir/numeric-time.stderr" >&2
    exit 1
fi
echo "  ok  int/float builtin rounding and truncation; boot-relative monotonic progression"

# Public declarations must still enforce their arity before an artifact exists.
printf '@import("%s/std/rt.zag") fn main() i32 { return _zag_memcmp(null as *i8, null as *i8); }\n' \
    "$repo_root" >"$tmpdir/bad-arity.zag"
if "$test_compiler" "$tmpdir/bad-arity.zag" "${target_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/bad-arity" \
    >"$tmpdir/bad-arity.log" 2>&1; then
    echo "XX  malformed public runtime call compiled" >&2
    exit 1
fi
test ! -e "$tmpdir/bad-arity"
if ! grep -Eq 'expects three arguments|expects 3 arguments|argument' "$tmpdir/bad-arity.log"; then
    echo "XX  malformed-call diagnostic was not specific" >&2
    sed -n '1,20p' "$tmpdir/bad-arity.log" >&2
    exit 1
fi
echo "  ok  malformed public runtime call rejects without an artifact"

printf '%s\n' 'fn main() i32 { return @floatToInt(1.0, 2.0); }' >"$tmpdir/bad-conversion.zag"
if "$test_compiler" "$tmpdir/bad-conversion.zag" "${target_args[@]}" \
    --no-zagd --no-analyze --no-foreground-cache -o "$tmpdir/bad-conversion" \
    >"$tmpdir/bad-conversion.log" 2>&1; then
    echo "XX  malformed conversion builtin compiled" >&2
    exit 1
fi
test ! -e "$tmpdir/bad-conversion"
if ! grep -Eq '@floatToInt expects one argument|expects one argument' "$tmpdir/bad-conversion.log"; then
    echo "XX  malformed-conversion diagnostic was not specific" >&2
    sed -n '1,20p' "$tmpdir/bad-conversion.log" >&2
    exit 1
fi
echo "  ok  malformed conversion builtin rejects without an artifact"
echo "════ ARM64 public runtime + numeric parity: pass=4 fail=0 ════"
