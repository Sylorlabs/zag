# Parser package: proposed unsupported `~` diagnostic

Editor: Tomo, independent compiler-engineering / scientific-audit manager. Branch: `research/2026-10-30-tomo-zag-diagnostics`. Scope: implemented edition-2026 behavior, not a change to the frozen normative v1 specification or a claim of a released v2.

**UNCOMPILED / UNEXECUTED.** The diff is NOT applied to compiler source. No native run or exact diagnostic output has been verified. Its proposed E0010 reuse is not an established unsupported-operator convention.

At base `1d7d405679e043ff220b1df20852f1a07729349a`, `selfhost/diag.zag` lists:
```text
//   E0010  unexpected token at top level
//   E0017  malformed or unavailable #embed resource
```
In `selfhost/parse.zag`, E0010 is also emitted by `annotation_error` for record-field and annotation errors. We propose reusing E0010 for unsupported unary `~`; this is a new use, not a previously assigned operator code. E0001 denotes unexpected EOF; E0018 is already used for struct representation annotations. The code table is incomplete and we do not claim another code is free.

The lexer emits unknown one-character punctuation as `Tk.Op`. `parse_unary` recognizes `-`, `!`, `&` and otherwise calls `parse_postfix`, eventually falling back to `mk_ident`. The proposed branch diagnoses the `~` token itself, then exits. Negative fixture expects line 2 column 12. Positive fixture uses integer `&`, `^`, `|` and unary `-`; this is source-reviewed but not compiled. The unrelated top-level `}` checks that other malformed input does not become a tilde error.

`tests/run_diag.sh` compares the full normalized text, not only the code and message:
```sh
actual=$(printf '%s\n' "$raw" | sed '/^znc:/d')
if [ "$rc" -eq 1 ] && [ ! -e "$artifact" ] && diff -q <(echo "$actual") "$expected" >/dev/null 2>&1; then
```
The expected file is a source-derived prediction, including path, source, caret, note and hint; line endings, path and output must be checked by a native run.

## Handoff (disposable checkout only)
From the repository root after fetching this package, and only after confirming the host's supported native bootstrap/build instructions:
```sh
P=zag-poc/research/tomo-parser-package-2026-10-30
git apply --check "$P/tomo_unsupported_bitwise_not.diff" && git apply "$P/tomo_unsupported_bitwise_not.diff"
cp "$P/tomo_bitnot_negative.zag" zag-poc/tests/diag/tomo_bitnot_negative.zag
cp "$P/tomo_bitnot_expected.txt" zag-poc/tests/diag/tomo_bitnot_negative.expected
cp "$P/tomo_bitwise_positive.zag" zag-poc/tests/tomo_bitwise_positive.zag
cp "$P/tomo_malformed_token.zag" zag-poc/tests/tomo_malformed_token.zag
cd zag-poc
make
bash tests/run_diag.sh
./znc tests/tomo_bitwise_positive.zag -o /tmp/tomo-bitwise-positive --no-zagd --no-foreground-cache
/tmp/tomo-bitwise-positive; echo "positive_exit=$?"
./znc tests/tomo_malformed_token.zag -o /tmp/tomo-malformed --no-zagd --no-foreground-cache; echo "malformed_compiler_exit=$?"
```
`make` may not rebuild `znc` from changed parser source; confirm and use the repository's actual bootstrap instructions before running the tests. Predicted: apply succeeds; diagnostic suite passes with compiler exit 1 and no artifact for the negative case; positive executable returns 0; unrelated malformed source returns compiler exit 1 and not the tilde diagnostic. Capture compiler executable hash, platform, commit, full output and exit status. None of these predictions is an execution receipt. Fixtures are in this package, not installed in the suite by the commits.
