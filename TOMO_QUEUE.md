# TOMO_QUEUE — source-only research ledger

Branch: `research/2026-10-30-tomo-zag-diagnostics`. Editor: Tomo. **UNCOMPILED / UNEXECUTED**. Snapshot created after the invention artifact; no native compiler, experiment or score has been run. Before work the inspected older base was `d623f16c366a4ce3ef18912828fee0a538a635b0`; two later prior commits were already present, so the then-current HEAD was `669870bf83b2c055f31ea60832f90a68dc6e111c`. This snapshot is not evidence of any later activity.

Qualification tier in every row is **source-only**, evidence category **source-only/unexecuted**, unless explicitly stated otherwise. Categories must remain distinct: `public-source-verified`, `public-logs-checked`, `compiler-reproduced`, `native-run-independently-reproduced`, `locally-reported-but-unpublished`, `source-only/unexecuted`, `unverified`. Published sources are not executed outcomes. User-reported campaign counts are locally-reported-but-unpublished. A missing searched reference is **NOT FOUND IN SEARCHED PUBLIC REFS**, never proof of nonexistence.

Path and commit key (all paths relative to repo root):

- `I`: `zag-poc/research/tomo-invention-falsification-cegis-2026-10-30.md` — `579a5d9021671d7e3cb690d87e44deeffa192f45`.
- `R`: `zag-poc/research/tomo-engineering-reference-2026-10-30.md` — `ae34a2cb4337c20eccbc4d834a3215a5d0d92cea`.
- `N`: `zag-poc/research/tomo-numeric-contract-ruling.md` — `28f29c5676677d373f051432065ededefb1676a6`.
- `NP`: `zag-poc/research/tomo_numeric_conversion_probe.zag` — `669870bf83b2c055f31ea60832f90a68dc6e111c`.
- `C`: `zag-poc/research/tomo-foreground-cache-audit.md` — `e69b9a43e3ac32b082b0ebf39cceea3c56a8e63f`.
- `V`: `zag-poc/research/tomo-zag-version-claims.md` — `d623f16c366a4ce3ef18912828fee0a538a635b0`.
- `P`: `zag-poc/research/tomo-unsupported-bitwise-not.patch` — historical `fa65edd` (short ID only here); an obsolete unverified candidate, **not a finished patch**.
- This ledger's own commit is obtained by `git log -1 --format=%H -- TOMO_QUEUE.md`; a file cannot contain its own final content-addressed commit SHA without changing that SHA.

