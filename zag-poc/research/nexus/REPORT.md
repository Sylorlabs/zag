# NEXUS minimal unified learner report

Date: 2026-10-26

## Verdict

**Informative prototype pass.** One continuing native-Zag process stores
acquisition, prediction, contradiction, investigation, revision, and
composition in one arena. A learner-created dependency crosses prediction to
investigation to revision: the investigation is selected from the contradicted
prediction's relation object, and its evidence revises that same relation
identity before composition.

This establishes a measured causal feedback loop for the minimal task. It does
not establish general unified cognition, learner invention of new operation
semantics, or superiority over conventional methods.

## Frozen experiment

Source: `nexus.zag`

Source SHA-256: `8bea0ad01987cbd260f419ea2cfbec85def5b0b3674910761a0a9009d90e6d8b`

Compiler: `znc 2026.07.0-dev`, arm64 Mach-O,
`3093d12dba9cc81b1dee69d2d4e604158d093b58f8f01ddab26c0f4297029956`

Binary SHA-256:
`1a2bccc387e504e33a2ed44ac4b529c21cbbbafaf77639736e901e801fe4afb0`

Three independent compilations produced the same binary hash:
`1a2bccc387e504e33a2ed44ac4b529c21cbbbafaf77639736e901e801fe4afb0`.
The binary is a signed native arm64 Mach-O.

## Developmental pathway

| Stage | Observed implementation |
|---|---|
| 1. Observe unfamiliar relationship | Two observations acquire relation object 0 (`2*x+3`) and relation object 3 (`x+1`). |
| 2. Acquire representation | Relation parameters, confidence, version, and evidence parents are stored in the arena. |
| 3. Predict novel event | Relation 0 predicts `x=5 -> 13`. |
| 4. Contradiction | World returns `14`; prediction is marked contradicted and immutable evidence object is added. |
| 5. Select investigation | Unified mode selects query `6` from the contradicted relation/prediction dataflow. |
| 6. Revise | Query returns `16`; relation 0 becomes intercept `4`, version `2`, with provenance edge from investigation. |
| 7. Compose | Revised relation 0 composes with relation 3. |
| 8. Later unfamiliar task | Composition at `x=5` returns `15`; it uses the revised relation identity. |

## Causal ablations

| Run | Query | Revision | Composite output | Cross dependency |
|---|---:|---:|---:|---:|
| unified | 6 | 1 | 15 | 1 |
| no-cross | 0 | 0 | 14 | 0 |
| knowledge-erased | 0 | 0 | -998 (typed miss) | 0 |
| investigation-erased | 0 | 0 | 14 | 0 |
| no-compose | disabled | 1 | unavailable | n/a |
| fresh matched evidence | -1 | 0 | 15 | 0 |
| conventional modular | 6 | 1 | 15 | 0 |

The critical comparison is unified versus `no-cross`: all initial evidence and
the world are matched, but removing the shared prediction-to-investigation
dataflow prevents the useful query and revision. `knowledge-erased` also
removes the executable relation, causing a typed applicability miss rather
than silently producing a result.

## Persistence

`persist-write` writes the complete 18,000-byte arena. A separate process using
`persist-read` reloads relation object 0, observes version 2/intercept 4, and
produces composite output 15. The persisted run records `PERSISTENT_REUSE 1`.
This is actual state reuse, not a copied summary.

## Conventional comparison

The modular control receives the same observations and world. It has separate
scalar inference and investigation calculations connected by an authored
bridge that hardcodes the query `6` and copies a correction into a new local
formula. It matches the final answer at 17 counted checks versus 31 for the
unified prototype, so this result is **not** a performance or accuracy win for
unification. Its role is causal: it lacks shared object identity, provenance
edges, and a persistent revision target.

## Hardcoded mechanisms

The following remain researcher-authored:

- the affine relation family and its integer parameterization;
- the record layouts and kind numbers;
- the world transition at `x>=5`;
- the one-step alternative-query scoring rule;
- the composition operator and pass-level safety bounds;
- the conventional bridge's exact query/correction logic.

The learner independently creates relation, evidence, prediction,
investigation, and composite records and their provenance edges. It does not
invent the object ontology, relation family, investigation scoring semantics,
or composition semantics. Those are explicitly separated from the causal
feedback result.

## Toolchain boundary

The current checked-in macOS seed is the verified arm64 compiler used by TNN,
but it is an edition-2026 compiler. The current Zag repository's self-host
source uses edition-2027 ownership forms that this seed cannot rebuild without
an intermediate current seed; its committed `zag-poc/znc` is Linux x86-64 and
cannot run on this Apple-Silicon host. Therefore this artifact is native Zag
execution with the repository's flat-arena compatibility language, compiled
for `macos-arm64`; it is **not** represented as a completed edition-2027
qualification. The exact failure and hashes are preserved in the workspace
history rather than hidden.

## Relation to other programs

