# Pre-Registration: Jules J15 — Wildcard B: Invented Third-Path Knowledge Substrate

- **Session ID:** J15
- **Branch:** `jules/tnn-J15-20261108`
- **Parent SHA / Current Repo SHA:** `f8b287bad32d4f93d272c270cff772e59b858515` (Note: prompt requests Sylorlabs/TNN commit b21387ea6834a9df186dedb109cc60f60bcaa7c5, but working repo clone is Sylorlabs/zag; pinned local SHA is recorded truthfully per common operating contract).
- **Date:** 2026-11-08
- **Initial Subjective Forecast:** P(primary PASS) = 0.30 (Prompt subjective forecast: 30%, in permissible [0.15, 0.85] bounds; no revision needed).

## 1. Single Narrow Hypothesis & H0
- **Hypothesis (H1):** An agent-invented third-path knowledge substrate—Causal Transition-Affinity Microcircuits (CTAM)—which retains episodic, state-conditioned micro-operation transition affinities with causal progress vectors across tasks, will causally reduce candidate evaluations to first correct solution by at least 20% on L2 (quotient-and-remainder) or L3 (GCD) compared to a matched conventional inductive search control operating over identical primitives and budgets.
- **Null Hypothesis (H0):** The addition of CTAM yields less than a 20% reduction in candidate evaluations to first correct solution on L2 and L3, or any observed benefit fails causal erasure / sham controls (e.g. sham randomized graph matches or exceeds CTAM, or erasure does not revert performance to baseline).

## 2. Proposed Third-Path Mechanism: Causal Transition-Affinity Microcircuits (CTAM)
- **State Representation:**
  Rather than symbolic expression libraries (DreamCoder) or continuous neural plasticity / fast weights (Miconi et al.), CTAM represents acquired operational knowledge as an episodic directed graph:
  $$M = (V, E, W, C)$$
  where:
  - $V$: Abstract program execution state contexts (e.g. register relationships such as $r_0 > r_1$, $r_0 = 0$, $r_1 = 0$, loop-depth, affine bounds).
  - $E$: Directed transitions representing elementary FoundryIR micro-operations ($r_i \leftarrow r_i - r_j$, $r_i \leftarrow r_i + 1$, conditional branching, register swaps).
  - $W: E \to \mathbb{R}^+$: Transition affinity weights determining sampling priors during program composition and mutation.
  - $C: E \to \mathbb{R}^k$: Empirical causal outcome vector tracking expected progress $\Delta \text{Progress}(s, s')$ toward invariant satisfaction and non-zero termination metrics.
- **Update Equation:**
  During candidate execution on training examples, when a micro-operation executes from state $s$ to $s'$:
  $$W_{e} \leftarrow (1 - \alpha) W_{e} + \alpha \cdot \text{clip}(\Delta \text{Progress}(s, s') + \beta \cdot \mathbb{I}_{\text{passed\_test}}, 0, W_{\max})$$
  where $\alpha = 0.15$ is the learning rate, $\beta = 1.0$ is the task completion credit, and $\Delta \text{Progress}$ measures decrease in residual error / loop termination distance.
- **Novelty Classification:**
  POTENTIALLY_NEW / ADAPTATION relative to cited literature:
  - Closest Prior Art 1: Differentiable Plasticity / Fast Weights (Miconi et al. 2018, "Differentiable plasticity: training plastic neural networks with backpropagation", ICML 2018; Ba et al. 2016, "Using Fast Weights to Attend to the Recent Past", NeurIPS 2016). CTAM operates on discrete executable micro-operation transition structures with explicit causal invariants, not continuous matrix modifications.
  - Closest Prior Art 2: CEGIS / Program Induction (Solar-Lezama 2008, "Program Synthesis by Sketching"; Ellis et al. 2020, "DreamCoder: Growing generalizable, interpretable knowledge with program synthesis"). CTAM retains fine-grained microcircuit transition affinities rather than compressed monolithic functional DSL abstractions ($\lambda$-expressions) or constraint satisfaction solving.

## 3. Matched Conventional Baseline
- Inductive grammar-guided stochastic search / genetic programming over the exact same elementary FoundryIR primitives (registers, conditional jumps, addition, subtraction, shifts, literals 0/1).
- No cross-task transition affinity storage (cold search or standard uniform mutation across L1 $\to$ L2 $\to$ L3).
- Identical candidate evaluation budgets, evaluation limits, timeout thresholds, and DEV examples.

## 4. Control / Causal Erasure / Sham Design
- **Causal Erasure:** The learned CTAM graph is zeroed / reset to uniform prior prior to L2/L3 search. Verification: Search performance must revert to cold baseline.
- **Sham Control:** The learned CTAM edge weights are randomly permuted across transitions. Verification: Sham CTAM must not yield the $\ge 20\%$ speedup observed with intact CTAM.
- **Restore Control:** The intact learned CTAM graph is restored. Verification: Search acceleration is recovered.
- **Transfer Evaluation:** Measure transfer from L1 (remainder) to L2 (quotient-and-remainder) and from L2 to L3 (GCD).

## 5. Exact Metrics and Binding Thresholds
- **Primary Metric:** `evaluations_to_first_correct` on public diagnostic suite for L2 and L3.
- **Binding Success Threshold:**
  $$\frac{\text{Baseline Eval Count} - \text{CTAM Eval Count}}{\text{Baseline Eval Count}} \ge 0.20 \quad (20\% \text{ reduction})$$
  with full 100% correctness on the public diagnostic suite, passing erasure and sham controls, and non-zero verified transfer.
- **Binding Falsifier:** If baseline outperforms or equals CTAM within 20%, if learned state causes no statistically meaningful change, or if full correctness is not achieved, verdict MUST be `FAIL`. If harness/environment blocks valid execution, report `BLOCKED` or `INCONCLUSIVE`.

## 6. Datasets, Tasks, and Seeds
- **Benchmark:** BENCHMARK-ALG-LADDER-v1 (session-local PROVISIONAL development harness until MUSE canonical manifest published).
  - L1: `rem(a, b)` for $0 \le a \le 4095, 1 \le b \le 255$.
  - L2: `qr(a, b)` for $0 \le a \le 4095, 1 \le b \le 255$, output $(q, r)$.
  - L3: `gcd(a, b)` for $1 \le a, b \le 4095$, output $g = \gcd(a, b)$.
- **DEV cases:** 256 deterministic cases per stage.
- **Diagnostic held-out cases:** 256 cases generated under independent seed (Seed 42 for DEV, Seed 1337 for diagnostic holdout). Boundary cases included: $a=0, a<b, a=b, b=1$, primes, coprime pairs, max operands.
- **Candidate Evaluation Budget:** 5,000 candidate evaluations max per task.

## 7. Leak-Prevention Rules & Human Assistance
- Learner receives only input-output examples; never reference implementations or ASTs.
- No built-in division, modulo, multiplication, or GCD primitives in candidate IR.
- Human Assistance Level: H2 (task specification provided by benchmark; synthesis algorithm and substrate invented autonomously). All human interactions recorded in `human_assistance.jsonl`.
- Confidence intervals: Bootstrap 95% CI across multiple random seeds (seeds 101, 202, 303).
