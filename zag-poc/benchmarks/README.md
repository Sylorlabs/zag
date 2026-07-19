# Zag Script benchmark protocol

Run `RUNS=30 benchmarks/run_zagscript.sh` from a clean checkout. Results are
written beneath `benchmarks/results/`, which is intentionally not source
evidence and should not be committed without review.

The recorder captures the compiler commit and version, input hash, kernel,
machine, CPU model, exact compile command and run count alongside raw samples.
It measures cold and immediately repeated foreground compilation, process
startup, binary size, generic/native output equivalence, daemon resident memory,
idle CPU ticks, cache size, and stable-file-change-to-snapshot latency. Report
distributions (at least median, minimum, maximum and standard deviation) from
the raw samples; never publish one run as a performance claim. Compare
implementations only after checking equal stdout, stderr and exit status for the
benchmark input.

Allocation-count and peak-memory rows remain absent until the runtime exposes
authoritative process-wide witnesses. `compile_warm` means a repeated compiler
invocation against unchanged input; it does not claim an incremental codegen
cache hit. `file_change_to_snapshot` ends at the daemon's content-hash status
witness, not at completion of semantic or deep planning. Missing rows mean “not
measured”, never zero cost.
