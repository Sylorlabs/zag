"""
gpu/lowering.py — MLIR pass pipeline driver.

Takes a .mlir file emitted by mlir_emitter.py and drives it through the
mlir-opt + mlir-translate chain to produce target-specific code.

Pipeline per target
───────────────────
  nvidia (CUDA/PTX):
    mlir-opt  → gpu-kernel-outlining         (separate gpu.func into gpu.module)
              → lower-affine                 (affine.for → scf.for)
              → convert-scf-to-cf            (structured → cf blocks)
              → convert-arith-to-llvm        (arith.* → llvm.*)
              → gpu-to-llvm                  (gpu.launch_func → runtime calls)
              → convert-gpu-to-nvvm          (gpu.func → nvvm.func with thread idx)
              → convert-func-to-llvm         (func.func → llvm.func)
              → reconcile-unrealized-casts   (clean up leftover cast ops)
    mlir-translate --mlir-to-llvmir          (MLIR LLVM dialect → LLVM IR text)
    llc -march=nvptx64 -mcpu=sm_86          (LLVM IR → PTX assembly)

  amd (HIP/AMDGPU):
    mlir-opt  → gpu-kernel-outlining
              → lower-affine
              → convert-scf-to-cf
              → convert-arith-to-llvm
              → gpu-to-llvm
              → convert-gpu-to-rocdl         (gpu.func → rocdl.func)
              → convert-func-to-llvm
              → reconcile-unrealized-casts
    mlir-translate --mlir-to-llvmir
    llc -march=amdgcn -mcpu=gfx90a          (→ GCN ISA for MI300X)

  vulkan (SPIR-V portability fallback):
    mlir-opt  → gpu-kernel-outlining
              → lower-affine
              → convert-scf-to-cf
              → convert-arith-to-spirv       (arith.* → spirv.*)
              → convert-gpu-to-spirv         (gpu.func → spirv.func)
              → serialize-spirv              (produce .spv binary)

Graceful degradation
────────────────────
If mlir-opt is not found, the .mlir file is still written to disk and a clear
install message is printed.  The emitted MLIR is valid; it can be processed
later once the toolchain is available.
"""

import os
import shutil
import subprocess
import tempfile

# ── pass pipelines ────────────────────────────────────────────────────────────

# Shared pre-lowering passes (normalize structured control flow and arithmetic)
_PRE_PASSES = [
    "lower-affine",
    "convert-scf-to-cf",
]

# Shared LLVM cleanup
_POST_LLVM_PASSES = [
    "convert-arith-to-llvm",
    "convert-func-to-llvm",
    "reconcile-unrealized-casts",
]

PIPELINES = {
    "nvidia": {
        "opt_passes": [
            "gpu-kernel-outlining",
            *_PRE_PASSES,
            "convert-gpu-to-nvvm{use-bare-ptr-memref-call-conv=true}",
            "gpu-to-llvm",
            *_POST_LLVM_PASSES,
        ],
        "translate_flag": "--mlir-to-llvmir",
        "llc_flags": ["-march=nvptx64", "-mcpu=sm_86", "-o"],
        "output_ext": ".ptx",
        "description": "NVIDIA PTX (sm_86 = Ampere A100/A6000; change -mcpu for Hopper H100/Blackwell B100)",
    },
    "amd": {
        "opt_passes": [
            "gpu-kernel-outlining",
            *_PRE_PASSES,
            "convert-gpu-to-rocdl{use-bare-ptr-memref-call-conv=true}",
            "gpu-to-llvm",
            *_POST_LLVM_PASSES,
        ],
        "translate_flag": "--mlir-to-llvmir",
        "llc_flags": ["-march=amdgcn", "-mcpu=gfx90a", "-o"],
        "output_ext": ".gcn",
        "description": "AMD GCN (gfx90a = MI300X; change -mcpu for RX 7900 XTX → gfx1100)",
    },
    "vulkan": {
        "opt_passes": [
            "gpu-kernel-outlining",
            *_PRE_PASSES,
            "convert-gpu-to-spirv",
            "serialize-spirv",
        ],
        "translate_flag": None,        # serialise-spirv writes binary directly
        "llc_flags": None,
        "output_ext": ".spv",
        "description": "Vulkan SPIR-V (portability fallback — runs on any Vulkan 1.3 device)",
    },
}

# ── tool discovery ────────────────────────────────────────────────────────────

def _find(name: str) -> str | None:
    env_key = name.upper().replace("-", "_")
    if os.environ.get(env_key):
        p = os.environ[env_key]
        if os.path.isfile(p) and os.access(p, os.X_OK):
            return p
    return shutil.which(name)


def _mlir_opt_path()       -> str | None: return _find("mlir-opt")
def _mlir_translate_path() -> str | None: return _find("mlir-translate")
def _llc_path()            -> str | None: return _find("llc")


# ── main entry point ──────────────────────────────────────────────────────────

