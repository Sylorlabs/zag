#!/usr/bin/env python3
"""DEV CONTROL ONLY: public deterministic toy, not a protected benchmark.

In-process reference and negative controls; no candidate sandbox, hidden
holdout, secure state erasure, or learner/generalization claim. The reference
is an explicitly authored XOR solver, not an independently trained learner.
"""
import random

SEED = 43021
EPISODES = 16
PROBES = 32

class Constant:
    def teach(self, label, x, y):
        pass
    def predict(self, label, x):
        return 0

class ExactLookup:
    def __init__(self):
        self.table = {}
    def teach(self, label, x, y):
        self.table[(label, x)] = y
    def predict(self, label, x):
        return self.table.get((label, x), 0)

class AuthoredXorReference:
    def __init__(self):
        self.masks = {}
    def teach(self, label, x, y):
        self.masks[label] = x ^ y
    def predict(self, label, x):
        return x ^ self.masks[label] if label in self.masks else 0

def make_episodes():
    rng = random.Random(SEED)
    episodes = []
    for _ in range(EPISODES):
        labels = rng.sample(range(2**32), 2)
        entries = []
        for label in labels:
            old_mask = rng.randrange(256)
            new_mask = rng.choice([x for x in range(256) if x != old_mask])
            train1, train2 = rng.sample(range(256), 2)
            probes = rng.sample([x for x in range(256) if x not in (train1, train2)], PROBES)
            entries.append((label, old_mask, new_mask, train1, train2, probes))
        episodes.append(entries)
    return episodes

def run(model_class, episodes, train):
    counts = [0, 0]
    totals = [0, 0]
    for entries in episodes:
        model = model_class()
        for phase in (0, 1):
            for label, old, new, x1, x2, probes in entries:
                mask, sample = (old, x1) if phase == 0 else (new, x2)
                if train:
                    model.teach(label, sample, sample ^ mask)
            for label, old, new, x1, x2, probes in entries:
                mask = old if phase == 0 else new
                for x in probes:
                    counts[phase] += model.predict(label, x) == (x ^ mask)
                    totals[phase] += 1
    return counts, totals

def main():
    episodes = make_episodes()
    print('TIER=PUBLIC_IN_PROCESS_DEVELOPMENT_CONTROL; NOT_PROTECTED; NOT_A_BENCHMARK')
    print('family=XOR; SEED=%d; EPISODES=%d; PROBES_PER_LABEL=%d' % (SEED, EPISODES, PROBES))
    for name, cls, train, expected in [
        ('constant_zero', Constant, True, 'reject'),
        ('exact_lookup', ExactLookup, True, 'reject'),
        ('authored_xor_reference', AuthoredXorReference, True, 'pass'),
        ('clean_untrained_reference', AuthoredXorReference, False, 'reject'),
    ]:
        counts, totals = run(cls, episodes, train)
        passed = all(correct * 10 >= total * 9 for correct, total in zip(counts, totals))
        print('%s acquired=%d/%d rebound=%d/%d gate=%s' % (
            name, counts[0], totals[0], counts[1], totals[1], 'PASS' if passed else 'REJECT'))
        if passed != (expected == 'pass'):
            raise SystemExit('CONTROL_FAILURE: ' + name)
        if expected == 'reject' and any(correct * PROBES > total for correct, total in zip(counts, totals)):
            raise SystemExit('NEGATIVE_CONTROL_EXCEEDS_ONE_PER_LABEL: ' + name)
    print('CONTROL_SELF_TEST=PASS; clean object is NOT verified persistence erasure')

if __name__ == '__main__':
    main()
