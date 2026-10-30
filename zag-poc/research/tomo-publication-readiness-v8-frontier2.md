# Publication-readiness checklist: MUSE-NEXT v8 run-3b and 2026-10-30 Frontier 2

**UNCOMPILED / UNEXECUTED.** This note records evidence requirements, not new execution. The older work remains reported-local-execution: not fabricated, but not independently reproduced. It must not be described as independently verified or as a confirmed v2 release result.

## Publisher must supply

- [ ] For each run, the exact remote repository, branch or immutable commit SHA, source paths, dirty-tree diff if any, hashes of all source and configuration files, scripts, input datasets, prompts, and generated artifacts. Link the precise source identity to each result. A branch name alone is mutable and insufficient. Missing source identities remain missing; do not substitute today's tree for historical bytes.
- [ ] Original run-specific stdout, stderr, command lines, environment and timestamps; build/bootstrap/compiler logs; raw per-case outputs; process exit statuses; metrics, seeds, task inputs and evaluation scripts; comparison outputs and any error or failed-run logs. Supply an artifact manifest listing exact actual filenames, sizes, hashes and their relationship to each run. The exact run-specific filenames have not been established here: do not pretend that generic or unrelated logs are them.
- [ ] Exact compiler executable version, executable SHA-256, compiler source commit, edition selection, target triple, ABI, optimization and other flags, OS, architecture and dependencies. A source SHA or the word “v2” alone does not establish the compiler executable or edition.
- [ ] Preserve runtime exit codes and how each program encodes outcomes. Distinguish compiler failure, launch failure, signal termination, timeout and the program's own nonzero result. Give the shell or runner's mapping and raw logs; never equate a nonzero program result with compiler failure or silently discard it.
- [ ] For identities of old local source files that cannot now be recovered, explicitly mark the exact source identity **unrecoverable from available evidence**, rather than guessing it from a related later commit. If backups or old machines exist, have their owner check them. Inability to recover identity limits provenance even when the reported run was genuine.
- [ ] Independently rerun from the pinned inputs where possible, with a separate environment and archived logs. Until then the reports remain local execution reports, not independent replications. Separate in-sample and held-out evaluation, disclose task selection, sample size, seeds, comparisons, failed/aborted trials and tuning, and avoid generalization or metareasoning claims beyond the actual evaluation.

## Scope of checks so far

The TNN `artifacts/run-logs/INDEX.md` describes `V17_COMPLETED_RUN.log` through `V25_COMPLETED_RUN.log` as completed-run logs from the pre-reorganization Research root with generation attribution unknown. Inspection of those nine logs did not locate the run-3b / WT2 / WT3 / WT8 markers in this review; that does not prove the requested logs do not exist elsewhere. The archive `archive/run-archives/tnn-v1-current-execution.zip` was visible, but its contents were not inspected in this browser.

A Frontier 2 materials note records “VM: Debian, 2 vCPU, ~1.9 GiB RAM (measured), no Zag compiler present.” This establishes only the recorded machine observation, not the compiler identity or independent reproduction of every Frontier 2 result.

No already-exhausted branch-name search was repeated. No canonical or frozen study was changed. `main` was not changed.

## Proposed evidence-collection commands (NOT RUN)

In the publisher's actual checkout and on the machine holding the real executable, substitute the recorded compiler path and preserve the outputs as run-specific files; these are proposed filenames, not claims that existing logs have these names.

```sh
git rev-parse HEAD > provenance-source-commit.txt
git status --porcelain=v1 > provenance-dirty-tree.txt
git diff --binary > provenance-working-tree.patch
sha256sum /path/to/actual/compiler > provenance-compiler-sha256.txt
/path/to/actual/compiler --version > provenance-compiler-version.txt 2>&1
uname -a > provenance-system.txt
```

The actual compiler's supported version command must first be confirmed. Also record the exit status of every command and collect untracked source files separately. Never replace missing historical logs with a newly generated reproduction; label the latter as a new run.
