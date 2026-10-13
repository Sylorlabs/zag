# Zag Script bounded-process boundary

Status: bounded supervisor and stable result ABI; portable wait corrections
executed on Darwin ARM64, Linux ARM64, and emulated Linux x86-64 (October 2026).
Kernel security sandboxing is **unsupported**.

Zag Script exposes `process_run_timeout`; strict Zag uses
`std:process.process_run_bounded`. The existing native `_zag_exec_capture` is
deliberately not used as its implementation.
It creates a pipe and child shell, performs a blocking read until EOF, and only
then waits for the child. A Zag wrapper cannot regain control while that read is
blocked, so it cannot enforce a deadline.

The executable characterization in `tests/process_timeout_blocker.zag` proves
the legacy helper returns after a sleeping child, not at a requested deadline.

## Typed platform boundary

`selfhost/std/process_platform.zag` is the only platform vocabulary used by the
shared supervisor. `ProcessPlatformCapabilities` declares the platform identity
and the declared supervision capabilities: process-group control, nonblocking
output observation, deadline waiting, and fail-closed backend selection. These
are backend declarations, not evidence that a particular kernel operation has
succeeded. Syscall failures still need handling. Unknown or partial supervision
backends reject a bounded process.

The native backend implements one source-level `process_platform_wait_readable`
primitive:

| Backend | Direct kernel operation | Timeout ABI |
|---|---|---|
| Linux x86-64 | `poll`, syscall 7 | milliseconds |
| Linux ARM64 | `ppoll`, syscall 73 | finite `{seconds,nanoseconds}`, no signal-mask change |
| Darwin ARM64 | explicit `ai_darwin_syscall(230)` | milliseconds; `nfds` in x1, timeout in x2 |

ARM `ai_syscall` is in the ARM Linux namespace; a Darwin selector must not be
passed to it. The shared supervisor neither selects kernel wait mechanisms nor
interprets Darwin errno values. Backend read normalization recognizes only its
own `EAGAIN`/`EWOULDBLOCK` plus `EINTR`.

Wait returns `1` for readable/HUP/error events, `0` for timeout **or interruption**,
and a negative code for a permanent error (`POLLNVAL` becomes `-9`). Zero is a
wake-up to recheck state and the monotonic deadline, not proof of expiry. Both
wrapper and lowering reject infinite/invalid timeouts. `fd=-1` gives a finite
idle wait after stdout EOF, avoiding a HUP busy loop while waiting for child exit.

## Supervision is not security isolation

**Process groups are NOT a sandbox.** A child retains filesystem, network,
credential, and inherited-descriptor authority; hostile descendants can leave
the process group. Neither backend installs Seatbelt, namespaces, seccomp,
Landlock, or an equivalent kernel sandbox. The `isolation` capability is zero.

`ProcessIsolationRequirement` separates `SupervisionOnly` from `SecuritySandbox`.
`process_platform_check_isolation` returns a typed `ProcessIsolationResult`:

- `SupervisionOnly`: accepted, `NotRequested`, `sandboxed=0`.
- `SecuritySandbox` (and unknown values): refused, `Unsupported`, `sandboxed=0`.

`process_run_bounded_with_isolation` makes that decision **before pipe/fork**.
A refused request returns `ProcessIsolationRunResult` with the decision and a
process result in state `process_state_isolation_unsupported()` (4), status -1,
and empty output. It never runs the command or degrades the request to ordinary
supervision. `process_run_bounded` / Script `process_run_timeout` retain their
supervision-only contract. No kernel isolation implementation is claimed.

Script helper authority recognizes the canonical sibling `process_platform.zag`
of the resolved `std:process`, including installed layouts. Each private runtime
bridge requires its exact approved owner, the owner's resolved origin, and an
extern declaration from the approved origin. Root definitions/externs with the
same names are rejected. This compiler policy is also not an OS sandbox.

## Native supervisor

The Linux implementations and the scoped Apple Silicon runtime adapter
perform all of these together:

1. Create a pipe and mark the parent observation end nonblocking.
2. Fork and place the child shell in a new process group before `execve`.
3. Close unused descriptors in both processes.
4. Drain stdout while checking `wait4(..., WNOHANG)` and a monotonic deadline.
5. Enforce a caller-provided output cap without deadlocking a verbose child.
6. On timeout or output overflow, signal the entire child process group.
7. Reap the child after termination; the normal reap loop retries interruption.
8. Close descriptors on every syscall failure path.
9. Return a statically typed result containing captured bytes, exit status,
   timeout/overflow state, and a runtime-error code.

The state machine is ordinary self-hosted Zag over the typed platform backend.
Linux provides the process-group and poll/ppoll implementation; Darwin provides the
same contract through its target backend. Unknown or computed target operations
fail closed. There is no libc, C compiler, linker, or external `timeout` program.
A regression specifically covers a child that closes stdout and keeps running, so EOF cannot
bypass the deadline.

The result boundary is implemented independently: `ProcessResult` contains a
compiler-owned opaque handle. Typed ordinary-Zag getters expose status, state,
and captured output. The handle layout is fixed at four 64-bit words (status,
state, output pointer, output length), so module name prefixing cannot change the
runtime ABI. The supervisor constructs this handle directly. A root Script owns
the handle through its selected allocator: the arena charges 32 bytes, while
the bounded heap charges 48 bytes and links the complete header-plus-payload
block for deterministic shutdown reclamation.

Adding only a timer around the current call,
killing only the shell PID, or returning partial output as success would be an
incorrect implementation.

Required acceptance tests are normal completion with captured stdout, nonzero
exit, deadline expiry, descendant termination, output-cap overflow, exec failure,
and repeated timeout runs with no unreaped children or descriptor growth.

## Focused execution checks

```sh
# Uses the current lowering in a small Zag driver, so an older seed can run it.
bash tests/run_process_platform.sh
# Also execute both Linux backends in Docker; x86-64 may be emulated.
PROCESS_TEST_LINUX=1 bash tests/run_process_platform.sh
# Optionally exercise the full CLI's Script authority walk with a rebuilt CLI.
PROCESS_TEST_CLI=/path/to/rebuilt/znc bash tests/run_process_platform.sh
```

The gate executes timeout/readiness/EOF/invalid-fd tests, capability rejection,
typed sandbox refusal, and the existing bounded-process fixture. Linux ARM64
also receives a real SIGUSR1 during `ppoll`. Darwin fault injection executes the
production wait emitter's EINTR, permanent-error, and stack-restoration paths;
it does not constitute a real Darwin signal-delivery test. The CLI option runs
a Script process and rejects forged owner/bridge declarations. The lower-only
driver intentionally bypasses CLI authority checks; its results must not be
reported as CLI policy coverage.
