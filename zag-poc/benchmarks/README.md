# Zag Script benchmark protocol

## Matched C / Rust / Python process-runtime comparison

The separate `run_cross_language.py` recorder closes a gap in the Zag-only
protocol below: it executes **three deterministic kernels** in ZagScript,
C, Rust, and Python: a bounded integer recurrence, a data-dependent
four-way branch, and two helper calls per iteration. Their templates live in
`benchmarks/cross_language/` as `kernel.*`, `branch.*`, and `call.*`.
All variants seed `x=17`, advance `x=(109*x+1021)%65521`, and accumulate
a checksum modulo `1000000007`. Branch uses a checksum update chosen by
`x%4`; call uses named `advance` and `accumulate` helpers, which the
language toolchain may inline. All intermediate values fit signed 64-bit
integers; every output is checked independently per kernel.

From `zag-poc/`, on a host with native `znc`, `clang`, `rustc`, and
`python3` installed:

```sh
RUNS=30 ITERATIONS=2000000 python3 benchmarks/run_cross_language.py
```

`RUNS` must be **at least 30**. `KERNELS` optionally selects a distinct
comma-separated subset of `recurrence,branch,call`; all three run by default.
`ITERATIONS` defaults to 2 million and is
embedded as the same literal in each compiled/interpreted source. `ZNC` may
point to a compatible **native** compiler binary elsewhere; `CC`, `RUSTC`,
and `OUT` override the tool paths/output directory. `BUILD_TIMEOUT_SECONDS`
(default 180) bounds each compiler and tool-version invocation;
`RUN_TIMEOUT_SECONDS` (default 60) bounds each measured process. Increase the
run timeout when increasing `ITERATIONS`. A timeout fails the run before results
are published; both limits are recorded in metadata. Default compiler names
are `znc` on Linux x86-64, `znc-linux-arm64` on Linux arm64, and
`znc-macos-arm64` on Apple Silicon. The checkout's committed `znc` seed
is Linux x86-64 and cannot run directly on macOS. An external `ZNC` is
copied into a temporary compiler bundle alongside symlinks to **this
checkout's** `std/` and `selfhost/`; its actual source path and SHA-256
are recorded, and results from it cannot be attributed to the checkout's
compiler revision without independent provenance.

For an interleaved before/after compiler comparison, set `ZNC` to the
candidate and `ZNC_BASELINE` to a runnable compiler for the same native host:

```sh
ZNC=/path/to/new/znc ZNC_BASELINE=/path/to/old/znc \
  RUNS=30 ITERATIONS=2000000 python3 benchmarks/run_cross_language.py
```

This adds `zagscript_baseline` as a fifth measured variant. It compiles the
identical ZagScript source for each kernel with both compilers in separate
source-compatible bundles. Every measured round rotates language order and
kernel order, with three warmups per language and kernel. The
baseline compiler path, version, and SHA-256 are recorded alongside the
candidate's. Omit `ZNC_BASELINE` for the original four-variant protocol.

On a macOS host where the default SDK/linker combination is incompatible,
select an installed working SDK using `SDKROOT=/path/to/MacOSX.sdk`. This
setting is inherited by the C and Rust compiler invocations and captured
in the metadata. On the macOS test host, the default MacOSX27.0 SDK failed
to link C; selecting the installed MacOSX26.5 SDK allowed the comparison to
complete. This does not change the ZagScript compiler target.

The recorder compiles C using `clang -O2 -std=c11`, Rust using
`rustc -C opt-level=2 -C target-cpu=generic`, and ZagScript using
`--no-zagd --no-analyze --no-foreground-cache`. Python runs under
`python3 -I -B`. It **checks stdout bytes, empty stderr, and zero exit
status against an independently computed result** for every warmup and
measured run. On any mismatch or failed build it stops without publishing
results. It warms each language three times, then rotates their order across
30 or more measured rounds per kernel. Measurements use `perf_counter_ns` around each
subprocess; **process creation, runtime initialization, computation and
output capture are included**. Compilation, import-time environment setup
outside the child, memory usage, and steady-state in-process kernel execution
are **not measured**. This is a whole-command comparison, not a pure
instruction throughput or cold-compile comparison. Small kernels can be
dominated by process launch; increase `ITERATIONS` for a workload-dependent
comparison, and keep run counts and machine load comparable.

