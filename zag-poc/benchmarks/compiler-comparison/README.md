# Compiler comparison benchmark

This suite measures a bounded local question: how the current `./znc` and
locally installed native compilers handle the same tiny program and the same
integer checksum program on Linux x86-64. It is evidence about these inputs and
this host, not a general language, optimizer, ecosystem, or release-quality
ranking.

Run the normal local protocol from `zag-poc/`:

```sh
RUNS=7 benchmarks/run_compiler_comparison.sh
```

The default result directory is a new timestamped directory under `/tmp`.
Select a new path explicitly with `OUT=/path`; an existing path is always
refused. Useful controls are:

```sh
# Refuse to run unless the preflight load/swap/build-process gate is clean.
STRICT_QUIET=1 RUNS=15 NICE_LEVEL=0 \
  OUT=/tmp/zag-compiler-controlled benchmarks/run_compiler_comparison.sh

# Minimum directional validation when the host cannot be made quiet.
STRICT_QUIET=0 RUNS=3 NICE_LEVEL=19 \
  benchmarks/run_compiler_comparison.sh
```

`RUNS` must be at least three. Fifteen or more runs on a quiet, dedicated host
are recommended before publishing a timing claim. `TIMEOUT_SECONDS` defaults
to 60. `QUIET_LOAD_PER_CPU_MAX` defaults to 0.25, and
`SWAP_USED_MAX_PCT` defaults to 50.

## Tools and modes

The harness always requires the checked-in `./znc` and GCC (GCC builds the
small `measure.c` process-tree observer). It discovers and records GCC, G++,
Rust, Clang/Clang++, Zig, and TCC independently. A missing optional compiler is
written to `tools.tsv` as unavailable rather than silently disappearing.

Zag has two deliberately separate rows:

- `zag-compiler-only` disables the analyzer, `zagd`, foreground profile input,
  and the foreground machine-code cache. This is the raw compiler comparison.
- `zag-default-user` invokes `znc INPUT -o OUTPUT` unchanged. Each fixture gets
  an isolated temporary project, including the analyzer, foreground cache, and
  a project-scoped `zagd`. The harness shuts down only that temporary daemon
  after the fixture. It never sends shutdown to the repository project or to a
  daemon that existed before the harness.

The common baseline disables optimization and newly requested debug info where
the other compiler exposes direct controls: GCC/G++ use `-O0 -g0`, and Rust
uses `-C opt-level=0 -C debuginfo=0`. Zig uses `-O Debug -fstrip`; its local and
global cache paths are new for every compilation so a cached Zig result cannot
masquerade as compiler throughput. Toolchain-provided runtime objects can still
carry metadata, so the emitted ELF is inspected instead of assuming flags made
all outputs identical.

## Fixtures and equivalence

`fixtures/tiny.*` exits successfully without output. `fixtures/checksum.*`
implements the same eight-stage unsigned 64-bit integer pipeline, performs
2,000,000 transitions, checks its own result, and writes exactly:

```text
115663923
```

The harness rejects a nonzero exit, extra output line, stderr byte, or checksum
mismatch. `equivalence.tsv` records the common stdout hash. The programs are
source-equivalent, but language safety checks, standard-library startup, ABI,
linkage, and optimizer behavior remain real differences rather than being
papered over.

## Measurements

For each available tool and fixture the harness records:

- one `clean` compile into a fresh result tree;
- `RUNS` repeated fresh compiler processes;
- nanosecond monotonic wall time;
- child-process-tree user and system CPU microseconds;
- Linux `ru_maxrss` peak resident KiB;
- `RUNS` executions of the equivalent checksum program;
- output bytes, SHA-256, ELF type, PIE status, section count, interpreter,
  `DT_NEEDED`, `GNU_STACK`, `GNU_RELRO`, and build ID;
- lower-bound compiler component footprints and bounded distribution-tree
  footprints where a meaningful tree exists.

`clean` means a fresh output plus a disabled or isolated compiler cache. It does
not mean the kernel page cache was dropped. The harness never changes global
page-cache state. A repeated row is a new compiler process after the clean
sample; compiler-only modes remain cache-disabled.

Compiler footprint is not one universally comparable number. The component
table deduplicates the invoked executable, explicit frontend/linker components,
and their `ldd` closure. Rust also records its host sysroot `bin` + `lib`; Zig
records its executable + reported `lib_dir`; Zag records its single compiler
executable. GCC system headers, libc development files, package metadata, Rust
downloads/docs/non-host targets, Zig's global cache, and repository source are
explicitly outside those bounded totals.

## Contamination policy

Every sample carries its own load, available-memory, swap-occupancy, cumulative
swap-in/out delta, and active build-process witnesses. A sample is marked
contaminated if any configured threshold is exceeded, a compiler/build process
is already active, or swapping occurs during the command.

`STRICT_QUIET=1` fails at preflight. Without it, the benchmark completes but
classifies the whole result as `directional-contaminated` if any sample is
contaminated. In that state:

- do not rank wall time or RSS;
- CPU-time medians are directional diagnostics, not release claims;
- rerun unchanged on a quiescent machine before publishing “fastest” wording.

## Result files

- `metadata.txt`: compiler identity, fixture hashes, exact profiles, host state,
  and overall result classification.
- `tools.tsv`: discovered and missing compilers with exact versions.
- `samples.tsv`: every raw compile/runtime sample and contamination witness.
- `summary.tsv`: min/median/max wall, median user/system/CPU, median RSS, and
  contaminated sample counts.
- `equivalence.tsv`: executable checksum equality proof.
- `artifacts.tsv`: output size, hash, and ELF properties.
- `toolchain-components.tsv`: exact measured compiler/component files.
- `toolchain-footprints.tsv`: deduplicated lower-bound footprint summaries.
- `logs/`: stdout, stderr, and raw observer rows for every command.

Results are generated evidence, not source truth. Keep them outside the
repository by default and review all contamination fields before preserving or
publishing them.
