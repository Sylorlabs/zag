# Zag v2 concurrency model (draft)

Data races on non-atomic shared storage are forbidden behavior.  Atomic scalar
and pointer operations provide relaxed, acquire, release, acq_rel, and seq_cst
orders; invalid order-operation combinations are compile-time errors.  Atomic
objects require natural alignment and have explicit lifetime rules.  Mixed
atomic/non-atomic concurrent access is a race.

Happens-before follows sequenced-before, release/acquire reads-from edges,
thread spawn/join, mutex unlock/lock, and condition-variable notification/wait.
Fences constrain compiler and CPU reordering according to their order. Volatile
is never synchronization.  Thread spawning, joining, mutexes, conditions,
semaphores, yielding, sleeping, and TLS are OS-target APIs with `Thread`,
`Block`, `Lock`, and/or `IO` effects.  `@realtime` rejects blocking and OS calls;
lock-free atomics remain allowed when their effects otherwise fit.

## Atomic API and ordering validity

Atomic types are distinct storage types, not a qualifier that can be applied
to an ordinary object after concurrent access begins.  They provide load,
store, exchange, compare-exchange, fetch-add/sub/and/or/xor, and fences for
the scalar and pointer widths that the target can lower correctly.  A load
cannot use release, a store cannot use acquire, and an invalid ordering is a
compile-time error.  `compare_exchange` specifies separate success and failure
orders, with failure no stronger than success and never release/acq_rel.

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

`spawn` publishes argument ownership before the new thread starts; `join`
establishes happens-before from all completed child actions to the join return.
Detach is not provided until a lifetime-safe handle and shutdown contract exist.
Mutexes are non-reentrant unless explicitly typed otherwise.  Condition waits
atomically release and later reacquire their mutex, tolerate spurious wakeups,
and must be used in a predicate loop.  Every stress test has a timeout and
must report timeout separately from an incorrect result.
