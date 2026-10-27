#!/usr/bin/env python3
"""Opt-in end-to-end smoke test; needs native znc, clang, rustc and Python."""

import collections
import csv
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile


BENCHMARK = Path(__file__).resolve().parent / "run_cross_language.py"


def main():
    with tempfile.TemporaryDirectory(prefix="zag-cross-language-test-") as scratch:
        env = dict(os.environ, OUT=scratch, ITERATIONS="10001", RUNS="29")
        rejected = subprocess.run([sys.executable, str(BENCHMARK)], env=env, capture_output=True)
        assert rejected.returncode != 0
        assert b"RUNS must be >= 30" in rejected.stderr, rejected.stderr
        assert list(Path(scratch).iterdir()) == [], "invalid run published output"

        env["RUNS"] = "30"
        finished = subprocess.run([sys.executable, str(BENCHMARK)], env=env, capture_output=True)
        assert finished.returncode == 0, finished.stdout + finished.stderr
        raw, = Path(scratch).glob("*.cross-language.raw.csv")
        summary, = Path(scratch).glob("*.cross-language.summary.csv")
        meta, = Path(scratch).glob("*.cross-language.meta.json")
        with raw.open(newline="") as handle:
            rows = list(csv.DictReader(handle))
        metadata = json.loads(meta.read_text())
        counts = collections.Counter(row["language"] for row in rows)
        assert counts == {"zagscript": 30, "c": 30, "rust": 30, "python": 30}, counts
        assert {int(row["round"]) for row in rows} == set(range(1, 31))
        assert all(row["exit_status"] == "0" and int(row["elapsed_ns"]) > 0 for row in rows)
        assert {row["stdout_sha256"] for row in rows} == {metadata["expected_stdout_sha256"]}
        with summary.open(newline="") as handle:
            summary_rows = list(csv.DictReader(handle))
        assert len(summary_rows) == 4
        assert all(int(row["runs"]) == 30 for row in summary_rows)
        assert metadata["iterations_per_run"] == 10001
        assert metadata["runs_per_language"] == 30
        assert len(metadata["source_sha256"]) == 4
        assert all(len(digest) == 64 for digest in metadata["source_sha256"].values())
    print("cross-language benchmark: PASS (parity, 30 runs each, metadata, rejection)")


if __name__ == "__main__":
    main()
