# Zag Script benchmark protocol

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
