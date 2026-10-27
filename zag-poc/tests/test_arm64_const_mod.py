#!/usr/bin/env python3
"""Native signed/unsigned remainder parity for AArch64 constant divisors.

Requires a compatible native compiler in ZNC; run on an ARM64 host. Builds
and executes one program so the optimized instruction sequence is exercised
with values loaded from named variables, including INT64_MIN.
"""

import os
import pathlib
import subprocess
import tempfile


ROOT = pathlib.Path(__file__).resolve().parents[1]
DIVISORS = (-1_000_000_007, -65_521, -3, 2, 3, 4, 5, 7, 65_521,
            1_000_000_007, 2_147_483_647, 2_147_483_648)
SIGNED = (
    -(2**63), -(2**63) + 1, -10_000_000_000, -65_522,
    -1, 0, 1, 2, 3, 65_520, 65_521, 65_522,
    1_000_000_007, 10_000_000_000, 2**63 - 1,
)
UNSIGNED = (0, 1, 3, 65521, 1_000_000_007, 2**63 - 1)


def expected_signed(n: int, d: int) -> int:
    r = abs(n) % abs(d)
    return -r if n < 0 else r


def source_number(n: int) -> str:
    if n == -(2**63):
        return "0 - 9223372036854775807 - 1"
    if n < 0:
        return f"0 - {abs(n)}"
    return str(n)


def main() -> None:
    compiler = os.environ.get("ZNC")
    if not compiler:
        raise SystemExit("Set ZNC to a native arm64 compiler binary")
    compiler = str(pathlib.Path(compiler).resolve())
    rows = []
    expected = []
    for typ, samples in (("i64", SIGNED), ("u64", UNSIGNED)):
        for n in samples:
            rows.append(f"let n{len(expected)}: {typ} = {source_number(n)};")
            for d in DIVISORS:
                if typ == "u64" and d < 0:
                    continue
                rows.append(f"println(n{len(expected)} % {d});")
            expected.append((typ, n))
    witness = []
    for typ, n in expected:
        for d in DIVISORS:
            if typ == "u64" and d < 0:
                continue
            witness.append(str(expected_signed(n, d) if typ == "i64" else n % d))
    with tempfile.TemporaryDirectory(prefix="zag-const-mod-") as tmp:
        src = pathlib.Path(tmp, "mod.zag")
        exe = pathlib.Path(tmp, "mod")
        src.write_text("script;\n" + "\n".join(rows) + "\nreturn 0;\n")
        build = subprocess.run(
            [compiler, str(src), "-o", str(exe), "--no-zagd", "--no-analyze", "--no-foreground-cache"],
            cwd=ROOT, text=True, capture_output=True,
        )
        if build.returncode:
            raise AssertionError(f"Compiler failed ({build.returncode}): {build.stderr}\n{build.stdout}")
        run = subprocess.run([str(exe)], cwd=ROOT, text=True, capture_output=True)
        if run.returncode or run.stderr:
            raise AssertionError(f"Program failed ({run.returncode}): {run.stderr}")
        actual = run.stdout.splitlines()
        if actual != witness:
            for i, (want, got) in enumerate(zip(witness, actual)):
                if want != got:
                    raise AssertionError(f"Mismatch at case {i}: expected {want}, got {got}")
            raise AssertionError(f"Wrong line count: {len(actual)} vs {len(witness)}")
        # Zero remains a checked runtime error for literal divisors.
        panic_src = pathlib.Path(tmp, "zero.zag")
        panic_exe = pathlib.Path(tmp, "zero")
        panic_src.write_text("script;\nlet x: i64 = 42;\nprintln(x % 0);\nreturn 0;\n")
        panic_build = subprocess.run(
            [compiler, str(panic_src), "-o", str(panic_exe), "--no-zagd", "--no-analyze", "--no-foreground-cache"],
            cwd=ROOT, text=True, capture_output=True,
        )
        if panic_build.returncode:
            raise AssertionError(f"Zero-divisor fixture failed to build: {panic_build.stderr}")
        panic = subprocess.run([str(panic_exe)], cwd=ROOT, text=True, capture_output=True)
        if panic.returncode != 134 or "division by zero" not in panic.stderr:
            raise AssertionError(f"Zero-divisor panic regression: {panic.returncode}: {panic.stderr}")
        print(f"AArch64 constant remainder parity: PASS ({len(witness)} cases)")


if __name__ == "__main__":
    main()
