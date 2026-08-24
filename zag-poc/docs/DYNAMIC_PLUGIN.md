# Bounded dynamic-plugin contract

`std:dynamic_plugin` is the Linux x86-64 runtime-loading slice used by the
ZagScript reference application suite. It opens a caller-selected shared
object with `dlopen(RTLD_NOW)`, resolves one named symbol with `dlsym`, invokes
that symbol, and closes the handle with `dlclose`.

The public boundary is intentionally narrow:

- the symbol must have the C ABI shape `i64 fn(i64)`;
- paths are non-empty, NUL-free, and at most 4096 bytes;
- symbols are C identifiers of at most 255 bytes;
- the raw address is never returned to the caller;
- a successful close invalidates the handle and releases its function carrier;
- a close failure retains the carrier so the caller can retry;
- consumers must opt into `--dynamic --needed libdl.so.2`.

Until the language enforces non-copyable resources, a live plugin value is
linear by contract: do not copy it, and close the successfully loaded value
exactly once.

The focused reference gate proves a real C plugin call, destructor execution
during close, use-after-close and double-close rejection, missing-library and
missing-symbol failures, allocation cleanup, exact ELF dependencies, and
byte-identical host artifacts from different working directories.

This does not claim general C signatures, aggregate ABI, callbacks, concurrent
calls, thread safety, hot reload, dependency isolation, namespace isolation,
signature verification, or shared-object production by `znc`.
