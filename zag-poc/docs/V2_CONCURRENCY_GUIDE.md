# Zag v2 concurrency guide (draft)

The current v2 public atomic slice is intentionally one operation:
`@atomicExchange64(ptr: *mut i64, value: i64) i64`, callable only inside an
`unsafe` block on Linux x86-64 native output. It emits one memory `XCHG`, which
is implicitly locked by x86 and returns the prior 64-bit value. The compiler
rejects a non-mutable pointer and the runtime rejects null or misaligned
addresses before issuing the instruction. With `--safety=checked`, ordinary
allocator liveness/bounds instrumentation also runs before the exchange.

This is not a general atomic or concurrency API: there are no atomic storage
types, load/store/CAS/fetch operations, selectable memory orders, fences with
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

`tests/run_v2_atomic_exchange.sh` proves the exchange result and inspects the
emitted ELF for `xchg`; it also covers the unsafe, pointer-mutability, and
misalignment failure paths. A successful single-thread run is not a memory
model proof. Each future primitive still needs a positive execution test, a
timeout-bounded stress test, and a negative effect test.
