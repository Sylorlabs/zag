# Linux clock and entropy services

`std:os_linux` is the bounded Linux x86-64 foundation for wall-clock reads,
monotonic elapsed-time reads, and secure random bytes.

- `os_linux_realtime()` and `os_linux_monotonic()` return a checked seconds and
  nanoseconds pair from `clock_gettime(2)`.
- `os_linux_secure_random_fill()` fills a caller-owned buffer through
  `getrandom(2)`. It accepts 1 through 65,536 bytes and performs at most 128
  kernel calls.
- The bounded random variant exposes a smaller call budget. Interrupted calls
  retry inside that budget; any other kernel error and any incomplete fill are
  reported without claiming success.
- Validation failures do not mutate the supplied buffer. The module performs no
  allocation and never substitutes timestamps, a userspace PRNG, `/dev/urandom`,
  or weak partial output for a successful kernel fill.

The focused native gate is:

```sh
bash tests/run_os_linux_services.sh
```

The gate validates both clock domains, monotonic ordering across a kernel sleep,
two independent kernel entropy fills, bounds and non-mutation failures,
allocator balance in the caller, and a static Linux x86-64 executable.

This slice does not claim timer queues, sleeps as a public API, timezone or
calendar conversion, deterministic seeded randomness, hardware RNG attestation,
non-Linux targets, logging, or configuration loading.
