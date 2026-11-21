# zag-complaints agent status

Worktree: /Users/Shared/micah/Documents/zag-complaints-20261121
Branch: agent/zag-complaints-20261121 (base fix/unsigned-integer-semantics @9a2af43)
Host: Apple M5, Darwin 25.6.0 arm64 (shared — heavy runs nice -n 12, load-gated <12)

## Progress

- [x] Read AGENTS.md (zag-poc/AGENTS.md — governing rules)
- [x] Survey: tests/ (300+ run_*.sh), docs/SUPPORT.md, programs/GAPS.md,
      stale audit logs in sibling checkout
- [x] Static missing-file audit → found + fixed 4 REAL-BUGs
- [x] Self-gates added for x86-64 ELF authorities (zir / dynamic ABI)
- [x] Dead test removed (run_optimize.sh — requires retired zagc)
- [x] GAPS.md: all 8 historical gaps re-verified on fixpoint compiler;
      gap-4 repro doc-noted for std:list import
- [x] docs gates run: run_docs_truth PASS, run_docs_consistency PASS,
      check_pure_zag_tree PASS, zagscript_1_0_matrix PASS (32/0/0)
- [x] bootstrap.sh to byte-identical fixpoint — DONE (stage 3,
      /tmp/zag-bootstrap-run.log; zagd built from fixpoint compiler)
- [x] vector-equiv x86-64 failure root-caused: Docker amd64 translator
      misexecutes loop-invariant VEX loads; same binary exits 0 under
      qemu-x86_64. Harness now probes executor fidelity (8ee1011) —
      PLATFORM-ARTIFACT
- [x] script allocation accounting failure root-caused: stale expected
      charge constant (1048520→1048504); cherry-picked upstream fix
      4f8f440 as 08db0b0 — REAL-BUG in test
- [x] full macOS test matrix — 68-row driver run complete; every FAIL
      root-caused, fixed, and re-verified green (see COMPLAINTS.md)
- [x] bootstrap to byte-identical fixpoint re-run after every selfhost
      source change (4f0a979, 6d35521, fd4bdbf) — stage 3 each time
- [~] test-macos-arm64-release — 3rd gate run in progress under the
      final fixpoint (prior attempts blocked by C-018/C-022, now fixed)
- [ ] fresh `make test` matrix under final fixpoint; STATUS/COMPLAINTS
      finalization; cruft cleanup; push attempt
- [ ] COMPLAINTS.md finalization + push attempt

## Complaints found so far

See COMPLAINTS.md (per-complaint evidence + verdict + fix SHA).
REAL-BUGs fixed: 4 missing files (09fa0c0, 1eeed3a, 5ddd054); install
recipe omits process_platform.zag (4b8b2fd); stale allocation constant
(08db0b0); repr(C) fixture ownership (8384c6c); manifest link deps
misclassified as package edges (4f0a979); three suites exec Linux
./znc on Darwin + audit-wrapper znc-real relocation + malformed
link-options fixture (c4299f5); aggregate suite ./znc default (0da81e0);
exponential nested-aggregate typecheck (6d35521); ARM64 narrow-cast
normalization (fd4bdbf).
PLATFORM-ARTIFACTs: ELF-authority self-gates (b7b5fa2); Docker amd64
translator VEX defect (8ee1011); SDK27 arm64e.x1 vs ld-1267 (b6bd973);
zagd-product load flake (closed); run_native_lint `--` foreign-seed
artifact (closed).
STALE-DOCs fixed: GAPS.md gap-4 repro note (08cb753); dead
run_optimize.sh removed (0701e2a).

## Commits

- 09fa0c0 fix: restore macOS seed intake and package release helpers
- 1eeed3a test: restore typed interpolation projection integration gate
- 5ddd054 test: restore macOS dylib loader C oracle fixture
- b7b5fa2 test: gate x86-64 ELF authorities to Linux x86-64 hosts
- 0701e2a test: remove dead optimize suite that requires retired zagc
- 08cb753 docs: note std:list import in GAPS gap-4 repro
- 8ee1011 test: probe amd64 executor fidelity in vector equivalence run
- 08db0b0 test: update stale process-capture allocation expectation
- 4b8b2fd fix: ship process_platform.zag in staged std install
- b6bd973 test: probe a linkable macOS SDK for C oracle fixtures
- 8384c6c test: preserve ownership on repr C early exits
- 4f0a979 fix(manifest): classify native link paths outside package closure
- c4299f5 test: resolve native compiler and preserve audit wrapper context
- 6d35521 fix(typecheck): avoid exponential nested aggregate revisits
- 0da81e0 test: resolve native compiler in aggregate provenance suite
- fd4bdbf fix(arm64): normalize explicit narrow integer casts and gate
  regression
- 574841c test: drop Python scaling harness forbidden by pure-tree gate

## Final state

- [x] fresh Darwin-arm64 matrix: all 55 DEFAULT_TEST_TARGETS run on the
      final fixpoint — 54 PASS + 1 transient (C-024, serial-verified pass x2)
- [x] test-macos-arm64-release: pass=69 fail=0 (twice: standalone gate
      run + embedded in the matrix)
- [x] bootstrap fixpoint re-verified at stage 3 after every selfhost
      change; final compiler sha256
      6b5e7b6e6816f4a3f661251f5489d850d329618bf44db3cb8106b8ab8c9a9fc1
- [x] run_vector_equiv_x86_64: honest BUILD-ONLY matrix (emulator defect
      probed; scalar rows all agree)
- [x] docs gates green: pure-tree, docs-truth, host-selection
- [x] generated cruft removed; git status clean except this file pair

VERDICT: 24 complaints (C-001..C-024) found — 12 REAL-BUGs fixed and
verified (3 genuine compiler defects: manifest link-dep closure 4f0a979,
exponential aggregate typecheck 6d35521, ARM64 narrow-cast lowering
fd4bdbf; plus repository/test/fixture defects), 5 PLATFORM-ARTIFACTs
(foreign-seed ELF runs, Docker VEX translator, SDK27/ld-1267,
zagd-product load flakes x2), 3 STALE-DOC/test removals, 1 NOT-A-BUG
(historical GAPS all hold), remainder infrastructure/completion rows —
every complaint closed and re-verified on the final fixpoint.
DONE 2026-11-21T17:08:34Z
