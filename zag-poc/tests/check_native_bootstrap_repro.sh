#!/usr/bin/env bash
# Prove the native Zag compiler reaches a byte-identical self-hosting fixpoint.
#
# The compiler invocations run with an empty PATH, so no C compiler, assembler,
# linker, shell, or other host executable can be resolved by command lookup.
# The shell is used only to orchestrate and compare completed results.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
source_file="$root/selfhost/native/znc.zag"

case ${ZNC_SEED:-} in
    '') seed="$root/znc" ;;
    /*) seed=$ZNC_SEED ;;
    *) seed="$PWD/$ZNC_SEED" ;;
esac

cd "$root"

if [ ! -x "$seed" ]; then
    echo "native bootstrap: seed is not executable: $seed" >&2
    exit 1
fi

tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-native-bootstrap.XXXXXX")
trap 'rm -rf "$tmp"' EXIT HUP INT TERM
mkdir "$tmp/empty-path"

build_stage() {
    compiler=$1
    output=$2
    label=$3
    log="$tmp/$label.log"

    if ! PATH="$tmp/empty-path" "$compiler" "$source_file" -o "$output" >"$log" 2>&1; then
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

echo "── native bootstrap reproducibility (Zag → ELF, empty PATH) ──"
build_stage "$seed" "$tmp/znc-stage1" "seed builds stage 1"
build_stage "$tmp/znc-stage1" "$tmp/znc-stage2" "stage 1 builds stage 2"
build_stage "$tmp/znc-stage2" "$tmp/znc-stage3" "stage 2 builds stage 3"

same_bytes "$seed" "$tmp/znc-stage1" "input seed matches its source rebuild"
same_bytes "$tmp/znc-stage1" "$tmp/znc-stage2" "stage 1 equals stage 2 byte-for-byte"
same_bytes "$tmp/znc-stage2" "$tmp/znc-stage3" "stage 2 equals stage 3 byte-for-byte"

if command -v sha256sum >/dev/null 2>&1; then
    digest=$(sha256sum "$tmp/znc-stage3")
    digest=${digest%% *}
    echo "  sha256  $digest"
fi
echo "════ native bootstrap reproducible: pass=6 fail=0 ════"
