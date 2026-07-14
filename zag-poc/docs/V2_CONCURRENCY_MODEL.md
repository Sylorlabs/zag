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
