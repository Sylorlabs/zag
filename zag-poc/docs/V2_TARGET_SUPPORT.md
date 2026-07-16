# Zag v2 target support matrix

This is generated in principle from release evidence, not a marketing matrix.
The gate inventory is in `V2_SUPPORT_MATRIX.generated.md`; a row below is not
v2 support unless all required v2 categories are green.

| Target/path | Current evidence | v2 operational status |
|---|---|---|
| x86-64 Linux static native | v1 bootstrap/native gates execute self-hosted output | v1 supported; v2 machine-control not implemented |
| ARM64 native | experimental lowering and separate regression tests | not a v2 supported target |
| WebAssembly | v1 emission/execution regression gate | not a v2 supported target |
| GPU MLIR / gfx bundle | frontend output validation only | not a GPU execution backend |
| Vulkan compute | no runtime implementation | unsupported |
| ROCm/HIP | no runtime implementation | unsupported |
| RISC-V | no executable backend evidence in this tree | unsupported |

Any new target must add target-specific lowering validation, executable corpus,
ABI/layout checks where relevant, and a support-matrix row sourced from those
tests.  Cross-compilation alone is not execution support.
