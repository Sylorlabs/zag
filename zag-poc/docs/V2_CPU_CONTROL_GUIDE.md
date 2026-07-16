# Zag v2 CPU control guide (draft)

Inline assembly, SIMD, target features, cache hints, timestamp counters, and
CPU intrinsics are not implemented in v2.  They will be target extensions, not
portable syntax dressed up as a no-op.  Every intrinsic declares feature
requirements, operand types/alignment, effects, and whether it requires an
unsafe boundary.

Assembly must name every input/output, register/immediate constraint,
read-write/early-clobber property, clobbered register/flags state, and memory
effect.  Machine-code tests inspect the selected target instruction and execute
a bounded result test.  A new architecture is unsupported until that corpus
runs on hardware or a trusted emulator; x86-64 design must not be advertised as
ARM64/RISC-V execution without that evidence.
