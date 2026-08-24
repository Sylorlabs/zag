#!/usr/bin/env bash
# Validate matrix syntax and generated documentation.
#
# --verify-evidence executes each distinct evidence script named by a supported
# row. --release enforces zero partial/unavailable rows for an aggregate gate
# that already runs those suites once. --release-evidence combines both checks
# for a standalone matrix release audit. Its completeness check runs first so an
# intentionally incomplete development matrix does not start expensive suites.
set -euo pipefail
cd "$(dirname "$0")/.."
matrix=tests/zagscript_1_0_capabilities.tsv

release=0
verify_evidence=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --release)
            release=1
            ;;
        --release-evidence)
            release=1
            verify_evidence=1
            ;;
        --verify-evidence)
            verify_evidence=1
            ;;
        --help)
            printf '%s\n' \
                'usage: bash tests/run_zagscript_1_0_matrix.sh [--verify-evidence] [--release|--release-evidence]' \
                '  --verify-evidence  run each distinct supported-row evidence script' \
                '  --release          require zero gaps; aggregate gate runs suites once' \
                '  --release-evidence require zero gaps, then verify executable evidence'
            exit 0
            ;;
        *)
            printf 'unknown ZagScript matrix option: %s\n' "$1" >&2
            exit 2
            ;;
    esac
    shift
done

if [[ ${ZAGSCRIPT_MATRIX_EVIDENCE_ACTIVE:-0} == 1 ]]; then
    echo 'recursive ZagScript matrix validation from an evidence script refused' >&2
    exit 1
fi

test "$(head -n 1 "$matrix")" = $'area\tcapability\tstatus\tevidence_or_blocker'

# Freeze the 1.0 contract independently from the status/evidence columns.  A
# release must close the agreed rows; deleting or renaming hard rows is not a
# way to make the partial/unavailable counters reach zero.
diff -u <(cat <<'ROWS'
frontend	shared Script profile parser and generated entry
frontend	lossless indentation-aware CST with stable spans
frontend	Python-shaped indentation convenience
frontend	Unicode and malformed-input recovery
language	static types functions records enums generics and errors
language	closures and bounded escape diagnostics
language	lists maps sets iterators ranges and Unicode strings
language	async await and cancellation
ir	one typed SSA IR is production authority
ir	effects ownership aliases lifetimes layouts and origins in IR
views	simple exact compact-source view
views	explained typed effect and policy view
views	explicit compilable strict-Zag expansion
views	native typed IR and instruction view
reversal	portable exact unchanged unexpansion
reversal	structural three-way edit projection
runtime	bounded allocator and deterministic shutdown
runtime	files paths environment and processes
runtime	JSON and CSV
runtime	TCP UDP DNS TLS HTTP and WebSocket
runtime	async epoll worker pools channels and synchronization
runtime	dynamic loading callbacks aggregates and database drivers
packages	deterministic lockfiles checksums offline vendor signatures and registry
daemon	stable snapshots invalidation singleton and foreground fallback
daemon	typed semantic region extraction and equality saturation
optimization	proof certificates and foreground differential validation
optimization	confidence-gated benchmark selection with no regressions
generation	sandboxed optimizer generation promotion and rollback
deployment	static Linux x86-64 native executable authority
deployment	clean bootstrap fixpoint and empty-PATH reproduction
applications	required native reference application suite
release	zero partial or unavailable ZagScript 1.0 rows
ROWS
) <(awk -F '\t' 'NR > 1 { print $1 "\t" $2 }' "$matrix")

awk -F '\t' '
    NR == 1 { next }
    NF != 4 { printf "invalid matrix row %d: expected 4 fields\n", NR > "/dev/stderr"; bad=1 }
    $3 != "supported" && $3 != "partial" && $3 != "unavailable" {
        printf "invalid matrix status on row %d: %s\n", NR, $3 > "/dev/stderr"; bad=1
    }
    END { exit bad }
' "$matrix"

# A supported row must name a real executable authority, never prose alone.
# The matrix validator and aggregate release gate are forbidden evidence: either
# would let status bookkeeping prove itself or recursively launch the complete
# release gate from inside one of its own rows.
declare -a evidence_scripts=()
declare -A evidence_seen=()
while IFS=$'\t' read -r area capability status evidence; do
    [[ $status == supported ]] || continue
    case "$evidence" in
        tests/*.sh)
            if [[ $evidence == *'/../'* || $evidence == *'/./'* ||
                  $evidence == *'//' || -L $evidence ||
                  ! -f $evidence || ! -x $evidence ]]; then
                printf 'supported row lacks executable evidence: %s / %s -> %s\n' \
                    "$area" "$capability" "$evidence" >&2
                exit 1
            fi
            ;;
        *)
            printf 'supported row names non-executable evidence: %s / %s -> %s\n' \
                "$area" "$capability" "$evidence" >&2
            exit 1
            ;;
    esac
    case "$evidence" in
        tests/run_zagscript_1_0_matrix.sh|\
        tests/run_zagscript_1_0_matrix_selftest.sh|\
        tests/run_zagscript_release_gate.sh|\
        tests/run_zagscript_master_gate.sh)
            printf 'supported row names recursive/self-authorizing evidence: %s / %s -> %s\n' \
                "$area" "$capability" "$evidence" >&2
            exit 1
            ;;
    esac
    if [[ ! ${evidence_seen[$evidence]+present} ]]; then
        evidence_seen[$evidence]=1
        evidence_scripts+=("$evidence")
    fi
done < <(tail -n +2 "$matrix")
diff -u docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md \
    <(bash tests/generate_zagscript_1_0_matrix.sh)

supported=$(awk -F '\t' '$3 == "supported" { n++ } END { print n+0 }' "$matrix")
partial=$(awk -F '\t' '$3 == "partial" { n++ } END { print n+0 }' "$matrix")
unavailable=$(awk -F '\t' '$3 == "unavailable" { n++ } END { print n+0 }' "$matrix")
printf 'zagscript-1.0-matrix supported=%s partial=%s unavailable=%s\n' \
    "$supported" "$partial" "$unavailable"

if [[ $release -eq 1 && ( $partial -ne 0 || $unavailable -ne 0 ) ]]; then
    echo 'ZagScript 1.0 release refused: every frozen capability row must be supported' >&2
    exit 1
fi

if [[ $verify_evidence -eq 1 ]]; then
    passed=0
    total=${#evidence_scripts[@]}
    for evidence in "${evidence_scripts[@]}"; do
        printf '\342\224\200\342\224\200 matrix evidence [%s/%s] %s\n' "$((passed + 1))" "$total" "$evidence"
        if ZAGSCRIPT_MATRIX_EVIDENCE_ACTIVE=1 bash "$evidence"; then
            passed=$((passed + 1))
        else
            status=$?
            printf 'supported evidence failed (exit=%s): %s\n' "$status" "$evidence" >&2
            exit 1
        fi
    done
    printf 'zagscript-1.0-evidence unique=%s passed=%s\n' "$total" "$passed"
fi