No Muse, Instinct, AXIOM, or ORBIT source was changed or imported. The proposed
shared contract is recorded in `NATIVE_INTERFACE.md` for later adapters. This
prototype's result must not be combined with their results as proof of a
larger integrated learner until an adapter preserves object identities,
provenance, revisions, and executable dataflow.

---

# NEXUS-02 developmental extension

Date: 2026-10-27

## NEXUS-02 verdict

**Causal integration demonstrated; architectural superiority not
demonstrated.** The same persistent arena and object identities let acquired
relation A select an investigation for uncertain relation B. The consequence
of that investigation revises B in place, and the revised B changes a later
composition. Removing A from the investigation or removing the B-learning
update removes the consequential improvement.

The matched conventional modular reference reaches the same result with
fewer counted checks and an authored bridge. This is functioning integration,
not a superiority result.

## Developmental sequence

The NEXUS-02 environment uses two relations:

- A is acquired as `2*x+3` from observations `(1,5),(3,9)`.
- B begins as `x+0` from `(1,1),(3,3)` and is deliberately uncertain at the
  later regime.
- B's environment returns `x+1` only for queries `x>=7`.

The continuing run is:

1. A predicts `2*2+3 = 7`.
2. The learner uses A's executable result to choose B query `7`.
3. B predicts `7`; the environment returns `8`.
4. The same B object is revised from intercept `0` to `1`, version `2`.
5. A and revised B compose at `x=4`, producing `12`.

The dependency trace is represented by runtime edges, not output text:

```text
A object 0
  -> investigation object 7 (edge kind 9)
  -> B evidence object 9 (edge kind 10)
  -> B object 3 revision/version 2 (edge kind 7)
  -> composite object 10 (edge kind 8)
```

The `A_TO_INVESTIGATION`, `INVESTIGATION_TO_B_LEARNING`, and
`A_TO_LATER_COMPOSITION` fields in the run evidence are derived from the same
arena state and identities.

## Causal controls

| Run | A prediction | B query | B revision | B version | Composite | Harmful predictions | Abstentions | Cost | Checks |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| development | 6 | 7 | 1 | 2 | **12** | 1 | 0 | 7 | 31 |
| dev-no-pred | erased | 7 | 1 | 2 | **12** | 1 | 0 | 7 | 28 |
| dev-no-investigation | 6 | 2 | 0 | 1 | **11** | 0 | 1 | 2 | 28 |
| dev-no-learning | 6 | 7 | 0 | 1 | **11** | 1 | 0 | 7 | 29 |
| dev-all | erased | 2 | 0 | 1 | **11** | 0 | 1 | 2 | 24 |
| developmental modular | hidden in module | 7 | 1 | 2 | **12** | 1 | 0 | 7 | 17 |

The `dev-no-pred` lesion is intentionally informative: prediction is not
needed for this particular investigation policy once A remains available to
the inquiry operation. The critical lesions are `dev-no-investigation` and
`dev-no-learning`; each removes a different causal link and loses the later
composite improvement. The all-lesion control removes all A dataflow.

The modular control is information-matched for this small task. It computes
the same A result, exposes it through an authored bridge to its inquiry module,
passes B's observation to a separate update module, and reaches 12. It has no
shared arena identity or learned provenance edge. Its 17 counted checks versus
31 for the unified learner mean that the unified architecture does not win on
this cost measure.

## Persistence

`dev-persist-write` saves the complete learner state. A separate
`dev-persist-read` process reuses A object `0` and B object `3`, observes B
version `2`/intercept `1`, and produces composite `12`, recording
`PERSISTENT_REUSE 1`. This preserves the developmental update rather than
copying a summary file.

## Measured hardcoded mechanisms

NEXUS-02 still hardcodes the affine relation family, arena schema, world
transition, query policy, and composition semantics. The learner does not
invent the B relation family, the investigation ontology, or the meaning of a
revision. What is learned and causally reused is the relation parameter state,
its evidence/provenance identity, the selected query's consequence, and B's
revised executable value.

## Toolchain result

The bounded compatibility assessment is recorded in
`COMPILER_COMPATIBILITY.md`. The current arm64 seed is `znc 2026.07.0-dev`
with SHA-256
`3093d12dba9cc81b1dee69d2d4e604158d093b58f8f01ddab26c0f4297029956`.
NEXUS-02 compiled as signed native arm64 Mach-O. The source hash for this
extension is
`e645e10c1747e7d1d6c2600e9aa74dfc8b28629282a228c10492242122c9007e` and the
binary hash is
`68a4b5cd41d41dc3dbaf00d3cd11379edaa84879e4d08cb5dcb0ea2c39a21824`.
The result remains native compatibility execution, not edition-2027
qualification.

## Next architectural question

Can the learner acquire the investigation policy itself as a relation-like
executable object, rather than receiving the authored query scoring rule, and
still preserve the same causal A→investigation→B revision effect under a
sealed unfamiliar task? That is the next discriminating test; scaling the
current hand-authored ontology would not answer it.
