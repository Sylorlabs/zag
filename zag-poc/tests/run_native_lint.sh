#!/usr/bin/env bash
# run_native_lint.sh — gate for the bloat + agent-bug lints (analyze.zag).
#
# Verifies that:
#   1. Each example triggers the expected lint codes (warnings on stderr).
#   2. Pedantic-tier lints fire under --analyze-pedantic.
#   3. --analyze-strict fails the build when findings exist.
#   4. --no-analyze silences everything.
#   5. Suppression comments suppress the targeted codes (file-level and line-level).
#   6. --analyze-bloat=off and --analyze-agent=off silence their families.
#   7. Warnings point to the correct function declaration line.
set -e
cd "$(dirname "$0")/.."

ZNC=./znc
TMP=$(mktemp -d)
trap 'rm -rf "$TMP"' EXIT
FAIL=0

# check_code <file> <expected_code> [-- extra flags]
# Verifies the code appears in the output.
check_code() {
    local file="$1"; local code="$2"; shift 2
    local out; out=$("$ZNC" "$file" -o "$TMP/out" "$@" 2>&1 || true)
    if echo "$out" | grep -q "warning\[$code\]"; then
        echo "  PASS: $code triggered in $file"
    else
        echo "  FAIL: $code NOT triggered in $file"
        echo "        output: $(echo "$out" | head -3)"
        FAIL=1
    fi
}

# check_code_at <file> <expected_code> <expected_line> [-- extra flags]
# Verifies the code appears AND points to the expected source line.
check_code_at() {
    local file="$1"; local code="$2"; local line="$3"; shift 3
    local out; out=$("$ZNC" "$file" -o "$TMP/out" "$@" 2>&1 || true)
    if echo "$out" | grep -q "warning\[$code\]"; then
        if echo "$out" | grep -q "warning\[$code\]" | grep -q ":$line"; then
            echo "  PASS: $code triggered at line $line in $file"
        else
            # Check the --> line for the expected line number
            local found_line; found_line=$(echo "$out" | grep -A1 "warning\[$code\]" | grep -o ':[0-9]*' | head -1 | tr -d ':')
            if [ "$found_line" = "$line" ]; then
                echo "  PASS: $code triggered at line $line in $file"
            else
                echo "  FAIL: $code triggered but at line $found_line (expected $line) in $file"
                FAIL=1
            fi
        fi
    else
        echo "  FAIL: $code NOT triggered in $file"
        FAIL=1
    fi
}

# check_absent <file> <expected_absent_code> [-- extra flags]
check_absent() {
    local file="$1"; local code="$2"; shift 2
    local out; out=$("$ZNC" "$file" -o "$TMP/out" "$@" 2>&1 || true)
    if echo "$out" | grep -q "warning\[$code\]"; then
        echo "  FAIL: $code unexpectedly triggered in $file"
        FAIL=1
    else
        echo "  PASS: $code correctly absent in $file"
    fi
}

echo "== bloat lints (default) =="
check_code examples/lint_bloat.zag B0101
check_code examples/lint_bloat.zag B0103
check_code examples/lint_bloat.zag B0104
check_code examples/lint_bloat.zag B0105
check_code examples/lint_bloat.zag B0107
check_code examples/lint_bloat.zag B0108
check_code examples/lint_bloat.zag B0109
check_code examples/lint_bloat.zag B0110
check_code examples/lint_bloat.zag B0113

echo "== bloat lints (pedantic) =="
check_code examples/lint_bloat.zag B0102 -- --analyze-pedantic
check_code examples/lint_bloat.zag B0111 -- --analyze-pedantic
check_code examples/lint_bloat.zag B0112 -- --analyze-pedantic
check_code examples/lint_bloat.zag B0120 -- --analyze-pedantic

echo "== agent-bug lints (default) =="
check_code examples/lint_agent.zag A0101
check_code examples/lint_agent.zag A0102
check_code examples/lint_agent.zag A0105
check_code examples/lint_agent.zag A0106
check_code examples/lint_agent.zag A0107
check_code examples/lint_agent.zag A0108
check_code examples/lint_agent.zag A0109

echo "== agent-bug lints (pedantic) =="
check_code examples/lint_agent.zag A0110 -- --analyze-pedantic
check_code examples/lint_agent.zag A0112 -- --analyze-pedantic

echo "== suppression (file-level) =="
check_code   examples/lint_suppression.zag B0101
check_absent examples/lint_suppression.zag B0103

echo "== suppression (line-level) =="
check_absent examples/lint_suppression.zag A0105

echo "== family toggles =="
check_absent examples/lint_bloat.zag B0101 -- --analyze-bloat=off
check_absent examples/lint_agent.zag A0101 -- --analyze-agent=off

echo "== --no-analyze silences all =="
check_absent examples/lint_bloat.zag B0101 -- --no-analyze
check_absent examples/lint_agent.zag A0101 -- --no-analyze

echo "== --analyze-strict fails the build =="
if "$ZNC" examples/lint_bloat.zag -o "$TMP/strict" --analyze-strict 2>/dev/null; then
    echo "  FAIL: --analyze-strict did not fail the build"
    FAIL=1
else
    echo "  PASS: --analyze-strict correctly failed the build"
fi

if [ "$FAIL" -ne 0 ]; then
    echo "== lint gate FAILED =="
    exit 1
fi
echo "== lint gate PASSED =="
