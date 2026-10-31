#!/usr/bin/env bash
# Focused authority for ZagScript semantic views and portable exact reversal.
set -euo pipefail
cd "$(dirname "$0")/.."

compiler=${ZNC:-./znc}
tmp=$(mktemp -d "${TMPDIR:-/tmp}/zag-views.XXXXXX")
trap 'rm -rf "$tmp"' EXIT

compile_and_expect_status() {
    local source=$1 binary=$2 expected=$3 actual
    "$compiler" "$source" -o "$binary" \
        --no-zagd --no-analyze --no-foreground-cache >/dev/null
    set +e
    "$binary" >/dev/null 2>&1
    actual=$?
    set -e
    test "$actual" -eq "$expected"
}

cat >"$tmp/app.zag" <<'ZAG'
script;
let answer: i32 = 40 + 2;
return answer;
ZAG

"$compiler" view "$tmp/app.zag" --level simple --no-zagd >"$tmp/simple"
cmp "$tmp/app.zag" "$tmp/simple"

"$compiler" view "$tmp/app.zag" --level explained --format json --no-zagd >"$tmp/explained"
grep -q '"profile":{"value":"script"' "$tmp/explained"

# Every view level uses the same bounded no-follow source snapshot. Explicit
# rendering must not follow a symlink or accept an oversized root merely
# because it does not publish an output file.
ln -s app.zag "$tmp/app-link.zag"
if "$compiler" view "$tmp/app-link.zag" --level explicit --format json \
    --no-zagd >"$tmp/link-view.out" 2>&1; then
    echo "explicit view followed a source symlink" >&2
    exit 1
fi
grep -q 'source is missing, unsafe, or exceeds the portable source bound' \
    "$tmp/link-view.out"
if "$compiler" expand "$tmp/app-link.zag" --to explicit --no-zagd \
    >"$tmp/link-expand.out" 2>&1; then
    echo "explicit expansion followed a source symlink" >&2
    exit 1
fi
grep -q 'source is missing, unsafe, or exceeds the portable source bound' \
    "$tmp/link-expand.out"
truncate -s 8388609 "$tmp/oversized.zag"
if "$compiler" view "$tmp/oversized.zag" --level explicit --format json \
    --no-zagd >"$tmp/oversized-view.out" 2>&1; then
    echo "explicit view accepted an oversized source" >&2
    exit 1
fi
grep -q 'source is missing, unsafe, or exceeds the portable source bound' \
    "$tmp/oversized-view.out"

"$compiler" view "$tmp/app.zag" --level explicit --format json --no-zagd >"$tmp/explicit"
grep -q '"candidate_compilable":true' "$tmp/explicit"

# A bounded captureless scalar closure is materialized as its parser-hoisted
# declaration before the strict generated body.  This is still deliberately
# narrower than general closure ownership/context equivalence.
cat >"$tmp/closure.zs" <<'ZAG'
script;
let f: fn(i32) i32 = fn[](x: i32) i32 { return x + 40; };
return f(2);
ZAG
"$compiler" view "$tmp/closure.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-view.out"
"$compiler" expand "$tmp/closure.zs" --to explicit \
    --output "$tmp/closure-explicit.zag" --no-zagd >/dev/null
grep -q '^fn __clos_[0-9][0-9]*' "$tmp/closure-explicit.zag"
compile_and_expect_status "$tmp/closure-explicit.zag" "$tmp/closure-explicit" 42
"$compiler" promote "$tmp/closure.zs" --to explicit \
    --output "$tmp/closure-promoted.zag" \
    --test-command "test -s $tmp/closure-promoted.zag" --no-zagd >/dev/null
test -s "$tmp/closure-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-promoted.zag" \
    --output "$tmp/closure-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure.zs" "$tmp/closure-restored.zs"

# A narrowly supported edit to the single-return body of that generated
# captureless closure projects through its exact compact origin. Other
# generated wrapper edits remain conflicts below.
sed -i 's/return x + 40/return x + 41/' "$tmp/closure-promoted.zag"
"$compiler" unexpand "$tmp/closure-promoted.zag" \
    --output "$tmp/closure-projected.zs" --no-zagd >/dev/null
grep -q '^let f: fn(i32) i32 = fn\[\](x: i32) i32 { return x + 41; };$' \
    "$tmp/closure-projected.zs"

# The same fail-closed envelope admits a two-argument captureless scalar
# closure.  Both parameters must be explicit scalar values, and the generated
# declaration must remain an ordinary strict function for checking/execution.
cat >"$tmp/closure-two.zs" <<'ZAG'
script;
let f:fn(i64,i64) i64 = fn[](a:i64,b:i64) i64 { return a + b; };
return f(20,21)+1;
ZAG
"$compiler" view "$tmp/closure-two.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-two-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-two-view.out"
"$compiler" expand "$tmp/closure-two.zs" --to explicit \
    --output "$tmp/closure-two-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(a: i64, b: i64\) i64 \{$' \
    "$tmp/closure-two-explicit.zag"
"$compiler" check "$tmp/closure-two-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-two-explicit.zag" -o "$tmp/closure-two" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-two" >/dev/null 2>&1
closure_two_status=$?
set -e
test "$closure_two_status" -eq 42
"$compiler" promote "$tmp/closure-two.zs" --to explicit \
    --output "$tmp/closure-two-promoted.zag" \
    --test-command "test -s $tmp/closure-two-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-two-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-two-promoted.zag" \
    --output "$tmp/closure-two-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-two.zs" "$tmp/closure-two-restored.zs"

# A nullary captureless scalar closure has no parameter environment at all;
# materializing its literal-only body is therefore the next direct envelope.
cat >"$tmp/closure-zero.zs" <<'ZAG'
script;
let f:fn() i64 = fn[]() i64 { return 41; };
return f()+1;
ZAG
"$compiler" view "$tmp/closure-zero.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-zero-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-zero-view.out"
"$compiler" expand "$tmp/closure-zero.zs" --to explicit \
    --output "$tmp/closure-zero-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(\) i64 \{$' \
    "$tmp/closure-zero-explicit.zag"
grep -q '^    return 41;$' "$tmp/closure-zero-explicit.zag"
"$compiler" check "$tmp/closure-zero-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-zero-explicit.zag" -o "$tmp/closure-zero" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-zero" >/dev/null 2>&1
closure_zero_status=$?
set -e
test "$closure_zero_status" -eq 42
"$compiler" promote "$tmp/closure-zero.zs" --to explicit \
    --output "$tmp/closure-zero-promoted.zag" \
    --test-command "test -s $tmp/closure-zero-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-zero-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-zero-promoted.zag" \
    --output "$tmp/closure-zero-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-zero.zs" "$tmp/closure-zero-restored.zs"

