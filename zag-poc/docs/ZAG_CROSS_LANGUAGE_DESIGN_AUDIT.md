# Zag and ZagScript Cross-Language Design Audit

This document is a release-design contract, not a feature wish list. Zag and
ZagScript share a compiler core, but they serve different jobs:

- **Zag** is the explicit systems language. ABI, allocation, ownership,
  concurrency, effects, layout, target policy, and unsafe operations must stay
  visible and compiler-checkable.
- **ZagScript** is the prototype language. It may infer routine policy and
  synthesize bounded helpers, but every convenience must lower into ordinary
  typed Zag/compiler IR with inspectable provenance and a path to an explicit
  Zag representation.

The design target is not feature parity with another language. The target is
to keep the strongest ideas from mature ecosystems while preventing their
well-known migration and complexity traps from becoming Zag defaults.

## C and C++

Keep:

- native ABI and layout control
- predictable data representation
- direct hardware and foreign-function access
- zero-runtime-cost low-level abstractions where they can be proven

Reject as safe-language defaults:

- undefined behavior for ordinary bounds, lifetime, initialization, aliasing,
  or signed-overflow mistakes
- implicit narrowing/conversion rules that silently change values
- preprocessor-style semantic rewriting outside the parser/type system
- ownership that exists only in programmer convention

Zag rule: unsafe machine contracts must be explicit and locally reviewable.
ZagScript rule: prototype convenience may never create an implicit unsafe
boundary.

## Rust

Keep:

- affine/owned resources
- explicit unsafe boundaries
- typed optional and error values
- exhaustive pattern matching
- compile-time prevention of common alias/lifetime errors

Avoid:

- making lifetime syntax and borrow reasoning dominate routine prototype code
- requiring a third-party runtime choice merely to use language async syntax
- forcing ecosystem extension patterns to work around overly rigid coherence
  rules when a safe local mechanism is possible
- making build-time procedural code an invisible second execution environment

Zag rule: ownership facts belong in the compiler and IR. ZagScript rule:
ownership should be inferred for ordinary code, with diagnostics that explain
the inferred contract and an explicit Zag form available when needed.

## Zig

Keep:

- explicit allocators in systems code
- errors and optionals as ordinary typed values
- strong compile-time evaluation
- integrated target/build awareness
- straightforward C ABI interop

Avoid:

- making allocator plumbing mandatory for simple prototype code
- allowing compile-time execution to become unbounded or nondeterministic
- making metaprogramming output difficult to audit after compilation

Zag rule: explicit allocator ownership remains available everywhere.
ZagScript rule: the default allocator is a bounded ScriptContext contract;
hidden unbounded allocation is forbidden. Compile-time/`auto` work has a
deterministic budget and evidence record.

## Go

Keep:

- small readable surface area
- fast, unsurprising tooling
- channels/tasks as standard language/runtime concepts
- simple package conventions

Avoid:

- typed-nil/interface ambiguity
- repetitive error boilerplate as the only propagation model
- detached concurrency with ownership and cancellation left mostly to
  convention
- adding core abstraction/safety concepts only after ecosystem patterns harden

Zag rule: optionality is explicit in the type. ZagScript rule: no hidden
nullable interface payloads. Task handles are affine and structured lifetime
is the default.

## Swift

Keep:

- value semantics
- actor/task isolation
- sendability as a compiler concept
- expressive enums and exhaustive matching

Avoid:

- retrofitting concurrency isolation after a large ecosystem already depends
  on weaker rules
- implicit actor/executor behavior that is difficult to see in performance
  critical code

Zag rule: sendability and ownership transfer belong in the type/effect model
from the start. ZagScript rule: inferred concurrency must still be visible in
`explain`/explicit views.

## Python

Keep:

- low ceremony
- indentation-oriented readability
- quick iteration and good diagnostics
- rich collection/string ergonomics

Avoid:

- a prototype-to-production rewrite cliff
- runtime-only type failures for contracts the compiler can know
- a language runtime architecture that prevents ordinary native parallelism
- hidden, unbounded allocations behind innocent-looking operations

ZagScript's reason to exist is specifically to avoid the rewrite cliff: the
prototype already uses Zag's parser/type/IR/runtime authority and can be
progressively made explicit.

## Java and Kotlin

Keep:

- mature package/tooling expectations
- structured concurrency ideas
- practical generics and strong IDE/compiler feedback

Avoid:

- erased generic identity where specialization/layout matters
- ambient nullability
- large hidden runtime requirements for otherwise simple native programs

Zag rule: generic type/layout identity must remain available to native code and
optimization. ZagScript rule: inference may omit spelling, not type identity.

## Non-negotiable design guards

Every new ZagScript convenience must satisfy all of these before release:

1. **Profile isolation** — strict Zag does not change meaning because a
   ZagScript feature exists.
2. **Typed lowering** — convenience syntax lowers to the shared typed compiler
   representation, not a parallel interpreter semantics.
3. **Explicit projection** — `view/expand/promote` can explain or materialize
   what the convenience implies, or fails closed with a precise unsupported
   reason.
4. **Bounded work** — allocation, compile-time evaluation, optimizer search,
   formatting/interpolation, collections, and background work have enforceable
   budgets.
5. **Ownership preservation** — generated code cannot weaken affine resource,
   borrow, lifetime, or cleanup rules.
6. **No hidden unsafe** — Script lowering cannot introduce an unsafe ABI,
   pointer, alias, or lifetime assumption without an explicit checked adapter.
7. **Determinism** — the same source/config/compiler identity yields the same
   generated result and evidence.
8. **No rewrite cliff** — production hardening is progressive disclosure of
   existing semantics, not a reimplementation in a different language.

## Required debt-regression corpus

The release test suite should keep permanent negative/positive cases for:

- out-of-bounds and use-after-free
- uninitialized reads and invalid pointer/borrow escape
- overflow/narrowing behavior
- typed-null/optional confusion
- leaked or double-consumed task handles
- uncancelled structured children
- cross-task non-sendable ownership
- hidden or unbounded Script allocation
- generic type/layout identity loss
- nondeterministic or over-budget compile-time/`auto` work
- generated code that crosses an unsafe boundary
- package resolution that changes without lock/provenance changes
- Script conveniences accidentally activating in strict Zag

These are language-level regression categories. A feature is not complete
merely because its positive syntax works; its failure modes must be explicit,
bounded, and stable too.
