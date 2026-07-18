# Zag Script bounded-process boundary

Status: supervisor blocked; stable result ABI implemented, 2026-07-18.

Zag Script does not expose `process_run_timeout`. The existing native
`_zag_exec_capture(command)` is deliberately not used as its implementation.
It creates a pipe and child shell, performs a blocking read until EOF, and only
then waits for the child. A Zag wrapper cannot regain control while that read is
blocked, so it cannot enforce a deadline.

The executable characterization in `tests/process_timeout_blocker.zag` proves
the current helper returns after a sleeping child, not at a requested deadline.
`tests/process_timeout_unavailable.zag` proves the misleading convenience stays
unavailable.

## Required native supervisor

The smallest correct Linux x86-64 primitive must implement all of these together:

1. Create a `pipe2` pipe with nonblocking parent observation.
2. Fork and place the child shell in a new process group before `execve`.
3. Close unused descriptors in both processes.
4. Drain stdout while checking `wait4(..., WNOHANG)` and a monotonic deadline.
5. Enforce a caller-provided output cap without deadlocking a verbose child.
6. On timeout or output overflow, signal the entire child process group.
7. Perform a blocking `wait4` after the signal so no zombie remains.
8. Close descriptors on every syscall failure path.
9. Return a statically typed result containing captured bytes, exit status,
   timeout/overflow state, and a runtime-error code.

The backend currently has fragments of this (`pipe2`, `fork`, `execve`, blocking
read, and `wait4`) but no nonblocking supervision state machine.

The result boundary is implemented independently: `ProcessResult` contains a
compiler-owned opaque handle. Typed ordinary-Zag getters expose status, state,
and captured output. The handle layout is fixed at four 64-bit words (status,
state, output pointer, output length), so module name prefixing cannot change the
runtime ABI. The native supervisor will construct this handle directly.

Adding only a timer around the current call,
killing only the shell PID, or returning partial output as success would be an
incorrect implementation.

Required acceptance tests are normal completion with captured stdout, nonzero
exit, deadline expiry, descendant termination, output-cap overflow, exec failure,
and repeated timeout runs with no unreaped children or descriptor growth.
