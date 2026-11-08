"""
Matched Conventional Baseline for BENCHMARK-ALG-LADDER-v1.

Synthesizer: Grammar-guided stochastic search / Genetic Programming / MCMC program induction.
- Operates over identical FoundryIR elementary primitives (SET_IMM, MOV, ADD, SUB, SHL, SHR, AND, OR, XOR, CMP, IF_GT_ZERO, WHILE_GT_ZERO).
- Does not retain cross-task state-conditioned microcircuit transition affinities (searches cold or with uniform grammar priors across tasks).
- Bounded candidate evaluation budget.
"""

import random
import copy
import time
from typing import List, Tuple, Dict, Any, Optional
from dev_harness import FoundryProgram, DevBenchmarkHarness

OPCODES = ['SET_IMM', 'MOV', 'ADD', 'SUB', 'SHL', 'SHR', 'AND', 'OR', 'XOR', 'CMP', 'IF_GT_ZERO', 'WHILE_GT_ZERO']
LEAF_OPS = ['SET_IMM', 'MOV', 'ADD', 'SUB', 'SHL', 'SHR', 'AND', 'OR', 'XOR', 'CMP']

def random_instruction(rng: random.Random, max_depth: int = 1, num_regs: int = 8) -> Tuple:
    op = rng.choice(OPCODES if max_depth > 0 else LEAF_OPS)
    if op == 'SET_IMM':
        dst = rng.randint(0, num_regs - 1)
        val = rng.choice([0, 1, 2, -1])
        return (op, dst, val)
    elif op == 'MOV':
        dst = rng.randint(0, num_regs - 1)
        src = rng.randint(0, num_regs - 1)
        return (op, dst, src)
    elif op in ('ADD', 'SUB', 'AND', 'OR', 'XOR', 'CMP'):
        dst = rng.randint(0, num_regs - 1)
        s1 = rng.randint(0, num_regs - 1)
        s2 = rng.randint(0, num_regs - 1)
        return (op, dst, s1, s2)
    elif op in ('SHL', 'SHR'):
        dst = rng.randint(0, num_regs - 1)
        src = rng.randint(0, num_regs - 1)
        amt = rng.choice([1, 2, 4])
        return (op, dst, src, amt)
    elif op == 'IF_GT_ZERO':
        cond = rng.randint(0, num_regs - 1)
        b_t = [random_instruction(rng, max_depth - 1, num_regs) for _ in range(rng.randint(1, 3))]
        b_f = [random_instruction(rng, max_depth - 1, num_regs) for _ in range(rng.randint(0, 2))]
        return (op, cond, b_t, b_f)
    elif op == 'WHILE_GT_ZERO':
        cond = rng.randint(0, num_regs - 1)
        body = [random_instruction(rng, max_depth - 1, num_regs) for _ in range(rng.randint(1, 4))]
        return (op, cond, body, 5000)
    return ('SET_IMM', 0, 0)

def random_program(rng: random.Random, num_instrs: int = 5, num_regs: int = 8) -> FoundryProgram:
    instrs = [random_instruction(rng, max_depth=1, num_regs=num_regs) for _ in range(num_instrs)]
    return FoundryProgram(instrs)

def mutate_instruction(instr: Tuple, rng: random.Random, num_regs: int = 8) -> Tuple:
    op = instr[0]
    if rng.random() < 0.25:
        return random_instruction(rng, max_depth=1 if op in ('IF_GT_ZERO', 'WHILE_GT_ZERO') else 0, num_regs=num_regs)

    # Mutate registers or arguments
    if op == 'SET_IMM':
        return (op, rng.randint(0, num_regs - 1), rng.choice([0, 1, 2, -1]))
    elif op in ('MOV', 'SHL', 'SHR'):
        return (op, rng.randint(0, num_regs - 1), rng.randint(0, num_regs - 1), instr[3] if len(instr) > 3 else None)
    elif op in ('ADD', 'SUB', 'AND', 'OR', 'XOR', 'CMP'):
        return (op, rng.randint(0, num_regs - 1), rng.randint(0, num_regs - 1), rng.randint(0, num_regs - 1))
    elif op == 'IF_GT_ZERO':
        b_t = [mutate_instruction(i, rng, num_regs) for i in instr[2]]
        return (op, rng.randint(0, num_regs - 1), b_t, instr[3])
    elif op == 'WHILE_GT_ZERO':
        body = [mutate_instruction(i, rng, num_regs) for i in instr[2]]
        return (op, rng.randint(0, num_regs - 1), body, 5000)
    return instr

def mutate_program(prog: FoundryProgram, rng: random.Random, num_regs: int = 8) -> FoundryProgram:
    new_instrs = copy.deepcopy(prog.instructions)
    r = rng.random()
    if r < 0.35 and len(new_instrs) > 1:
        # Delete an instruction
        idx = rng.randint(0, len(new_instrs) - 1)
        new_instrs.pop(idx)
    elif r < 0.70 and len(new_instrs) < 12:
        # Insert an instruction
        idx = rng.randint(0, len(new_instrs))
        new_instrs.insert(idx, random_instruction(rng, max_depth=1, num_regs=num_regs))
    else:
        # Mutate existing instruction
        if new_instrs:
            idx = rng.randint(0, len(new_instrs) - 1)
            new_instrs[idx] = mutate_instruction(new_instrs[idx], rng, num_regs=num_regs)
    return FoundryProgram(new_instrs)


class BaselineSynthesizer:
    def __init__(self, seed: int = 42, max_evals: int = 5000, population_size: int = 40):
        self.rng = random.Random(seed)
        self.max_evals = max_evals
        self.population_size = population_size
        self.eval_count = 0
        self.total_vm_steps = 0

    def synthesize(self, task: str, harness: DevBenchmarkHarness, initial_seed_programs: Optional[List[FoundryProgram]] = None) -> Tuple[Optional[FoundryProgram], Dict[str, Any]]:
        self.eval_count = 0
        self.total_vm_steps = 0
        start_time = time.time()

        population: List[Tuple[FoundryProgram, float]] = []

        # Subsample small batch of training cases for fast candidate rejection (e.g. 16 cases)
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

        # Seed initial population
        if initial_seed_programs:
            for p in initial_seed_programs:
                population.append((copy.deepcopy(p), _quick_eval(p)))

        while len(population) < self.population_size:
            p = random_program(self.rng, num_instrs=self.rng.randint(2, 6))
            score = _quick_eval(p)
            population.append((p, score))

        population.sort(key=lambda x: x[1], reverse=True)

        best_prog = None
        best_score = population[0][1]

        while self.eval_count < self.max_evals:
            # Check if top candidate solves full DEV suite
            top_cand, top_score = population[0]
            if top_score > 0.6:
                full_ok, full_acc, full_steps, fail = harness.evaluate_program(top_cand, task, held_out=False)
                self.total_vm_steps += full_steps
                if full_ok:
                    best_prog = top_cand
                    break

            # Selection & reproduction
            parent = population[self.rng.randint(0, min(10, len(population) - 1))][0]
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
            'found': best_prog is not None
        }
        return best_prog, metrics


if __name__ == '__main__':
    print("Testing baseline smoke test...")
    h = DevBenchmarkHarness()
    base = BaselineSynthesizer(seed=123, max_evals=100)
    # Quick synthesis check
    p, met = base.synthesize('L1', h)
    print(f"Smoke test result: evals={met['eval_count']}, found={met['found']}")
    print("Baseline synthesizer smoke test complete.")
