# Zag driver foundation

`std:driver` is the single source-level contract for a pure-Zag driver core.
Userspace and kernel adapters are selected outside the core and must preserve
the same handle, layout, effect, DMA, interrupt, and teardown rules.

The initial support boundary is deliberately finite:

- Linux 6.1 and 6.6 LTS;
- x86-64, ARM64, and i686;
- userspace and loadable kernel-module adapters;
- QEMU plus the generic virtual-device emulator.

No physical device, other operating system, other kernel series, other
architecture, or unlisted DMA/IOMMU mode is implied by importing the module.
Those become supported only after their adapter and executable conformance
matrix are present.

The contract and emulator are source-complete only where the checked-in
compiler gates say so. In particular, a metadata facade or an emulator pass
does not claim that a kernel object, target lowering, or Linux VM image exists.

## Handles and ownership

`Device`, `MmioRegion`, `DmaDomain`, `DmaBuffer[T]`, `BusAddress`, `IrqHandle`,
`DriverState`, `Atomic[T]`, and `DriverMutex` are affine opaque capabilities.  Their public
representation contains a compiler-owned `*opaque` token.  A handle literal,
field projection, pointer cast, ordinary copy, or direct free in driver code
is rejected.  Acquisition, borrowing, consumption, and teardown are named
operations with explicit contracts.

The handle rule is separate from ordinary resource flow: resource flow proves
that a live token is released exactly once, while the driver authority rule
proves that source code could not fabricate or inspect the token in the first
place.

## Critical contexts

`@realtime` and `@irq` are checked transitively by the effect system.  They
fail closed on allocation, I/O, locking/blocking, unsafe machine operations,
unknown foreign calls, and forbidden device effects.  The typed driver pass
also requires a syntactically bounded loop in a critical function; an opaque
retry loop is unavailable until a bounded proof form exists.

`@driver_init`, `@driver_control`, and `@driver_teardown` are explicit
operation profiles.  They do not grant authority by themselves: unsafe
operations still require their documented preconditions and typed adapter
boundary.

## Concurrency and synchronization

`Atomic[T]` exposes exact-width 8/16/32/64-bit load, store, exchange, fetch
add/sub/and/or/xor, compare-exchange, and fence operations.  Each operation
requires named memory orders; load/store and compare-exchange order
combinations are rejected at the call site.  The target adapter reports
lock-free capability for the selected width instead of the compiler guessing
from its host.  A non-emulated handle cannot silently become an ordinary
memory access.  `DriverMutex.try_lock` is bounded and IRQ-safe when the
adapter reports that capability; `DriverMutex.lock` is explicitly
`@blocking`, so the effect checker rejects it from `@realtime` and `@irq`.

## Emulator boundary

`std:driver_emulator` models BAR/MMIO bounds, register epochs and endian
selection, DMA mapping/handoff/completion, descriptor rings, interrupt
coalescing and acknowledgement, reset, suspend/resume, hot-unplug, power
loss, malformed descriptors, stale/reordered completion, and teardown races.
Its invariant word reports out-of-range MMIO, double completion, DMA after
teardown, leaked handles, and critical-path allocation/blocking.

The emulator is a generic protocol proof.  It is not a physical-device
certification and contains no audio-specific assumptions.

## Binary layout

Fixed-width scalar layout is queried only through `@sizeOf[T]()`,
`@alignOf[T]()` and `@offsetOf[T]("field")`.  The backend uses the same layout
registry for these constants and for field lowering; an unknown type, field,
representation, or alignment is rejected before artifact output.  `@repr(C)`
is target-aware for the initial Linux x86-64, AArch64, and i686 ABIs. x86-64
and AArch64 use byte-exact fixed-width C leaves; i686 uses its four-byte
pointer/alignment ABI and currently rejects subword aggregate leaves until its
lowering can prove byte/halfword aggregate accesses. `@repr(packed)` is
accepted only when every field remains naturally aligned for the selected
lowering.
Unsupported packed/target combinations remain unavailable rather than being
lowered through the host ABI.  Explicit `@align(N)` values are validated as
power-of-two declarations and are included in layout identity.
For a struct, `@align(N)` raises the aggregate alignment and rounds its final
size; it does not insert artificial leading padding before the first field.

