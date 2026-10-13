# Zag and ZagScript boundary

Zag and ZagScript share a compiler, type system, IR, runtime contracts, and native backend, but they are different language profiles with different responsibilities.

## Zag

Zag is the strict systems language. Its source is explicit and compiler-visible: ownership, allocation, effects, capabilities, ABI/layout choices, error flow, and low-level operations belong in ordinary Zag syntax or explicit libraries. The compiler must not silently inject ZagScript conveniences into a strict Zag module.

Strict Zag invariants:

- No implicit Script entry point or hidden `ScriptContext`.
- No Script-only syntax normalization or convenience prelude binding.
- No automatic Script JSON/map/interpolation adapter imports.
- No implicit bounded Script allocator policy.
- No Script `auto` markers or generated optimizer helpers unless an ordinary Zag API explicitly requests them.
- Strict source remains byte-exact through Script CST/profile discovery when no Script profile is active.
- Low-level control stays available through explicit Zag APIs and explicit unsafe/capability boundaries.

## ZagScript

ZagScript is the prototype profile. It removes routine ceremony while retaining a mechanically visible path into Zag. It may infer types and ownership, bind a bounded convenience prelude, inject the hidden root Script context, normalize Python-shaped syntax, and lower bounded convenience forms such as interpolation, maps, JSON helpers, async task syntax, and `auto` optimization markers.

Those conveniences are compiler-owned transformations with bounded behavior and provenance. They must lower to ordinary typed operations before native code generation, and `view`/`expand` must expose what was inferred or inserted.

ZagScript invariants:

- Convenience defaults are bounded and fail closed.
- Hidden allocation is charged to `ScriptContext`; raw unaccounted root allocation is rejected.
- Generated helpers carry synthetic provenance and deterministic names.
- Promotion to strict Zag is explicit and evidence-backed.
- A convenience that cannot be represented safely in strict Zag must remain visible as an unresolved promotion blocker instead of being silently guessed.

## Shared core

The profiles intentionally share:

- lexer/parser foundations and stable source origins;
- static type checking and generic specialization;
- ownership/lifetime/effect analysis;
- typed IR and native backends;
- ABI/layout definitions;
- package and dependency identities;
- diagnostics and proof/evidence formats.

Sharing the core prevents a prototype-to-production rewrite. Keeping the profiles distinct prevents prototype convenience from weakening the strict language.

## Design rule for new features

Every new feature must answer four questions before it is accepted:

1. Is this a Zag capability, a ZagScript convenience, or shared core machinery?
2. If it is ZagScript-only, what ordinary typed Zag operations does it lower to?
3. What resource, ownership, effect, and failure bounds apply to the lowering?
4. What test proves the feature cannot activate accidentally in strict Zag?

Features that cannot answer those questions do not belong in the language yet.
