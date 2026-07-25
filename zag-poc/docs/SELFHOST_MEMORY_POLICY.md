# Self-host memory policy

Native compiler fixpoint tests are memory-intensive and must not endanger an
interactive Linux workstation. `tests/run_native_memory_regression.sh` is the
authoritative bounded measurement harness. A normal invocation only probes the
safety controls and does **not** compile anything.

## Normal bootstrap guard

`bootstrap.sh` always runs its three compiler generations sequentially and
requires stage 2 and stage 3 to be byte-identical before replacing the trusted
seed. On Linux with a usable systemd user manager, each compiler process runs
in a transient low-priority cgroup with swap disabled. The automatic
`MemoryMax` is the smaller of 60% of physical RAM and current
`MemAvailable - 2 GiB`; bootstrap refuses to start when that leaves less than
1 GiB. `MemorySwapMax` is zero by default.

Set `ZAG_BOOTSTRAP_MEMORY_MAX_BYTES` to an explicit reviewed byte ceiling. An
explicit ceiling is fail-closed: bootstrap rejects it if the user cgroup cannot
be created. `ZAG_BOOTSTRAP_MEMORY_GUARD=off` is the deliberate escape hatch for
an environment where the operator has supplied equivalent isolation. When no
explicit ceiling is requested and user cgroups are unavailable, bootstrap
reports that fact and preserves the pure-Zag build path without pretending it
was cgroup-protected.

On a memory-constrained interactive host, an operator may explicitly set
`ZAG_BOOTSTRAP_SWAP_MAX_BYTES` to let only the compiler cgroup spill a bounded
amount to already configured swap. The RAM ceiling remains hard, the stages
remain sequential, and the selected swap ceiling is printed before compilation.
This is a workstation-safety escape valve, not a no-swap memory certification.

This guard protects routine self-hosting; it is not a peak-memory
certification. Use the regression harness below for recorded stage-by-stage
process RSS, cgroup RAM and swap peaks, timeout, and fixpoint evidence.

## Measured regression gate

The heavy run requires all of the following:

- a working systemd user manager with cgroup v2 memory control;
- active `earlyoom` protection (the harness never stops or changes it);
- GNU `time` for an independent peak-RSS measurement;
- explicit `ZAG_RUN_HEAVY_MEMORY_GATE=1` consent.

Each self-host stage runs sequentially with low CPU and I/O weights, positive
nice priority, a hard runtime timeout, and a hard memory limit. Cgroup swap is
disabled by default. An explicit `ZAG_SELFHOST_SWAP_MAX_BYTES` is recorded in
the report and proves only a bounded-swap functional/fixpoint run, not the
default no-swap memory profile.
The requested default ceiling is 16 GiB, but the effective hard limit is the
smallest of that ceiling, 60% of physical RAM, and current
`MemAvailable - 2 GiB`. The working-set regression budget is the smaller of
the requested budget and 90% of the combined RAM plus explicitly allowed swap
limit. It compares cgroup `memory.peak + memory.swap.peak`, while retaining
process RSS as a separate diagnostic. This matters on a 16 GiB workstation: a
nominal
16 GiB cgroup is not protective because global reclaim can kill unrelated
applications before the compiler reaches it. Override the ceiling, budget,
25–75% physical-memory share, or the 2 GiB workstation reserve only with
reviewed machine-specific policy:

```bash
tests/run_native_memory_regression.sh --probe
ZAG_RUN_HEAVY_MEMORY_GATE=1 tests/run_native_memory_regression.sh
```

The TSV report contains process RSS plus cgroup RAM, swap, and combined
working-set peaks for every compiler generation. A stage fails if compilation
fails, systemd kills it, the timeout expires, its combined RAM-plus-swap peak
crosses the budget, or the generated compiler fails the byte-for-byte fixpoint
comparison. It records requested and effective RAM limits, the swap allowance,
and the workstation reserve, so a clamped workstation run cannot be mistaken
for a 16 GiB certification.
Unsupported cgroup environments exit 77 rather than pretending the memory gate
passed.

This is a process-level regression measurement, not allocation provenance.
Compiler-owned phase/allocation accounting must be emitted by the self-hosted
compiler and compared with this operating-system witness. The optimizer may use
those facts to recommend arena release, buffer reuse, and copy elimination in
its own compiler sources, but it must not silently rewrite explicit allocation
or weaken correctness to meet the budget.

Never disable `earlyoom`, silently enable swap, or run self-host stages
concurrently to make this gate pass. Prefer reducing retained compiler state or
allocation volume. When bounded swap is deliberately selected for workstation
safety, record it and do not present that run as no-swap certification.

## Native-codegen temporary ownership

`selfhost/native/ncodegen.zag` has a deliberately narrow compiler-memory
release boundary. It releases only `ArrayList` backing allocations that are
created and consumed entirely within native code generation:

- per-function pre-scan indexes (`seen`, local type maps, and function-return
  maps) immediately after frame sizing;
- per-function lowering environments after the epilogue has been emitted;
- transient argument-slot arrays used while emitting direct, indirect, and
  interface-dispatch calls;
- synthetic call argument/type-argument containers after their lowering pass;
- top-level symbol, runtime-use, and dynamic-name indexes on both normal and
  no-`main` exits.

Those releases never free AST nodes, parsed declaration lists, or source/type
text stored in the arrays: those values are borrowed and remain owned by the
parse/expansion lifetime. The codegen pass also intentionally leaves generic
expansion output, parsed embedded-runtime declarations, synthetic AST nodes,
and lookup-result placeholder containers alone where ownership may be shared
or replaced by an AST result. This is a retained-container reduction, not a
claim of whole-compiler leak freedom or general allocation provenance.

## Typed-flow temporary ownership

Edition-2027 ownership, stack-address, and borrow checks clone compiler-only
`ArrayList` state at control-flow branches. A join creates a fresh backing
array, releases the superseded destination and all unselected branch clones,
and transfers only the joined container to its caller. Per-function flow
tables, owner-summary fixed-point temporaries, declared-name indexes, and
expression/machine-check environments are released when their analysis ends.
The names and types stored in these containers remain borrowed AST/source
text; this boundary does not free them or claim ownership of diagnostic/type
strings whose provenance can be mixed.

The edition-2027 aggregate-provenance flow follows the same rule. Branch,
loop, and switch states are cloned into owned backing arrays, joined into a
fresh may-state, and freed before replacement. Field-path and provenance-root
names are borrowed from the AST; the pass never frees that text.

`tests/check_optimizer_memory_hygiene.sh` statically guards these ownership
boundaries. The heavy regression harness remains the only evidence for actual
RSS behavior; static guards cannot certify peak memory or absence of leaks.