# Boolean captureless closures use a separate pure-expression whitelist. This
# admits only homogeneous bool parameters and !/&&/||/==/!=; the ordinary
# formatter, checker, native compiler, promotion, and exact reversal remain
# authoritative for the generated candidate.
cat >"$tmp/closure-bool.zs" <<'ZAG'
script;
let f:fn(bool) bool = fn[](x:bool) bool { return !x; };
if (f(false)) { return 42; }
return 0;
ZAG
"$compiler" view "$tmp/closure-bool.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-bool-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-bool-view.out"
"$compiler" expand "$tmp/closure-bool.zs" --to explicit \
    --output "$tmp/closure-bool-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(x: bool\) bool \{$' \
    "$tmp/closure-bool-explicit.zag"
grep -q '^    return !x;$' "$tmp/closure-bool-explicit.zag"
"$compiler" check "$tmp/closure-bool-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-bool-explicit.zag" -o "$tmp/closure-bool" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-bool" >/dev/null 2>&1
closure_bool_status=$?
set -e
test "$closure_bool_status" -eq 42
"$compiler" promote "$tmp/closure-bool.zs" --to explicit \
    --output "$tmp/closure-bool-promoted.zag" \
    --test-command "test -s $tmp/closure-bool-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-bool-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-bool-promoted.zag" \
    --output "$tmp/closure-bool-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-bool.zs" "$tmp/closure-bool-restored.zs"

# The bool envelope remains fail-closed for effectful closure bodies.
cat >"$tmp/closure-bool-call.zs" <<'ZAG'
script;
fn flip(value:bool) bool { return !value; }
let f:fn(bool) bool = fn[](x:bool) bool { return flip(x); };
return 0;
ZAG
if "$compiler" expand "$tmp/closure-bool-call.zs" --to explicit \
    --output "$tmp/closure-bool-call-explicit.zag" --no-zagd \
    >"$tmp/closure-bool-call.log" 2>&1; then
    echo "explicit view accepted an effectful bool closure" >&2
    exit 1
fi
grep -q 'closure literals are not yet supported by explicit expansion' \
    "$tmp/closure-bool-call.log"

# A pure f64 closure is the next numeric envelope: literals, parameter names,
# and +/−/* remain syntactically bounded, while the ordinary typed/native path
# owns exact floating-point semantics and diagnostics.
cat >"$tmp/closure-f64.zs" <<'ZAG'
script;
let f:fn(f64) f64 = fn[](x:f64) f64 { return x + 0.5; };
// An explicit result annotation keeps the higher-order call's f64 result
// visible to the typed native checker; an unannotated direct comparison would
// intentionally fall back to the integer default and be rejected as mixed.
let y:f64 = f(41.5);
// The integer argument must widen according to the preserved fn(f64) f64
// signature, and copying the function value must preserve that signature for
// the second indirect call.
let z:f64 = f(41);
let g:fn(f64) f64 = f;
let w:f64 = g(41);
if (y == 42.0 && z == 41.5 && w == 41.5) { return 42; }
return 0;
ZAG
"$compiler" view "$tmp/closure-f64.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-f64-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-f64-view.out"
"$compiler" expand "$tmp/closure-f64.zs" --to explicit \
    --output "$tmp/closure-f64-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(x: f64\) f64 \{$' \
    "$tmp/closure-f64-explicit.zag"
grep -q '^    return x + 0.5;$' "$tmp/closure-f64-explicit.zag"
"$compiler" check "$tmp/closure-f64-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-f64-explicit.zag" -o "$tmp/closure-f64" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-f64" >/dev/null 2>&1
closure_f64_status=$?
set -e
test "$closure_f64_status" -eq 42
# Promotion remains covered by the integer/bool closure fixtures above. The
# f64 arithmetic closure is intentionally execution/view-only here: its float
# operation is outside the prepared semantic-manifest domain, so promotion
# must remain fail-closed rather than manufacturing provenance.

# Division remains outside this proof envelope even though it is pure: the
# generated candidate must not widen the closure grammar without an explicit
# checked floating-point operation contract.
cat >"$tmp/closure-f64-div.zs" <<'ZAG'
script;
let f:fn(f64) f64 = fn[](x:f64) f64 { return x / 2.0; };
return 0;
ZAG
if "$compiler" expand "$tmp/closure-f64-div.zs" --to explicit \
    --output "$tmp/closure-f64-div-explicit.zag" --no-zagd \
    >"$tmp/closure-f64-div.log" 2>&1; then
    echo "explicit view accepted an unproved f64 division closure" >&2
    exit 1
fi
grep -q 'closure literals are not yet supported by explicit expansion' \
    "$tmp/closure-f64-div.log"

# The bounded renderer also admits exactly four homogeneous scalar
# parameters. This exercises the same explicit/promotion/native path while
# keeping eight-or-more-parameter closures outside the bounded proof.
cat >"$tmp/closure-three.zs" <<'ZAG'
script;
let f:fn(i64,i64,i64) i64 = fn[](a:i64,b:i64,c:i64) i64 { return a + b + c; };
return f(13,14,15);
ZAG
"$compiler" view "$tmp/closure-three.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-three-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-three-view.out"
"$compiler" expand "$tmp/closure-three.zs" --to explicit \
    --output "$tmp/closure-three-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(a: i64, b: i64, c: i64\) i64 \{$' \
    "$tmp/closure-three-explicit.zag"
"$compiler" check "$tmp/closure-three-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-three-explicit.zag" -o "$tmp/closure-three" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-three" >/dev/null 2>&1
closure_three_status=$?
set -e
test "$closure_three_status" -eq 42
"$compiler" promote "$tmp/closure-three.zs" --to explicit \
    --output "$tmp/closure-three-promoted.zag" \
    --test-command "test -s $tmp/closure-three-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-three-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-three-promoted.zag" \
    --output "$tmp/closure-three-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-three.zs" "$tmp/closure-three-restored.zs"

cat >"$tmp/closure-four.zs" <<'ZAG'
script;
let f:fn(i64,i64,i64,i64) i64 = fn[](a:i64,b:i64,c:i64,d:i64) i64 { return a + b + c + d; };
return f(10,11,10,11);
ZAG
"$compiler" view "$tmp/closure-four.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-four-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-four-view.out"
"$compiler" expand "$tmp/closure-four.zs" --to explicit \
    --output "$tmp/closure-four-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(a: i64, b: i64, c: i64, d: i64\) i64 \{$' \
    "$tmp/closure-four-explicit.zag"
