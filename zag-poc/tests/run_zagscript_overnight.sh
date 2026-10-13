#!/usr/bin/env bash
# Resumable long-horizon Zag/ZagScript verification driver.
set -eu

cd "$(dirname "$0")/.."

state_dir=${ZAGSCRIPT_OVERNIGHT_STATE:-"$PWD/.zagscript-overnight"}
mkdir -p "$state_dir/logs"

fingerprint_file="$state_dir/source.sha256"
current_fingerprint=$(
    find selfhost std tests -type f \( -name '*.zag' -o -name '*.sh' -o -name '*.tsv' \) -print0 \
        | LC_ALL=C sort -z \
        | xargs -0 shasum -a 256 \
        | shasum -a 256 \
        | awk '{print $1}'
)
old_fingerprint=
if [ -f "$fingerprint_file" ]; then old_fingerprint=$(cat "$fingerprint_file"); fi
if [ "$old_fingerprint" != "$current_fingerprint" ]; then
    find "$state_dir" -maxdepth 1 -type f \( -name '*.done' -o -name '*.failed' \) -delete
    printf '%s\n' "$current_fingerprint" >"$fingerprint_file"
fi

phase() {
    name=$1
    shift
    done_file="$state_dir/$name.done"
    failed_file="$state_dir/$name.failed"
    log="$state_dir/logs/$name.log"
    if [ -f "$done_file" ]; then
        echo "== overnight: $name already verified =="
        return 0
    fi
    echo "== overnight: $name =="
    rm -f "$failed_file"
    set +e
    "$@" >"$log" 2>&1
    rc=$?
    set -e
    if [ "$rc" -ne 0 ]; then
        printf '%s\n' "$rc" >"$failed_file"
        cat "$log"
        echo "overnight phase failed: $name rc=$rc" >&2
        return "$rc"
    fi
    : >"$done_file"
    cat "$log"
}

phase bootstrap env ZAG_BOOTSTRAP_MEMORY_GUARD=off bash bootstrap.sh

export ZNC=${ZNC:-"$PWD/znc-macos-arm64"}
export ZAGD=${ZAGD:-"$PWD/zagd-macos-arm64"}
if [ ! -x "$ZNC" ]; then export ZNC="$PWD/znc"; fi
if [ ! -x "$ZAGD" ]; then export ZAGD="$PWD/zagd"; fi

phase profile-separation bash tests/run_zag_zagscript_separation.sh
if [ -f tests/run_language_design_debt_guards.sh ]; then
    phase design-debt bash tests/run_language_design_debt_guards.sh
fi
phase completion bash tests/run_zagscript_1_0_completion.sh
if [ -f tests/run_zagscript_gap_audit.sh ]; then
    phase gap-audit bash tests/run_zagscript_gap_audit.sh
fi
phase matrix-selftest bash tests/run_zagscript_1_0_matrix_selftest.sh
phase release-matrix bash tests/run_zagscript_1_0_matrix.sh --release
phase diff-check git diff --check

echo 'Zag/ZagScript overnight verification: PASS'
