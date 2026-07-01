#!/usr/bin/env bash
# selfhost/oracle/run_diff.sh — differential oracle runner
#
# Compiles a Zag test program two ways and diffs the stdout:
#   1) zagc  (C backend; "ground truth" so long as we trust zagc)
#   2) znc selfhost/oracle/diff_test.zag + the interpreter (new oracle)
#
# If they match, the interpreter is verified for the features that program
# exercises. Each new test in this script adds one feature to the verified
# set. The C backend stays in the tree as the reference; the interpreter
# grows until its verified set covers everything zagc covers, at which
# point zagc can be retired.

set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../.." && pwd)"
ZAGC="${ZAGC:-$ROOT/zagc}"
ZNC="${ZNC:-$ROOT/znc}"
TMP="${TMP:-/tmp}"

# Test source: fib(10). This is the canonical differential test from
# selfhost/codegen_test.zag. As we add features, each gets its own test
# case below; the loop aggregates the result.
FIB_SRC='fn fib(n: i32) i32 { if (n < 2) { return n; } return fib(n - 1) + fib(n - 2); } fn main() void { print_i32(fib(10)); }'

# A second test: simple let + assign + arithmetic, to exercise the let/assign
# paths in the interpreter (fib only exercises params + recursion).
LET_SRC='fn main() void { let x: i32 = 7; let y: i32 = 3; let z: i32 = x * y + 1; print_i32(z); }'

# A third test: if/else, to exercise the has_els path.
IFELSE_SRC='fn pick(n: i32) i32 { if (n > 0) { return 1; } else { return 0 - 1; } } fn main() void { print_i32(pick(5)); print_i32(pick(0 - 3)); }'

# A fourth test: while loop, to exercise the while_ path. sum_to_n(10) = 55
# (same answer as fib(10), but the path is iterative not recursive).
WHILE_SRC='fn sum_to_n(n: i32) i32 { let s: i32 = 0; let i: i32 = 1; while (i <= n) { s = s + i; i = i + 1; } return s; } fn main() void { print_i32(sum_to_n(10)); }'

# A fifth test: i64 type, to exercise type promotion in let. The literal
# `4000000000` is too big for i32; declared as i64, it must round-trip.
I64_SRC='fn main() void { let big: i64 = 4000000000; print_i64(big); }'

# A sixth test: @len on a string literal. Exercises the @len builtin dispatch
# in the interpreter's call handler, plus the heap-allocated string buffer
# the interpreter uses to represent []u8 values.
LEN_SRC='fn main() void { let s: []u8 = "abcde"; print_i32(@len(s)); }'

# A seventh test: while loop with i64 accumulator. Exercises the combination
# of i64 promotion + while + arithmetic, all of which are independently
# verified by the other tests but haven't been tested together.
I64_WHILE_SRC='fn main() void { let s: i64 = 0; let i: i64 = 1; while (i <= 10) { s = s + i; i = i + 1; } print_i64(s); }'

# An eighth test: slice indexing. Reads the 3rd byte of a string literal as
# an i32. The C backend lowers `s[2]` to `s.ptr[2]` for slice bases; the
# interpreter reads from its heap-allocated string buffer.
IDX_SRC='fn main() void { let s: []u8 = "abcde"; print_i32(s[2] as i32); }'

# A ninth test: combination — while loop summing the bytes of a string.
# Exercises idx + while + add in one program, all of which are independently
# verified by the other tests but haven't been tested together.
SUM_BYTES_SRC='fn main() i32 { let s: []u8 = "abc"; let total: i32 = 0; let i: i32 = 0; while (i < @len(s)) { total = total + s[i] as i32; i = i + 1; } print_i32(total); return 0; }'

# A tenth test: .len field access (vs @len builtin). Both should give the
# same result; verifying both forms keeps the slice value representation
# consistent with the C backend's struct-literal lowering.
LEN_FIELD_SRC='fn main() i32 { let s: []u8 = "abcde"; print_i32(s.len); return 0; }'

# (print_str of a string literal is deferred — see interp.zag's emit_str_ln
# comment. Adding a new native-runtime symbol requires hand-tuning in
# selfhost/native/ncodegen.zag's RT_* dispatch table, which is a separate
# piece of work from growing the interpreter.)

PASS=0
FAIL=0
FAILED_TESTS=""

run_test() {
    local name="$1"
    local src="$2"
    local src_file="$TMP/diff_src_$name.zag"
    local zagc_out="$TMP/diff_zagc_$name.txt"
    local interp_out="$TMP/diff_interp_$name.txt"
    local interp_bin="$TMP/diff_interp_$name.bin"

    echo "== differential oracle: $name =="
    printf '%s' "$src" > "$src_file"

    # Path 1: C backend. zagc writes to <src>.out regardless of -o, so we
    # copy the source to a known location and run the resulting binary.
    if ! "$ZAGC" "$src_file" >/dev/null 2>&1; then
        echo "  FAIL: zagc failed to compile $name"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name(zagc)"
        return
    fi
    "$TMP/diff_src_$name.zag.out" > "$zagc_out" 2>&1 || true

    # Path 2: new oracle (interpreter via znc).
    if ! "$ZNC" "$ROOT/selfhost/oracle/diff_test.zag" -o "$interp_bin" >/dev/null 2>&1; then
        echo "  FAIL: znc failed to compile diff_test.zag (interpreter broken)"
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name(znc-interp)"
        return
    fi
    "$interp_bin" < "$src_file" > "$interp_out" 2>&1 || true

    # Compare.
    if diff -q "$zagc_out" "$interp_out" >/dev/null 2>&1; then
        echo "  PASS: stdout matches zagc"
        echo "  --- zagc stdout ---"
        sed 's/^/    /' "$zagc_out"
        echo "  --- interp stdout ---"
        sed 's/^/    /' "$interp_out"
        echo
        PASS=$((PASS + 1))
    else
        echo "  FAIL: stdout diverges"
        echo "  --- zagc ---"
        sed 's/^/    /' "$zagc_out"
        echo "  --- interp ---"
        sed 's/^/    /' "$interp_out"
        echo "  --- diff ---"
        diff "$zagc_out" "$interp_out" | sed 's/^/    /' | head -20
        echo
        FAIL=$((FAIL + 1))
        FAILED_TESTS="$FAILED_TESTS $name(divergence)"
    fi
}

run_test "fib"      "$FIB_SRC"
run_test "let_arith" "$LET_SRC"
run_test "ifelse"    "$IFELSE_SRC"
run_test "while"     "$WHILE_SRC"
run_test "i64"       "$I64_SRC"
run_test "len"       "$LEN_SRC"
run_test "i64_while" "$I64_WHILE_SRC"
run_test "idx"       "$IDX_SRC"
run_test "sum_bytes" "$SUM_BYTES_SRC"
run_test "len_field" "$LEN_FIELD_SRC"

echo "============================================"
echo "differential oracle: $PASS passed, $FAIL failed"
if [[ "$FAIL" -gt 0 ]]; then
    echo "failed:$FAILED_TESTS"
    exit 1
fi
echo "all oracle tests passed"