"$compiler" check "$tmp/closure-four-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-four-explicit.zag" -o "$tmp/closure-four" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-four" >/dev/null 2>&1
closure_four_status=$?
set -e
test "$closure_four_status" -eq 42
"$compiler" promote "$tmp/closure-four.zs" --to explicit \
    --output "$tmp/closure-four-promoted.zag" \
    --test-command "test -s $tmp/closure-four-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-four-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-four-promoted.zag" \
    --output "$tmp/closure-four-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-four.zs" "$tmp/closure-four-restored.zs"

# The bounded explicit renderer also admits exactly five homogeneous scalar
# parameters, matching the direct scalar-call ZIR envelope. Promotion and
# unexpansion must retain the original compact closure bytes.
cat >"$tmp/closure-five.zs" <<'ZAG'
script;
let f:fn(i64,i64,i64,i64,i64) i64 = fn[](a:i64,b:i64,c:i64,d:i64,e:i64) i64 { return a + b + c + d + e; };
return f(8,8,8,9,9);
ZAG
"$compiler" view "$tmp/closure-five.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-five-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-five-view.out"
"$compiler" expand "$tmp/closure-five.zs" --to explicit \
    --output "$tmp/closure-five-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(a: i64, b: i64, c: i64, d: i64, e: i64\) i64 \{$' \
    "$tmp/closure-five-explicit.zag"
"$compiler" check "$tmp/closure-five-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-five-explicit.zag" -o "$tmp/closure-five" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-five" >/dev/null 2>&1
closure_five_status=$?
set -e
test "$closure_five_status" -eq 42
"$compiler" promote "$tmp/closure-five.zs" --to explicit \
    --output "$tmp/closure-five-promoted.zag" \
    --test-command "test -s $tmp/closure-five-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-five-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-five-promoted.zag" \
    --output "$tmp/closure-five-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-five.zs" "$tmp/closure-five-restored.zs"

# Six scalar parameters use the same explicit/promotion/native path as the
# smaller closure envelopes. This is the current upper edge of the direct
# scalar-call proof slice.
cat >"$tmp/closure-six.zs" <<'ZAG'
script;
let f:fn(i64,i64,i64,i64,i64,i64) i64 = fn[](a:i64,b:i64,c:i64,d:i64,e:i64,g:i64) i64 { return a + b + c + d + e + g; };
return f(6,7,8,7,7,7);
ZAG
"$compiler" view "$tmp/closure-six.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-six-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-six-view.out"
"$compiler" expand "$tmp/closure-six.zs" --to explicit \
    --output "$tmp/closure-six-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(a: i64, b: i64, c: i64, d: i64, e: i64, g: i64\) i64 \{$' \
    "$tmp/closure-six-explicit.zag"
"$compiler" check "$tmp/closure-six-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-six-explicit.zag" -o "$tmp/closure-six" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-six" >/dev/null 2>&1
closure_six_status=$?
set -e
test "$closure_six_status" -eq 42
"$compiler" promote "$tmp/closure-six.zs" --to explicit \
    --output "$tmp/closure-six-promoted.zag" \
    --test-command "test -s $tmp/closure-six-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-six-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-six-promoted.zag" \
    --output "$tmp/closure-six-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-six.zs" "$tmp/closure-six-restored.zs"

# Seven scalar parameters cross the System V register boundary and use the
# native indirect-call stack-argument path. The explicit envelope remains
# bounded and source-preserving.
cat >"$tmp/closure-seven.zs" <<'ZAG'
script;
let f:fn(i64,i64,i64,i64,i64,i64,i64) i64 = fn[](a:i64,b:i64,c:i64,d:i64,e:i64,g:i64,h:i64) i64 { return a + b + c + d + e + g + h; };
return f(6,6,6,6,6,6,6);
ZAG
"$compiler" view "$tmp/closure-seven.zs" --level explicit --format json \
    --no-zagd >"$tmp/closure-seven-view.out"
grep -q '"candidate_compilable":true' "$tmp/closure-seven-view.out"
"$compiler" expand "$tmp/closure-seven.zs" --to explicit \
    --output "$tmp/closure-seven-explicit.zag" --no-zagd >/dev/null
grep -Eq '^fn __clos_[0-9]+\(a: i64, b: i64, c: i64, d: i64, e: i64, g: i64, h: i64\) i64 \{$' \
    "$tmp/closure-seven-explicit.zag"
"$compiler" check "$tmp/closure-seven-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/closure-seven-explicit.zag" -o "$tmp/closure-seven" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/closure-seven" >/dev/null 2>&1
closure_seven_status=$?
set -e
test "$closure_seven_status" -eq 42
"$compiler" promote "$tmp/closure-seven.zs" --to explicit \
    --output "$tmp/closure-seven-promoted.zag" \
    --test-command "test -s $tmp/closure-seven-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/closure-seven-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/closure-seven-promoted.zag" \
    --output "$tmp/closure-seven-restored.zs" --no-zagd >/dev/null
cmp "$tmp/closure-seven.zs" "$tmp/closure-seven-restored.zs"

# Eight parameters remain outside the bounded explicit envelope.
cat >"$tmp/closure-eight.zs" <<'ZAG'
script;
let f:fn(i64,i64,i64,i64,i64,i64,i64,i64) i64 = fn[](a:i64,b:i64,c:i64,d:i64,e:i64,g:i64,h:i64,j:i64) i64 { return a + b + c + d + e + g + h + j; };
return 0;
ZAG
if "$compiler" expand "$tmp/closure-eight.zs" --to explicit \
    --output "$tmp/closure-eight-explicit.zag" --no-zagd \
    >"$tmp/closure-eight.log" 2>&1; then
    echo "explicit view accepted an unproved eight-parameter closure" >&2
    exit 1
fi
grep -q 'closure literals are not yet supported by explicit expansion' \
    "$tmp/closure-eight.log"

# Non-scalar parameters remain fail-closed even within the five-parameter
# count because the explicit ownership/layout contract is not established.
cat >"$tmp/closure-five-nonscalar.zs" <<'ZAG'
script;
let f:fn([]u8,i64,i64,i64,i64) i64 = fn[](a:[]u8,b:i64,c:i64,d:i64,e:i64) i64 { return b + c + d + e; };
return 0;
ZAG
if "$compiler" expand "$tmp/closure-five-nonscalar.zs" --to explicit \
    --output "$tmp/closure-five-nonscalar-explicit.zag" --no-zagd \
    >"$tmp/closure-five-nonscalar.log" 2>&1; then
    echo "explicit view accepted a non-scalar five-parameter closure" >&2
    exit 1
