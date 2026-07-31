#!/usr/bin/env bash
# Metal compat runtime test — run on macOS (Apple Silicon or Intel).
#
# This script verifies that the MSL source emitted by znc --target metal-compat
# compiles with the Metal compiler and produces correct output when run on a
# physical GPU via the Metal framework.
#
# Requirements:
#   - macOS 13+ (for Metal 3 / thread_position_in_grid)
#   - Xcode Command Line Tools (xcrun, metal, metallib)
#   - Swift 5.9+ (for the test harness)
#
# Usage:
#   cd .
#   bash tests/run_metal_mac.sh
#
# If znc is not built on this machine, build it first:
#   # On macOS, znc may need to be cross-compiled or built from the Linux host.
#   # If you only have the .metal output, use --skip-emit to test compilation only:
#   bash tests/run_metal_mac.sh --skip-emit /path/to/fill.metal
set -euo pipefail

cd "$(dirname "$0")/.."
ZNC=${ZNC:-./znc}
case "$ZNC" in /*) ;; *) ZNC="$PWD/${ZNC#./}";; esac
tmp=$(mktemp -d /tmp/zag-metal-mac.XXXXXX)
trap 'rm -rf "$tmp"' EXIT
pass=0
fail=0

ok() { echo "  ok  $1"; pass=$((pass + 1)); }
xx() { echo "  XX  $1"; fail=$((fail + 1)); }

# Check if we're on macOS
if [ "$(uname)" != "Darwin" ]; then
    echo "This script must be run on macOS. Current OS: $(uname)"
    exit 1
fi

# Check for Metal compiler
if ! command -v xcrun >/dev/null 2>&1; then
    echo "xcrun not found. Install Xcode Command Line Tools: xcode-select --install"
    exit 1
fi

# ── 1. Emit MSL source from the fill kernel ─────────────────────────────────
skip_emit=false
provided_msl=""
if [ "${1:-}" = "--skip-emit" ] && [ -n "${2:-}" ]; then
    skip_emit=true
    provided_msl="$2"
fi

if [ "$skip_emit" = "true" ]; then
    cp "$provided_msl" "$tmp/fill.metal"
    ok "Using provided MSL source: $provided_msl"
elif [ -x "$ZNC" ]; then
    cat >"$tmp/fill.zag" <<'ZAG'
fn fillKernel(out: []i32, value: i32, count: i32) void @kernel {
    let i: i32 = @gpuBlockIdx(0) * @gpuBlockDim(0) + @gpuThreadIdx(0);
    if (i < count) { out[i] = value; }
}
fn main() void { print_i32(0); }
ZAG
    if "$ZNC" "$tmp/fill.zag" --target metal-compat -o "$tmp/fill.metal" >/dev/null 2>&1; then
        ok "znc emits MSL source for the fill kernel"
    else
        xx "znc failed to emit MSL source"
        exit 1
    fi
else
    echo "znc not found at $ZNC and no --skip-emit provided"
    exit 1
fi

# ── 2. Verify MSL source structure ──────────────────────────────────────────
if grep -q 'kernel void fillKernel' "$tmp/fill.metal"; then
    ok "MSL declares kernel function fillKernel"
else
    xx "MSL missing kernel function declaration"
fi

if grep -q 'thread_position_in_grid' "$tmp/fill.metal"; then
    ok "MSL uses thread_position_in_grid for global ID"
else
    xx "MSL missing thread_position_in_grid"
fi

if grep -q 'device int\*' "$tmp/fill.metal"; then
    ok "MSL uses device address space for output buffer"
else
    xx "MSL missing device address space qualifier"
fi

# ── 3. Compile MSL to metallib ──────────────────────────────────────────────
if xcrun -sdk macosx metal -c "$tmp/fill.metal" -o "$tmp/fill.air" 2>"$tmp/metal_err.txt"; then
    ok "MSL compiles with metal compiler (macosx SDK)"
else
    xx "MSL compilation failed"
    cat "$tmp/metal_err.txt"
    exit 1
fi

if xcrun -sdk macosx metallib "$tmp/fill.air" -o "$tmp/fill.metallib" 2>"$tmp/metallib_err.txt"; then
    ok "metallib produced from compiled AIR"
else
    xx "metallib production failed"
    cat "$tmp/metallib_err.txt"
    exit 1
fi

# ── 4. Run the kernel on the GPU via a Swift harness ────────────────────────
cat >"$tmp/harness.swift" <<'SWIFT'
import Foundation
import Metal

// Load the metallib.
let metallibURL = URL(fileURLWithPath: CommandLine.arguments[1])
let device = MTLCreateSystemDefaultDevice()!
let library = try device.makeLibrary(URL: metallibURL)
let function = library.makeFunction(name: "fillKernel")!

// Create compute pipeline state.
let pipeline = try device.makeComputePipelineState(function: function)

// Create output buffer: 1024 ints, initialized to 0.
let count = 1024
let value = 42
let bufferSize = count * MemoryLayout<Int32>.size
let buffer = device.makeBuffer(length: bufferSize, options: .storageModeShared)!

// Create command queue and buffer.
let queue = device.makeCommandQueue()!
let cmdBuffer = queue.makeCommandBuffer()!
let encoder = cmdBuffer.makeComputeCommandEncoder()!

// Set pipeline and arguments.
encoder.setComputePipelineState(pipeline)
encoder.setBuffer(buffer, offset: 0, index: 0)

// Pack value and count as Int32 arguments.
var valueArg: Int32 = Int32(value)
var countArg: Int32 = Int32(count)
encoder.setBytes(&valueArg, length: 4, index: 1)
encoder.setBytes(&countArg, length: 4, index: 2)

// Dispatch with 1 thread per group, count groups (1D).
let threadsPerGroup = MTLSize(width: 1, height: 1, depth: 1)
let threadGroups = MTLSize(width: count, height: 1, depth: 1)
encoder.dispatchThreadgroups(threadGroups, threadsPerThreadgroup: threadsPerGroup)
encoder.endEncoding()
cmdBuffer.commit()
cmdBuffer.waitUntilCompleted()

// Read back results.
let ptr = buffer.contents().bindMemory(to: Int32.self, capacity: count)
var allCorrect = true
for i in 0..<count {
    if ptr[i] != Int32(value) {
        print("  MISMATCH at index \(i): expected \(value), got \(ptr[i])")
        allCorrect = false
        break
    }
}

if allCorrect {
    print("  METAL_RUNTIME_OK: all \(count) elements filled with \(value)")
    exit(0)
} else {
    print("  METAL_RUNTIME_FAIL: output verification failed")
    exit(1)
}
SWIFT

if swift "$tmp/harness.swift" "$tmp/fill.metallib" >"$tmp/swift_out.txt" 2>&1; then
    ok "Metal kernel runs on GPU and produces correct output"
    cat "$tmp/swift_out.txt" | head -1
else
    xx "Metal kernel runtime test failed"
    cat "$tmp/swift_out.txt"
fi

# ── 5. Determinism check ────────────────────────────────────────────────────
if [ "$skip_emit" = "false" ] && [ -x "$ZNC" ]; then
    "$ZNC" "$tmp/fill.zag" --target metal-compat -o "$tmp/fill2.metal" >/dev/null 2>&1
    if cmp -s "$tmp/fill.metal" "$tmp/fill2.metal"; then
        ok "MSL emission is deterministic"
    else
        xx "MSL emission is not deterministic"
    fi
fi

echo "════ metal-mac pass=$pass fail=$fail ════"
[ "$fail" -eq 0 ]
