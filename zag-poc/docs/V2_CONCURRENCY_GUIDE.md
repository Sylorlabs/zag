# Zag v2 concurrency guide (draft)

The current v2 public atomic slice is intentionally four fixed-order
operations: `@atomicLoad64(ptr: *const/*mut i64) i64`,
`@atomicStore64(ptr: *mut i64, value: i64) void`, and
`@atomicExchange64(ptr: *mut i64, value: i64) i64`, plus
`@atomicCompareExchange64(ptr: *mut i64, expected: i64, desired: i64) i64`.
Compare-exchange returns the old word whether the swap succeeds or fails. They are callable only
inside an `unsafe` block on Linux x86-64 native output. Load emits `LOCK XADD`
with zero, preserving and returning the old word; store/exchange use memory
`XCHG`, which is implicitly locked by x86. The compiler rejects invalid
mutability and non-`i64` bound store/exchange/compare-exchange values; integer
literals are contextually accepted as `i64`. The runtime rejects null or misaligned addresses
before issuing the instruction. With `--safety=checked`, ordinary allocator liveness/bounds
instrumentation also runs before each operation.

This is not a general atomic or concurrency API: there are no atomic storage
types, fetch operations, selectable memory orders, fences with
language ordering semantics, thread spawn/join, or race detector. The raw
pointer's allocation, lifetime, sharing, and absence of mixed atomic/non-atomic
access remain the caller's unsafe contract. `@volatileLoad` and
`@volatileStore` remain MMIO transactions, not atomics: they neither synchronize
threads nor imply a memory order.

Safe concurrent APIs own or synchronize every mutable shared object.  Raw
shared access, lifetime handoff, and mixed atomic/non-atomic transitions are
unsafe contracts.  `@realtime` code must use bounded lock-free algorithms or
explicitly fail capability checking; mutexes, condition waits, sleep, and OS
thread operations are not permitted there.

`tests/run_v2_atomic_exchange.sh` proves load/store/exchange/compare-exchange
results and inspects the emitted ELF for locked `xadd`, `xchg`, and `cmpxchg`;
it also covers compare-exchange unsafe, arity, mutability, and value-type
rejection, `Unsafe` effect rejection in `@pure`, and the shared misalignment
failure path. A successful
single-thread run is not a memory
model proof. Each future primitive still needs a positive execution test, a
timeout-bounded stress test, and a negative effect test.
