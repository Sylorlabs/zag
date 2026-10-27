#!/usr/bin/env python3
"""Measured, output-verified ZagScript/C/Rust/Python process-runtime comparison."""

import csv
import hashlib
import json
import os
from pathlib import Path
import platform
import shutil
import statistics
import subprocess
import sys
import tempfile
import time
from datetime import datetime, timezone


ROOT = Path(__file__).resolve().parents[1]
SOURCES = ROOT / "benchmarks" / "cross_language"
LANGUAGES = ("zagscript", "c", "rust", "python")
EXTENSIONS = {"zagscript": "zag", "c": "c", "rust": "rs", "python": "py"}


def positive_setting(name, default, minimum):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"benchmark: {name} must be an integer >= {minimum}")
    if value < minimum:
        raise SystemExit(f"benchmark: {name} must be >= {minimum}")
    return value


def command_output(command):
    result = subprocess.run(command, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
    if result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {command!r}\n"
            f"{result.stdout.decode(errors='replace')}"
            f"{result.stderr.decode(errors='replace')}"
        )
    return result.stdout


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def reference_checksum(iterations):
    x, checksum = 17, 0
    for _ in range(iterations):
        x = (x * 109 + 1021) % 65521
        checksum = (checksum + x) % 1000000007
    return f"{checksum}\n".encode("ascii")


def cpu_model():
    if sys.platform == "darwin":
        for key in ("machdep.cpu.brand_string", "hw.model"):
            result = subprocess.run(["sysctl", "-n", key], capture_output=True)
            if result.returncode == 0 and result.stdout.strip():
                return result.stdout.decode().strip()
    if sys.platform.startswith("linux"):
        for line in Path("/proc/cpuinfo").read_text().splitlines():
            if line.startswith(("model name", "Hardware")):
                return line.partition(":")[2].strip()
    return platform.processor() or "unavailable"


