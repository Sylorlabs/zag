# NEXUS-02 compiler compatibility assessment

Date: 2026-10-27

## Decision

Do not spend the NEXUS-02 budget on a compiler migration. Preserve the native
compatibility execution and explicitly exclude edition-2027 qualification.

## Evidence

Compiler tested:

```text
/Users/Shared/micah/Documents/TNN/.bin/znc
znc 2026.07.0-dev (edition 2026)
Mach-O 64-bit executable arm64
sha256 3093d12dba9cc81b1dee69d2d4e604158d093b58f8f01ddab26c0f4297029956
```

The current NEXUS source compiles and runs with function-level `@borrows` and
`@borrows_mut` contracts under the compatibility toolchain.

An exact edition-2027 root was tested separately with two minimal files. The
compiler emitted the same ownership diagnostics for both:

```text
error[E0204]: cannot pass a borrow to a consuming call (root `b`) in function main
error[E0204]: cannot mutate owner `b` while a shared borrow is active in function main
```

The edition-2027 parameter-local spelling was also rejected as:

```text
error[E0202]: unknown type '@borrows' in function get_len
```

The available seed is therefore not a current edition-2027 compiler for this
source tree. This is a toolchain/version boundary, not evidence that the
ownership rules themselves are unsound or that the NEXUS source has a native
runtime defect. The checked-in Zag `zag-poc/znc` is Linux x86-64 and cannot run
on this Apple-Silicon host; the tested compiler is the pinned arm64 seed.

## Safe native conclusion

The scientific experiment remains valid as native Zag compatibility execution:
the compiler emits and runs a signed macOS arm64 binary, and the source does
not use unsupported edition-2027-only constructs. The result must be labeled
`native-compatibility`, not `edition-2027-qualified`.