fi
grep -q 'closure literals are not yet supported by explicit expansion' \
    "$tmp/closure-five-nonscalar.log"

# A bounded scalar value-capture now reconstructs the closure literal in strict
# source and evaluates the root result before an explicit close. This is the
# only captured-closure envelope in the Script explicit renderer; promotion and
# exact reversal still use the same ledger path as captureless closures.
cat >"$tmp/captured-closure.zs" <<'ZAG'
script;
let base: i32 = 40;
let f: fn(i32) i32 = fn[base](x: i32) i32 { return x + base; };
return f(2);
ZAG
"$compiler" view "$tmp/captured-closure.zs" --level explicit --format json \
    --no-zagd >"$tmp/captured-view.out" 2>"$tmp/captured-view.err"
grep -q '"candidate_compilable":true' "$tmp/captured-view.out"
if grep -q 'unused local `base`' "$tmp/captured-view.err"; then
    echo "captured closure construction was not counted as a read" >&2
    exit 1
fi
"$compiler" expand "$tmp/captured-closure.zs" --to explicit \
    --output "$tmp/captured-explicit.zag" --no-zagd >/dev/null
grep -q 'fn\[base\](x: i32) i32' "$tmp/captured-explicit.zag"
grep -q 'let __zag_hardened_closure_result: i32 = f(2);' \
    "$tmp/captured-explicit.zag"
grep -q '^close(f);$' "$tmp/captured-explicit.zag"
"$compiler" check "$tmp/captured-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/captured-explicit.zag" -o "$tmp/captured-explicit" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/captured-explicit" >/dev/null 2>&1
captured_status=$?
set -e
test "$captured_status" -eq 42
"$compiler" promote "$tmp/captured-closure.zs" --to explicit \
    --output "$tmp/captured-promoted.zag" \
    --test-command "test -s $tmp/captured-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/captured-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/captured-promoted.zag" \
    --output "$tmp/captured-restored.zs" --no-zagd >/dev/null
cmp "$tmp/captured-closure.zs" "$tmp/captured-restored.zs"

# Multiple immutable scalar value-captures use the same bounded strict
# reconstruction envelope. Every captured local must be accounted for as a
# closure read, and the generated literal/result/close sequence must preserve
# both values through execution and exact promotion reversal.
cat >"$tmp/captured-multi.zs" <<'ZAG'
script;
let base: i32 = 40;
let delta: i32 = 2;
let f: fn(i32) i32 = fn[base, delta](x: i32) i32 { return x + base + delta; };
return f(2);
ZAG
"$compiler" view "$tmp/captured-multi.zs" --level explicit --format json \
    --no-zagd >"$tmp/captured-multi-view.out" 2>"$tmp/captured-multi-view.err"
grep -q '"candidate_compilable":true' "$tmp/captured-multi-view.out"
if grep -Eq 'unused local `(base|delta)`' "$tmp/captured-multi-view.err"; then
    echo "multi-capture closure construction was not counted as a read" >&2
    exit 1
fi
"$compiler" expand "$tmp/captured-multi.zs" --to explicit \
    --output "$tmp/captured-multi-explicit.zag" --no-zagd >/dev/null
grep -q 'fn\[base,delta\](x: i32) i32' "$tmp/captured-multi-explicit.zag"
grep -q 'let __zag_hardened_closure_result: i32 = f(2);' \
    "$tmp/captured-multi-explicit.zag"
grep -q '^close(f);$' "$tmp/captured-multi-explicit.zag"
"$compiler" check "$tmp/captured-multi-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/captured-multi-explicit.zag" -o "$tmp/captured-multi-explicit" \
    --no-analyze --no-zagd >/dev/null
set +e
"$tmp/captured-multi-explicit" >/dev/null 2>&1
captured_multi_status=$?
set -e
test "$captured_multi_status" -eq 44
"$compiler" promote "$tmp/captured-multi.zs" --to explicit \
    --output "$tmp/captured-multi-promoted.zag" \
    --test-command "test -s $tmp/captured-multi-promoted.zag" --no-zagd >/dev/null
test -s "$tmp/captured-multi-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/captured-multi-promoted.zag" \
    --output "$tmp/captured-multi-restored.zs" --no-zagd >/dev/null
cmp "$tmp/captured-multi.zs" "$tmp/captured-multi-restored.zs"

# Pointer captures remain fail-closed: they need a v2 lifetime contract rather
# than the scalar value-copy envelope above.
cat >"$tmp/captured-pointer.zs" <<'ZAG'
script;
let base: i32 = 40;
let f: fn(i32) i32 = fn[&base](x: i32) i32 { return x + base; };
return f(2);
ZAG
if "$compiler" view "$tmp/captured-pointer.zs" --level explicit --format json \
    --no-zagd >"$tmp/captured-pointer-view.out" 2>"$tmp/captured-pointer-view.err"; then
    echo "explicit view accepted an unsupported pointer capture" >&2
    exit 1
fi
grep -Eq 'closure literals are not yet supported by explicit expansion|capturing pointer closure requires an explicit v2 lifetime contract' \
    "$tmp/captured-pointer-view.err"

"$compiler" view "$tmp/app.zag" --level native --no-zagd >"$tmp/native"
grep -q '^module {' "$tmp/native"
grep -q 'func.func' "$tmp/native"
grep -q '^// schema=zag-ir-v1 transform=zag-transform-v1' "$tmp/native"
grep -q '^// native-target=linux-x86_64 cpu=' "$tmp/native"
grep -q ' lowering=\(zir-direct\|verified-ast-bridge\) ir-verifier=def-before-use-v1+structured-cf-v1 artifact_ir_consumed=[01]$' \
    "$tmp/native"
grep -q '^// machine-pipeline=regalloc,optimize,peephole raw-instructions=' "$tmp/native"
grep -q '^// x86\[[0-9][0-9]*\] [a-z0-9_][a-z0-9_]* kind=' "$tmp/native"
grep -q '^// machine-code-hex=[0-9a-f][0-9a-f]*$' "$tmp/native"

# The same narrow closure that explicit expansion materializes must resolve its
# immutable function-value binding to the parser-hoisted declaration in the
# native IR view. Capturing, mutable, imported, and mismatched function values
# remain on the checked AST bridge.
"$compiler" view "$tmp/closure.zs" --level native --no-zagd >"$tmp/closure-native"
grep -q 'func.call @__clos_0' "$tmp/closure-native"
! grep -q 'func.call @f' "$tmp/closure-native"

