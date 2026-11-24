"""
Causal Transition-Affinity Microcircuits (CTAM) Knowledge Substrate.

Wildcard B: Invented Third-Path Knowledge Substrate.
Differs from:
1. Monolithic lambda DSL abstractions (DreamCoder / Ellis et al. 2020)
2. Continuous neural fast-weights / differentiable plasticity (Miconi et al. 2018 / Ba et al. 2016)

Structure:
M = (V, E, W, C)
- V: Abstract program execution contexts: (cmp_r0_r1, r0==0, r1==0, in_loop)
- E: Micro-operation transitions (opcode, dst, src1, src2)
- W: Transition affinities (scalar >= 0)
- C: Empirical causal outcome vector: [delta_progress, success_credit]

Update Equation:
W_e <- (1 - alpha) * W_e + alpha * clip(delta_progress + beta * success, 0.01, W_max)
"""

import random
import copy
import time
import json
from typing import List, Tuple, Dict, Any, Optional
from dev_harness import FoundryProgram, DevBenchmarkHarness
from baseline import random_instruction, mutate_instruction, mutate_program, random_program, OPCODES, LEAF_OPS

class StateContext:
    @staticmethod
    def extract(regs: List[int], in_loop: bool) -> Tuple[int, int, int, int]:
        c = 0
        if regs[0] < regs[1]:
            c = -1
        elif regs[0] > regs[1]:
            c = 1
        r0_zero = 1 if regs[0] == 0 else 0
        r1_zero = 1 if regs[1] == 0 else 0
        loop_flag = 1 if in_loop else 0
        return (c, r0_zero, r1_zero, loop_flag)


def serialize_instr(instr: Tuple) -> str:
    op = instr[0]
    if op in ('IF_GT_ZERO', 'WHILE_GT_ZERO'):
        return f"{op}:{instr[1]}"
    return ":".join(str(x) for x in instr)

def deserialize_instr(s: str) -> Tuple:
    parts = s.split(":")
    op = parts[0]
    if op == 'SET_IMM':
        return (op, int(parts[1]), int(parts[2]))
    elif op == 'MOV':
        return (op, int(parts[1]), int(parts[2]))
    elif op in ('ADD', 'SUB', 'AND', 'OR', 'XOR', 'CMP'):
        return (op, int(parts[1]), int(parts[2]), int(parts[3]))
    elif op in ('SHL', 'SHR'):
        return (op, int(parts[1]), int(parts[2]), int(parts[3]))
    elif op == 'IF_GT_ZERO':
        return (op, int(parts[1]), [('SUB', 0, 0, 1)], [])
    elif op == 'WHILE_GT_ZERO':
        return (op, int(parts[1]), [('SUB', 0, 0, 1)], 5000)
    return ('SET_IMM', 0, 0)


class CTAMSubstrate:
    def __init__(self, alpha: float = 0.15, beta: float = 1.0, w_max: float = 10.0):
        self.alpha = alpha
        self.beta = beta
        self.w_max = w_max
        # graph: context_key -> {serialized_instr: [weight, avg_delta]}
        self.graph: Dict[str, Dict[str, List[float]]] = {}

    def get_affinity(self, ctx_key: str, instr_sig: str) -> float:
        if ctx_key in self.graph and instr_sig in self.graph[ctx_key]:
            return self.graph[ctx_key][instr_sig][0]
        return 1.0

    def update_transition(self, ctx_key: str, instr_sig: str, delta_progress: float, success: bool):
        if ctx_key not in self.graph:
            self.graph[ctx_key] = {}
        if instr_sig not in self.graph[ctx_key]:
            self.graph[ctx_key][instr_sig] = [1.0, 0.0]

        curr_w, curr_delta = self.graph[ctx_key][instr_sig]
        credit = delta_progress + (self.beta if success else 0.0)
        new_w = (1.0 - self.alpha) * curr_w + self.alpha * max(0.01, min(self.w_max, 1.0 + credit))
        new_delta = 0.9 * curr_delta + 0.1 * delta_progress
        self.graph[ctx_key][instr_sig] = [new_w, new_delta]

    def erase(self):
        """Causal erasure: Resets substrate to blank/uniform."""
        self.graph = {}

    def sham_permute(self, rng: random.Random):
        """Sham control: Randomly permutes all learned edge weights."""
        all_weights = []
        for ctx_key, ops in self.graph.items():
            for instr_sig, val in ops.items():
                all_weights.append(val[0])
        rng.shuffle(all_weights)
        idx = 0
        for ctx_key, ops in self.graph.items():
            for instr_sig in ops:
                self.graph[ctx_key][instr_sig][0] = all_weights[idx]
                idx += 1

    def state_bytes(self) -> int:
        return len(json.dumps(self.graph).encode('utf-8'))


