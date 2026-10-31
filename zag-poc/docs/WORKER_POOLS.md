# Bounded worker-pool foundation

ZagScript now ships a deliberately narrow Linux/x86-64 worker-pool primitive in
`std/worker_pool_i64.zag`. It accepts an explicitly owned stable `*i64` job
region, copies at most 64 jobs into a pool-owned page, starts at most eight
captureless workers, atomically claims indexes, accumulates an i64 result, and
joins every worker before returning.

The API is an unsafe boundary because the caller owns the input region for the
duration of the call. The implementation copies the input before starting
workers and never retains the caller pointer. Bounds, spawn failures, incomplete
completion, static ELF output, deterministic rebuilds, and clone/futex witnesses
are covered by `tests/run_worker_pool_i64.sh`.

This is not ZagScript `async`/`await`, a scheduler, a generic task/result API,
or a proof that arbitrary shared code is race-free. The optional cancellation
entry point accepts a one-shot token and polls it only between finite jobs; it
cannot interrupt an in-flight operation or provide general task cancellation
propagation. A separate `std/channel_mpmc_i64` module now covers bounded,
try-only i64 MPMC queues; scheduler, async/await, portable, and generic-element
gaps remain separate capability gaps in the 1.0 matrix.
