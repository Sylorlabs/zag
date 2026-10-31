# Bounded TaskI64 runtime

Zag currently exposes a deliberately narrow Linux x86-64 cooperative task
boundary through compiler intrinsics. `@taskSpawn(worker, input)` accepts only
a direct, captureless, non-generic `fn(i64) i64` worker and returns an affine
`*opaque` handle. `@taskAwait` joins and returns the worker's `i64` result;
`@taskCancel` sets a cancellation flag; workers poll `@taskCancelled` and may
read their copied input with `@taskInput`.

The handle owns a compiler-created clone stack and result slot. Await is the
only release operation. Calls are unsafe, target-specific, and fail closed for
captures, generics, indirect function values, wrong worker signatures, wrong
handle types, or leaked handles.

`std:task_i64` provides the typed boundary helpers
`task_i64_valid`, `task_i64_cancel`, and `task_i64_cancelled`. These observation
and cancellation operations borrow the handle. `task_i64_ready` is a bounded
non-consuming completion poll backed by the kernel child-tid word; it reports
only ready/not-ready and does not release the handle. `task_i64_poll` adds a
target-specific result observation: after readiness it reads the documented
Linux x86-64 result word and reports pending or ready without consuming the
handle. The direct `task_i64_result_borrowed` helper returns zero for a null
handle instead of dereferencing it. Every poll carries typed `ok` and `code`
fields: pending and ready
observations use the success status, while a null/invalid handle returns a
rejected result with the explicit invalid-handle status. It also carries
`cancellation_requested`; this observes the
cooperative request flag but does not claim that the worker has stopped or
that its result is ready. `task_i64_poll_cascaded` adds one explicit
borrow-only parent-to-child
cancellation propagation step during polling, rejecting null or aliased
handles and still requiring exactly-once consuming awaits. The ABI has no
automatic scheduler propagation or parent-readable cancellation-state word;
cancellation is therefore observed through the worker's result after
consuming await (the fixture uses its explicit `-999` cancellation result). The consuming await remains the compiler-owned
`@taskAwait` spelling because release must stay visibly ownership-aware at the
source boundary. `task_i64_wait(handle, timeout_ms)` adds a bounded,
non-consuming observation loop (zero to 5000 ms) that yields between readiness
samples and returns the same pending/ready result shape; invalid intervals are
rejected and a timeout never releases the handle. The façade, result poll,
bounded wait, and double-await rejection are
verified by `tests/run_task_i64_library.sh`; this does not add generic futures
or hide the one-shot consume. `task_i64_wait_cancel(handle, token,
timeout_ms)` composes that same bounded poll with the caller-owned,
one-shot `std:cancel_token_i64`: it checks the token before each sample and
requests cooperative task cancellation when the token is set. It rejects
null/closed tokens and invalid intervals, never consumes the token or task,
and still requires exactly one `@taskAwait`. The token bridge is verified by
`tests/run_task_i64_wait_cancel.sh`; it is explicit caller policy, not
automatic scheduler propagation.

`std:task_i64_select` provides a fixed max-eight borrowed ready/value selector
with duplicate/null/timeout validation. `std:task_i64_scope` builds the next
bounded composition: a parent handle plus a dense prefix of up to seven child
handles is polled cooperatively, parent cancellation is propagated to active
children, and a ready child is selected before each child is removed and
awaited exactly once. The scope is caller-maintained and Linux-specific; it is
not a generic executor, forced-cancellation primitive, or automatic scheduler.

`std:task_i64_cancel_join` adds an explicit consuming cleanup helper. It
requests cooperative cancellation, samples the request bit, awaits exactly
once, and writes a `TaskI64JoinResult`, including distinct invalid-handle and
invalid-output paths. A null output still consumes a valid handle after the
request/await sequence. The focused `tests/run_task_i64_cancel_join.sh` gate
proves this seam; it remains cooperative, Linux-specific, and non-generic.

`std:task_i64_wait_many` adds a bounded non-consuming observation over a
disjoint set of at most eight handles. It returns a typed completed count,
ready bitmask, cancellation bitmask, and per-slot values, with explicit
timeout, duplicate/null-set, and output-pointer rejection. It never awaits or
releases a handle; callers retain the affine `@taskAwait` responsibility. The
focused `tests/run_task_i64_wait_many.sh` gate proves the transport and its
fail-closed boundaries without claiming generic futures or scheduler
semantics.

For callers that need one typed completion record, `task_i64_await_into` takes
an affine handle and a caller-owned `TaskI64JoinResult`, samples the cooperative
cancellation bit, performs exactly one `@taskAwait`, and writes `{ok, code,
value, cancellation_requested}`. Null handles and null output pointers are
rejected with distinct status codes. A valid affine handle is still consumed
exactly once when the output pointer is null; only a null handle is rejected
before consumption. This is a bounded i64 status/value transport only; it does
not introduce generic result types, error unions, or scheduler semantics.

The first bounded language spelling is now `async fn worker() i64` or
`async fn worker(i64) i64`, followed by `await(handle)` and explicit
`cancel(handle)`. Both forms lower directly to this same TaskI64 ABI and are
guarded by the exact captureless worker contract; callers still use an
explicit `unsafe` block. The zero-argument form has no source input payload;
the raw `@taskSpawn` intrinsic remains restricted to a direct `fn(i64) i64`
worker. This is not a general future or scheduler: there is no state-machine
lowering, automatic scheduler cancellation propagation, generic result/error
channel, or portable target. Fresh native evidence is collected by
`tests/run_async_surface.sh`; that gate covers both bounded Linux x86-64
spellings, so the language row is partial while the general contract remains
unavailable.
