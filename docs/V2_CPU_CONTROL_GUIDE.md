# Zag v2 CPU control guide (draft)

Portable inline assembly, SIMD, target-feature selection, timestamp counters,
and the broad CPU-intrinsic surface are not implemented in v2.  The supported
baseline cache-hint and scalar intrinsic slices are target extensions, not
portable syntax dressed up as a no-op.  Every intrinsic declares feature
requirements, operand types/alignment, effects, and whether it requires an
unsafe boundary.

The only current CPU selection is the documented `--cpu` profile resolver.
Compiler-style `-m...` controls, LLVM-style target/feature options, and Rust
`-C...` controls (including `-march`, ISA-feature switches, target CPU, and
word-size requests) are rejected rather than silently compiling the generic
baseline. They do not grant permission to emit SIMD or other optional opcodes.

The native `@prefetch(*T)` slice emits baseline x86-64 `PREFETCHT0` after
checking its one raw-pointer operand. It is advisory only: it creates no
allocation, validity, ordering, synchronization, or realtime guarantee.

`unsafe { @simdAddI32x4(dst, lhs, rhs) }`,
`@simdSubI32x4`, `@simdAndI32x4`, `@simdOrI32x4`, and `@simdXorI32x4`
are the only user-visible packed-SIMD operations. Their arguments are raw
`i32` pointers (`dst` is `*mut i32` or `*host i32`; inputs may also be const);
each performs exactly four unaligned lanes using baseline x86-64 SSE2
`MOVDQU` plus `PADDD`, `PSUBD`, `PAND`, `POR`, or `PXOR`, followed by `MOVDQU`.
Add and subtract use modulo-2^32 lane semantics; bitwise operations act on all
128 bits without interpreting signedness.
Checked mode validates each 16-byte allocation access. It does not establish a
vector value ABI, alignment promise, aliasing policy, optional ISA selection,
or general inline-assembly facility.

Assembly must name every input/output, register/immediate constraint,
read-write/early-clobber property, clobbered register/flags state, and memory
effect.  Machine-code tests inspect the selected target instruction and execute
a bounded result test.  A new architecture is unsupported until that corpus
runs on hardware or a trusted emulator; x86-64 design must not be advertised as
ARM64/RISC-V execution without that evidence.
