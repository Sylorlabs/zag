# Research artifacts

**UNCOMPILED / UNEXECUTED.** All candidate patches, fixtures and commands here are uncompiled and unexecuted in this review; notes are static source observations, not independent reproductions. Research base: `f8b287bad32d4f93d272c270cff772e59b858515`; branch: `research/2026-10-30-tomo-zag-diagnostics`. Editor: Tomo on behalf of Micah, using the GitHub session shown as `micahcooley`. No canonical or frozen studies or `main` were modified.

## Artifacts

- `tomo-unsupported-bitwise-not.patch`: candidate parser diagnostic, not applied to the compiler. Its applicability and behavior are unverified.
- `tomo_bitnot_negative.zag`: proposed negative fixture; expected diagnostic is not yet established byte-for-byte.
- `tomo_bitwise_positive.zag`: proposed positive fixture; parser support for every operator and syntax remains unverified, notably `|`. It may require adjustment before it is a valid regression.
- `tomo-pointer-portability-abi.md`: static pointer portability note, not a bug claim; AArch64 and native behavior unverified.
- `tomo-publication-readiness-v8-frontier2.md`: evidence checklist; earlier local execution is not independently reproduced.

## Edition boundary

`zag-poc/selfhost/v2_edition.zag` defaults to `2026` absent a valid project edition, and gates selected v2 syntax on `2027`. `zag-poc/docs/V1_LANGUAGE_SPEC.md` says “Implicit conversion between different named numeric types is not part of v1.” `zag-poc/selfhost/typed.zag` accepts numeric pairs without an edition parameter and describes existing v1 extensions as backend-owned. These are distinct published-contract and implementation facts. Actual in-tree i64-to-i32 reliance and the governing extension boundary have not been established: do not treat this note as a definitive ruling or v2 conformance claim.

## Reproduction handoff (NOT RUN)

In a clean disposable checkout on the research branch, from the repository root:

```sh
git apply --check zag-poc/research/tomo-unsupported-bitwise-not.patch
# Proceed only if the check succeeds and the candidate was reviewed:
git apply zag-poc/research/tomo-unsupported-bitwise-not.patch
cd zag-poc
ZAG_BOOTSTRAP_MEMORY_GUARD=off bash bootstrap.sh
./znc research/tomo_bitnot_negative.zag -o /tmp/tomo-bitnot-negative
./znc research/tomo_bitwise_positive.zag -o /tmp/tomo-bitwise-positive
/tmp/tomo-bitwise-positive
bash tests/run_diag.sh
bash tests/run_foreground_cache_integration.sh
```

Capture stdout, stderr, each command's exit status, exact compiler hash and environment. The negative fixture is expected to fail only after the candidate patch is successfully applied and bootstrapped; the positive fixture is intended to compile and exit 0, but syntax and expectations require validation. The fixtures are in `research/`, not installed in the exact-comparison diagnostic suite; `run_diag.sh` does not automatically test them. No `.expected` file is claimed without observing the actual full diagnostic. Integration-script cache expectations are assertions in source, not observed results. Do not run these commands on a canonical checkout.
