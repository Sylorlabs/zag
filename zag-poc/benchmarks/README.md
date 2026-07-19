# Zag Script benchmark protocol

Run `RUNS=30 benchmarks/run_zagscript.sh` from a clean checkout. Results are
written beneath `benchmarks/results/`, which is intentionally not source
evidence and should not be committed without review.

The recorder rejects fewer than 30 runs. It captures compiler commit/version,
input hash, kernel, machine, CPU model/count, physical memory, exact commands,
and the generic/native stdout, stderr, and exit-status equivalence witness.
It measures cold and immediately repeated foreground compilation, process
startup, binary size, generic/native output equivalence, daemon resident memory,
idle CPU ticks, cache size, and stable-file-change-to-snapshot latency. Report
It writes raw CSV plus a summary containing sample count, minimum, median,
maximum, mean, and population standard deviation. Never publish one run as a performance claim. Compare
implementations only after checking equal stdout, stderr and exit status for the
benchmark input.

Compiler peak RSS uses Linux `/usr/bin/time`'s maximum-resident-set-size witness
when available. Allocation count remains explicitly `unavailable` in metadata
until the runtime exposes an authoritative process-wide witness; unavailable is
never encoded as zero. `compile_warm` means a repeated compiler
invocation against unchanged input; it does not claim an incremental codegen
cache hit. `stable_change_to_plan` requires both a changed content identity and
`planner_state=complete`; it is sampled once per stable edit. Missing rows mean
“not measured”, never zero cost. Idle CPU and RSS use 30 unchanged
100-ms observation windows so their distributions obey the same minimum sample
rule; a zero tick delta is an observed kernel counter value, not an estimate.