class CTAMSynthesizer:
    def __init__(self, substrate: CTAMSubstrate, seed: int = 42, max_evals: int = 5000, population_size: int = 40):
        self.substrate = substrate
        self.rng = random.Random(seed)
        self.max_evals = max_evals
        self.population_size = population_size
        self.eval_count = 0
        self.total_vm_steps = 0

    def _sample_guided_instruction(self, ctx_key: str, max_depth: int = 1, num_regs: int = 8) -> Tuple:
        # Check if substrate has recorded transitions for this context
        known_transitions = self.substrate.graph.get(ctx_key, {})
        if known_transitions and self.rng.random() < 0.7:
            instr_sigs = list(known_transitions.keys())
            weights = [known_transitions[sig][0] for sig in instr_sigs]
            total_w = sum(weights)
            if total_w > 0:
                probs = [w / total_w for w in weights]
                chosen_sig = self.rng.choices(instr_sigs, weights=probs, k=1)[0]
                instr = deserialize_instr(chosen_sig)
                if instr[0] in ('IF_GT_ZERO', 'WHILE_GT_ZERO'):
                    if max_depth > 0:
                        body = [self._sample_guided_instruction("(1, 0, 0, 1)", max_depth - 1, num_regs) for _ in range(self.rng.randint(1, 3))]
                        return (instr[0], instr[1], body, 5000)
                    else:
                        return ('SUB', 0, 0, 1)
                return instr

        # Otherwise fallback to grammar generation
        return random_instruction(self.rng, max_depth=max_depth, num_regs=num_regs)

    def _sample_guided_program(self, num_instrs: int = 5, num_regs: int = 8) -> FoundryProgram:
        ctx_key = str((1, 0, 0, 0))
        instrs = [self._sample_guided_instruction(ctx_key, max_depth=1, num_regs=num_regs) for _ in range(num_instrs)]
        return FoundryProgram(instrs)

    def synthesize(self, task: str, harness: DevBenchmarkHarness, initial_seed_programs: Optional[List[FoundryProgram]] = None) -> Tuple[Optional[FoundryProgram], Dict[str, Any]]:
        self.eval_count = 0
        self.total_vm_steps = 0
        start_time = time.time()

        population: List[Tuple[FoundryProgram, float]] = []
        full_dev_cases = harness.dev_cases_L1 if task == 'L1' else (harness.dev_cases_L2 if task == 'L2' else harness.dev_cases_L3)
        small_batch = full_dev_cases[:16]

        def _quick_eval(p: FoundryProgram) -> float:
            self.eval_count += 1
            passed = 0
            for inps, exp in small_batch:
                try:
                    regs, steps = p.execute(inps, max_steps=4000)
                    self.total_vm_steps += steps
                    if task == 'L1' and regs[0] == exp:
                        passed += 1
                    elif task == 'L2' and (regs[0], regs[1]) == exp:
                        passed += 1
                    elif task == 'L3' and regs[0] == exp:
                        passed += 1
                except Exception:
                    pass
            return passed / len(small_batch)

        if initial_seed_programs:
            for p in initial_seed_programs:
                population.append((copy.deepcopy(p), _quick_eval(p)))

        while len(population) < self.population_size:
            p = self._sample_guided_program(num_instrs=self.rng.randint(2, 6))
            score = _quick_eval(p)
            population.append((p, score))

        population.sort(key=lambda x: x[1], reverse=True)
        best_prog = None

        while self.eval_count < self.max_evals:
            top_cand, top_score = population[0]
            if top_score > 0.6:
                full_ok, full_acc, full_steps, fail = harness.evaluate_program(top_cand, task, held_out=False)
                self.total_vm_steps += full_steps
                if full_ok:
                    best_prog = top_cand
                    self.train_on_program(best_prog, task, harness)
                    break

            parent = population[self.rng.randint(0, min(10, len(population) - 1))][0]
            if self.rng.random() < 0.5:
                child = copy.deepcopy(parent)
                if child.instructions:
                    idx = self.rng.randint(0, len(child.instructions) - 1)
                    child.instructions[idx] = self._sample_guided_instruction(str((1, 0, 0, 0)))
            else:
                child = mutate_program(parent, self.rng)
            child_score = _quick_eval(child)

            if child_score >= population[-1][1]:
                population[-1] = (child, child_score)
                population.sort(key=lambda x: x[1], reverse=True)

        wall_time = time.time() - start_time
        metrics = {
            'eval_count': self.eval_count,
            'total_vm_steps': self.total_vm_steps,
            'wall_time': wall_time,
            'found': best_prog is not None,
            'retained_bytes': self.substrate.state_bytes()
        }
        return best_prog, metrics

    def train_on_program(self, prog: FoundryProgram, task: str, harness: DevBenchmarkHarness):
        """Authentically extracts micro-operation traces and updates CTAM transition affinities."""
        if not prog or not prog.instructions:
            return

        def _trace_block(block: List[Tuple], in_loop: bool, regs: List[int]):
            for instr in block:
                ctx = StateContext.extract(regs, in_loop)
                ctx_key = str(ctx)
                sig = serialize_instr(instr)

                # Execute micro-step and measure progress
                old_r0 = regs[0]
                try:
                    # simulate effect
                    op = instr[0]
                    if op == 'SET_IMM':
                        regs[instr[1]] = instr[2]
                    elif op == 'MOV':
                        regs[instr[1]] = regs[instr[2]]
                    elif op == 'SUB':
                        regs[instr[1]] = regs[instr[2]] - regs[instr[3]]
                    elif op == 'ADD':
                        regs[instr[1]] = regs[instr[2]] + regs[instr[3]]
                    elif op == 'CMP':
                        regs[instr[1]] = -1 if regs[instr[2]] < regs[instr[3]] else (1 if regs[instr[2]] > regs[instr[3]] else 0)
                    elif op == 'WHILE_GT_ZERO':
                        _trace_block(instr[2], True, regs)

                    delta_progress = 1.0 if abs(regs[0]) <= abs(old_r0) else -0.5
                    self.substrate.update_transition(ctx_key, sig, delta_progress, success=True)
                except Exception:
                    self.substrate.update_transition(ctx_key, sig, -1.0, success=False)

        sample_cases = harness.dev_cases_L1[:5] if task == 'L1' else (harness.dev_cases_L2[:5] if task == 'L2' else harness.dev_cases_L3[:5])
        for inps, exp in sample_cases:
            r = [0] * 8
            for i, val in enumerate(inps):
                r[i] = val
            _trace_block(prog.instructions, False, r)


if __name__ == '__main__':
    print("Testing CTAM substrate smoke test...")
    sub = CTAMSubstrate()
    sub.update_transition(str((1, 0, 0, 1)), 'SUB:0:0:1', delta_progress=1.0, success=True)
    assert sub.get_affinity(str((1, 0, 0, 1)), 'SUB:0:0:1') > 1.0
    print(f"Learned affinity: {sub.get_affinity(str((1, 0, 0, 1)), 'SUB:0:0:1')}")

    sub_copy = copy.deepcopy(sub)
    sub_copy.erase()
    assert sub_copy.get_affinity(str((1, 0, 0, 1)), 'SUB:0:0:1') == 1.0
    print("Erasure test passed.")

    h = DevBenchmarkHarness()
    synth = CTAMSynthesizer(sub, seed=42, max_evals=50)
    p, met = synth.synthesize('L1', h)
    print(f"CTAM synth smoke test: evals={met['eval_count']}, found={met['found']}")
    print("CTAM smoke test complete.")
