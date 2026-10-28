# Full-width bounded bit-vector superoptimization (offline)

The ZagScript v1 finite `script_auto` optimizer checks all inputs in tiny
1–4-bit domains. `tools/bv_superopt.sh` extends **proof checking** to the exact
8-, 16-, 32- and 64-bit modular integer domains using the installed Z3 solver.
It is an offline exploratory tool; neither the compiler nor its generated code
uses an unproven rewrite from this tool.

## Run

Install `z3` and run from `zag-poc`:

```bash
tools/bv_superopt.sh prove 64 'x 0 +' 'x'
tools/bv_superopt.sh prove 64 'x 1 +' 'x'                  # SAT; exits 1, prints a model
tools/bv_superopt.sh search 64 'x 0 + y 0 + *' --proof-file /tmp/selected.smt2
z3 /tmp/selected.smt2                                    # unsat
bash tests/run_bv_superopt.sh
```

`prove` returns 0 for `unsat` (fully equivalent), 1 for `sat` (not
equivalent; x/y counterexample), and 2 for invalid expressions or inconclusive
solver results. `search` returns 0 only after independently rechecking the
selected expression; unknown, timeout and solver failure are errors.

The expression format is space-separated **postfix** with variables `x`, `y`,
in-range unsigned decimal constants and binary `+`, `-`, `*`, `&`, `|`, `^`.
Operations wrap modulo 2^width. Expressions have at most 31 tokens.
No comparisons, shifts, division, floats, signed division/overflow traps,
pointer arithmetic, memory, calls, or control flow are accepted. In particular,
the proof says nothing about UB, signed overflow traps or memory side effects
outside this explicit pure wrapping contract.

## What the search guarantees

The search enumerates leaves `0`, `1`, `2`, `2^width-1`, `x`, `y`, followed by
all ordered pairs of these leaves with the six supported binary operators.
Its only cost proxy is the **number of postfix nodes**. It returns the
first equivalent candidate strictly smaller than the reference at the
lowest available node count. The reference is retained if no cheaper
candidate is proved. All candidates evaluated before the winner must
be disproved by SAT; inconclusive checks stop the search.

`(assert (not (= original candidate)))` over symbolic x and y proves equivalence
for **all** inputs at the selected width when Z3 returns `unsat`. SAT yields
a concrete counterexample. Saving `--proof-file` writes replayable SMT-LIB;
the solver response is retained in CLI output. This is solver-backed evidence,
not a proof certificate checked by an independently verified proof kernel.

The enumerated grammar is deliberately small. Passing the search does not prove
an optimal machine implementation or a globally minimal expression; node count
does not model throughput, register pressure, cache traffic, scheduling, vector
instruction widths, or target ISA costs. Production optimizations still need
verified lowerings plus differential tests and runtime benchmarks against
compiled C/Rust equivalents.

The GitHub Linux CI job installs `z3`, so the release gate runs the test
suite. Developer environments without Z3 skip only the optional offline proof
gate; `bash tests/run_bv_superopt.sh` itself fails if the solver is absent.
