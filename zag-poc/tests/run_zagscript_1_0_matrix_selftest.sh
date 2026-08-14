#!/usr/bin/env bash
# Focused fail-closed tests for the frozen matrix inventory and evidence runner.
set -euo pipefail
cd "$(dirname "$0")/.."

tmp=$(mktemp -d /tmp/zagscript-matrix-selftest.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
fixture="$tmp/fixture"
mkdir -p "$fixture/tests" "$fixture/docs"
cp tests/run_zagscript_1_0_matrix.sh "$fixture/tests/"
cp tests/generate_zagscript_1_0_matrix.sh "$fixture/tests/"
cp tests/zagscript_1_0_capabilities.tsv "$fixture/tests/"

make_supported_stubs() {
    awk -F '\t' '$3 == "supported" { print $4 }' \
        "$fixture/tests/zagscript_1_0_capabilities.tsv" | sort -u |
    while IFS= read -r evidence; do
        mkdir -p "$fixture/$(dirname "$evidence")"
        apply="$fixture/$evidence"
        printf '%s\n' \
            '#!/usr/bin/env bash' \
            'set -euo pipefail' \
            'if [[ -n ${ZAGSCRIPT_MATRIX_SELFTEST_LOG:-} ]]; then' \
            '    printf "%s\\n" "$0" >>"$ZAGSCRIPT_MATRIX_SELFTEST_LOG"' \
            'fi' >"$apply"
        chmod +x "$apply"
    done
}

render_fixture_doc() {
    (cd "$fixture" && bash tests/generate_zagscript_1_0_matrix.sh) \
        >"$fixture/docs/ZAGSCRIPT_1_0_CAPABILITIES.generated.md"
}

make_supported_stubs
render_fixture_doc

# The unmodified inventory validates and evidence paths are deduplicated before
# execution (four supported view/reversal rows share one script).
(cd "$fixture" && bash tests/run_zagscript_1_0_matrix.sh) >"$tmp/baseline.log"
evidence_log="$tmp/evidence.log"
(cd "$fixture" && ZAGSCRIPT_MATRIX_SELFTEST_LOG="$evidence_log" \
    bash tests/run_zagscript_1_0_matrix.sh --verify-evidence) >"$tmp/evidence.out"
expected_unique=$(awk -F '\t' '$3 == "supported" { print $4 }' \
    "$fixture/tests/zagscript_1_0_capabilities.tsv" | sort -u | wc -l)
actual_unique=$(wc -l <"$evidence_log")
test "$actual_unique" -eq "$expected_unique"
test -z "$(sort "$evidence_log" | uniq -d)"
grep -q "zagscript-1.0-evidence unique=$expected_unique passed=$expected_unique" \
    "$tmp/evidence.out"

# Removing or renaming a frozen capability cannot reduce the release burden.
cp "$fixture/tests/zagscript_1_0_capabilities.tsv" "$tmp/matrix.good"
awk 'NR != 2' "$tmp/matrix.good" \
    >"$fixture/tests/zagscript_1_0_capabilities.tsv"
if (cd "$fixture" && bash tests/run_zagscript_1_0_matrix.sh) \
    >"$tmp/deleted.log" 2>&1; then
    echo 'matrix selftest: deleted frozen row false-greened' >&2
    exit 1
fi

cp "$tmp/matrix.good" "$fixture/tests/zagscript_1_0_capabilities.tsv"
awk -F '\t' 'BEGIN { OFS="\t" }
    NR == 2 { $2="renamed Script profile parser" }
    { print }' "$tmp/matrix.good" \
    >"$fixture/tests/zagscript_1_0_capabilities.tsv"
if (cd "$fixture" && bash tests/run_zagscript_1_0_matrix.sh) \
    >"$tmp/renamed.log" 2>&1; then
    echo 'matrix selftest: renamed frozen row false-greened' >&2
    exit 1
fi

# A present, executable evidence script that exits nonzero must fail the
# evidence mode. Restore the authoritative matrix/doc before this check.
cp "$tmp/matrix.good" "$fixture/tests/zagscript_1_0_capabilities.tsv"
render_fixture_doc
printf '%s\n' '#!/usr/bin/env bash' 'exit 42' \
    >"$fixture/tests/run_script_frontend.sh"
chmod +x "$fixture/tests/run_script_frontend.sh"
if (cd "$fixture" && bash tests/run_zagscript_1_0_matrix.sh --verify-evidence) \
    >"$tmp/failing-evidence.log" 2>&1; then
    echo 'matrix selftest: failing supported evidence false-greened' >&2
    exit 1
fi
grep -q 'supported evidence failed (exit=42): tests/run_script_frontend.sh' \
    "$tmp/failing-evidence.log"

# Matrix bookkeeping, its self-test, and aggregate/master coordinators may not
# serve as capability evidence. Probe the two indirect cases explicitly; the
# direct matrix/release cases are protected by the same exact allowlist.
for self_authorizing in \
    tests/run_zagscript_1_0_matrix_selftest.sh \
    tests/run_zagscript_master_gate.sh
do
    awk -F '\t' -v evidence="$self_authorizing" 'BEGIN { OFS="\t" }
        NR == 2 { $4=evidence }
        { print }' "$tmp/matrix.good" \
        >"$fixture/tests/zagscript_1_0_capabilities.tsv"
    printf '%s\n' '#!/usr/bin/env bash' 'exit 0' >"$fixture/$self_authorizing"
    chmod +x "$fixture/$self_authorizing"
    render_fixture_doc
    name=${self_authorizing##*/}
    if (cd "$fixture" && bash tests/run_zagscript_1_0_matrix.sh) \
        >"$tmp/self-authorizing-$name.log" 2>&1; then
        echo "matrix selftest: $self_authorizing self-authorized a supported row" >&2
        exit 1
    fi
    grep -q 'supported row names recursive/self-authorizing evidence' \
        "$tmp/self-authorizing-$name.log"
done

# A synthesized incomplete matrix refuses release before starting expensive
# evidence commands. Do not depend on the checked-in matrix remaining partial:
# this self-test must still pass when every real 1.0 row becomes supported.
awk -F '\t' 'BEGIN { OFS="\t" }
    NR == 2 { $3="partial"; $4="self-test injected incomplete row" }
    { print }' "$tmp/matrix.good" \
    >"$fixture/tests/zagscript_1_0_capabilities.tsv"
render_fixture_doc
make_supported_stubs
: >"$evidence_log"
if (cd "$fixture" && ZAGSCRIPT_MATRIX_SELFTEST_LOG="$evidence_log" \
    bash tests/run_zagscript_1_0_matrix.sh --release-evidence) \
    >"$tmp/release.log" 2>&1; then
    echo 'matrix selftest: incomplete release false-greened' >&2
    exit 1
fi
test ! -s "$evidence_log"
grep -q 'ZagScript 1.0 release refused' "$tmp/release.log"

echo 'zagscript-1.0-matrix-selftest pass=6 fail=0'
