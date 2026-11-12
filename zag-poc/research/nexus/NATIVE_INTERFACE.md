# NEXUS native interface contract

This is the minimal interface for importing the experiment into another native
Zag learner without copying summaries between programs.

## Arena records

All fields are little-endian `i32` cells. Object `id` is stable for the life of
the arena and across a persisted snapshot.

| Field | Offset | Meaning |
|---|---:|---|
| id | 0 | object identity |
| kind | 4 | relation, evidence, prediction, investigation, composite |
| operation | 8 | executable operation family |
| p0..p3 | 12..24 | typed operands/values |
| confidence | 28 | applicability/confidence bit |
| provenance parent | 32 | source object identity |
| version | 36 | revision version |

The state header contains epoch at 0, object count at 4, edge count at 8,
revision count at 12, computation checks at 16, selected investigation at 20,
query value at 24, and final composite at 28.

## Required dataflow

1. Observation creates a relation and evidence objects.
2. Prediction references the relation object.
3. Contradiction references the prediction and creates new evidence.
4. Investigation selection reads those same object identities and creates an
   investigation edge from prediction and relation.
5. Revision updates the relation's parameters and version in place, with an
   edge from investigation to the revised relation.
6. Composition consumes the revised relation identity and another acquired
   relation identity.

An adapter may translate transport or persistence formats, but it must preserve
object identity, provenance parent, version, and edge direction. A text
summary is not a conforming adapter.

## Safety and evidence

The current implementation uses typed Zag slices and explicit arena bounds in
the record constructors. The scientific evidence is immutable by convention:
contradiction creates a new evidence object; revision changes only the
relation's current executable parameters and version. The source, compiler
hash, binary hash, run outputs, and controls are frozen together by the
experiment runner.
