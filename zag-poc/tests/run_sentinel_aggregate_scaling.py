#!/usr/bin/env python3
"""Bounded native Zag compilation witness for deep aggregate provenance.

The project under test is Zag; Python only generates inputs, invokes the
native compiler, and records process outcomes. Never replace a timeout with
a passing result or use this exploratory benchmark as a release qualification.
"""

import argparse
import hashlib
import json
import os
import platform
import signal
import subprocess
import tempfile
import time
from pathlib import Path


def witness(depth: int, mode: str) -> str:
    types = ["struct Node { value:i32 }", f"struct Nest{depth} {{ ptr:*mut Node }}"]
    types += [f"struct Nest{i} {{ next:Nest{i+1} }}" for i in reversed(range(depth))]
    literal = f"Nest{depth}{{.ptr={'p' if mode in ('full', 'owner') else 'null as *mut Node'}}}"
    for i in reversed(range(depth)):
        literal = f"Nest{i}{{.next={literal}}}"
    path = "next." * depth + "ptr"
    if mode == "types":
        return "\n".join([*types, "fn main() i32 { return 0; }", ""])
    prologue = "let p:*mut Node=new(Node{.value=1}) as *mut Node; " if mode in ("full", "owner") else ""
    check = f"value.{path}=null as *mut Node; inspect(value); " if mode in ("full", "clear") else ""
    epilogue = "delete(p); " if mode in ("full", "owner") else ""
    return "\n".join(
        [
            *types,
            "fn inspect(value:Nest0) void @borrows { }",
            "fn main() i32 { unsafe { "
            f"{prologue}let value:Nest0={literal}; {check}{epilogue}"
            "} return 0; }",
            "",
        ]
    )


def trial(compiler: Path, depth: int, mode: str, timeout: float, base: Path) -> dict:
    project = base / f"{mode}-depth-{depth:02d}"
    project.mkdir()
    (project / "zag.mod").write_text('name = "sentinel-depth"\nversion = "0"\nedition = "2027"\n')
    source = witness(depth, mode)
    (project / "main.zag").write_text(source)
    cmd = [str(compiler), "check", "main.zag", "--no-zagd", "--no-analyze"]
    start = time.monotonic()
    process = subprocess.Popen(
        cmd,
        cwd=project,
        stdout=subprocess.PIPE,
        stderr=subprocess.PIPE,
        start_new_session=True,
    )
    timed_out = False
    try:
        out, err = process.communicate(timeout=timeout)
    except subprocess.TimeoutExpired:
        timed_out = True
        os.killpg(process.pid, signal.SIGTERM)
        try:
            out, err = process.communicate(timeout=2)
        except subprocess.TimeoutExpired:
            os.killpg(process.pid, signal.SIGKILL)
            out, err = process.communicate()
    elapsed = round(time.monotonic() - start, 3)
    (project / "stdout").write_bytes(out)
    (project / "stderr").write_bytes(err)
    return {
        "mode": mode,
        "depth": depth,
        "elapsed_seconds": elapsed,
        "timed_out": timed_out,
        "returncode": process.returncode,
        "pass": not timed_out and process.returncode == 0,
        "fixture_sha256": hashlib.sha256(source.encode()).hexdigest(),
        "stderr_sha256": hashlib.sha256(err).hexdigest(),
        "stderr_first_lines": err.decode(errors="replace").splitlines()[:3],
    }


def main() -> None:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("compiler", type=Path)
    parser.add_argument("--depths", default="4,8,12,16,20,24,32")
    parser.add_argument("--modes", default="full", help="Comma separated: types,literal,owner,clear,full")
    parser.add_argument("--timeout", type=float, default=15)
    parser.add_argument("--output", type=Path)
    args = parser.parse_args()
    compiler = args.compiler.resolve(strict=True)
    result = {
        "compiler_sha256": hashlib.sha256(compiler.read_bytes()).hexdigest(),
        "target": platform.machine(),
        "system": platform.system(),
        "bounded_timeout_seconds": args.timeout,
        "samples": [],
    }
    with tempfile.TemporaryDirectory(prefix="sentinel-zag-aggregate-") as temp:
        for mode in args.modes.split(","):
            if mode not in ("types", "literal", "owner", "clear", "full"):
                raise SystemExit(f"invalid mode: {mode}")
            for depth in (int(n) for n in args.depths.split(",")):
                sample = trial(compiler, depth, mode, args.timeout, Path(temp))
                result["samples"].append(sample)
                print(json.dumps(sample, sort_keys=True), flush=True)
    if args.output:
        args.output.write_text(json.dumps(result, indent=2, sort_keys=True) + "\n")


if __name__ == "__main__":
    main()
