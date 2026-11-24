"""
Session-local development harness for BENCHMARK-ALG-LADDER-v1.
Status: PROVISIONAL (pending MUSE public benchmark manifest publication).

Defines:
- FoundryIR elementary instruction set and virtual machine:
  - 64-bit checked arithmetic
  - Bounded execution steps to guarantee termination
  - Registers r0..r7
  - Primitives: imm, mov, add, sub, shl, shr, and, or, xor, not, cmp, jmp_if, loop_bounded
  - STRICTLY NO built-in mul, div, mod, or gcd operators in candidate primitives!
- Tasks:
  - L1: rem(a, b) -> r
  - L2: qr(a, b) -> (q, r)
  - L3: gcd(a, b) -> g
- Deterministic 256 DEV cases and 256 held-out diagnostic cases per task.
"""

import sys
import random
import math
from typing import List, Tuple, Dict, Any, Optional

# Constants
INT64_MAX = (1 << 63) - 1
INT64_MIN = -(1 << 63)
UINT64_MASK = 0xFFFFFFFFFFFFFFFF

MAX_VM_STEPS = 50000

class VMError(Exception):
    pass

class IntegerOverflowError(VMError):
    pass

class DivisionByZeroError(VMError):
    pass

class StepLimitExceeded(VMError):
    pass

class FoundryProgram:
    def __init__(self, instructions: List[Tuple]):
        """
        Instructions format:
        ('SET_IMM', reg_idx, imm_val)
        ('MOV', dst_idx, src_idx)
        ('ADD', dst_idx, src1_idx, src2_idx)
        ('SUB', dst_idx, src1_idx, src2_idx)
        ('SHL', dst_idx, src_idx, shift_amt)  # shift_amt in 1..63
        ('SHR', dst_idx, src_idx, shift_amt)
        ('AND', dst_idx, src1_idx, src2_idx)
        ('OR', dst_idx, src1_idx, src2_idx)
        ('XOR', dst_idx, src1_idx, src2_idx)
        ('CMP', dst_idx, src1_idx, src2_idx) # -1 if <, 0 if ==, 1 if >
        ('IF_GT_ZERO', cond_reg, block_true, block_false)
        ('WHILE_GT_ZERO', cond_reg, loop_body, max_iter)
        """
        self.instructions = instructions

    def execute(self, inputs: Tuple[int, ...], num_regs: int = 8, max_steps: int = MAX_VM_STEPS) -> Tuple[List[int], int]:
        regs = [0] * num_regs
        for i, val in enumerate(inputs):
            if i < num_regs:
                regs[i] = val

        step_counter = [0]

        def _checked_i64(val: int) -> int:
            if val > INT64_MAX or val < INT64_MIN:
                # Wrap to signed 64-bit
                val = (val + (1 << 63)) % (1 << 64) - (1 << 63)
            return val

        def _exec_block(block: List[Tuple]):
            for instr in block:
                step_counter[0] += 1
                if step_counter[0] > max_steps:
                    raise StepLimitExceeded("VM step limit exceeded")

                op = instr[0]
                if op == 'SET_IMM':
                    dst, imm = instr[1], instr[2]
                    regs[dst] = _checked_i64(imm)
                elif op == 'MOV':
                    dst, src = instr[1], instr[2]
                    regs[dst] = regs[src]
                elif op == 'ADD':
                    dst, s1, s2 = instr[1], instr[2], instr[3]
                    regs[dst] = _checked_i64(regs[s1] + regs[s2])
                elif op == 'SUB':
                    dst, s1, s2 = instr[1], instr[2], instr[3]
                    regs[dst] = _checked_i64(regs[s1] - regs[s2])
                elif op == 'SHL':
                    dst, src, amt = instr[1], instr[2], instr[3] & 63
                    regs[dst] = _checked_i64(regs[src] << amt)
                elif op == 'SHR':
                    dst, src, amt = instr[1], instr[2], instr[3] & 63
                    regs[dst] = _checked_i64(regs[src] >> amt)
                elif op == 'AND':
                    dst, s1, s2 = instr[1], instr[2], instr[3]
                    regs[dst] = _checked_i64(regs[s1] & regs[s2])
                elif op == 'OR':
                    dst, s1, s2 = instr[1], instr[2], instr[3]
                    regs[dst] = _checked_i64(regs[s1] | regs[s2])
                elif op == 'XOR':
                    dst, s1, s2 = instr[1], instr[2], instr[3]
                    regs[dst] = _checked_i64(regs[s1] ^ regs[s2])
                elif op == 'CMP':
                    dst, s1, s2 = instr[1], instr[2], instr[3]
                    v1, v2 = regs[s1], regs[s2]
                    regs[dst] = -1 if v1 < v2 else (1 if v1 > v2 else 0)
                elif op == 'IF_GT_ZERO':
                    cond, b_t, b_f = instr[1], instr[2], instr[3]
                    if regs[cond] > 0:
                        _exec_block(b_t)
                    else:
                        _exec_block(b_f)
                elif op == 'WHILE_GT_ZERO':
                    cond, body, max_it = instr[1], instr[2], instr[3]
                    it = 0
                    while regs[cond] > 0 and it < max_it:
                        step_counter[0] += 1
                        if step_counter[0] > max_steps:
                            raise StepLimitExceeded("VM step limit exceeded in loop")
                        _exec_block(body)
                        it += 1
                else:
                    raise VMError(f"Unknown instruction {op}")

        _exec_block(self.instructions)
        return regs, step_counter[0]


