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
- `std:channel_mpmc_i64` is a separate fixed-capacity MPMC try-only ring for
  `i64` values. Capacity is a power of two from 2 through 64; a one-slot MPMC
  ring is rejected because its sequence layout cannot distinguish a published
  item from a released slot. Multiple producers and consumers reserve
  sequence-numbered slots with acquire,
  release, and CAS operations; full, empty, contention, closed, and wrap-limit
  outcomes are explicit. It is non-blocking and has no implicit scheduler or
  cancellation behavior.

Successful constructor results must be consumed with their `take` helper.
The `take` helpers fail closed for null, unsuccessful, closed, or negative-fd
results, including caller-forged aggregate state; they never turn an invalid
descriptor into an open resource.
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

`std:channel_mpmc_i64_cancel` composes the same token with the MPMC try-only
queue. Its send/receive waits use finite ten-millisecond sleep slices, a
five-second total bound, and a 512-attempt cap; cancellation is explicit and
queued values are not consumed by a cancelled operation. It remains i64-only,
Linux x86-64, and does not provide scheduler integration or concurrent close.

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
a scheduler, a general worker pool, portable concurrency, or automatic
race-freedom and lifetime inference. The MPMC slice is Linux x86-64 and i64
only, and its quiescent-close/try-only contract remains separate runtime work.
