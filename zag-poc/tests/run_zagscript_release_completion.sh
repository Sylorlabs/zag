#!/usr/bin/env bash
set -euo pipefail
cd "$(dirname "$0")/.."

matrix=tests/zagscript_1_0_capabilities.tsv
test "$(head -n 1 "$matrix")" = $'area\tcapability\tstatus\tevidence_or_blocker'

rows=$(awk -F '\t' 'NR > 1 { n++ } END { print n+0 }' "$matrix")
supported=$(awk -F '\t' '$3 == "supported" { n++ } END { print n+0 }' "$matrix")
partial=$(awk -F '\t' '$3 == "partial" { n++ } END { print n+0 }' "$matrix")
unavailable=$(awk -F '\t' '$3 == "unavailable" { n++ } END { print n+0 }' "$matrix")

test "$rows" -eq 32
test "$supported" -eq "$rows"
test "$partial" -eq 0
test "$unavailable" -eq 0

while IFS=$'\t' read -r area capability status evidence; do
    [ "$status" = supported ] || exit 1
    case "$evidence" in
        tests/*.sh) [ -f "$evidence" ] && [ -x "$evidence" ] ;;
        *) exit 1 ;;
    esac
done < <(tail -n +2 "$matrix")

echo "ZagScript 1.0 release completion: PASS rows=$rows supported=$supported partial=$partial unavailable=$unavailable"
