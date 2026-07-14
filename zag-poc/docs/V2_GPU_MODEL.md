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
