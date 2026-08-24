# Linux concurrency services

Zag's current Linux x86-64 application foundation includes two deliberately
bounded concurrency modules:

- `std:linux_epoll` owns `epoll` and nonblocking `eventfd` descriptors. A wait
  accepts 1 through 64 output slots and a timeout from 0 through 5000 ms. The
  implementation issues `epoll_create1`, `epoll_ctl`, `epoll_wait`, `eventfd2`,
  `read`, `write`, and `close` syscalls directly.
- `std:channel_i64` is a fixed-capacity SPSC ring for `i64` values. Capacity is
  immutable and limited to 1 through 64. Exactly one producer and one consumer
  may use a channel. Release/acquire atomics publish slots, and bounded private
  futex waits block full or empty operations without an idle polling loop.

Successful constructor results must be consumed with their `take` helper.
Open handles are move-by-convention until the language can make resource
structs noncopyable. `close` is one-time, and closing concurrently with an
operation is outside the contract. Every blocking channel operation has a
finite caller-supplied timeout and at most 64 kernel-wait attempts.

`std:cancel_token_i64` adds a caller-owned, one-shot cooperative cancellation
token. It uses an acquire/release i64 flag, supports idempotent request and
post-join close, and is safe to poll from a joined Linux worker. It does not
interrupt a blocked syscall or infer task lifetime.

`std:channel_i64_cancel` adapts the SPSC send/receive waits to that token. It
uses finite ten-millisecond polling slices, a five-second total bound, and a
64-attempt cap; cancellation is reported explicitly and never consumes a
queued value. The adapter does not change the channel's one-producer/one-
consumer ownership rule.

The reference application at `tests/reference_apps/async_worker/main.zag`
uses two channels and one real `@threadSpawn`/`@threadJoin` worker. One parent
producer sends eight jobs, one worker produces eight deterministic results,
and both mapped channel pages are released after join. The focused gate checks
exact output, allocator balance, static ELF64 x86-64 output, byte-identical
rebuilds, kernel epoll/eventfd/futex/clone activity, timeout behavior, and
invalid, empty, full, closed, capacity, and double-close cases:

```sh
bash tests/run_linux_concurrency_services.sh
```

This evidence is not language async/await, automatic cancellation propagation,
a scheduler, a general worker pool, MPMC channels, portable concurrency, or
automatic race-freedom and lifetime inference. Those remain separate
language/runtime work.
