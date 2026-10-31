#!/usr/bin/env python3
"""TIER: SOURCE-ONLY / UNEXECUTED development evaluator, NOT a qualified benchmark.

Run: python3 research/tomo-independent-genotype-dev-v1.py --self-check
     python3 research/tomo-independent-genotype-dev-v1.py --candidate 'python3 learner_adapter.py'
Protocol: a fresh long-lived child for each episode, JSON lines in/out on stdin/stdout.
Request: {"op":"train", "input_b64":..., "target_b64":...}; response: {"ok":true}.
Request: {"op":"predict", "input_b64":...}; response: {"output_b64":...}.
All inputs, feedback and outputs are raw bytes encoded as base64. No feedback on tests.
State persists in process only. Restart/erasure is an experimental control, NOT proof
that disk state was erased. Run candidates only in an external isolated sandbox with
network disabled, resource quotas, no access to evaluator, test keys or parent source.
No sandbox, protected held-out set, state export, or independent reproduction is
provided here. Public development tasks are not evidence of acquired intelligence.
"""
import argparse
import base64
import json
import random
import select
import shlex
import string
import subprocess
import sys


def enc(x):
    return base64.b64encode(x).decode('ascii')


def dec(x):
    return base64.b64decode(x, validate=True)


class Candidate:
    def __init__(self, command):
        self.proc = subprocess.Popen(shlex.split(command), stdin=subprocess.PIPE,
                                     stdout=subprocess.PIPE, stderr=subprocess.DEVNULL,
                                     bufsize=0)

    def request(self, obj):
        self.proc.stdin.write((json.dumps(obj, separators=(',', ':')) + '\n').encode())
        self.proc.stdin.flush()
        if not select.select([self.proc.stdout], [], [], 10)[0]:
            raise TimeoutError('candidate response exceeded 10 seconds')
        line = self.proc.stdout.readline(1048577)
        if not line or len(line) > 1048576:
            raise ValueError('missing or oversized candidate response')
        return json.loads(line)

    def train(self, x, y):
        reply = self.request({'op': 'train', 'input_b64': enc(x), 'target_b64': enc(y)})
        if reply.get('ok') is not True:
            raise ValueError('training was not acknowledged')

    def predict(self, x):
        return dec(self.request({'op': 'predict', 'input_b64': enc(x)})['output_b64'])

    def close(self):
        self.proc.kill()
        self.proc.wait()


class Control:
    def __init__(self, kind):
        self.kind = kind
        self.table = {}

    def train(self, x, y):
        self.table[x] = y

    def predict(self, x):
        return self.table.get(x, b'') if self.kind == 'lookup' else b'constant'

    def close(self):
        pass


def make_id(r):
    return ''.join(r.choice(string.ascii_lowercase) for _ in range(12)).encode()


def apply(op, x):
    return x[::-1] if op == 0 else x[1:] + x[:1]


def prompt(f, x):
    return b'call ' + f + b' ' + x


def run_function_episode(factory, seed, variant):
    r = random.Random(seed)
    f, g = make_id(r), make_id(r)
    # Randomly assign the taught transformation to opaque identifiers.
    first = r.randrange(2)
    train = []
    for _ in range(24):
        x = make_id(r)
        train.append((prompt(f, x), apply(first, x)))
        train.append((prompt(g, x), apply(1 - first, x)))
    tests = []
    for _ in range(24):
        x = make_id(r)
        if variant == 'composition':
            tests.append((b'compose ' + f + b' ' + g + b' ' + x,
                          apply(1-first, apply(first, x))))
        else:
            tests.append((prompt(f, x), apply(first, x)))
    # A fresh process must not have access to training state in the erasure control.
    c = factory()
    try:
        for x, y in train:
            c.train(x, y)
        if variant == 'erasure':
            c.close()
            c = factory()
        inputs = [x for x, _ in tests]
        if variant == 'shuffled-input':
            inputs = inputs[1:] + inputs[:1]
        answers = [c.predict(x) for x in inputs]
    finally:
        c.close()
    correct = sum(a == target for a, (_, target) in zip(answers, tests))
    # Frequent-constant output fails independently of prediction loss.
    diverse = len(set(answers)) > 1
    return {'correct': correct, 'total': len(tests), 'distinct_outputs': len(set(answers)),
            'pass_development_gate': bool(correct >= 18 and diverse)}


def next_byte_episode(factory):
    c = factory()
    try:
        for x, y in [(b'ab', b'c'), (b'bc', b'd'), (b'cd', b'e')]:
            c.train(x, y)
        tests = [(b'de', b'f'), (b'ef', b'g'), (b'fg', b'h')]
        outputs = [c.predict(x) for x, _ in tests]
    finally:
        c.close()
    return {'correct': sum(a == y for a, (_, y) in zip(outputs, tests)),
            'total': len(tests), 'measure': 'exact next byte, not understanding'}


def main():
    p = argparse.ArgumentParser(description=__doc__)
    p.add_argument('--candidate', help='JSONL byte-adapter command; trusted sandbox only')
    p.add_argument('--seed', type=int, default=20261031)
    p.add_argument('--self-check', action='store_true', help='run built-in negative controls only')
    a = p.parse_args()
    if not a.self_check and not a.candidate:
        p.error('supply --candidate or --self-check')
    factories = {'constant-output': lambda: Control('constant'),
                 'lookup-table': lambda: Control('lookup')}
    if a.candidate:
        factories['candidate'] = lambda: Candidate(a.candidate)
    report = {'tier': 'development only; unqualified', 'seed': a.seed,
              'limitations': ['public examples and seed; not held-out or secure',
                  'no isolation or resource quotas', 'process restart is not verified state erasure',
                  'hand-coded reverse and rotate may defeat acquisition claims',
                  'test-specific routing and external state are not detected'],
              'subtests': {}, 'not_implemented': ['independent binding intervention',
                  'delayed recall', 'continual acquisition', 'negative transfer',
                  'representation growth', 'cross-domain reuse', 'protected state persistence',
                  'hidden independent evaluator', 'matched-compute control']}
    for name, factory in factories.items():
        results = {}
        results['prediction_next_byte'] = next_byte_episode(factory)
        for variant in ('unseen-identifiers', 'composition', 'erasure', 'shuffled-input'):
            results[variant] = run_function_episode(factory, a.seed, variant)
        report['subtests'][name] = results
    print(json.dumps(report, indent=2, sort_keys=True))
    if a.self_check:
        if any(report['subtests'][k]['unseen-identifiers']['pass_development_gate']
               for k in ('constant-output', 'lookup-table')):
            return 1
    return 0


if __name__ == '__main__':
    sys.exit(main())