| Item | Hypothesis / purpose | Status | Artifact and commit | Tier | Blocker | Next discriminating task |
|---|---|---|---|---|---|---|
| T01.01 | `~` should receive a supported diagnostic category | open | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | `E0001` is unexpected EOF; registry says E0010 is top-level, no operator-specific code established | trace all authoritative diagnostic definitions and choose a documented code, without inventing an existing one |
| T01.02 | `~` location can be taken from lexer token | partial | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | no runtime receipt | verify token span and diagnostic on a compiled fixture |
| T01.03 | parser diagnostic can be supplied without changing frozen work | open | P / fa65edd | source-only | old patch uses wrong E0001; create-file-only constraint excludes modifying existing parse.zag | produce reviewed unified diff against exact HEAD and native apply receipt |
| T01.04 | minimal negative fixture isolates `~` | open | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | prior research fixture and exact output unverified | freeze minimal fixture, expected output and line/column after code choice |
| T01.05 | existing unary/bitwise positive fixture uses valid grammar | open | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | fixture grammar not proved by build | compare operators with implemented grammar and passing repository fixtures |
| T01.06 | full `.expected` enables normal diagnostic runner | open | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | exact output and diagnostic code not fixed | create fixture under tests/diag with exact normalized output and verify |
| T01.09 | patch and test package can be independently qualified | open | P / fa65edd | source-only | not applied or compiled | publish new create-file patch package and read back commits |
| T01.10 | one-command handoff yields an objective receipt | open | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | validated build command absent | pin compiler build and smoke command and capture stdout and exit |
| T02.01 | numeric conversions are an implementation extension, not proven v1 conformance | source-reviewed | N / 28f29c5676677d373f051432065ededefb1676a6 | source-only | no full call/return behavior established | run differential tests with pinned compiler |
| T02.04 | local and assignment narrowing may truncate then sign-extend | probe published | NP / 669870bf83b2c055f31ea60832f90a68dc6e111c | source-only | uncompiled; source hypotheses only | run probe and preserve exit/trace |
| T03.01 | inspected cache identities prevent specific stale hits | partial negative audit | C / e69b9a43e3ac32b082b0ebf39cceea3c56a8e63f | source-only | complete option coverage not established | trace planner choices through cache paths |
| T03.09 | no defect in reviewed identities is not global proof | partial negative audit | C / e69b9a43e3ac32b082b0ebf39cceea3c56a8e63f | source-only | native behavior not tested | run dependency and flags-only change experiments |
| T04.01 | pointer arithmetic and element indexing have different contracts | source-reviewed | R / ae34a2cb4337c20eccbc4d834a3215a5d0d92cea | source-only | no cross-target execution | run pointer fixture and compare targets |
| T05.09 | v2 claims require evidence separate from frozen v1 spec | source-reviewed | V / d623f16c366a4ce3ef18912828fee0a538a635b0 | source-only | claims and compiler edition need per-run manifests | obtain actual compiler identities without re-searching exhausted refs |
| T06.01 | good candidates may never be generated or may be rejected | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | candidate traces unavailable | record every candidate before filtering |
| T06.02 | accepted candidate may fail applicability at use | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | no use traces | freeze candidate and compare normal gate to fallback |
| T06.03 | evaluator ambiguity can mimic wrong commits | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | no independent adjudication | blinded property and trace review |
| T06.04 | apparent absence of opportunity may be search incompleteness | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | no bounded existence certificate | exhaust tiny finite legal grammar or verify a witness |
| T06.05 | abstention can be optimal under calibrated asymmetric costs | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | calibration and costs not measured | preregister risk/coverage and cost sweep |
| T06.06 | Pareto retention can preserve useful alternatives | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | no implementation | implement bounded archive and log evictions |
| T06.07 | applicability should use legal visible information with fallback | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | calibration and certification unbuilt | implement gate and false positive/negative accounting |
| T06.08 | equal-grammar Pareto/CEGIS can falsify the invention claim | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | no native implementation or scored comparison | implement contract without learner adoption scalar |
| T06.09 | holding candidates fixed isolates acceptance effects | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | rejected-candidate logs unavailable | deterministic fixed-stream replay and charge all validation |
| T06.10 | five mechanisms have distinct observable signatures | specification published | I / 579a5d9021671d7e3cb690d87e44deeffa192f45 | source-only | frozen split and independent evaluator absent | preregister costs, criteria, then run blinded audit |
| T07.03 | delayed credit may reveal useful paid information | not started | none | unverified | no instrumented trace or implementation | design prospective masked-answer control and cost accounting |
| T07.04 | cost-sensitive algorithm selection is a strong challenger | not started | none | unverified | baseline contract not yet authored | specify equal-information SATzilla-style selector |
| T07.07 | zero probes can be rational when information costs exceed value | not started | none | unverified | control worlds not yet defined | construct rational-no-probe control with analytic VOC |
| T12.09 | a queue can preserve provenance without inventing runs | initial snapshot | TOMO_QUEUE.md / own commit via git log | source-only | immutable create-file-only policy prevents editing this file in place | publish a new create-file snapshot for each update and preserve links; never claim this file itself was updated |

## Verification and next queue

This is an initial snapshot, not a continuously running service. Create-file-only publication prohibits editing this existing ledger; future updates require separately named immutable snapshots until that constraint changes. This does not satisfy a literal in-place living ledger; report the limitation. Verify with `git log -1 --format=%H -- TOMO_QUEUE.md` and `git show HEAD:TOMO_QUEUE.md` (expected exit 0 and this text in a checkout containing the commit). No native test or score is implied.

Next ready tasks in order: finish precise operator code and parser patch package; implement the five-way experiment and independent baseline; prospectively test delayed-credit versus paid-masked-answer and rational-no-probe controls; implement cost-sensitive SATzilla-style selection; design version-aware memory challengers and poisoning/invalidation cases. Do not restart exhausted reference searches or touch main/canonical/frozen studies.
