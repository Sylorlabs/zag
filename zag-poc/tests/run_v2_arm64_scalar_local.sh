#!/usr/bin/env bash
# Native observable parity for scalar-local assignment address elimination.
set -euo pipefail
cd "$(dirname "$0")/.."
if [ "$(uname -s):$(uname -m)" != Darwin:arm64 ]; then
  echo 'v2 ARM64 scalar local assignment: SKIP (macOS ARM64 required)'
  exit 0
fi
python3 - <<'PY'
import os
import pathlib
import subprocess
import tempfile

root = pathlib.Path.cwd()
znc = pathlib.Path(os.environ.get('ZNC', str(root / 'znc-macos-arm64'))).resolve()
baseline_arg = os.environ.get('SCALAR_BASELINE')
baseline = pathlib.Path(baseline_arg).resolve() if baseline_arg else None
if not znc.is_file() or (baseline and not baseline.is_file()):
    raise SystemExit('A required native compiler is missing')
cases = {
    'loop-carried-updates': ('fn main() i32 { let i:i32=0; let v:i32=3; while (i<10) { v=v+i; i=i+1; } return v; }', 48),
    'shadowed-local': ('fn main() i32 { let x:i32=1; if (1==1) { let x:i32=17; x=x+6; } x=x+41; return x; }', 42),
    'address-taken-local': ('fn main() i32 { unsafe { let x:i32=1; let p:*i32=&x; x=x+41; return p.*; } }', 42),
    'rhs-mutates-local': ('fn mutate(p:*i32) i32 { p.*=21; return p.* * 2; } fn main() i32 { unsafe { let x:i32=0; let p:*i32=&x; x=mutate(p); return x; } }', 42),
    'signed-scalar': ('fn main() i32 { let x:i64=0-50; let i:i64=0; while (i<9) { x=x+10; i=i+1; } return x as i32; }', 40),
}
flags = ('--target', 'macos-arm64', '--no-zagd', '--no-analyze', '--no-foreground-cache')
with tempfile.TemporaryDirectory(prefix='zag-v2-scalar-local-') as dirname:
    tmp = pathlib.Path(dirname)
    changes = 0
    for name, (source, expected) in cases.items():
        d = tmp / name
        d.mkdir()
        (d / 'main.zag').write_text(source + '\n')
        (d / 'zag.mod').write_text('name = "scalar"\nversion = "0"\nedition = "2027"\n')
        snapshots = []
        for label, compiler in (('optimized', znc), ('control', baseline)):
            if compiler is None:
                continue
            exe = d / label
            compile_result = subprocess.run([str(compiler), 'main.zag', *flags, '-o', str(exe)], cwd=d, text=True, capture_output=True, timeout=120)
            if compile_result.returncode:
                raise AssertionError(f'{name} {label} compilation failed:\n{compile_result.stdout}\n{compile_result.stderr}')
            result = subprocess.run([str(exe)], cwd=d, capture_output=True, timeout=10)
            if result.returncode != expected or result.stdout or result.stderr:
                raise AssertionError(f'{name} {label}: expected status {expected} and empty streams, got {result.returncode}, stdout={result.stdout!r}, stderr={result.stderr!r}')
            snapshots.append((result.returncode, result.stdout, result.stderr))
        if len(snapshots) == 2:
            if snapshots[0] != snapshots[1]:
                raise AssertionError(f'{name}: observable mismatch with unchanged compiler control')
            changes += (d / 'optimized').read_bytes() != (d / 'control').read_bytes()
        print(f'  ok {name}')
    print(f'v2 ARM64 scalar local assignment: PASS {len(cases)} cases, {changes} changed images against control')
    if baseline and not changes:
        raise AssertionError('No machine-code difference from the unchanged compiler control')
PY