# An explicitly typed immutable function value may also bind an exact
# source-local captureless declaration. The public native view must show the
# declaration target and direct artifact consumption; mismatched/imported or
# captured values remain on the bridge below.
cat >"$tmp/named-function-value.zag" <<'ZAG'
fn wide(x:i64) i64 { return x; }
fn main() i64 { let f:fn(i64) i64=wide; return f(41)+1; }
ZAG
"$compiler" view "$tmp/named-function-value.zag" --level native --no-zagd \
    >"$tmp/named-function-value-native"
grep -q 'func.call @wide' "$tmp/named-function-value-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/named-function-value-native"

# Inferred scalar locals now admit canonical integer arguments through the six
# register Linux x86-64 ABI boundary plus one audited stack argument. The native
# view and executable both have to consume the same typed ZIR call; eight or
# more arguments remain deliberately bridge-only.
cat >"$tmp/native-inferred-ternary-i32.zag" <<'ZAG'
fn add3(a:i32,b:i32,c:i32) i32 { return a+b+c; }
fn main() i32 { let x = add3(13,14,15); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-ternary-i32.zag" --level native \
    --no-zagd >"$tmp/native-inferred-ternary-i32-native"
grep -q 'func.call @add3(%' "$tmp/native-inferred-ternary-i32-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-ternary-i32-native"
"$compiler" "$tmp/native-inferred-ternary-i32.zag" \
    -o "$tmp/native-inferred-ternary-i32" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-ternary-i32" >/dev/null 2>&1
native_inferred_ternary_i32_status=$?
set -e
test "$native_inferred_ternary_i32_status" -eq 42

cat >"$tmp/native-inferred-ternary-i64.zag" <<'ZAG'
fn add3(a:i64,b:i64,c:i64) i64 { return a+b+c; }
fn main() i64 { let x = add3(13,14,15); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-ternary-i64.zag" --level native \
    --no-zagd >"$tmp/native-inferred-ternary-i64-native"
grep -q 'func.call @add3(%' "$tmp/native-inferred-ternary-i64-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-ternary-i64-native"
"$compiler" "$tmp/native-inferred-ternary-i64.zag" \
    -o "$tmp/native-inferred-ternary-i64" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-ternary-i64" >/dev/null 2>&1
native_inferred_ternary_i64_status=$?
set -e
test "$native_inferred_ternary_i64_status" -eq 42

cat >"$tmp/native-inferred-quaternary-i32.zag" <<'ZAG'
fn add4(a:i32,b:i32,c:i32,d:i32) i32 { return a+b+c+d; }
fn main() i32 { let x = add4(10,11,10,11); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-quaternary-i32.zag" --level native \
    --no-zagd >"$tmp/native-inferred-quaternary-i32-native"
grep -q 'func.call @add4(%' "$tmp/native-inferred-quaternary-i32-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-quaternary-i32-native"
"$compiler" "$tmp/native-inferred-quaternary-i32.zag" \
    -o "$tmp/native-inferred-quaternary-i32" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-quaternary-i32" >/dev/null 2>&1
native_inferred_quaternary_i32_status=$?
set -e
test "$native_inferred_quaternary_i32_status" -eq 42

cat >"$tmp/native-inferred-quaternary-i64.zag" <<'ZAG'
fn add4(a:i64,b:i64,c:i64,d:i64) i64 { return a+b+c+d; }
fn main() i64 { let x = add4(10,11,10,11); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-quaternary-i64.zag" --level native \
    --no-zagd >"$tmp/native-inferred-quaternary-i64-native"
grep -q 'func.call @add4(%' "$tmp/native-inferred-quaternary-i64-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-quaternary-i64-native"
"$compiler" "$tmp/native-inferred-quaternary-i64.zag" \
    -o "$tmp/native-inferred-quaternary-i64" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-quaternary-i64" >/dev/null 2>&1
native_inferred_quaternary_i64_status=$?
set -e
test "$native_inferred_quaternary_i64_status" -eq 42

cat >"$tmp/native-inferred-five-arg.zag" <<'ZAG'
fn add5(a:i32,b:i32,c:i32,d:i32,e:i32) i32 { return a+b+c+d+e; }
fn main() i32 { let x = add5(8,8,8,9,9); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-five-arg.zag" --level native \
    --no-zagd >"$tmp/native-inferred-five-arg-native"
grep -q 'func.call @add5(%' "$tmp/native-inferred-five-arg-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-five-arg-native"

cat >"$tmp/native-inferred-six-arg.zag" <<'ZAG'
fn add6(a:i32,b:i32,c:i32,d:i32,e:i32,f:i32) i32 { return a+b+c+d+e+f; }
fn main() i32 { let x = add6(7,7,7,7,7,7); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-six-arg.zag" --level native \
    --no-zagd >"$tmp/native-inferred-six-arg-native"
grep -q 'func.call @add6(%' "$tmp/native-inferred-six-arg-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-six-arg-native"
"$compiler" "$tmp/native-inferred-six-arg.zag" \
    -o "$tmp/native-inferred-six-arg" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-six-arg" >/dev/null 2>&1
native_inferred_six_arg_status=$?
set -e
test "$native_inferred_six_arg_status" -eq 42

cat >"$tmp/native-inferred-six-arg-i64.zag" <<'ZAG'
fn add6(a:i64,b:i64,c:i64,d:i64,e:i64,f:i64) i64 { return a+b+c+d+e+f; }
fn main() i64 { let x = add6(7,7,7,7,7,7); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-six-arg-i64.zag" --level native \
    --no-zagd >"$tmp/native-inferred-six-arg-i64-native"
grep -q 'func.call @add6(%' "$tmp/native-inferred-six-arg-i64-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-six-arg-i64-native"
"$compiler" "$tmp/native-inferred-six-arg-i64.zag" \
    -o "$tmp/native-inferred-six-arg-i64" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-six-arg-i64" >/dev/null 2>&1
native_inferred_six_arg_i64_status=$?
set -e
test "$native_inferred_six_arg_i64_status" -eq 42

# Explicit floating-point calls use the same direct ZIR func.call contract as
# integer calls. Values travel through the internal canonical IEEE-754 bit
# representation, so exercise both f64 and f32 declaration paths and execute
# each artifact rather than relying on a view-only claim.
cat >"$tmp/native-f64-call.zag" <<'ZAG'
fn addf(a:f64,b:f64) f64 { return a+b; }
fn main() i32 { let x:f64 = addf(1.5,2.5); if (x == 4.0) { return 42; } return 1; }
ZAG
"$compiler" view "$tmp/native-f64-call.zag" --level native --no-zagd \
    >"$tmp/native-f64-call-native"
grep -q 'func.call @addf(%' "$tmp/native-f64-call-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-f64-call-native"
"$compiler" "$tmp/native-f64-call.zag" -o "$tmp/native-f64-call" \
    --no-analyze --no-zagd --no-foreground-cache >/dev/null
set +e
"$tmp/native-f64-call" >/dev/null 2>&1
native_f64_call_status=$?
set -e
test "$native_f64_call_status" -eq 42

cat >"$tmp/native-f32-call.zag" <<'ZAG'
fn addf(a:f32,b:f32) f32 { return a+b; }
fn main() i32 { let x:f32 = addf(1.5,2.5); if (x == 4.0) { return 42; } return 1; }
ZAG
"$compiler" view "$tmp/native-f32-call.zag" --level native --no-zagd \
    >"$tmp/native-f32-call-native"
grep -q 'func.call @addf(%' "$tmp/native-f32-call-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-f32-call-native"
"$compiler" "$tmp/native-f32-call.zag" -o "$tmp/native-f32-call" \
    --no-analyze --no-zagd --no-foreground-cache >/dev/null
set +e
"$tmp/native-f32-call" >/dev/null 2>&1
native_f32_call_status=$?
set -e
test "$native_f32_call_status" -eq 42

cat >"$tmp/native-inferred-seven-arg.zag" <<'ZAG'
fn add7(a:i32,b:i32,c:i32,d:i32,e:i32,f:i32,g:i32) i32 { return a+b+c+d+e+f+g; }
fn main() i32 { let x = add7(6,6,6,6,6,6,6); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-seven-arg.zag" --level native \
    --no-zagd >"$tmp/native-inferred-seven-arg-native"
grep -q 'func.call @add7(%' "$tmp/native-inferred-seven-arg-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-seven-arg-native"
"$compiler" "$tmp/native-inferred-seven-arg.zag" \
    -o "$tmp/native-inferred-seven-arg" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-seven-arg" >/dev/null 2>&1
native_inferred_seven_arg_status=$?
set -e
test "$native_inferred_seven_arg_status" -eq 42

cat >"$tmp/native-inferred-seven-arg-i64.zag" <<'ZAG'
fn add7(a:i64,b:i64,c:i64,d:i64,e:i64,f:i64,g:i64) i64 { return a+b+c+d+e+f+g; }
fn main() i64 { let x = add7(6,6,6,6,6,6,6); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-seven-arg-i64.zag" --level native \
    --no-zagd >"$tmp/native-inferred-seven-arg-i64-native"
grep -q 'func.call @add7(%' "$tmp/native-inferred-seven-arg-i64-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-inferred-seven-arg-i64-native"
"$compiler" "$tmp/native-inferred-seven-arg-i64.zag" \
    -o "$tmp/native-inferred-seven-arg-i64" --no-analyze --no-zagd \
    --no-foreground-cache >/dev/null
set +e
"$tmp/native-inferred-seven-arg-i64" >/dev/null 2>&1
native_inferred_seven_arg_i64_status=$?
set -e
test "$native_inferred_seven_arg_i64_status" -eq 42

cat >"$tmp/native-inferred-eight-arg.zag" <<'ZAG'
fn add8(a:i32,b:i32,c:i32,d:i32,e:i32,f:i32,g:i32,h:i32) i32 { return a+b+c+d+e+f+g+h; }
fn main() i32 { let x = add8(5,5,5,5,5,5,6,6); return x; }
ZAG
"$compiler" view "$tmp/native-inferred-eight-arg.zag" --level native \
    --no-zagd >"$tmp/native-inferred-eight-arg-native"
grep -q 'func.call @add8(%' "$tmp/native-inferred-eight-arg-native"
grep -q 'lowering=verified-ast-bridge .*artifact_ir_consumed=0$' \
    "$tmp/native-inferred-eight-arg-native"

# Scalar i32/i64 casts are source-proven by the typed ZIR operation contract
# and use the same sign-extension/truncation normalization as the AST backend.
cat >"$tmp/native-scalar-cast.zag" <<'ZAG'
fn main() i32 {
    let x:i64 = 41;
    return (x as i32)+1;
}
ZAG
"$compiler" view "$tmp/native-scalar-cast.zag" --level native --no-zagd \
    >"$tmp/native-scalar-cast-native"
grep -q 'zag.cast .*: i32' "$tmp/native-scalar-cast-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-scalar-cast-native"

# Floating-point-to-integer casts are now covered by the checked numeric ZIR
# contract alongside scalar integer casts; the native view must report direct
# artifact consumption rather than the retired AST bridge. Execute the
# artifact as well: a bit-copy bug here would turn 41.75 into an unrelated
# integer instead of truncating it toward zero.
cat >"$tmp/native-nonscalar-cast.zag" <<'ZAG'
fn main() i32 {
    let x:f64 = 41.75;
    return x as i32;
}
ZAG
"$compiler" view "$tmp/native-nonscalar-cast.zag" --level native --no-zagd \
    >"$tmp/native-nonscalar-cast-native"
grep -q 'zag.cast .*: i32' "$tmp/native-nonscalar-cast-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-nonscalar-cast-native"
"$compiler" "$tmp/native-nonscalar-cast.zag" -o "$tmp/native-nonscalar-cast" \
    --no-analyze --no-zagd --no-foreground-cache >/dev/null
set +e
"$tmp/native-nonscalar-cast" >/dev/null 2>&1
native_float_to_int_status=$?
set -e
test "$native_float_to_int_status" -eq 41

# Exercise the reverse SSE conversion too. The round trip must preserve an
# exactly representable integer while both casts remain on the direct route.
cat >"$tmp/native-int-float-cast.zag" <<'ZAG'
fn main() i32 {
    let n:i32 = 41;
    let f:f64 = n as f64;
    let back:i32 = f as i32;
    return back;
}
ZAG
"$compiler" view "$tmp/native-int-float-cast.zag" --level native --no-zagd \
    >"$tmp/native-int-float-cast-native"
grep -c 'zag.cast' "$tmp/native-int-float-cast-native" | grep -q '^2$'
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-int-float-cast-native"
"$compiler" "$tmp/native-int-float-cast.zag" -o "$tmp/native-int-float-cast" \
    --no-analyze --no-zagd --no-foreground-cache >/dev/null
set +e
"$tmp/native-int-float-cast" >/dev/null 2>&1
native_int_float_status=$?
set -e
test "$native_int_float_status" -eq 41

# The Script explicit view gets the same scalar cast coverage with portable
# promotion provenance and exact unchanged unexpansion.
cat >"$tmp/script-scalar-cast.zs" <<'ZAG'
script;
let x:i64 = 41;
return (x as i32)+1;
ZAG
"$compiler" expand "$tmp/script-scalar-cast.zs" --to explicit \
    --output "$tmp/script-scalar-cast-explicit.zag" --no-zagd >/dev/null
grep -q 'return x as i32 + 1;' "$tmp/script-scalar-cast-explicit.zag"
"$compiler" check "$tmp/script-scalar-cast-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/script-scalar-cast-explicit.zag" \
    -o "$tmp/script-scalar-cast" --no-analyze --no-zagd >/dev/null
set +e
"$tmp/script-scalar-cast" >/dev/null 2>&1
script_scalar_cast_status=$?
set -e
test "$script_scalar_cast_status" -eq 42
"$compiler" promote "$tmp/script-scalar-cast.zs" --to explicit \
    --output "$tmp/script-scalar-cast-promoted.zag" \
    --test-command "test -s $tmp/script-scalar-cast-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/script-scalar-cast-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/script-scalar-cast-promoted.zag" \
    --output "$tmp/script-scalar-cast-restored.zs" --no-zagd >/dev/null
cmp "$tmp/script-scalar-cast.zs" "$tmp/script-scalar-cast-restored.zs"

# Native ZIR also consumes an exact parser-hoisted captureless closure value
# in a regular strict module. The same name/arity/type proof is required; this
# is distinct from Script expansion, whose context wrapper remains a bridge.
cat >"$tmp/native-closure-function-value.zag" <<'ZAG'
fn main() i32 {
    let f:fn(i32) i32 = fn[](x:i32) i32 { return x + 40; };
    return f(2)+2;
}
ZAG
"$compiler" view "$tmp/native-closure-function-value.zag" --level native \
    --no-zagd >"$tmp/native-closure-function-value-native"
grep -q 'func.call @__clos_0' \
    "$tmp/native-closure-function-value-native"
grep -q 'lowering=zir-direct .*artifact_ir_consumed=1$' \
    "$tmp/native-closure-function-value-native"

# The same narrow source-local captureless function-value domain must survive
# the public Script expansion path.  Expansion retains the declaration and
# immutable binding, the checked candidate executes with the source status,
# and promotion records enough portable provenance for an exact reversal.
cat >"$tmp/named-function-value.zs" <<'ZAG'
script;
fn wide(x:i64) i64 { return x; }
let f:fn(i64) i64 = wide;
return f(41)+1;
ZAG
"$compiler" expand "$tmp/named-function-value.zs" --to explicit \
    --output "$tmp/named-function-value-explicit.zag" --no-zagd >/dev/null
grep -q '^fn wide(x:i64) i64 { return x; }$' \
    "$tmp/named-function-value-explicit.zag"
grep -q 'let f: fn(i64)i64 = wide;' \
    "$tmp/named-function-value-explicit.zag"
"$compiler" check "$tmp/named-function-value-explicit.zag" --no-zagd >/dev/null
"$compiler" "$tmp/named-function-value-explicit.zag" \
    -o "$tmp/named-function-value" --no-analyze --no-zagd >/dev/null
set +e
"$tmp/named-function-value" >/dev/null 2>&1
named_function_value_status=$?
set -e
test "$named_function_value_status" -eq 42
"$compiler" promote "$tmp/named-function-value.zs" --to explicit \
    --output "$tmp/named-function-value-promoted.zag" \
    --test-command "test -s $tmp/named-function-value-promoted.zag" \
    --no-zagd >/dev/null
test -s "$tmp/named-function-value-promoted.zag.zsledger"
"$compiler" unexpand "$tmp/named-function-value-promoted.zag" \
    --output "$tmp/named-function-value-restored.zs" --no-zagd >/dev/null
cmp "$tmp/named-function-value.zs" "$tmp/named-function-value-restored.zs"

# A mismatched function signature remains on the checked AST bridge.  It must
# not be silently widened into the direct named-target ZIR route.
cat >"$tmp/named-function-value-mismatch.zs" <<'ZAG'
script;
fn wide(x:i64) i64 { return x; }
let f:fn(i32) i64 = wide;
return f(41);
ZAG
"$compiler" view "$tmp/named-function-value-mismatch.zs" --level native \
    --no-zagd >"$tmp/named-function-value-mismatch-native"
grep -q 'func.call @f' "$tmp/named-function-value-mismatch-native"
! grep -q 'func.call @wide' "$tmp/named-function-value-mismatch-native"
grep -q 'lowering=verified-ast-bridge' \
    "$tmp/named-function-value-mismatch-native"

# Type-mismatched and captured closure values stay unresolved in the native
# view; the checked AST bridge remains the only fallback for those domains.
cat >"$tmp/mismatched-closure.zs" <<'ZAG'
script;
let f: fn(i64) i64 = fn[](x: i32) i32 { return x + 40; };
return f(2);
ZAG
"$compiler" view "$tmp/mismatched-closure.zs" --level native --no-zagd \
    >"$tmp/mismatched-closure-native"
grep -q 'func.call @f' "$tmp/mismatched-closure-native"
! grep -q 'func.call @__clos_0' "$tmp/mismatched-closure-native"
"$compiler" view "$tmp/captured-closure.zs" --level native --no-zagd \
    >"$tmp/captured-closure-native"
grep -q 'func.call @f' "$tmp/captured-closure-native"
! grep -q 'func.call @__clos_cap_0' "$tmp/captured-closure-native"

# Native instruction view: compile a minimal edition-2027 C ABI export to an ELF
# object and disassemble it to prove machine-instruction output is available.
cat >"$tmp/zag.mod" <<'MOD'
name = "objview"
version = "0"
edition = "2027"
MOD
cat >"$tmp/cabi.zag" <<'ZAG'
pub fn add(a:i64,b:i64)i64 @cabi_export { return a+b; }
ZAG
"$compiler" "$tmp/cabi.zag" --emit-obj -o "$tmp/cabi.o" --no-zagd --no-analyze --no-foreground-cache >"$tmp/cabidump.log" 2>&1
objdump -d "$tmp/cabi.o" >"$tmp/cabi.asm"
grep -q 'add .*%rcx,%rax' "$tmp/cabi.asm"

"$compiler" expand "$tmp/app.zag" --to explicit \
    --output "$tmp/derived-only.zag" --no-zagd >/dev/null
test -s "$tmp/derived-only.zag"
test ! -e "$tmp/derived-only.zag.zsledger"
compile_and_expect_status "$tmp/derived-only.zag" "$tmp/derived-only" 42

# Every helper family must materialize its strict module even when the lowered
# body contains no constructor/helper that happens to be first in the family.
"$compiler" expand tests/script_frontend/list.zag --to explicit \
    --output "$tmp/list-explicit.zag" --no-zagd >/dev/null
grep -q '@import("std:script_list")' "$tmp/list-explicit.zag"
"$compiler" "$tmp/list-explicit.zag" -o "$tmp/list-explicit" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/list-explicit"

cat >"$tmp/path-basename-only.zag" <<'ZAG'
script;
if (!@strEq(path_basename("/tmp/report.json"), "report.json")) { return 1; }
return 0;
ZAG
"$compiler" expand "$tmp/path-basename-only.zag" --to explicit \
    --output "$tmp/path-basename-explicit.zag" --no-zagd >/dev/null
grep -q '@import("std:script_path")' "$tmp/path-basename-explicit.zag"
"$compiler" "$tmp/path-basename-explicit.zag" -o "$tmp/path-basename-explicit" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/path-basename-explicit"

cat >"$tmp/builder-helper-only.zag" <<'ZAG'
script;
let builder = string_builder_from_buffer(null as *i8, 0);
if (string_builder_len(&builder) != 0 ||
    string_builder_failed(&builder) != 0 ||
    string_builder_output(&builder).len != 0) { return 1; }
return 0;
ZAG
"$compiler" expand "$tmp/builder-helper-only.zag" --to explicit \
    --output "$tmp/builder-helper-explicit.zag" --no-zagd >/dev/null
grep -q '@import("std:script_string_builder")' \
    "$tmp/builder-helper-explicit.zag"
"$compiler" "$tmp/builder-helper-explicit.zag" \
    -o "$tmp/builder-helper-explicit" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/builder-helper-explicit"

cat >"$tmp/process-argv-only.zag" <<'ZAG'
script;
let argv = list("explicit-argv");
let result = process_run_argv("/usr/bin/printf", argv, 1000, 64);
if (process_result_state(result) != process_state_exited() ||
    process_result_status(result) != 0 ||
    !@strEq(process_result_output(result), "explicit-argv")) { return 1; }
return 0;
ZAG
"$compiler" expand "$tmp/process-argv-only.zag" --to explicit \
    --output "$tmp/process-argv-explicit.zag" --no-zagd >/dev/null
grep -q '@import("std:process")' "$tmp/process-argv-explicit.zag"
grep -q '@import("std:script_list")' "$tmp/process-argv-explicit.zag"
"$compiler" "$tmp/process-argv-explicit.zag" -o "$tmp/process-argv-explicit" \
    --no-zagd --no-analyze --no-foreground-cache >/dev/null
"$tmp/process-argv-explicit"

"$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/promoted.zag" \
    --test-command "test -s $tmp/promoted.zag" --no-zagd >/dev/null
test -s "$tmp/promoted.zag"
test -s "$tmp/promoted.zag.zsledger"
grep -q '^format=zagscript-derivation-v2$' "$tmp/promoted.zag.zsledger"
grep -q '^complete=true$' "$tmp/promoted.zag.zsledger"
grep -q '^projection=common-prefix-suffix-envelope-with-multiple-unique-line-context-v2$' \
    "$tmp/promoted.zag.zsledger"

# Promotion never overwrites a human-owned output or its provenance.
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/promoted.zag" --test-command true --no-zagd \
    >"$tmp/existing.log" 2>&1; then
    echo "promote overwrote an existing output" >&2
    exit 1
fi
grep -q 'already exists' "$tmp/existing.log"

# A failed parity command leaves neither promoted source nor provenance behind.
if "$compiler" promote "$tmp/app.zag" --to explicit \
    --output "$tmp/failed.zag" --test-command false --no-zagd \
    >"$tmp/failed.log" 2>&1; then
    echo "promote accepted a failing parity command" >&2
    exit 1
fi
grep -q 'parity tests failed' "$tmp/failed.log"
test -s "$tmp/failed.zag"
test ! -e "$tmp/failed.zag.zsledger"

# Provenance is portable and independent of daemon/cache lifetime.
rm -rf "$tmp/.zag-cache"
"$compiler" unexpand "$tmp/promoted.zag" --output "$tmp/restored.zag" --no-zagd >/dev/null
cmp "$tmp/app.zag" "$tmp/restored.zag"
if "$compiler" unexpand "$tmp/promoted.zag" --output "$tmp/restored.zag" \
    --no-zagd >"$tmp/restored-existing.log" 2>&1; then
    echo "unexpand overwrote an existing output" >&2
    exit 1
fi
grep -q 'output already exists' "$tmp/restored-existing.log"

# Appended or truncated ledger data invalidates the complete-record checksum.
cp "$tmp/promoted.zag.zsledger" "$tmp/ledger.saved"
printf 'tampered=true\n' >>"$tmp/promoted.zag.zsledger"
if "$compiler" unexpand "$tmp/promoted.zag" --no-zagd \
    >"$tmp/tampered-ledger.log" 2>&1; then
    echo "unexpand accepted a tampered ledger" >&2
    exit 1
fi
grep -q 'invalid portable derivation ledger' "$tmp/tampered-ledger.log"
mv "$tmp/ledger.saved" "$tmp/promoted.zag.zsledger"

# A localized edit to uniquely preserved body context projects back to compact
# source without carrying generated policy/wrapper code with it.
sed -i 's/let answer: i32 = 40 + 2;/let answer: i32 = 41 + 2;/' "$tmp/promoted.zag"
"$compiler" unexpand "$tmp/promoted.zag" --output "$tmp/projected.zag" \
    --no-zagd >/dev/null
grep -q '^script;$' "$tmp/projected.zag"
grep -q '^let answer: i32 = 41 + 2;$' "$tmp/projected.zag"
! grep -q '__zag_hardened_' "$tmp/projected.zag"

# Generated-only edits have no compact source context and remain conflicts.
"$compiler" promote "$tmp/app.zag" --to explicit --output "$tmp/wrapper.zag" \
    --test-command "test -s $tmp/wrapper.zag" --no-zagd >/dev/null
sed -i 's/Generated by znc harden/Generated by human edit/' "$tmp/wrapper.zag"
if "$compiler" unexpand "$tmp/wrapper.zag" --output "$tmp/conflict.zag" \
    --no-zagd >"$tmp/conflict.log" 2>&1; then
    echo "unexpand accepted a generated-only edit" >&2
    exit 1
fi
grep -q 'structural projection conflict at derived bytes' "$tmp/conflict.log"
test ! -e "$tmp/conflict.zag"

echo "zagscript-views pass=36 fail=0"
