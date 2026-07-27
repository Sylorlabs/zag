# Zag v2 concurrency model (draft)

The complete model below is not implemented. The current executable slice is
limited to edition-2027 native x86-64 `@atomicLoad64`, `@atomicStore64`,
`@atomicExchange64`, `@atomicCompareExchange64`, `@atomicFetchAdd64`, and
`@atomicFetchSub64`, `@atomicFetchAnd64`, `@atomicFetchOr64`, and
`@atomicFetchXor64` on naturally aligned raw
`i64` pointers. These are unsafe,
fixed full-order x86 transactions, plus literal-validated
`@atomicLoad64Order(ptr, order)`, `@atomicStore64Order(ptr, value, order)`,
the suffixed RMW order forms, and
`@atomicCompareExchange64Order(ptr, expected, desired, success, failure)`, and
`@atomicFence(order)`. The fence accepts the same literal order ABI: relaxed is
a no-op, and every non-relaxed order lowers conservatively to a full hardware
fence. Compiler-reserved `AtomicI64` storage now exists for a deliberately
narrow receiver-only native slice; threads and litmus evidence remain release
blockers. See
`docs/V2_CONCURRENCY_GUIDE.md` for the implemented boundary.

Edition-2027 Linux/x86-64 also has two deliberately narrow futex building
blocks: `@atomicWait32(ptr: *const/*mut/*host i32, expected: i32) i64` and
`@atomicWake32(ptr: *const/*mut/*host i32, count: i32) i64`. They issue the
shared `futex(2)` WAIT/WAKE operations and return the raw kernel result. They
are unsafe, require a non-null four-byte-aligned host word, and do not supply
a memory order, retry policy, ownership transfer, or a thread API. In
particular, a caller must not infer a happens-before edge merely from these
operations; `AtomicI64` does not yet make that general language-model claim.

Data races on non-atomic shared storage are forbidden behavior.  The intended
full model gives atomic scalar and pointer operations relaxed, acquire,
release, acq_rel, and seq_cst orders; the implemented slice currently validates
the load/store/RMW/CAS forms described above.  Invalid combinations in that
slice are compile-time errors.  Atomic objects require natural alignment and
have explicit lifetime rules.  Mixed atomic/non-atomic concurrent access is a
race.

Happens-before follows sequenced-before, release/acquire reads-from edges,
thread spawn/join, mutex unlock/lock, and condition-variable notification/wait.
Fences constrain compiler and CPU reordering according to their order. Volatile
is never synchronization.  Thread spawning, joining, mutexes, conditions,
semaphores, yielding, sleeping, and TLS are OS-target APIs with `Thread`,
`Block`, `Lock`, and/or `IO` effects.  `@realtime` rejects blocking and OS calls;
lock-free atomics remain allowed when their effects otherwise fit.

## Atomic API and ordering validity

The implemented order ABI uses literals `0=relaxed`, `1=acquire`,
`2=release`, `3=acq_rel`, and `4=seq_cst`. Loads reject release/acq_rel and
stores reject acquire/acq_rel at compile time. RMW forms accept every literal;
compare-exchange validates separate success/failure literals, with failure
limited to relaxed/acquire/seq_cst and no stronger than success. On x86-64, the bounded
load/store forms use MOV for relaxed/acquire/release and locked transactions
for seq_cst, while every RMW/CAS order form intentionally retains its existing
locked seq_cst-superset lowering; this does not establish compiler-wide ordering
or a happens-before graph. `AtomicI64` is compiler-reserved, one-word opaque
storage initialized locally with `@atomicI64(i64)` or as a zeroed global. Its
unsafe receiver operations are `load`, `store`, `exchange`, `fetch_add`,
`fetch_sub`, `fetch_and`, `fetch_or`, `fetch_xor`, and `compare_exchange`.
It cannot be read, copied, assigned, addressed, cast, embedded, passed, or
returned. The legacy operations accept unsafe raw `i64` pointers only; neither
API makes mixed atomic/non-atomic access safe. A load cannot use release, a store cannot use
acquire, and an invalid ordering is a compile-time error. `compare_exchange`
specifies separate success and failure orders, with failure no stronger than
success and never release/acq_rel.

`@atomicFence(order)` is an unsafe typed operation. `relaxed` emits no machine
fence; acquire, release, acq_rel, and seq_cst each currently emit the same
conservative full target fence. This bounded lowering validates fence-order
inputs, but it does not establish compiler-wide ordering, a happens-before
model, thread safety, or object lifetime.

`relaxed` provides atomicity only.  A release operation synchronizes with an
acquire operation that reads its value or its release sequence.  `seq_cst`
operations participate in one global total order in addition to their ordinary
acquire/release constraints.  Fences only establish synchronization alongside
the required atomic reads/writes; they are not a substitute for atomic storage.
The compiler must preserve these edges in IR and target lowering, including
across inline assembly with a memory clobber.

## Race and lifetime rules

Two conflicting non-atomic accesses not ordered by happens-before are a data
race and violate the unsafe/shared-memory contract.  Safe APIs must prevent
such access through ownership, synchronization, or an explicitly unsafe shared
view.  Atomic and non-atomic accesses to the same storage are also a race
unless the object is no longer concurrently reachable and the transition is
synchronized.  An atomic object's storage cannot be freed, reused, or
reinterpreted while another thread can access it.

## Threads and blocking

Linux/x86-64 native output now has a bounded unsafe `@threadSpawn(worker)` /
`@threadJoin(handle)` pair. Spawn accepts only a direct captureless `fn() void`
worker and returns an affine `*opaque` handle; join consumes that handle after
the kernel clears its TID and wakes the futex. This establishes a real kernel
completion boundary for the worker and join result, but does not yet model
worker arguments, detach, mutexes, condition variables, TLS, general atomic storage,
or general source-level happens-before/race freedom. `selfhost/native/thread_rt.zag`
remains an unintegrated historical sketch and is not evidence of support.
Every future stress test must have a timeout and report timeout separately from
an incorrect result.