def lower(mlir_text: str, target: str, out_base: str) -> int:
    """
    Drive the full lowering pipeline.

    mlir_text  — MLIR textual IR string from mlir_emitter.emit_module()
    target     — 'nvidia' | 'amd' | 'vulkan'
    out_base   — output file path WITHOUT extension (extensions added per stage)

    Returns 0 on success, nonzero on error.
    """
    if target not in PIPELINES:
        print(f"zagc gpu: unknown target '{target}'. Valid: {', '.join(PIPELINES)}")
        return 1

    pipe = PIPELINES[target]

    # Always write the .mlir file so it can be inspected or processed manually
    mlir_path = out_base + ".mlir"
    open(mlir_path, "w").write(mlir_text)
    print(f"  [gpu/{target}] wrote {mlir_path}")

    opt = _mlir_opt_path()
    if not opt:
        _print_install_hint(target)
        return 0   # not an error; .mlir is usable

    # ── stage 1: mlir-opt ────────────────────────────────────────────────
    passes = pipe["opt_passes"]
    # Build the --pass-pipeline string
    pipeline_str = ",".join(passes)
    opt_cmd = [opt, "--pass-pipeline", f"builtin.module({pipeline_str})",
               mlir_path, "-o", "-"]
    print(f"  [gpu/{target}] mlir-opt  {' '.join(opt_cmd[1:3])} ...")
    r = subprocess.run(opt_cmd, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"  mlir-opt failed:\n{r.stderr}")
        return r.returncode
    opt_ir = r.stdout

    # ── stage 2: mlir-translate (optional) ───────────────────────────────
    if pipe["translate_flag"]:
        xlt = _mlir_translate_path()
        if not xlt:
            llvmir_path = out_base + ".ll"
            open(llvmir_path, "w").write(opt_ir)
            print(f"  mlir-translate not found — wrote lowered MLIR to {llvmir_path}")
            print(f"  install: https://mlir.llvm.org/getting_started/")
            return 0
        xlt_cmd = [xlt, pipe["translate_flag"], "-"]
        r2 = subprocess.run(xlt_cmd, input=opt_ir, capture_output=True, text=True)
        if r2.returncode != 0:
            print(f"  mlir-translate failed:\n{r2.stderr}")
            return r2.returncode
        llvmir = r2.stdout
    else:
        # spirv serialise-spirv wrote binary bytes via stdout
        llvmir = opt_ir   # treat as binary content (will be written below)

    # ── stage 3: llc (NVIDIA / AMD only) ─────────────────────────────────
    ext = pipe["output_ext"]
    out_path = out_base + ext

    if pipe["llc_flags"] is not None:
        llc = _llc_path()
        if not llc:
            ll_path = out_base + ".ll"
            open(ll_path, "w").write(llvmir)
            print(f"  llc not found — wrote LLVM IR to {ll_path}")
            print(f"  install LLVM: https://releases.llvm.org/")
            return 0
        llc_cmd = [llc] + pipe["llc_flags"] + [out_path]
        r3 = subprocess.run(llc_cmd, input=llvmir, capture_output=True, text=True)
        if r3.returncode != 0:
            print(f"  llc failed:\n{r3.stderr}")
            return r3.returncode
    else:
        # SPIR-V: write binary from translate output
        open(out_path, "wb").write(llvmir.encode() if isinstance(llvmir, str) else llvmir)

    print(f"  [gpu/{target}] wrote {out_path}  ({pipe['description']})")
    return 0


# ── diagnostic helper ─────────────────────────────────────────────────────────

def _print_install_hint(target: str):
    print(f"""
  mlir-opt not found. The .mlir file above is valid and ready to process.

  Install options:
    # Ubuntu/Debian (LLVM 18+):
    apt install mlir-tools llvm-18

    # macOS (Homebrew):
    brew install llvm  # mlir-opt is in $(brew --prefix llvm)/bin/

    # From source (full MLIR build):
    https://mlir.llvm.org/getting_started/

    # Then to lower manually ({target}):""")
    pipe = PIPELINES.get(target, {})
    passes = " ".join(f"--{p}" for p in pipe.get("opt_passes", []))
    print(f"    mlir-opt {passes} <input.mlir> -o lowered.mlir")
    if pipe.get("translate_flag"):
        print(f"    mlir-translate {pipe['translate_flag']} lowered.mlir -o output.ll")
    llc_flags = pipe.get("llc_flags")
    if llc_flags:
        print(f"    llc {' '.join(llc_flags)} output.ll -o output{pipe.get('output_ext','')}")
    print()


# ── auto-detect target ────────────────────────────────────────────────────────

def detect_target() -> str:
    """Best-effort: return 'nvidia', 'amd', or 'vulkan' based on installed drivers."""
    if shutil.which("nvidia-smi"):
        return "nvidia"
    if shutil.which("rocm-smi") or shutil.which("rocminfo"):
        return "amd"
    # Vulkan: check for libvulkan or vulkaninfo
    if shutil.which("vulkaninfo") or os.path.exists("/usr/lib/x86_64-linux-gnu/libvulkan.so.1"):
        return "vulkan"
    # Fall back to nvidia (most common for AI workloads)
    return "nvidia"