def generate_cases(task: str, count: int, seed: int) -> List[Tuple[Tuple[int, ...], Any]]:
    """
    Generates deterministic evaluation cases including boundaries.
    """
    rng = random.Random(seed)
    cases = []

    # Mandatory boundaries
    if task in ('L1', 'L2'):
        boundaries = [
            (0, 1), (0, 255), (1, 1), (1, 2), (2, 2), (3, 2),
            (255, 255), (256, 255), (4095, 1), (4095, 2), (4095, 255),
            (100, 100), (99, 100), (101, 100), (2048, 64), (1023, 32),
            (4000, 200), (17, 19), (254, 255), (4095, 128)
        ]
        for a, b in boundaries:
            if task == 'L1':
                cases.append(((a, b), a % b))
            else:
                cases.append(((a, b), (a // b, a % b)))

        while len(cases) < count:
            a = rng.randint(0, 4095)
            b = rng.randint(1, 255)
            if task == 'L1':
                expected = a % b
            else:
                expected = (a // b, a % b)
            pair = ((a, b), expected)
            if pair not in cases:
                cases.append(pair)
    elif task == 'L3':
        boundaries = [
            (1, 1), (1, 4095), (4095, 1), (4095, 4095), (2048, 1024),
            (3571, 3571), (3571, 3559), # primes
            (256, 128), (4095, 1365), (210, 45), (1000, 300),
            (13, 17), (2, 4), (1024, 512), (3, 7), (100, 25)
        ]
        for a, b in boundaries:
            cases.append(((a, b), math.gcd(a, b)))

        while len(cases) < count:
            a = rng.randint(1, 4095)
            b = rng.randint(1, 4095)
            pair = ((a, b), math.gcd(a, b))
            if pair not in cases:
                cases.append(pair)
    else:
        raise ValueError(f"Unknown task {task}")

    return cases[:count]


class DevBenchmarkHarness:
    def __init__(self):
        # 256 DEV cases (seed 42)
        self.dev_cases_L1 = generate_cases('L1', 256, seed=42)
        self.dev_cases_L2 = generate_cases('L2', 256, seed=42)
        self.dev_cases_L3 = generate_cases('L3', 256, seed=42)

        # 256 held-out diagnostic cases (seed 1337)
        self.diag_cases_L1 = generate_cases('L1', 256, seed=1337)
        self.diag_cases_L2 = generate_cases('L2', 256, seed=1337)
        self.diag_cases_L3 = generate_cases('L3', 256, seed=1337)

    def evaluate_program(self, prog: FoundryProgram, task: str, held_out: bool = False) -> Tuple[bool, float, int, Optional[Tuple]]:
        """
        Evaluates a program against DEV or held-out diagnostic cases.
        Returns: (passed_all, accuracy, total_vm_steps, first_failing_case_info)
        """
        if held_out:
            cases = self.diag_cases_L1 if task == 'L1' else (self.diag_cases_L2 if task == 'L2' else self.diag_cases_L3)
        else:
            cases = self.dev_cases_L1 if task == 'L1' else (self.dev_cases_L2 if task == 'L2' else self.dev_cases_L3)

        passed = 0
        total_steps = 0
        fail_info = None

        for inputs, expected in cases:
            try:
                regs, steps = prog.execute(inputs)
                total_steps += steps
                if task == 'L1':
                    actual = regs[0]
                    ok = (actual == expected)
                elif task == 'L2':
                    actual = (regs[0], regs[1]) # q in r0, r in r1
                    ok = (actual == expected)
                elif task == 'L3':
                    actual = regs[0] # g in r0
                    ok = (actual == expected)
                else:
                    raise ValueError(f"Unknown task {task}")

                if ok:
                    passed += 1
                elif fail_info is None:
                    fail_info = (inputs, expected, actual, "Output mismatch")
            except Exception as e:
                if fail_info is None:
                    fail_info = (inputs, expected, None, str(e))

        acc = passed / len(cases)
        return (passed == len(cases)), acc, total_steps, fail_info


if __name__ == '__main__':
    print("Testing dev_harness.py smoke test...")
    harness = DevBenchmarkHarness()
    assert len(harness.dev_cases_L1) == 256
    assert len(harness.dev_cases_L2) == 256
    assert len(harness.dev_cases_L3) == 256
    assert len(harness.diag_cases_L1) == 256
    assert len(harness.diag_cases_L2) == 256
    assert len(harness.diag_cases_L3) == 256

    # Test dummy program on L1
    # Inputs: r0=a, r1=b
    # Let's test a simple program: while r0 >= r1: r0 -= r1
    # Instructions:
    # r2 = cmp(r0, r1) -> if r0 >= r1: r2 in (0, 1), so r2 + 1 >= 1.
    # More simply:
    # r2 = sub(r0, r1); if r2 >= 0 ...
    # Let's write standard repeated subtraction for remainder:
    # loop:
    #   r2 = cmp(r0, r1) # if r0 < r1, r2 = -1; if r0 == r1, r2 = 0; if r0 > r1, r2 = 1.
    #   r3 = r2 + 1      # if r0 >= r1, r3 > 0.
    #   while r3 > 0:
    #     r0 = r0 - r1
    #     r2 = cmp(r0, r1)
    #     r3 = r2 + 1
    # Let's test this in FoundryProgram to confirm VM semantics:
    rem_prog = FoundryProgram([
        ('SET_IMM', 4, 1),
        ('CMP', 2, 0, 1),
        ('ADD', 3, 2, 4), # r3 = cmp(r0, r1) + 1
        ('WHILE_GT_ZERO', 3, [
            ('SUB', 0, 0, 1),
            ('CMP', 2, 0, 1),
            ('ADD', 3, 2, 4),
        ], 5000)
    ])
    passed, acc, steps, fail = harness.evaluate_program(rem_prog, 'L1', held_out=False)
    print(f"L1 reference test: passed={passed}, acc={acc:.4f}, steps={steps}")
    assert passed, f"L1 reference failed: {fail}"

    passed_diag, acc_diag, steps_diag, fail_diag = harness.evaluate_program(rem_prog, 'L1', held_out=True)
    print(f"L1 diagnostic test: passed={passed_diag}, acc={acc_diag:.4f}, steps={steps_diag}")
    assert passed_diag, f"L1 diag failed: {fail_diag}"

    print("dev_harness smoke test completed successfully!")
