# Zag Script bounded-process boundary

Status: native supervisor and stable result ABI implemented, 2026-08-20.

Zag Script exposes `process_run_timeout`; strict Zag uses
`std:process.process_run_bounded`. The existing native `_zag_exec_capture` is
deliberately not used as its implementation.
It creates a pipe and child shell, performs a blocking read until EOF, and only
then waits for the child. A Zag wrapper cannot regain control while that read is
blocked, so it cannot enforce a deadline.

The executable characterization in `tests/process_timeout_blocker.zag` proves
the legacy helper returns after a sleeping child, not at a requested deadline.

## Native supervisor

The Linux x86-64 implementation performs all of these together:

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

The state machine is ordinary self-hosted Zag over the backend's raw Linux
syscall lowering. There is no libc, C compiler, linker, or external `timeout`
program. A regression specifically covers a child that closes stdout and keeps
running, so EOF cannot bypass the deadline.

The result boundary is implemented independently: `ProcessResult` contains a
compiler-owned opaque handle. Typed ordinary-Zag getters expose status, state,
and captured output. The handle layout is fixed at four 64-bit words (status,
state, output pointer, output length), so module name prefixing cannot change the
runtime ABI. The supervisor constructs this handle directly. A root Script owns
the handle through its selected allocator: the arena charges 32 bytes, while
the bounded heap charges 48 bytes and links the complete header-plus-payload
block for deterministic shutdown reclamation.

## Direct argv boundary

The strict-Zag `std:process.process_run_argv_bounded` declaration and the
Script convenience `process_run_argv(executable, arguments, timeout_ms,
max_output)` provide a smaller shell-free boundary. The executable path and
each `[]u8` argument are copied into bounded NUL-terminated storage and passed
as an `execve` argv vector. Argument bytes therefore remain literal: there is
no shell parsing, quoting, expansion, or command-string reconstruction. The
path must be an executable path (normally absolute); this slice deliberately
does not perform `PATH` lookup.

The Linux x86-64 implementation accepts at most 31 arguments, 4095 bytes per
path or argument, and 64 KiB of combined copied argv storage. It uses the same
nonblocking stdout capture, monotonic deadline, process-group cleanup, output
cap, typed result states, and zombie-reaping behavior as the shell boundary.
The raw syscall passes a null `envp`, so the child receives an empty
environment; ambient environment is never imported implicitly. Stderr and
stdin are not transported by this API. Malformed list descriptors, embedded
NUL bytes, empty paths, and out-of-range limits fail closed with the runtime
error state. The focused native fixture covers literal metacharacters,
timeout, output overflow, missing executable, and validation rejection in
`tests/process_argv_native.zag`, while `tests/run_process_argv.sh` verifies a
static Linux x86-64 executable. This is a bounded process primitive, not a
general shell-free supervisor or a cross-platform process contract.

Adding only a timer around the current call,
killing only the shell PID, or returning partial output as success would be an
incorrect implementation.

Required acceptance tests are normal completion with captured stdout, nonzero
exit, deadline expiry, descendant termination, output-cap overflow, exec failure,
and repeated timeout runs with no unreaped children or descriptor growth.