def main():
    runs = positive_setting("RUNS", 30, 30)
    iterations = positive_setting("ITERATIONS", 2_000_000, 1)
    # Resolve against the caller's directory before changing working directories.
    out_dir = Path(os.environ.get("OUT", ROOT / "benchmarks" / "results")).expanduser().resolve()
    default_compiler = (
        "znc-macos-arm64" if sys.platform == "darwin"
        else "znc-linux-arm64" if platform.machine().lower() in ("aarch64", "arm64")
        else "znc"
    )
    compiler = Path(os.environ.get("ZNC", ROOT / default_compiler)).expanduser().resolve()
    if not compiler.is_file() or not os.access(compiler, os.X_OK):
        raise SystemExit(f"benchmark: native compiler missing: {compiler} (set ZNC)")
    clang = shutil.which(os.environ.get("CC", "clang"))
    rustc = shutil.which(os.environ.get("RUSTC", "rustc"))
    if not clang or not rustc:
        raise SystemExit("benchmark: both clang (or CC) and rustc (or RUSTC) are required")

    expected = reference_checksum(iterations)
    metadata = {
        "protocol": "zagscript-cross-language-v1",
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "source_checkout_commit": command_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"]
        ).decode().strip(),
        "host": platform.platform(),
        "architecture": platform.machine(),
        "cpu_model": cpu_model(),
        "logical_cpu_count": os.cpu_count(),
        "runs_per_language": runs,
        "warmups_per_language": 3,
        "iterations_per_run": iterations,
        "timing": "perf_counter_ns around child process (spawn + execution + stdout/stderr capture)",
        "interleaving": "rotate starting language each measured round",
        "expected_stdout": expected.decode("ascii"),
        "expected_stdout_sha256": sha256(expected),
        "expected_stderr": "",
        "expected_exit_status": 0,
        "compiler_path": str(compiler),
        "compiler_sha256": sha256(compiler.read_bytes()),
        "compiler_from_this_checkout": compiler.parent == ROOT,
        "compiler_bundled_source_root": str(ROOT),
        "environment": {
            "SDKROOT": os.environ.get("SDKROOT"),
            "CC": os.environ.get("CC"),
            "RUSTC": os.environ.get("RUSTC"),
            "python_executable": sys.executable,
        },
        "versions": {
            "znc": command_output([str(compiler), "version"]).decode().strip(),
            "clang": command_output([clang, "--version"]).decode().splitlines()[0],
            "rustc": command_output([rustc, "--version"]).decode().strip(),
            "python": sys.version.splitlines()[0],
        },
        "source_sha256": {},
        "build_commands": {},
        "run_commands": {},
    }

    rows = []
    with tempfile.TemporaryDirectory(prefix="zag-cross-language-") as scratch:
        tmp = Path(scratch)
        # The Zag compiler resolves its shipped modules relative to its own
        # executable; bundle a temporary compiler with this checkout's sources.
        bundled_znc = tmp / "znc"
        shutil.copy2(compiler, bundled_znc)
        (tmp / "std").symlink_to(ROOT / "std", target_is_directory=True)
        (tmp / "selfhost").symlink_to(ROOT / "selfhost", target_is_directory=True)

        commands = {}
        for language in LANGUAGES:
            template = (SOURCES / f"kernel.{EXTENSIONS[language]}").read_text()
            if template.count("__ITERATIONS__") != 1:
                raise RuntimeError(f"{language}: expected exactly one iteration placeholder")
            source = tmp / f"kernel.{EXTENSIONS[language]}"
            source.write_text(template.replace("__ITERATIONS__", str(iterations)))
            metadata["source_sha256"][language] = sha256(source.read_bytes())
            artifact = tmp / language
            if language == "zagscript":
                build = [
                    str(bundled_znc), str(source), "-o", str(artifact),
                    "--no-zagd", "--no-analyze", "--no-foreground-cache",
                ]
            elif language == "c":
                build = [clang, "-O2", "-std=c11", str(source), "-o", str(artifact)]
            elif language == "rust":
                build = [
                    rustc, "-C", "opt-level=2", "-C", "target-cpu=generic",
                    str(source), "-o", str(artifact),
                ]
            else:
                build = None  # Python is interpreted; no ahead-of-time build.
            if build is not None:
                command_output(build)
                if not artifact.is_file() or not os.access(artifact, os.X_OK):
                    raise RuntimeError(f"{language}: compiler returned success without an executable")
            commands[language] = (
                [sys.executable, "-I", "-B", str(source)]
                if language == "python" else [str(artifact)]
            )
            metadata["build_commands"][language] = build
            metadata["run_commands"][language] = commands[language]

        def execute(language, phase, number, position):
            start = time.perf_counter_ns()
            result = subprocess.run(commands[language], stdout=subprocess.PIPE, stderr=subprocess.PIPE)
            elapsed = time.perf_counter_ns() - start
            if result.returncode != 0 or result.stdout != expected or result.stderr != b"":
                raise RuntimeError(
                    f"{language} {phase} {number}: parity failure: "
                    f"exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}, "
                    f"expected_stdout={expected!r}"
                )
            if phase == "measured":
                rows.append([number, position, language, elapsed, result.returncode,
                             sha256(result.stdout), sha256(result.stderr)])

        for warmup in range(1, 4):
            for position, language in enumerate(LANGUAGES, 1):
                execute(language, "warmup", warmup, position)
        for round_number in range(1, runs + 1):
            rotation = (round_number - 1) % len(LANGUAGES)
            for position, language in enumerate(
                LANGUAGES[rotation:] + LANGUAGES[:rotation], 1
            ):
                execute(language, "measured", round_number, position)

    out_dir.mkdir(parents=True, exist_ok=True)
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    base = out_dir / f"{stamp}.cross-language"
    with base.with_suffix(".cross-language.raw.csv").open("x", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["round", "position", "language", "elapsed_ns",
                         "exit_status", "stdout_sha256", "stderr_sha256"])
        writer.writerows(rows)
    with base.with_suffix(".cross-language.summary.csv").open("x", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["language", "runs", "min_ns", "median_ns", "max_ns",
                         "mean_ns", "pstdev_ns"])
        for language in LANGUAGES:
            samples = [row[3] for row in rows if row[2] == language]
            if len(samples) != runs:
                raise RuntimeError(f"{language}: missing measured samples")
            writer.writerow([language, len(samples), min(samples),
                             f"{statistics.median(samples):.1f}", max(samples),
                             f"{statistics.mean(samples):.1f}",
                             f"{statistics.pstdev(samples):.1f}"])
    with base.with_suffix(".cross-language.meta.json").open("x") as handle:
        json.dump(metadata, handle, indent=2)
        handle.write("\n")
    print(f"Matched stdout for all four languages: {expected.decode().strip()}")
    print(f"Measured {runs} interleaved runs per language (3 warmups each)")
    print(f"Raw:     {base.with_suffix('.cross-language.raw.csv')}")
    print(f"Summary: {base.with_suffix('.cross-language.summary.csv')}")
    print(f"Meta:    {base.with_suffix('.cross-language.meta.json')}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"benchmark: {error}")
