# Native bootstrap reproducibility

The authoritative self-hosting proof for Zag's native compiler is:

```sh
./tests/check_native_bootstrap_repro.sh
```

The check builds three successive `znc` executables from
`selfhost/native/znc.zag`:

```text
default ./znc seed -> stage 1 -> stage 2 -> stage 3
```

It requires all four executables to be byte-identical. With the default seed,
this proves both that `./znc` corresponds to the checked-in compiler source and
that successive native self-compilation has reached a deterministic fixpoint.

Every compiler invocation receives an empty `PATH`, so no C compiler,
assembler, linker, or other host executable can be resolved through command
lookup to generate a stage. The only authoritative translation in this proof
is Zag source directly to a static x86-64 ELF executable through `znc`. Shell
utilities only create the temporary directory and compare completed artifacts.

All stages are written under a temporary directory and removed on exit. The
check does not replace `./znc` or leave generated compiler files in the source
tree. To audit another seed without changing the repository, set
`ZNC_SEED=/path/to/znc`.

## Scope of the proof

Byte-identical self-reproduction demonstrates deterministic code generation;
it does not independently establish that the original seed is non-malicious.
As with other self-hosted toolchains, that seed remains the trust root. A
diverse-double-compilation audit from an independently implemented compiler is
a separate supply-chain check, not a prerequisite for the native fixpoint.
