# Zag v2 concurrency guide (draft)

The v2 atomic/thread API is not implemented.  When it exists, selecting an
atomic order will be an explicit design decision rather than a default hidden
behind a convenience wrapper.  Use release/acquire only when a publication edge
is intended, relaxed only for atomicity without ordering, and seq_cst only when
its global order is required by the algorithm.

Safe concurrent APIs own or synchronize every mutable shared object.  Raw
shared access, lifetime handoff, and mixed atomic/non-atomic transitions are
unsafe contracts.  `@realtime` code must use bounded lock-free algorithms or
explicitly fail capability checking; mutexes, condition waits, sleep, and OS
thread operations are not permitted there.

Each future primitive needs a positive execution test, a timeout-bounded stress
test, and a negative effect test.  A successful run on one CPU is not a memory
model proof; litmus outcomes and target lowering are both release evidence.