Three untracked files are written to `benchmarks/results/` by default:
`*.cross-language.raw.csv` (every sample with execution position and output
hashes and the kernel name), `*.cross-language.summary.csv` (one row
per kernel/language, count, min, median, max, mean, population standard
deviation in nanoseconds), and `*.cross-language.meta.json` (compiler
identity/hash, host, tool versions, SHA-256 of each generated input, exact
build/run command arrays, timing semantics, independent reference output
for each kernel, and sample counts). The `benchmarks/results/` directory is ignored by git. Do not
publish speed ratios without examining raw distributions, the machine,
compiler provenance and each language's different execution model.

Set `RETAIN_ARTIFACTS=1` to keep the exact generated sources and verified
executables used in the timed runs under a timestamped `*.cross-language.artifacts/`
directory alongside the CSV results. The metadata lists each retained file
and its SHA-256, allowing `otool`, `objdump`, `size`, and other inspection tools
to attribute machine-code differences. The default is `0` (no retained
artifacts). Invalid values fail before building or measuring.

Run the opt-in smoke test with
`python3 benchmarks/test_cross_language.py`. It exercises 30 verified runs
per kernel/language at a short iteration count for both the default and
optional baseline comparison, and also checks that `RUNS=29`, invalid
`KERNELS`, and a zero run timeout are rejected. It requires the same compilers and honors `ZNC`/`SDKROOT`.

## Zag-only compiler, daemon, and allocation protocol

Run `RUNS=30 benchmarks/run_zagscript.sh` from a clean checkout. Results are
written beneath `benchmarks/results/`, which is intentionally not source
evidence and should not be committed without review.

The recorder rejects fewer than 30 runs. It captures compiler commit/version,
input hash, kernel, machine, CPU model/count, physical memory, exact commands,
and the generic/native stdout, stderr, and exit-status equivalence witness.
It measures cold and immediately repeated foreground compilation, process
startup, binary size, generic/native output equivalence, daemon resident memory,
idle CPU ticks, cache size, generic/native runtime, and
stable-file-change-to-snapshot latency. It writes raw CSV plus a summary
containing sample count, minimum, median,
maximum, mean, and population standard deviation. Never publish one run as a performance claim. Compare
implementations only after checking equal stdout, stderr and exit status for the
benchmark input.

Compiler peak RSS uses Linux `/usr/bin/time`'s maximum-resident-set-size witness
when available. `allocation_count` and `peak_live_allocation` come from
allocation-free native runtime observers. They count successful logical
allocation events and peak simultaneously-live payload capacity across the
native allocator, Zag Script arena suballocations, and supported raw allocation
builtins. They exclude allocator metadata, reserved-but-unused arena capacity,
RSS, and explicit raw `mmap` syscalls; those are separate resource facts, not
silently encoded as zero. `compile_cold` explicitly bypasses the foreground cache.
`compile_warm` requires a machine-readable cache-hit witness saying that
checksum-validated machine code and data were reused and code generation was
skipped. `stable_change_to_plan` requires both a changed content identity and
`planner_state=complete`; it is sampled once per stable edit. Missing rows mean
“not measured”, never zero cost. Idle CPU and RSS use 30 unchanged
100-ms observation windows so their distributions obey the same minimum sample
rule; a zero tick delta is an observed kernel counter value, not an estimate.
`cache_size` is likewise sampled after each of the 30 stable snapshots and
included in the dispersion summary, so cache growth cannot be hidden behind a
single final-size number.

`stable_change_to_plan` is the end-to-end incremental-reanalysis witness: it
starts at the final stable write and ends only after the daemon publishes the
new content identity with a complete plan. It therefore includes the configured
stability window, complete-file read/hash, invalidation, semantic recheck, and
plan publication. The recorder does not claim a separately isolated parser-only
or semantic-only latency.
