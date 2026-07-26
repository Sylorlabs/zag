# Zag v2 concurrency guide (draft)

The current v2 public atomic slice is intentionally nine fixed-order
operations: `@atomicLoad64(ptr: *const/*mut i64) i64`,
`@atomicStore64(ptr: *mut i64, value: i64) void`, and
`@atomicExchange64(ptr: *mut i64, value: i64) i64`, plus
`@atomicCompareExchange64(ptr: *mut i64, expected: i64, desired: i64) i64`,
`@atomicFetchAdd64(ptr: *mut i64, delta: i64) i64`, and
`@atomicFetchSub64(ptr: *mut i64, delta: i64) i64`, plus
`@atomicFetchAnd64(ptr: *mut i64, mask: i64) i64`,
`@atomicFetchOr64(ptr: *mut i64, mask: i64) i64`, and
`@atomicFetchXor64(ptr: *mut i64, mask: i64) i64`.
Compare-exchange returns the old word whether the swap succeeds or fails. They are callable only
inside an `unsafe` block on Linux x86-64 native output. Load emits `LOCK XADD`
with zero, preserving and returning the old word; store/exchange use memory
`XCHG`, which is implicitly locked by x86. The compiler rejects invalid
mutability and non-`i64` bound store/exchange/compare-exchange values; integer
literals are contextually accepted as `i64`. The runtime rejects null or misaligned addresses
before issuing the instruction. With `--safety=checked`, ordinary allocator liveness/bounds
instrumentation also runs before each operation.
The bitwise fetches evaluate their pointer and mask once, then use a locked
compare-exchange retry loop. They are lock-free but not wait-free: contention
can cause retries, so they remain outside a realtime guarantee.

This is not a general atomic or concurrency API: there are no atomic storage
types, selectable memory orders, fences with
language ordering semantics, thread spawn/join, or race detector. The raw
pointer's allocation, lifetime, sharing, and absence of mixed atomic/non-atomic
access remain the caller's unsafe contract. `@volatileLoad`/`@volatileStore`
and their explicit 8/16/32-bit companions remain MMIO transactions, not
atomics: they neither synchronize threads nor imply a memory order.
`@memoryFence` remains a legacy native `mfence` emission, not a typed fence
operation; it carries the `Unsafe` effect and cannot make a `@pure` or
`@realtime` function appear compliant.

Safe concurrent APIs own or synchronize every mutable shared object.  Raw
shared access, lifetime handoff, and mixed atomic/non-atomic transitions are
unsafe contracts.  `@realtime` code must use bounded lock-free algorithms or
explicitly fail capability checking; mutexes, condition waits, sleep, and OS
thread operations are not permitted there.

`tests/run_v2_atomic_exchange.sh` proves load/store/exchange/compare-exchange/
fetch-add/sub/and/or/xor results and inspects the emitted ELF for locked `xadd`, `xchg`, and
`cmpxchg`;
it also covers compare-exchange unsafe, arity, mutability, and value-type
rejection, `Unsafe` effect rejection in `@pure`, and the shared misalignment
failure path. A successful
single-thread run is not a memory
model proof. Each future primitive still needs a positive execution test, a
timeout-bounded stress test, and a negative effect test.
