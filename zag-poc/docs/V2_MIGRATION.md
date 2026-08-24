# Migrating from Zag v1 to v2 (draft)

v1 is frozen.  A project remains v1 unless its nearest `zag.mod` selects
`edition = "2027"`; no existing source changes meaning merely because a newer
compiler is used.  The current compiler recognizes that edition boundary but
does not implement v2 machine-control operations yet, so moving a production
project to edition 2027 is intentionally blocked by E0201 until the required
vertical slices land.

## Preparation

1. Run the v1 semantic and native gates before changing the manifest.
2. Inventory direct pointer use, `new`/`delete`, extern declarations, globals,
   kernel annotations, and any syscall/runtime helpers.  These are not proof of
   a v2 safety contract.
3. Give every foreign boundary a written ownership, lifetime, nullability,
   layout, and thread-safety contract before translating it to v2 FFI.
4. Keep target-specific code behind an explicit module/target boundary; do not
   rely on legacy MLIR/bundle output as GPU execution.

## Planned translations

| Legacy pattern | Planned v2 form | Migration requirement |
|---|---|---|
| `*T` used as a raw address | `*const T`, `*mut T`, or `*opaque` | choose mutability, lifetime, provenance, and address space explicitly |
| unchecked pointer indexing | unsafe pointer/slice operation | document object extent/alignment and add a checked wrapper where possible |
| implicit allocator/runtime helper | `Allocator` operation | handle fallible allocation and declare `Alloc` effect |
| ad-hoc fence/runtime thread helper | typed atomic/thread API | choose ordering and establish lifetime/happens-before proof |
| `extern` without ownership contract | explicit ABI import/export | select calling convention, representation, visibility, and unsafe wrapper |
| GPU MLIR/bundle emission | typed kernel plus runtime buffer/dispatch API | add CPU-vs-device result test before claiming runtime support |

## Compatibility rule

Do not paper over an unsupported v2 construct with a v1 spelling or an ignored
command-line option.  The compiler's edition/option gates intentionally reject
that state.  A migration issue should remain a failing negative test until its
implementation, effect propagation, and runtime evidence are present.
