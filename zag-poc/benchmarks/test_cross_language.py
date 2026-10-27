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
KERNELS = ("recurrence", "branch", "call")
LANGUAGES = ("zagscript", "c", "rust", "python")


def main():
    with tempfile.TemporaryDirectory(prefix="zag-cross-language-test-") as scratch:
        env = dict(os.environ, OUT=scratch, ITERATIONS="10001", RUNS="29")
        env.pop("ZNC_BASELINE", None)
        env["KERNELS"] = ",".join(KERNELS)
        rejected = subprocess.run([sys.executable, str(BENCHMARK)], env=env, capture_output=True)
        assert rejected.returncode != 0
        assert b"RUNS must be >= 30" in rejected.stderr, rejected.stderr
        assert list(Path(scratch).iterdir()) == [], "invalid run published output"

        env["KERNELS"] = "recurrence,invalid"
        env["RUNS"] = "30"
        rejected = subprocess.run([sys.executable, str(BENCHMARK)], env=env, capture_output=True)
        assert rejected.returncode != 0
        assert b"KERNELS must list distinct names" in rejected.stderr, rejected.stderr
        assert list(Path(scratch).iterdir()) == [], "invalid kernel published output"
        env["KERNELS"] = ",".join(KERNELS)

        env["RUN_TIMEOUT_SECONDS"] = "0"
        rejected = subprocess.run([sys.executable, str(BENCHMARK)], env=env, capture_output=True)
        assert rejected.returncode != 0
        assert b"RUN_TIMEOUT_SECONDS must be >= 1" in rejected.stderr, rejected.stderr
        assert list(Path(scratch).iterdir()) == [], "invalid timeout published output"
        env["RUN_TIMEOUT_SECONDS"] = "60"

        finished = subprocess.run([sys.executable, str(BENCHMARK)], env=env, capture_output=True)
        assert finished.returncode == 0, finished.stdout + finished.stderr
        raw, = Path(scratch).glob("*.cross-language.raw.csv")
        summary, = Path(scratch).glob("*.cross-language.summary.csv")
        meta, = Path(scratch).glob("*.cross-language.meta.json")
        with raw.open(newline="") as handle:
            rows = list(csv.DictReader(handle))
        metadata = json.loads(meta.read_text())
        counts = collections.Counter((row["kernel"], row["language"]) for row in rows)
        assert counts == {(k, lang): 30 for k in KERNELS for lang in LANGUAGES}, counts
        assert {int(row["round"]) for row in rows} == set(range(1, 31))
        assert all(row["exit_status"] == "0" and int(row["elapsed_ns"]) > 0 for row in rows)
        assert all(row["stdout_sha256"] ==
                   metadata["expected_stdout_sha256_by_kernel"][row["kernel"]]
                   for row in rows)
        with summary.open(newline="") as handle:
            summary_rows = list(csv.DictReader(handle))
        assert len(summary_rows) == len(KERNELS) * len(LANGUAGES)
        assert {(row["kernel"], row["language"]) for row in summary_rows} == set(counts)
        assert all(int(row["runs"]) == 30 for row in summary_rows)
        assert metadata["iterations_per_run"] == 10001
        assert metadata["runs_per_language"] == 30
        assert metadata["run_timeout_seconds"] == 60
        assert metadata["build_timeout_seconds"] == 180
        assert metadata["protocol"] == "zagscript-cross-language-v2"
        assert metadata["kernels"] == list(KERNELS)
        assert len(metadata["source_sha256"]) == len(KERNELS) * len(LANGUAGES)
        assert all(len(digest) == 64 for digest in metadata["source_sha256"].values())
        with tempfile.TemporaryDirectory(prefix="zag-cross-language-paired-test-") as paired:
            env["OUT"] = paired
            env["ZNC_BASELINE"] = metadata["compiler_path"]
            finished = subprocess.run([sys.executable, str(BENCHMARK)], env=env,
                                      capture_output=True)
            assert finished.returncode == 0, finished.stdout + finished.stderr
            paired_raw, = Path(paired).glob("*.cross-language.raw.csv")
            paired_meta, = Path(paired).glob("*.cross-language.meta.json")
            paired_rows = list(csv.DictReader(paired_raw.open(newline="")))
            counts = collections.Counter((row["kernel"], row["language"]) for row in paired_rows)
            assert counts == {(k, lang): 30 for k in KERNELS
                              for lang in LANGUAGES + ("zagscript_baseline",)}, counts
            paired_metadata = json.loads(paired_meta.read_text())
            assert paired_metadata["baseline_compiler_sha256"] == metadata["compiler_sha256"]
            assert all(row["stdout_sha256"] ==
                       paired_metadata["expected_stdout_sha256_by_kernel"][row["kernel"]]
                       for row in paired_rows)
    print("cross-language benchmark: PASS (three kernels, parity, 30 runs each, metadata, rejection)")


if __name__ == "__main__":
    main()
