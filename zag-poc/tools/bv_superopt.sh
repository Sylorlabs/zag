#!/usr/bin/env bash
# Offline bit-vector superoptimization explorer for pure, wrapping integers.
# A candidate is accepted only when Z3 proves the negation of equivalence UNSAT.
# No compiler/backend rewrite is enabled by this tool.
set -euo pipefail
export LC_ALL=C

usage() {
    echo "usage: $0 {prove|search} {8|16|32|64} 'postfix reference' ['postfix candidate'] [--proof-file path]" >&2
    exit 2
}
die() { echo "bv-superopt: $*" >&2; exit 2; }

[[ $# -ge 3 ]] || usage
mode=$1
bits=$2
reference=$3
shift 3
case "$bits" in
    8) max=255 ;;
    16) max=65535 ;;
    32) max=4294967295 ;;
    64) max=18446744073709551615 ;;
    *) die "unsupported bit width (use 8, 16, 32 or 64)" ;;
esac
case "$mode" in
    prove) [[ $# -ge 1 ]] || usage; candidate=$1; shift ;;
    search) candidate='';;
    *) usage ;;
esac
proof_file=''
if [[ $# -ne 0 ]]; then
    [[ $# -eq 2 && $1 == '--proof-file' && -n $2 ]] || usage
    proof_file=$2
fi
solver=${Z3:-z3}
command -v "$solver" >/dev/null 2>&1 || die "Z3 not found: $solver"
# Z3 -T is a process time bound in seconds. Unknown/timeout/errors fail closed.
timeout=${BV_SUPEROPT_TIMEOUT:-5}
[[ "$timeout" =~ ^[1-9][0-9]*$ && ${#timeout} -le 3 ]] || die "invalid BV_SUPEROPT_TIMEOUT"

temp=$(mktemp -d "${TMPDIR:-/tmp}/zag-bv-superopt.XXXXXX")
trap 'rm -rf "$temp"' EXIT

# Parse the same pure postfix subset as ScriptAuto, at native bit widths.
# Reject all unknown operations, out-of-range literals, and malformed stacks.
# No shell or SMT syntax supplied by the expression can enter the query.
BV_AST=''
BV_COST=0
parse_expr() {
    local expr=$1 token instruction a b n
    local -a tokens=() stack=()
    [[ -n $expr && $expr != *$'\n'* && $expr != *$'\r'* ]] || return 1
    read -r -a tokens <<< "$expr"
    [[ ${#tokens[@]} -gt 0 && ${#tokens[@]} -le 31 ]] || return 1
    for token in "${tokens[@]}"; do
        case "$token" in
            x|y) stack+=("$token"); continue ;;
            '+') instruction=bvadd ;;
            '-') instruction=bvsub ;;
            '*') instruction=bvmul ;;
            '&') instruction=bvand ;;
            '|') instruction=bvor ;;
            '^') instruction=bvxor ;;
            *)
                [[ $token =~ ^(0|[1-9][0-9]*)$ ]] || return 1
                [[ ${#token} -le ${#max} ]] || return 1
                if [[ ${#token} -eq ${#max} && $token > $max ]]; then return 1; fi
                stack+=("(_ bv$token $bits)")
                continue
                ;;
        esac
        n=${#stack[@]}
        [[ $n -ge 2 ]] || return 1
        a=${stack[$((n - 2))]}
        b=${stack[$((n - 1))]}
        stack=("${stack[@]:0:$((n - 2))}" "($instruction $a $b)")
    done
    [[ ${#stack[@]} -eq 1 ]] || return 1
    BV_AST=${stack[0]}
    BV_COST=${#tokens[@]}
}

parse_expr "$reference" || die "invalid reference expression"
reference_ast=$BV_AST
reference_cost=$BV_COST
if [[ $mode == prove ]]; then
    parse_expr "$candidate" || die "invalid candidate expression"
fi

# Single, reproducible QF_BV query, no assumptions about inputs.
make_query() {
    local left=$1 right=$2 target=$3
    {
        printf '(set-logic QF_BV)\n'
        printf '(set-option :produce-models true)\n'
        printf '(declare-fun x () (_ BitVec %s))\n' "$bits"
        printf '(declare-fun y () (_ BitVec %s))\n' "$bits"
        printf '(assert (not (= %s %s)))\n' "$left" "$right"
        printf '(check-sat)\n'
    } > "$target"
}

checked=0
BV_STATUS=''
check_equivalence() {
    local left=$1 right=$2 output rc=0
    make_query "$left" "$right" "$temp/query.smt2"
    output=$("$solver" "-T:$timeout" "$temp/query.smt2" 2>"$temp/solver.err") || rc=$?
    [[ $rc -eq 0 ]] || die "solver failed (status $rc): $(cat "$temp/solver.err")"
    case "$output" in
        unsat|sat) BV_STATUS=$output ;;
        unknown) die "Z3 returned unknown (budget exhausted or unsupported query)" ;;
        *) die "unexpected Z3 response: $output $(cat "$temp/solver.err")" ;;
    esac
    checked=$((checked + 1))
}

# When proving arbitrary candidates, SAT is an actual counterexample, not a
# qualified optimization. Request model values only after confirmed SAT.
if [[ $mode == prove ]]; then
    check_equivalence "$reference_ast" "$BV_AST"
    if [[ -n $proof_file ]]; then cp "$temp/query.smt2" "$proof_file"; fi
    printf 'width=%s\nreference=%s\ncandidate=%s\nresult=%s\n' "$bits" "$reference" "$candidate" "$BV_STATUS"
    if [[ $BV_STATUS == unsat ]]; then
        echo 'equivalent=yes'
        exit 0
    fi
    printf '(get-value (x y))\n' >> "$temp/query.smt2"
    rc=0
    model=$("$solver" "-T:$timeout" "$temp/query.smt2" 2>"$temp/model.err") || rc=$?
    [[ $rc -eq 0 ]] || die "solver model failed (status $rc): $(cat "$temp/model.err")"
    printf 'counterexample=%s\n' "$model"
    exit 1
fi

# Bounded cost grammar: six leaves and all ordered pairs combined with six
# operators. Selection minimizes postfix nodes, then enumeration order.
# Semantic proof ranges over ALL 2^(bits*2) inputs, symbolically via QF_BV.
# "Best" applies only to this grammar and node-count cost, never machine cycles.
selected=$reference
selected_ast=$reference_ast
selected_cost=$reference_cost
selected_kind=reference
leaves=(0 1 2 "$max" x y)

if [[ $reference_cost -gt 1 ]]; then
    for leaf in "${leaves[@]}"; do
        parse_expr "$leaf" || die "internal leaf invalid: $leaf"
        check_equivalence "$reference_ast" "$BV_AST"
        if [[ $BV_STATUS == unsat ]]; then
            selected=$leaf
            selected_ast=$BV_AST
            selected_cost=1
            selected_kind=leaf
            break
        fi
    done
fi

if [[ $selected_kind == reference && $reference_cost -gt 3 ]]; then
    for op in + - '*' '&' '|' '^'; do
        for left in "${leaves[@]}"; do
            for right in "${leaves[@]}"; do
                expr="$left $right $op"
                parse_expr "$expr" || die "internal candidate invalid: $expr"
                check_equivalence "$reference_ast" "$BV_AST"
                if [[ $BV_STATUS == unsat ]]; then
                    selected=$expr
                    selected_ast=$BV_AST
                    selected_cost=3
                    selected_kind=binary
                    break 3
                fi
            done
        done
    done
fi

# Always re-verify the selected candidate and record a replayable query.
check_equivalence "$reference_ast" "$selected_ast"
[[ $BV_STATUS == unsat ]] || die "final candidate proof failed: $BV_STATUS"
if [[ -n $proof_file ]]; then cp "$temp/query.smt2" "$proof_file"; fi
printf 'width=%s\nreference=%s\nselected=%s\noriginal_nodes=%s\nselected_nodes=%s\nselection=%s\nchecked=%s\nproof=unsat\n' \
    "$bits" "$reference" "$selected" "$reference_cost" "$selected_cost" "$selected_kind" "$checked"
echo 'scope=pure-unsigned-wrapping-bv; grammar=leaf-or-binary-leaves; cost=postfix-nodes'

