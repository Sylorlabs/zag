#!/usr/bin/env bash
# Prove ./znc deterministically reproduces a byte-identical ./znc-target fixpoint.
#
# Unlike ./znc, the GPU/WASM helper is not self-hosted: the lean ./znc compiler
# always builds znc-target from selfhost/native/znc_target.zag. This script
# checks that repeated builds match the committed seed and each other.
#
# Compiler invocations run with an empty PATH so no C compiler, assembler,
# linker, shell, or other host executable can be resolved by command lookup.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
target_source="$root/selfhost/native/znc_target.zag"
. "$root/tests/portable.sh"

host_target_args=()
case "$(uname -s):$(uname -m)" in
    Darwin:arm64) host_platform=macos-arm64; host_target_args=(--target macos-arm64) ;;
    Linux:x86_64|Linux:amd64) host_platform=linux-x86_64 ;;
    Linux:aarch64|Linux:arm64) host_platform=linux-arm64; host_target_args=(--target arm64) ;;
    *) echo "native target repro: unsupported host: $(uname -s) $(uname -m)" >&2; exit 1 ;;
esac

case ${ZNC_SEED:-} in
    '')
        seed=""
        for candidate in "$root/znc-$host_platform" "$root/seeds/$host_platform/znc" "$root/znc"; do
            if [ -x "$candidate" ] && zag_assert_native_executable "$candidate"; then seed=$candidate; break; fi
        done
        ;;
    /*) seed=$ZNC_SEED ;;
    *) seed="$PWD/$ZNC_SEED" ;;
esac

case ${ZNC_TARGET_SEED:-} in
    '')
        target_seed=""
        for candidate in "$root/znc-target-$host_platform" "$root/seeds/$host_platform/znc-target" "$root/znc-target"; do
            if [ -x "$candidate" ] && zag_assert_native_executable "$candidate"; then target_seed=$candidate; break; fi
        done
        ;;
    /*) target_seed=$ZNC_TARGET_SEED ;;
    *) target_seed="$PWD/$ZNC_TARGET_SEED" ;;
esac

cd "$root"

if [ ! -x "$seed" ]; then
    echo "native target repro: znc seed is not executable: $seed" >&2
    exit 1
fi

if [ ! -x "$target_seed" ]; then
    echo "native target repro: znc-target seed is not executable: $target_seed" >&2
    echo "native target repro: provide a trusted $host_platform target seed via ZNC_TARGET_SEED" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-target.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/empty-path"

build_target_stage() {
    compiler=$1
    output=$2
    label=$3
    log="$tmp/$label.log"

    if ! PATH="$tmp/empty-path" "$compiler" "$target_source" \
        "${host_target_args[@]}" -o "$output" >"$log" 2>&1; then
        echo "  XX  $label failed" >&2
        sed -n '1,40p' "$log" >&2
        exit 1
    fi
    if [ ! -x "$output" ]; then
        echo "  XX  $label did not produce an executable" >&2
        exit 1
    fi
    echo "  ok  $label"
}

same_bytes() {
    left=$1
    right=$2
    label=$3

    if cmp -s "$left" "$right"; then
        echo "  ok  $label"
        return
    fi

    echo "  XX  $label" >&2
    echo "      $(zag_sha256_file "$left")  $left" >&2
    echo "      $(zag_sha256_file "$right")  $right" >&2
    exit 1
}

echo "── native znc-target reproducibility (./znc → $host_platform, empty PATH) ──"
build_target_stage "$seed" "$tmp/target-stage1" "znc builds znc-target stage 1"
build_target_stage "$seed" "$tmp/target-stage2" "znc rebuilds znc-target stage 2"
build_target_stage "$seed" "$tmp/target-stage3" "znc rebuilds znc-target stage 3"

same_bytes "$target_seed" "$tmp/target-stage1" "committed seed matches znc rebuild"
same_bytes "$tmp/target-stage1" "$tmp/target-stage2" "stage 1 equals stage 2 byte-for-byte"
same_bytes "$tmp/target-stage2" "$tmp/target-stage3" "stage 2 equals stage 3 byte-for-byte"

digest=$(zag_sha256_file "$tmp/target-stage3")
echo "  sha256  $digest"
echo "════ native znc-target reproducible: pass=6 fail=0 ════"
