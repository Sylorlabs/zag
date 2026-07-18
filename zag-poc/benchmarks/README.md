# Zag Script benchmark protocol

Run `RUNS=30 benchmarks/run_zagscript.sh` from a clean checkout. Results are
written beneath `benchmarks/results/`, which is intentionally not source
evidence and should not be committed without review.

The recorder captures the compiler commit and version, input hash, kernel,
machine, CPU model, exact compile command and run count alongside raw samples.
It currently measures cold foreground compilation, process startup, binary size,
daemon resident memory and idle CPU ticks. Report distributions (at least median,
minimum, maximum and standard deviation) from the raw samples; never publish one
run as a performance claim. Compare implementations only after checking equal
stdout, stderr and exit status for the benchmark input.

Incremental reanalysis, warm-cache, allocation-count, peak-memory, native-profile
and file-change-to-plan measurements are added only when their corresponding
implementation exposes an authoritative completion witness. Missing rows mean
“not measured”, never zero cost.
