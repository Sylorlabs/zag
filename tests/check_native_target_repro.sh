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

case ${ZNC_SEED:-} in
    '') seed="$root/znc" ;;
    /*) seed=$ZNC_SEED ;;
    *) seed="$PWD/$ZNC_SEED" ;;
esac

case ${ZNC_TARGET_SEED:-} in
    '') target_seed="$root/znc-target" ;;
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
    echo "native target repro: run ./bootstrap.sh to build ./znc-target from ./znc" >&2
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

    if ! PATH="$tmp/empty-path" "$compiler" "$target_source" -o "$output" >"$log" 2>&1; then
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
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$left" "$right" >&2
    fi
    exit 1
}

echo "── native znc-target reproducibility (./znc → ELF, empty PATH) ──"
build_target_stage "$seed" "$tmp/target-stage1" "znc builds znc-target stage 1"
build_target_stage "$seed" "$tmp/target-stage2" "znc rebuilds znc-target stage 2"
build_target_stage "$seed" "$tmp/target-stage3" "znc rebuilds znc-target stage 3"

same_bytes "$target_seed" "$tmp/target-stage1" "committed seed matches znc rebuild"
same_bytes "$tmp/target-stage1" "$tmp/target-stage2" "stage 1 equals stage 2 byte-for-byte"
same_bytes "$tmp/target-stage2" "$tmp/target-stage3" "stage 2 equals stage 3 byte-for-byte"

if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$tmp/target-stage3")
    digest=${digest%% *}
    echo "  sha256  $digest"
fi
echo "════ native znc-target reproducible: pass=6 fail=0 ════"