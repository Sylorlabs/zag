# Bounded configuration and structured logging

`std:config_flat` and `std:log_json` provide a small deterministic application
configuration and logging foundation.

The configuration parser accepts blank lines, whole-line `#` comments, and
flat `key = value` entries. It borrows slices from a caller-owned input buffer,
allocates nothing, rejects duplicates, malformed keys, control bytes, and
limit exhaustion, and exposes exact boolean and signed 64-bit conversion.
Inputs are capped at 65,536 bytes, 128 entries, 64 bytes per key, and 4,096
bytes per value. There are deliberately no sections, includes, interpolation,
environment expansion, secret storage, or implicit coercions.

The logging encoder preflights one JSON Lines record into a caller-owned buffer,
so validation and capacity failures do not modify that buffer. Records contain
checked realtime seconds/nanoseconds, one of four severity levels, a bounded
event name, and an escaped message. The v1 message contract is printable ASCII
plus tab, CR, and LF; it does not claim Unicode normalization. A bounded write
helper handles partial writes and `EINTR` without allocating.

Run the focused native gate with:

```sh
bash tests/run_config_log_services.sh
```

It covers valid lookup and typed conversion, duplicate/malformed/capacity
failures, overflow, exact structured stderr, non-mutating log failures,
allocator balance, and static Linux x86-64 output. This is not a hot-reload
configuration service, multi-process log rotation, remote telemetry, tracing,
redaction engine, or cryptographic audit log.
