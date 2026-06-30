#!/usr/bin/env bash
# Integration gate: compile and run every programs/*.zag example, checking exit
# codes and expected stdout substrings (not just "ran without crashing").
set -euo pipefail
cd "$(dirname "$0")/.."

ZNC=${ZNC:-./znc}
case "$ZNC" in
    /*) ;;
    *) ZNC="$PWD/${ZNC#./}" ;;
esac
tmp=$(mktemp -d /tmp/zag-programs.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

# run_prog <name> <want_exit> <substring>...
run_prog() {
    local name=$1
    local want_exit=$2
    shift 2

    if ! "$ZNC" "programs/$name.zag" -o "$tmp/$name" >/dev/null 2>&1; then
        echo "  XX  $name (compile failed)"
        fail=$((fail + 1))
        return
    fi

    local out ec
    out=$("$tmp/$name" 2>&1) || true
    ec=$?

    if [ "$ec" != "$want_exit" ]; then
        echo "  XX  $name (exit $ec, want $want_exit)"
        fail=$((fail + 1))
        return
    fi

    local sub
    for sub in "$@"; do
        if [[ "$out" != *"$sub"* ]]; then
            echo "  XX  $name (missing stdout: $sub)"
            fail=$((fail + 1))
            return
        fi
    done

    echo "  ok  $name"
    pass=$((pass + 1))
}

echo "── programs integration gate ──"

run_prog arena 0 \
    "1000 objects in-range: PASS" \
    "reset: PASS" \
    "free_all: PASS"

run_prog csv_parser 0 \
    "Parsed rows = 6" \
    "Parsed cols = 4" \
    "[2,2]='Los Angeles, CA' (quoted): PASS"

run_prog hash_map 0 \
    "lookup all 20: PASS" \
    "deletion confirmed: PASS" \
    "tombstone reuse: PASS"

run_prog json_parser 0 \
    "=> Parse OK" \
    "12345 -> 12345" \
    "null -> null"

run_prog sort_bench 0 \
    "sorted: PASS" \
    "QS == MS: PASS" \
    "LCG i32 wrap: PASS"

run_prog state_machine 0 \
    "final state (Green after 10 ticks): PASS" \
    "final state (Ident for 'world'): PASS" \
    "stayed in Ident: PASS"

echo "════ programs pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]