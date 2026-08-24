# Explicit dynamic system ABI

Zag's native x86-64 backend can emit a minimal dynamic ELF without invoking
`cc`, `as`, or `ld`:

```sh
znc app.zag --dynamic --needed libvulkan.so.1 -o app
```

This mode exists for bounded system transports such as Vulkan. It does not
replace Linux's kernel GPU driver. The Zag application and compiler own the
scene/compute model and explicit dependency list; the installed ELF interpreter
and Vulkan loader resolve the requested SONAME and symbols.

The current C-call surface is intentionally narrow and fail-closed:

- outbound calls only;
- integer, boolean, pointer, and void parameters/returns;
- System V AMD64 register and stack argument placement (the executable gate
  covers a fixed seven-integer call, including one stack argument);
- one `R_X86_64_GLOB_DAT` GOT slot per non-`_zag_` extern declaration;
- explicit safe SONAMEs only; no path-bearing dependency names;
- no float, aggregate, TLS, variadic, debug, hot-reload, or mixed
  static/dynamic linking support yet. The sole callback exception is a direct,
  captureless named scalar/pointer Zag function passed to a declared `fn(P...)R`
  parameter as one code pointer; function-value aliases and captures reject.

Ordinary builds remain static. `--needed` without `--dynamic`, an unsupported
ABI class, an unsafe SONAME, or an empty import surface rejects the build.

`tests/run_dynamic_abi.sh` proves the ELF metadata, positive Vulkan loader call,
and negative fail-closed boundaries. `tests/run_gpu_runtime.sh` adds the
separate pure-Zag loader probe and generated host harness that submits a
bounded Vulkan shader and verifies readback on the local RADV device. This is
still not a claim of complete general C ABI coverage or a native DRM backend.
