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
KERNELS = ("recurrence", "branch", "call")
EXTENSIONS = {"zagscript": "zag", "zagscript_baseline": "zag",
              "c": "c", "rust": "rs", "python": "py"}


def positive_setting(name, default, minimum):
    raw = os.environ.get(name, str(default))
    try:
        value = int(raw)
    except ValueError:
        raise SystemExit(f"benchmark: {name} must be an integer >= {minimum}")
    if value < minimum:
        raise SystemExit(f"benchmark: {name} must be >= {minimum}")
    return value


def command_output(command, timeout_seconds=180):
    try:
        result = subprocess.run(
            command, stdout=subprocess.PIPE, stderr=subprocess.PIPE,
            timeout=timeout_seconds,
        )
    except subprocess.TimeoutExpired as exc:
        raise RuntimeError(
            f"command timed out after {timeout_seconds}s: {command!r}"
        ) from exc
    if result.returncode:
        raise RuntimeError(
            f"command failed ({result.returncode}): {command!r}\n"
            f"{result.stdout.decode(errors='replace')}"
            f"{result.stderr.decode(errors='replace')}"
        )
    return result.stdout


def sha256(data):
    return hashlib.sha256(data).hexdigest()


def reference_checksum(kernel, iterations):
    x, checksum = 17, 0
    for _ in range(iterations):
        x = (x * 109 + 1021) % 65521
        if kernel == "recurrence":
            checksum = (checksum + x) % 1000000007
        elif kernel == "call":
            checksum = (checksum + x * 7 + 3) % 1000000007
        elif kernel == "branch":
            branch = x % 4
            if branch == 0:
                checksum = (checksum + x * 7 + 3) % 1000000007
            elif branch == 1:
                checksum = (checksum + x * 11 + 5) % 1000000007
            elif branch == 2:
                checksum = (checksum + x * 13 + 7) % 1000000007
            else:
                checksum = (checksum + x * 17 + 9) % 1000000007
        else:
            raise ValueError(f"unknown kernel: {kernel}")
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
    kernels = tuple(os.environ.get("KERNELS", ",".join(KERNELS)).split(","))
    if not kernels or any(k not in KERNELS for k in kernels) or len(set(kernels)) != len(kernels):
        raise SystemExit("benchmark: KERNELS must list distinct names from " + ",".join(KERNELS))
    build_timeout = positive_setting("BUILD_TIMEOUT_SECONDS", 180, 1)
    run_timeout = positive_setting("RUN_TIMEOUT_SECONDS", 60, 1)
    retain_setting = os.environ.get("RETAIN_ARTIFACTS", "0")
    if retain_setting not in ("0", "1"):
        raise SystemExit("benchmark: RETAIN_ARTIFACTS must be 0 or 1")
    retain_artifacts = retain_setting == "1"
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
    baseline_setting = os.environ.get("ZNC_BASELINE")
    baseline = Path(baseline_setting).expanduser().resolve() if baseline_setting else None
    if baseline is not None and (not baseline.is_file() or not os.access(baseline, os.X_OK)):
        raise SystemExit(f"benchmark: baseline compiler missing: {baseline}")
    languages = LANGUAGES + (("zagscript_baseline",) if baseline is not None else ())
    clang = shutil.which(os.environ.get("CC", "clang"))
    rustc = shutil.which(os.environ.get("RUSTC", "rustc"))
    if not clang or not rustc:
        raise SystemExit("benchmark: both clang (or CC) and rustc (or RUSTC) are required")

    expected = {kernel: reference_checksum(kernel, iterations) for kernel in kernels}
    metadata = {
        "protocol": "zagscript-cross-language-v2",
        "kernels": list(kernels),
        "timestamp_utc": datetime.now(timezone.utc).isoformat(),
        "source_checkout_commit": command_output(
            ["git", "-C", str(ROOT), "rev-parse", "HEAD"]
        ).decode().strip(),
        "host": platform.platform(),
        "architecture": platform.machine(),
        "cpu_model": cpu_model(),
        "logical_cpu_count": os.cpu_count(),
        "runs_per_language": runs,
        "build_timeout_seconds": build_timeout,
        "run_timeout_seconds": run_timeout,
        "warmups_per_language": 3,
        "iterations_per_run": iterations,
        "timing": "perf_counter_ns around child process (spawn + execution + stdout/stderr capture)",
        "interleaving": "rotate starting language each measured round",
        "expected_stdout_by_kernel": {
            kernel: value.decode("ascii") for kernel, value in expected.items()
        },
        "expected_stdout_sha256_by_kernel": {
            kernel: sha256(value) for kernel, value in expected.items()
        },
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
            "znc": command_output([str(compiler), "version"], build_timeout).decode().strip(),
            "clang": command_output([clang, "--version"], build_timeout).decode().splitlines()[0],
            "rustc": command_output([rustc, "--version"], build_timeout).decode().strip(),
            "python": sys.version.splitlines()[0],
        },
        "source_sha256": {},
        "retained_artifacts": {},
        "build_commands": {},
        "run_commands": {},
    }
    if baseline is not None:
        metadata["baseline_compiler_path"] = str(baseline)
        metadata["baseline_compiler_sha256"] = sha256(baseline.read_bytes())
        metadata["versions"]["znc_baseline"] = command_output(
            [str(baseline), "version"], build_timeout
        ).decode().strip()

    rows = []
    artifacts_dir = None
    with tempfile.TemporaryDirectory(prefix="zag-cross-language-") as scratch:
        tmp = Path(scratch)
        # The Zag compiler resolves its shipped modules relative to its own
        # executable; bundle a temporary compiler with this checkout's sources.
        bundled_znc = tmp / "znc"
        shutil.copy2(compiler, bundled_znc)
        (tmp / "std").symlink_to(ROOT / "std", target_is_directory=True)
        (tmp / "selfhost").symlink_to(ROOT / "selfhost", target_is_directory=True)

        baseline_znc = None
        if baseline is not None:
            baseline_dir = tmp / "baseline_bundle"
            baseline_dir.mkdir()
            baseline_znc = baseline_dir / "znc"
            shutil.copy2(baseline, baseline_znc)
            (baseline_dir / "std").symlink_to(ROOT / "std", target_is_directory=True)
            (baseline_dir / "selfhost").symlink_to(ROOT / "selfhost", target_is_directory=True)

        commands = {}
        for kernel in kernels:
            for language in languages:
                key = f"{kernel}:{language}"
                basename = "kernel" if kernel == "recurrence" else kernel
                template = (SOURCES / f"{basename}.{EXTENSIONS[language]}").read_text()
                if template.count("__ITERATIONS__") != 1:
                    raise RuntimeError(f"{key}: expected exactly one iteration placeholder")
                source = tmp / f"{basename}.{EXTENSIONS[language]}"
                source.write_text(template.replace("__ITERATIONS__", str(iterations)))
                metadata["source_sha256"][key] = sha256(source.read_bytes())
                artifact = tmp / f"{kernel}-{language}"
                if language in ("zagscript", "zagscript_baseline"):
                    build = [
                        str(baseline_znc if language == "zagscript_baseline" else bundled_znc),
                        str(source), "-o", str(artifact),
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
                    build = None
                if build is not None:
                    command_output(build, timeout_seconds=build_timeout)
                    if not artifact.is_file() or not os.access(artifact, os.X_OK):
                        raise RuntimeError(f"{key}: compiler returned success without an executable")
                commands[key] = (
                    [sys.executable, "-I", "-B", str(source)]
                    if language == "python" else [str(artifact)]
                )
                metadata["build_commands"][key] = build
                metadata["run_commands"][key] = commands[key]

        def execute(kernel, language, phase, number, position):
            key = f"{kernel}:{language}"
            start = time.perf_counter_ns()
            try:
                result = subprocess.run(
                    commands[key], stdout=subprocess.PIPE,
                    stderr=subprocess.PIPE, timeout=run_timeout,
                )
            except subprocess.TimeoutExpired as exc:
                raise RuntimeError(
                    f"{key} {phase} {number}: timed out after "
                    f"{run_timeout}s (increase RUN_TIMEOUT_SECONDS for larger ITERATIONS)"
                ) from exc
            elapsed = time.perf_counter_ns() - start
            if result.returncode != 0 or result.stdout != expected[kernel] or result.stderr != b"":
                raise RuntimeError(
                    f"{key} {phase} {number}: parity failure: "
                    f"exit={result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}, "
                    f"expected_stdout={expected[kernel]!r}"
                )
            if phase == "measured":
                rows.append([kernel, number, position, language, elapsed, result.returncode,
                             sha256(result.stdout), sha256(result.stderr)])

        # Rotate implementation order within each kernel. Rotate kernel order
        # between rounds too, so time/load drift cannot favor a fixed workload.
        for warmup in range(1, 4):
            for kernel in kernels:
                for position, language in enumerate(languages, 1):
                    execute(kernel, language, "warmup", warmup, position)
        for round_number in range(1, runs + 1):
            rotation = (round_number - 1) % len(languages)
            kernel_rotation = (round_number - 1) % len(kernels)
            for kernel in kernels[kernel_rotation:] + kernels[:kernel_rotation]:
                for position, language in enumerate(
                    languages[rotation:] + languages[:rotation], 1
                ):
                    execute(kernel, language, "measured", round_number, position)

        # Preserve only verified, fully executed variants. The same exact
        # binary and generated source bytes were used for the timed run.
        if retain_artifacts:
            out_dir.mkdir(parents=True, exist_ok=True)
            stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
            artifacts_dir = out_dir / f"{stamp}.cross-language.artifacts"
            artifacts_dir.mkdir()
            for kernel in kernels:
                for language in languages:
                    key = f"{kernel}:{language}"
                    basename = "kernel" if kernel == "recurrence" else kernel
                    ext = EXTENSIONS[language]
                    source = tmp / f"{basename}.{ext}"
                    retained_source = artifacts_dir / f"{kernel}-{language}.source.{ext}"
                    shutil.copy2(source, retained_source)
                    entry = {"source": retained_source.name,
                             "source_sha256": sha256(retained_source.read_bytes())}
                    if language != "python":
                        binary = artifacts_dir / f"{kernel}-{language}"
                        shutil.copy2(tmp / f"{kernel}-{language}", binary)
                        entry["binary"] = binary.name
                        entry["binary_sha256"] = sha256(binary.read_bytes())
                    metadata["retained_artifacts"][key] = entry
            metadata["artifacts_directory"] = str(artifacts_dir)

    out_dir.mkdir(parents=True, exist_ok=True)
    if not retain_artifacts:
        stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%S.%fZ")
    base = out_dir / f"{stamp}.cross-language"
    with base.with_suffix(".cross-language.raw.csv").open("x", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["kernel", "round", "position", "language", "elapsed_ns",
                         "exit_status", "stdout_sha256", "stderr_sha256"])
        writer.writerows(rows)
    with base.with_suffix(".cross-language.summary.csv").open("x", newline="") as handle:
        writer = csv.writer(handle)
        writer.writerow(["kernel", "language", "runs", "min_ns", "median_ns", "max_ns",
                         "mean_ns", "pstdev_ns"])
        for kernel in kernels:
            for language in languages:
                samples = [row[4] for row in rows if row[0] == kernel and row[3] == language]
                if len(samples) != runs:
                    raise RuntimeError(f"{kernel}:{language}: missing measured samples")
                writer.writerow([kernel, language, len(samples), min(samples),
                                 f"{statistics.median(samples):.1f}", max(samples),
                                 f"{statistics.mean(samples):.1f}",
                                 f"{statistics.pstdev(samples):.1f}"])
    with base.with_suffix(".cross-language.meta.json").open("x") as handle:
        json.dump(metadata, handle, indent=2)
        handle.write("\n")
    for kernel, value in expected.items():
        print(f"{kernel}: matched stdout for all {len(languages)} variants: {value.decode().strip()}")
    print(f"Measured {runs} interleaved runs per kernel/language (3 warmups each)")
    print(f"Raw:     {base.with_suffix('.cross-language.raw.csv')}")
    print(f"Summary: {base.with_suffix('.cross-language.summary.csv')}")
    print(f"Meta:    {base.with_suffix('.cross-language.meta.json')}")
    if artifacts_dir is not None:
        print(f"Artifacts: {artifacts_dir}")


if __name__ == "__main__":
    try:
        main()
    except (OSError, RuntimeError) as error:
        raise SystemExit(f"benchmark: {error}")
