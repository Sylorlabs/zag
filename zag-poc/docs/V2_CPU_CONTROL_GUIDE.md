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

The native `@prefetch(*T)` slice checks one host raw-pointer operand and emits
the target baseline cache hint: x86-64 `PREFETCHT0` or Apple-Silicon AArch64
`PRFM PLDL1KEEP`. It is advisory only: it creates no allocation, validity,
ordering, synchronization, or realtime guarantee.

The compiler-owned scalar spellings `popcount(i64)`, `byte_swap64(i64)`,
`leading_zeros(i64)`, `trailing_zeros(i64)`, and `andn(i64,i64)` execute on
both native x86-64 and Apple Silicon macOS. Apple Silicon uses mandatory
AArch64 instructions: Advanced SIMD `CNT` + `ADDV` for popcount, `REV` for
byte swap, `CLZ` for leading zeros, `RBIT` + `CLZ` for trailing zeros, and
`BIC` with operands reversed to preserve `andn(a,b) == (~a) & b`. The zero
count contracts are identical across targets: both leading/trailing zero count
return 64 for zero. x86-64 retains its documented optional POPCNT/BMI1
selection and exact generic fallbacks; Apple Silicon needs no optional feature
probe for this bounded slice.

`unsafe { @simdAddI32x4(dst, lhs, rhs) }`,
`@simdSubI32x4`, `@simdAndI32x4`, `@simdOrI32x4`, and `@simdXorI32x4`
are the only user-visible packed-SIMD operations. Their arguments are raw
`i32` pointers (`dst` is `*mut i32` or `*host i32`; inputs may also be const);
each performs exactly four unaligned lanes. Native x86-64 uses baseline SSE2
`MOVDQU` plus `PADDD`, `PSUBD`, `PAND`, `POR`, or `PXOR`, followed by `MOVDQU`.
Apple Silicon uses mandatory AArch64 Advanced SIMD/NEON 128-bit load/store plus
`ADD .4S`, `SUB .4S`, `AND .16B`, `ORR .16B`, or `EOR .16B`.
Add and subtract use modulo-2^32 lane semantics; bitwise operations act on all
128 bits without interpreting signedness.
Checked mode validates each 16-byte allocation access. It does not establish a
vector value ABI, alignment promise, aliasing policy, optional ISA selection,
or general inline-assembly facility.

Assembly must name every input/output, register/immediate constraint,
read-write/early-clobber property, clobbered register/flags state, and memory
effect.  Machine-code tests inspect the selected target instruction and execute
a bounded result test.  A new architecture is unsupported until that corpus
runs on hardware or a trusted emulator. The Apple-Silicon slices are covered by
`tests/run_macos_machine_control.sh` and `tests/run_macos_scalar_intrinsics.sh`;
no other architecture inherits that claim without equivalent evidence.
