# Bounded MPMC channel

`std/channel_mpmc_i64.zag` provides a Linux x86-64, fixed-capacity i64 queue
with multiple-producer/multiple-consumer try operations. It uses a sequence
word per slot and acquire/release/CAS publication; the focused gate proves
FIFO behavior, full/empty/closed diagnostics, static self-contained output,
and byte-identical rebuilds.

This is intentionally not an async language feature. Operations are bounded
and non-blocking: a full queue returns `status_full`, an empty queue returns
`status_empty`, and sustained contention returns `status_contention`. A
caller may compose it with an explicit epoll/futex policy. Handles must not
be copied into independent owners, and `close` is only valid after all
operations have quiesced. There is no scheduler, cancellation inference,
fairness guarantee, dynamic capacity, arbitrary element type, or ARM64
certification. The broader concurrency and async/await capability rows
therefore remain partial/unavailable.

Capacity is a power of two from 2 through 64. A one-slot MPMC ring is rejected
because the sequence layout cannot distinguish a published item from a
released slot; use the cancellation adapter or an SPSC channel for a one-slot
bounded handoff.
