# Bounded process services

`selfhost/std/process.zag` exposes two deliberately separate process
boundaries on Linux x86-64:

- `process_run_bounded` is the explicit `/bin/sh -c` boundary used when shell
  interpretation is wanted.
- `process_run_argv_bounded` copies an executable path and a bounded
  `ArrayList[[]u8]` of arguments into NUL-terminated storage and calls
  `execve` directly. Argument bytes are never parsed by a shell.
- Script exposes the same direct boundary as
  `process_run_argv(executable, args(), timeout_ms, max_output)`; `args()` is
  the currently proven homogeneous `ScriptList[[]u8]` producer. Its
  compiler-owned descriptor bridge validates the list and uses the same
  bounded core without changing the strict API. Generic string-list literal
  inference remains outside this slice.

The direct-argv helper accepts at most 31 arguments, 4,095 bytes per path or
argument, and 64 KiB of combined copied argument storage. Both APIs retain the
same 1–5,000 ms timeout, process-group termination, stdout cap (up to 1 MiB),
and `ProcessResult` states for exit, timeout, output limit, and runtime error.
The path is not searched through `PATH`; callers provide the executable path.
The child receives an empty environment. There is no stdin transport, stderr
capture, shell expansion in the argv API, or general supervisor contract.

`tests/run_process_argv.sh` proves literal shell metacharacters, timeout and
output-limit behavior, missing-executable status, invalid-path rejection, and
static Linux x86-64 output. Existing shell execution remains explicit and is
not silently changed.
