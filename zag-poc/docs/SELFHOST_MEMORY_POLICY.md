# Self-host memory policy

Native compiler fixpoint tests are memory-intensive and must not endanger an
interactive Linux workstation. `tests/run_native_memory_regression.sh` is the
authoritative bounded measurement harness. A normal invocation only probes the
safety controls and does **not** compile anything.

The heavy run requires all of the following:

- a working systemd user manager with cgroup v2 memory control;
- active `earlyoom` protection (the harness never stops or changes it);
- GNU `time` for an independent peak-RSS measurement;
- explicit `ZAG_RUN_HEAVY_MEMORY_GATE=1` consent.

Each self-host stage runs sequentially with low CPU and I/O weights, positive
nice priority, no cgroup swap, a hard runtime timeout, and a hard memory limit.
The default hard limit is 16 GiB and the regression budget is 14 GiB. Override
these only with reviewed CI/machine-specific policy:

```bash
tests/run_native_memory_regression.sh --probe
ZAG_RUN_HEAVY_MEMORY_GATE=1 tests/run_native_memory_regression.sh
```

The TSV report contains a peak for every compiler generation. A stage fails if
compilation fails, systemd kills it, the timeout expires, its peak crosses the
budget, or the generated compiler fails the byte-for-byte fixpoint comparison.
Unsupported cgroup environments exit 77 rather than pretending the memory gate
passed.

This is a process-level regression measurement, not allocation provenance.
Compiler-owned phase/allocation accounting must be emitted by the self-hosted
compiler and compared with this operating-system witness. The optimizer may use
those facts to recommend arena release, buffer reuse, and copy elimination in
its own compiler sources, but it must not silently rewrite explicit allocation
or weaken correctness to meet the budget.

Never disable `earlyoom`, add swap, or run self-host stages concurrently to make
this gate pass. Reduce retained compiler state or allocation volume instead.
