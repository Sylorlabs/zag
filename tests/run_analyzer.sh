#!/usr/bin/env bash
# tests/run_analyzer.sh — regression tests for the static analyzer (analyze.zag).
#
# The analyzer runs by default on every build/check and emits leak (L00xx) and
# efficiency (E01xx) WARNINGS to stderr. These tests assert that:
#   * genuine leaks and inefficiencies are reported,
#   * correct code (frees / returns / ownership transfer) is NOT flagged,
#   * the --no-analyze / --analyze-strict / --analyze-pedantic flags work.
#
# The ONLY supported compiler is ./znc (the native ELF backend).
#
# Exit: 0 = all passed, 1 = at least one mismatch.
set -uo pipefail
cd "$(dirname "$0")/.."

ZNC="${ZNC:-./znc}"
DIR=tests/analyzer

if [ ! -x "$ZNC" ]; then
    echo "run_analyzer: $ZNC not found or not executable" >&2
    exit 1
fi

pass=0
fail=0

# check_has <label> <expected-substring> <cmd...>
check_has() {
    local label="$1"; local want="$2"; shift 2
    local out; out="$("$@" 2>&1)"
    if printf '%s' "$out" | grep -qF "$want"; then
        echo "  ok    $label  (found: $want)"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label  (expected to find: $want)"
        printf '%s\n' "$out" | sed 's/^/        /'
        fail=$((fail + 1))
    fi
}

# check_absent <label> <forbidden-substring> <cmd...>
check_absent() {
    local label="$1"; local no="$2"; shift 2
    local out; out="$("$@" 2>&1)"
    if printf '%s' "$out" | grep -qF "$no"; then
        echo "  FAIL  $label  (did not expect: $no)"
        printf '%s\n' "$out" | sed 's/^/        /'
        fail=$((fail + 1))
    else
        echo "  ok    $label  (absent: $no)"
        pass=$((pass + 1))
    fi
}

# check_rc <label> <expected-rc> <cmd...>
check_rc() {
    local label="$1"; local want="$2"; shift 2
    "$@" >/dev/null 2>&1
    local got=$?
    if [ "$got" -eq "$want" ]; then
        echo "  ok    $label  (exit $got)"
        pass=$((pass + 1))
    else
        echo "  FAIL  $label  (exit $got, expected $want)"
        fail=$((fail + 1))
    fi
}

# ── leak detection ────────────────────────────────────────────────────────────
check_has    "leak_basic → L0001"       "warning[L0001]" "$ZNC" check "$DIR/leak_basic.zag"
check_has    "leak_discard → L0002"     "warning[L0002]" "$ZNC" check "$DIR/leak_discard.zag"

# ── efficiency lints ──────────────────────────────────────────────────────────
check_has    "ineff → E0101 (identity)" "warning[E0101]" "$ZNC" check "$DIR/ineff.zag"
check_has    "ineff → E0102 (const-0)"  "warning[E0102]" "$ZNC" check "$DIR/ineff.zag"

# ── no false positives on correct code ────────────────────────────────────────
check_absent "clean has no warnings"    "warning["       "$ZNC" check "$DIR/clean.zag"

# ── flags ─────────────────────────────────────────────────────────────────────
check_absent "--no-analyze silences"    "warning["       "$ZNC" check "$DIR/leak_basic.zag" --no-analyze
check_rc     "--analyze-strict fails"   1                "$ZNC" check "$DIR/leak_basic.zag" --analyze-strict
check_absent "pedantic off: no E0103"   "warning[E0103]" "$ZNC" check "$DIR/pedantic.zag"
check_has    "--analyze-pedantic: E0103" "warning[E0103]" "$ZNC" check "$DIR/pedantic.zag" --analyze-pedantic

echo "════ analyzer pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
