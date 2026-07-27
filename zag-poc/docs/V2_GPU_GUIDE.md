# Zag v2 GPU guide (draft)

Zag does not currently execute a GPU kernel.  MLIR text, deterministic bundles,
and a virtual GPU model are compilation/validation aids, not a device runtime.
Do not use them to claim device enumeration, allocation, dispatch, barriers,
or checked readback.

The first physical backend is planned as an opt-in direct Linux AMDGPU DRM
adapter for the native `amdgpu-gfx1010` target; Vulkan is a development
frontend, not a runtime dependency. A test begins with an explicitly selected
render node, tiny buffers, a conservative one-workgroup dispatch, a driver
fence timeout, strict host bounds, and full cleanup. On the display-bound AMD
RX 5700 XT it must never submit an unbounded workload. Absence of a compatible
device is an explicit skip with the discovered reason; a compatible device
requires checked CPU-vs-GPU output before it is counted as operational.

Device code must use typed host/device/workgroup/private/constant address
spaces, a bounded kernel domain, and barrier-safe uniform control flow.  Host
allocation, OS I/O, dynamic loading, and arbitrary FFI remain invalid in device
code even inside `unsafe`.