Typed register declarations use `RegisterField`/`register_field_new(width,
shift, bits, endian)`. Constant declarations are checked before lowering for
an exact 8/16/32/64-bit register width, an in-range non-empty bit range, and a
known endian. Runtime-discovered fields retain the same validation and cannot
be used to bypass the typed MMIO policy. Descriptor declarations use
`DescriptorField`/`descriptor_field_new(descriptor_bytes, offset, width,
endian)`; constant declarations must fit the descriptor extent and be aligned
to their exact width. `descriptor_field_encode` and `descriptor_field_decode`
make the logical CPU value versus bus byte image transition explicit.
The constructor records a validity bit, so runtime-discovered descriptor
metadata cannot become an unchecked access path.

## Versioned Linux adapters

`std:driver_linux` exposes explicit tags for Linux 6.1/6.6, target
architecture, context, effects, ownership, and availability.  An unknown
series or API returns a precise unsupported result.  The kernel-owned final
module link remains a separate adapter/linker step; the common core does not
include C driver logic. Each matrix row also requires a Kbuild handoff that
declares only a generated pure-Zag object as `obj-m`; the checker rejects
C/C++/assembly driver sources, compares two independently supplied object
generations byte-for-byte, and leaves the final link to the kernel. The
`selfhost/native/driver_elf.zag` implementation is a separate deterministic
ET_REL writer: it consumes target encoder text and explicit text/data
relocations, emits `.text`, `.data`, `.modinfo`, `.rela.text`/`.rel.text`,
`.rela.data`/`.rel.data`, symbols, and DWARF sections, and has source-level
writer proof for x86-64, ARM64, and i686. The ordinary compiler's executable
and narrow C-ABI object paths are not driver module output and are rejected by
the driver-object checker.

`tests/run_driver_cli.sh` additionally compiles one minimal pure-Zag module
through a freshly rebuilt foreground compiler for all three targets, checks
the architecture relocation families and metadata, reruns each output for
byte determinism, and rejects an unsupported kernel series. This proves the
compiler integration boundary only; it does not replace Kbuild or QEMU.

`std:driver_linux_6_1` and `std:driver_linux_6_6` are series-pinned pure-Zag
facades.  They do not imply that a loadable module row exists.  The object gate
requires one ET_REL object per matrix row with `.modinfo`, symbols, text/data
relocations, the architecture relocation family, and retained DWARF. Kbuild
and the kernel own only the final module link. The ET_REL carries an explicit
`zag_kernel_series` provenance tag; Kbuild/kernel-owned final module generation
must supply the real kernel metadata and `vermagic`. The writer is structural
lowering evidence until the fresh foreground compiler image, kernel-owned final
link, and QEMU lifecycle evidence pass. No supported loadable-module row is
claimed from the standalone writer harness.

The focused source-backend checks
`tests/run_driver_i686_source_backend.sh` and
`tests/run_driver_arm64_source_backend.sh` exercise the checked-in i386 and
AArch64 lowering sources through isolated harnesses and execute their generated
programs under QEMU. The i686 source check includes the complete emulator-backed
userspace adapter fixture. They are useful regression evidence for generic
aggregate and target-layout lowering, but they never create matrix evidence or
promote a Linux adapter row; that still requires the foreground compiler,
Kbuild, module load/unload, and full six-row QEMU gate below.

The real handoff is exercised by `tests/run_driver_kbuild.sh`: a compiler
produced payload is consumed through an `if_changed` Kbuild rule, composed with
kernel `ld -r`, checked by `modpost`, and finalized by the kernel's
`Makefile.modfinal`. `tests/run_driver_matrix_build.sh` repeats this for the six
rows, builds target-native initramfs images with target-native static BusyBox,
and invokes `tests/run_driver_qemu_matrix.sh`. The QEMU executable can be
selected with `ZAG_DRIVER_QEMU_BIN_DIR` or the per-target override variables;
missing rows remain blocked.

The Linux userspace adapter has one modeled mode: an explicitly selected
generic emulator backend. Its physical device path remains
`driver_unsupported()` until device-specific evidence exists. The adapter's
foreground-compiler matrix is still release evidence, not a source claim; a
target remains blocked until that compiler artifact lowers and executes the
same core. The kernel adapter's source-level `load`/`unload` facade remains
fail-closed; loadable-module support is claimed only after the real Kbuild and
QEMU lifecycle rows pass.

Adapter declarations may use
`@linux_api(series, api, context, effects, ownership)`. The typed frontend
accepts only series 61/66, the known API range, and the exact contract row;
unknown or mismatched declarations fail before lowering.

The release gate is:

```text
make test-driver-foundation
```

It is the only claim-producing gate for this foundation.  Focused MMIO,
atomic, ABI, or emulator tests do not independently establish driver support.
