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
The load/store subset also has an explicitly limited order form:
`@atomicLoad64Order(ptr, order)` and
`@atomicStore64Order(ptr, value, order)`, where the order is a compile-time
literal `0=relaxed`, `1=acquire`, `2=release`, `3=acq_rel`, or `4=seq_cst`.
Loads reject release/acq_rel; stores reject acquire/acq_rel. On x86-64,
relaxed/acquire loads and relaxed/release stores lower to ordinary MOV
transactions, while seq_cst uses the existing locked transaction. This is a
real ordering-validation/lowering slice, not a thread or race proof.
The same literal vocabulary is accepted by the suffixed RMW forms
`@atomicExchange64Order`, `@atomicFetchAdd64Order`,
`@atomicFetchSub64Order`, `@atomicFetchAnd64Order`,
`@atomicFetchOr64Order`, and `@atomicFetchXor64Order` with `(ptr, value,
order)`, plus `@atomicCompareExchange64Order(ptr, expected, desired, success,
failure)`. Every valid RMW/CAS order currently keeps its established locked
x86 lowering (a seq_cst superset); CAS failure is restricted to
relaxed/acquire/seq_cst and may not be stronger than success. This is not a
claim of relaxed machine code or of a complete language memory model.
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

`@atomicFence(order)` accepts the same literal order ABI. `0=relaxed` emits
no hardware fence; each non-relaxed order emits a conservative full hardware
fence (`mfence` on x86-64 and `dmb` on ARM). It is a typed `Unsafe` operation,
but does not establish a compiler-wide happens-before graph, prove object
lifetime, or provide thread/race safety.

On Linux x86-64, `@atomicWait32(ptr, expected) i64` and
`@atomicWake32(ptr, count) i64` are a separate unsafe futex(2) slice. They
accept only non-null, four-byte-aligned `*const`, `*mut`, or `*host i32`
pointers and a typed `i32` expected value/count; checked mode also validates
tracked allocation liveness and four-byte bounds before the syscall. Wait maps
to shared `FUTEX_WAIT`; wake maps to shared `FUTEX_WAKE`; both return the raw
kernel result, including negative errno values. There is deliberately no
implicit retry, timeout conversion, ownership handoff, or memory-order claim.
These primitives are useful native building blocks, but they do not establish
atomic storage, a happens-before relation, race freedom, or a supported
threading API.

This is not a general atomic or concurrency API: there are no atomic storage
types, thread spawn/join, or race detector. The raw
pointer's allocation, lifetime, sharing, and absence of mixed atomic/non-atomic
access remain the caller's unsafe contract. `@volatileLoad`/`@volatileStore`
and their explicit 8/16/32-bit companions remain MMIO transactions, not
atomics: they neither synchronize threads nor imply a memory order.
`@memoryFence` remains a legacy native `mfence` emission; `@atomicFence` is
the typed fence entry point. Both carry the `Unsafe` effect and cannot make a `@pure` or
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
`tests/run_v2_atomic_orders.sh` separately proves the literal order ABI across
load/store/RMW/CAS, invalid load/store and CAS failure combinations,
runtime-order rejection, unsafe enforcement, typed-fence execution and
lowering, and the MOV versus locked x86 lowering boundary.
`tests/run_x86_atomic_futex.sh` runs a deliberately nonblocking mismatched
wait and waiter-free wake under `strace`, proving actual `FUTEX_WAIT`/`WAKE`
kernel calls and raw return values while also covering unsafe, type, pure, and
null-pointer rejection. It is not a thread stress or litmus test.
