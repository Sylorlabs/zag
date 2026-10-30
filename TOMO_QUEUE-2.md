# TOMO_QUEUE-2 — corrected research ledger snapshot

Branch: `research/2026-10-30-tomo-zag-diagnostics`. This immutable snapshot supersedes `TOMO_QUEUE.md` at `1d7d405679e043ff220b1df20852f1a07729349a`; the earlier snapshot remains available as historical context. Create-file-only publication means future revisions require new snapshot files, not edits to this one.

## Diagnostic correction

The registry labels E0010 `unexpected token at top level`, but its use in `parse.zag` is not confined to top-level errors: record-field and annotation syntax errors also use it. No dedicated unsupported-unary-operator code has been established. Reuse of E0010 for unsupported unary `~` in the candidate patch is a proposal, not an authoritative code assignment; E0018 is already used for representation annotations. The earlier E0001 candidate was incorrect. The package diff has not been applied, built, or run; maintainer review of the code choice remains open. The expected text is source-derived, not a captured compiler result.

## Artifact ledger

Each row records the create-file commit for that path. Qualification tiers are source-only, compiled, run, scored, and independent. Every item below is **source-only** for this work: not compiled, run, scored, or independently reproduced. Historical results quoted by a document remain reported claims, not independent verification. Paths are repository-relative.

| Artifact path | Commit SHA | Qualification tier |
|---|---|---|
| `zag-poc/research/README.md` | `0dd0dcc6e790202c7467c2f6adff311124b639cf` | source-only |
| `zag-poc/research/tomo-engineering-reference-2026-10-30.md` | `ae34a2cb4337c20eccbc4d834a3215a5d0d92cea` | source-only |
| `zag-poc/research/tomo-zag-version-claims.md` | `d623f16c366a4ce3ef18912828fee0a538a635b0` | source-only |
| `zag-poc/research/tomo-numeric-contract-ruling.md` | `28f29c5676677d373f051432065ededefb1676a6` | source-only |
| `zag-poc/research/tomo_numeric_conversion_probe.zag` | `669870bf83b2c055f31ea60832f90a68dc6e111c` | source-only |
| `zag-poc/research/tomo-foreground-cache-audit.md` | `e69b9a43e3ac32b082b0ebf39cceea3c56a8e63f` | source-only |
| `zag-poc/research/tomo-pointer-portability-abi.md` | `3916a493e6f235b8161acd4ea374c9859f34f72a` | source-only |
| `zag-poc/research/tomo-publication-readiness-v8-frontier2.md` | `4f1d6697adf077e7bf86cc9d1360699f8d4c7133` | source-only |
| `zag-poc/research/tomo-invention-falsification-cegis-2026-10-30.md` | `579a5d9021671d7e3cb690d87e44deeffa192f45` | source-only |
| `zag-poc/research/tomo-unsupported-bitwise-not.patch` | `fa65edd567fe175480be1e7020e48cf60ee975e7` | source-only; obsolete candidate |
| `zag-poc/research/tomo_bitnot_negative.zag` | `35e8f10bb52f8a0a843cc0ca232e623e961b06ac` | source-only; historical fixture |
| `zag-poc/research/tomo_bitwise_positive.zag` | `62616ff36cac39971b079100abbcf53f51e9f995` | source-only; historical fixture |
| `TOMO_QUEUE.md` | `1d7d405679e043ff220b1df20852f1a07729349a` | source-only; superseded snapshot |
| `zag-poc/research/tomo-parser-package-2026-10-30/tomo-parser-package-2026-10-30.md` | `5a269e1b6dc157cd82b0c9cb5cb90d52a5bb9ffa` | source-only; package README |
| `zag-poc/research/tomo-parser-package-2026-10-30/tomo_unsupported_bitwise_not.diff` | `2c862c6d5918cf5826b3f9ba8c23b205a5a61d2e` | source-only; proposed, not applied |
| `zag-poc/research/tomo-parser-package-2026-10-30/tomo_bitnot_negative.zag` | `16509122a379e6b3d203abf41587550c2f8b4b1c` | source-only |
| `zag-poc/research/tomo-parser-package-2026-10-30/tomo_bitwise_positive.zag` | `66a122875c0352dc1a0b7ace85226bc396315e3c` | source-only |
| `zag-poc/research/tomo-parser-package-2026-10-30/tomo_bitnot_expected.txt` | `0bdc6de4c0b8c2e17ad3940d84fe51629b6c236a` | source-only; predicted output |
| `zag-poc/research/tomo-parser-package-2026-10-30/tomo_malformed_token.zag` | `ecceb68b67fbeb2f4d32a0eb65f181e93aa3305c` | source-only |

This snapshot itself is source-only. Its own content-addressed commit SHA cannot be included in its contents without changing that SHA; read it from the create-file commit or `git log -1 --format=%H -- TOMO_QUEUE-2.md`.

## Outstanding work

- Review and correct the candidate parser diff against the actual diagnostic function and agree on its error code; apply in a disposable checkout, rebuild, and run the negative, positive, and separate malformed-token checks. Verify the exact expected output rather than treating the prediction as a receipt. The diagnostic runner compares the full text after removing lines beginning `znc:`, and requires exit 1 and no output artifact. See the package README for its derivation and proposed commands; commands are unverified.
- Trace remaining foreground-cache input and option coverage; perform a deterministic invalidation attempt, including the observed `src_arg()` paired-option concern. The existing audit establishes no reproduced staleness defect and does not prove complete coverage. Pointer arithmetic and ABI review also needs executable regression evidence before asserting a defect.
- Implement and evaluate the five-way falsification experiment and an independent equal-budget baseline, followed by cost-sensitive selection and version-aware memory invalidation/poisoning challengers. Report outcomes only after actual runs and distinguish historical claims from independent replication.

## Next discriminating task

Implement the zero-probe credit-assignment test with delayed credit, a paid-masked-answer control, and a rational-no-probe control. Specify the decision rule and matched task/information/compute budgets before running; compare outcomes and costs so that a no-probe choice justified by rational cost avoidance is not mistaken for failed credit assignment. Keep it source-only until compiled and run, and do not claim scored or independent evidence until those stages actually occur. Do not alter main, canonical, or frozen studies.
