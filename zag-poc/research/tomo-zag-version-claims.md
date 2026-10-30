# Zag version-claim compatibility matrix

**UNCOMPILED / UNEXECUTED.** Static review only. Zag baseline `f8b287bad32d4f93d272c270cff772e59b858515`; TNN GitHub default-branch code-search snapshot, not a complete inventory of all branches or an independently reproduced run. Paths below are relative to their respective repository roots. Search results are files, not counts of individual occurrences.

## Compatibility and evidence matrix

| Question | Source and evidence | Interpretation |
| --- | --- | --- |
| Implemented edition-2026 behavior | `zag-poc/selfhost/v2_edition.zag` opens `// Edition gate for v2-only surface syntax.` and defaults the project edition to 2026 when no valid project edition is found; selected v2 syntax is gated on 2027. `zag-poc/selfhost/typed.zag` describes “Existing v1 extensions” with numeric representation rules “backend-owned”. | The default 2026 implementation and its extensions are not evidence that all v2 features or the v2 release are complete. |
| Published Zag v1 | `zag-poc/docs/V1_LANGUAGE_SPEC.md`: “Status: frozen v1 core, 2026-06-29.” “This document is the normative boundary for Zag v1.” It says “Implicit conversion between different named numeric types is not part of v1.” | The frozen core is a published boundary; implementation extensions are not automatically part of that core. |
| Proposed v2 features | `zag-poc/selfhost/v2_edition.zag`: “Edition gate for v2-only surface syntax.” `zag-poc/README.md`: “Zag v2 remains a fail-closed development edition even when an individual v2 slice passes.” | A proposal, gate, or passing slice is not evidence that the whole proposal is implemented or release-qualified. |
| Edition-2027 design intent | `zag-poc/selfhost/v2_edition.zag` explicitly gates selected v2-only syntax at the 2027 edition, unlike the default 2026 edition. | Distinguish the edition target from the compiler executable version and from the published v1 core; selecting a design edition is not a release-verification result. |
| Actually implemented | `zag-poc/selfhost/typed.zag` implements `zt_compatible`; `zag-poc/selfhost/native/ncodegen.zag` says “Known scalar numeric types retain the backend's existing widening and narrowing behavior.” `zag-poc/README.md` identifies `znc` as the supported compiler. | Source shows these implementation paths, not independently verified execution of every language feature. The numeric extension is outside the published v1 normative core; see `tomo-numeric-contract-ruling.md`. |
| Independently tested | This review did not run a compiler, benchmark, integration test or release gate. | No independent runtime verification is claimed, including for TNN results or individual v2 slices. |
| Failing required release verification | `zag-poc/docs/V2_FINAL_VERIFICATION.md`: “Status: not a release verification.” Its reported 2026-07-29 `bash tests/run_v2_release_gate.sh` result is 37 passing categories, 10 failing required categories, exit 1. | This is the document's reported historical run, not an independently rerun result and not proof of the current gate outcome. |

## TNN search categorization

GitHub search `repo:Sylorlabs/TNN "native Zag v2"` showed **51 files** across three pages. Categories are file extensions, not conclusions about each file's claim or execution. Counts: 40 Markdown (`.md`), 6 Zag source (`.zag`), 3 Zag fragments (`.zagfrag`), 1 run request (`.txt`), and 1 structured baseline (`.json`): **51 total**. Search is indexed/default-branch only. For single-file categories, the sole path is shown rather than inventing additional examples. The snippets include historical results and plans as well as source comments; do not silently rewrite historical records or say all hits are executed v2.

### Markdown — 40
Representative paths:
* `docs/generations/R32/R32_E51G_STATUS.md`
* `docs/generations/R32/R32_E51M_RESULT.md`
* `docs/generations/R32/R32_E51AB_RESULT.md`
* `docs/program/TNN_NATIVE_MIGRATION_STATUS.md`
* `docs/generations/R33/R33_PROGRAM_CHARTER.md`

Replacement for a demonstrated execution: “native Zag compiled by a pinned edition-2026 compiler [record compiler commit/hash and run evidence].” For a goal or plan: “planned native Zag implementation; compiler edition and qualification to be verified.” Do not replace a historical result without retaining its original claim and noting the correction.

### Zag source — 6
Representative paths:
* `docs/generations/R34/runs/R34_BEHAVIORAL_HELDOUT_STAGE_20260916/r34_memory_lifecycle_v1.zag`
* `docs/generations/R34/runs/R34_NATIVE_QUALIFICATION_STAGE_20260916/r34_memory_lifecycle_v1.zag`
* `docs/generations/R34/runs/R34_CONTINUING_LIFE_INTEGRATION_STAGE_20260916/r34_memory_lifecycle_v1.zag`
* `archive/transfer-staging/r34_native_extract_20260917/Research/R34_NATIVE_QUALIFICATION_STAGE_20260916/r34_memory_lifecycle_v1.zag`

Suggested comment: “native Zag source; intended for a pinned edition-2026 compiler; compiler identity and execution require verification.” State an exact compiler identity only when evidence supports it.

### Zag fragments — 3
All three paths:
* `docs/generations/R32/runs/R32_E51S_NATIVE/01_extended_optimization.zagfrag`
* `docs/generations/R32/runs/R32_E51M_NATIVE/01_calibration_curve.zagfrag`
* `docs/generations/R32/runs/R32_E51M_NATIVE/fragments/00_calibration_curve.zagfrag`

Suggested comment: “native Zag source fragment intended for assembly and compilation with a pinned edition-2026 compiler; not standalone proof of execution.” Pin only when verified.

### Run request text — 1
* `docs/generations/R32/runs/R32_E51AB_NATIVE/RUN_REQUEST_20260830T2203_PDT.txt`

Suggested request: “Run native Zag using a pinned edition-2026 compiler; record compiler hash, source identity, logs and exit status.” This is a requested run, not a result.

### Structured baseline JSON — 1
* `docs/generations/R32/R32_E51_BASELINE_V1.json`

The indexed snippet states “Promotable cognition must execute in native Zag v2; Python is assembly and infrastructure only.” Suggested replacement value: “Promotable cognition must execute in native Zag compiled by a pinned edition-2026 compiler; record compiler identity and run evidence; Python remains assembly and infrastructure only.” This is a proposed wording, not an edit of the original JSON or proof the referenced run used that edition.

## Reproduction handoff — NOT RUN

On a disposable, appropriately authorized checkout, confirm the exact TNN commit and run `git grep -l -i 'native Zag v2' -- '*.md' '*.zag' '*.zagfrag' '*.txt' '*.json'`; the GitHub search is indexed and may differ from literal `git grep`. At the Zag baseline, inspect `zag-poc/docs/V1_LANGUAGE_SPEC.md`, `zag-poc/docs/V2_FINAL_VERIFICATION.md`, `zag-poc/README.md` and `zag-poc/selfhost/v2_edition.zag`. Run `cd zag-poc && bash tests/run_v2_release_gate.sh` only in an authorized environment with the required toolchain, capturing source identity, compiler hash, logs and exit code. No such commands were run in this review.
