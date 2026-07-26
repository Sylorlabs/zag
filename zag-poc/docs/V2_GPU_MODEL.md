# Zag v2 GPU model (draft)

GPU source is not supported merely because it parses or emits MLIR.  `@kernel`
and `@device` are target-scoped declarations checked against host/device effect
rules.  Pointer address spaces are host, device/global, workgroup, private,
and constant/uniform; implicit crossing is forbidden.  Barriers and fences have
specified workgroup/device scope and cannot be used to synchronize host code.

The first operational backend will be an opt-in Vulkan compute runtime.  It
must enumerate the selected device, create context/queues, allocate buffers,
transfer inputs, load validated target code, issue bounded dispatch, wait with a
timeout, transfer outputs, validate CPU equivalence, and destroy all resources.
On the display-bound RX 5700 XT, tests use tiny buffers, one conservative
workgroup, subprocess timeouts, and never join the default release gate until
physical validation is stable.  Missing compatible hardware is an explicit
skip; MLIR emission is reported separately from target binary, load, launch,
and correct output.

## Kernel and address-space contract

`@kernel` identifies a host-launchable entry and `@device` a helper callable
only from device code.  Kernel parameters are explicitly address-space
qualified.  Conversion between host and device pointers is forbidden; buffer
objects mediate transfer.  Workgroup variables have one instance per
workgroup, private variables one per invocation, and device/global storage has
a lifetime governed by its host handle.  Constant/uniform storage is read-only.
Native x86-64 lowering rejects `*device` and `*workgroup` dereference/indexing;
it must not reinterpret device addresses as host pointers while the GPU runtime
is unavailable.

Invocation, workgroup, and grid dimensions are validated against backend limits
before submission.  A kernel must include an explicit `id < len` guard unless
the dispatch API proves its exact domain.  A workgroup barrier is valid only
when every active invocation reaches the same dynamic instance; the frontend
rejects provable divergence and the backend validator rejects residual invalid
control flow.

## Synchronization and errors

Device fences carry storage scope and ordering; they do not synchronize the
host.  Queue completion/fence waiting is the host synchronization point for
readback.  Device loss, validation failure, timeout, compilation failure, and
transfer failure return structured errors, never plausible output.  A timeout
must not free storage still used by the driver; destroy the context if safe
cancellation is unavailable.

## Truthful milestones

The support matrix distinguishes syntax accepted, semantic validation, MLIR
emitted, MLIR verified, target binary produced, runtime loaded, kernel launched,
results checked, and performance measured.  Current GPU bundle/VM facilities
are not a physical GPU runtime.
