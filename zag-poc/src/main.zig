// main.zig — Zag compiler CLI driver (Zig 0.14)
//
// Implements the same interface as zagc.py:
//   zagc check <file.zag>
//   zagc build <file.zag> [-o out] [--run] [--emit-c] [--target <target>]
//
// Pipeline: lex → parse → sema.checkTypes → sema.checkStores →
//           sema.checkCapabilities → codegen.gen → cc → (run)

const std = @import("std");

const lex_mod   = @import("lex.zig");
const parse_mod = @import("parse.zig");
const sema_mod  = @import("sema.zig");
// codegen.zig does not exist yet; we stub it below via a comptime shim.
// When codegen.zig is present alongside main.zig the stub is replaced.

// ── Target table ──────────────────────────────────────────────────────────────

const TargetInfo = struct {
    name:               []const u8,
    cc_flags:           []const []const u8,
    has_int128:         bool,
    has_sat_intrinsics: bool,
    cross_cc:           ?[]const u8,   // preferred cross-compiler prefix, or null
};

// Comptime-constant flag slices for each target
const flags_native:  []const []const u8 = &.{ "-O2" };
const flags_ppu32:   []const []const u8 = &.{ "-O2", "-march=rv64g" };
const flags_x86_64:  []const []const u8 = &.{ "-O2", "-march=x86-64-v2" };
const flags_arm64:   []const []const u8 = &.{ "-O2", "-march=armv8-a" };
const flags_riscv32: []const []const u8 = &.{ "-O2", "-march=rv32imac", "-mabi=ilp32" };
const flags_riscv64: []const []const u8 = &.{ "-O2", "-march=rv64imac", "-mabi=lp64" };
const flags_wasm:    []const []const u8 = &.{ "-O2", "-msimd128" };

const CPU_TARGETS = [_]TargetInfo{
    .{ .name = "native",  .cc_flags = flags_native,  .has_int128 = true,  .has_sat_intrinsics = false, .cross_cc = null },
    .{ .name = "ppu32",   .cc_flags = flags_ppu32,   .has_int128 = true,  .has_sat_intrinsics = false, .cross_cc = "riscv64-linux-gnu-gcc" },
    .{ .name = "x86_64",  .cc_flags = flags_x86_64,  .has_int128 = true,  .has_sat_intrinsics = true,  .cross_cc = null },
    .{ .name = "arm64",   .cc_flags = flags_arm64,   .has_int128 = true,  .has_sat_intrinsics = true,  .cross_cc = "aarch64-linux-gnu-gcc" },
    .{ .name = "riscv32", .cc_flags = flags_riscv32, .has_int128 = false, .has_sat_intrinsics = false, .cross_cc = "riscv64-linux-gnu-gcc" },
    .{ .name = "riscv64", .cc_flags = flags_riscv64, .has_int128 = true,  .has_sat_intrinsics = false, .cross_cc = "riscv64-linux-gnu-gcc" },
    .{ .name = "wasm",    .cc_flags = flags_wasm,    .has_int128 = false, .has_sat_intrinsics = false, .cross_cc = "emcc" },
};

fn lookupTarget(name: []const u8) *const TargetInfo {
    for (&CPU_TARGETS) |*t| {
        if (std.mem.eql(u8, t.name, name)) return t;
    }
    return &CPU_TARGETS[0]; // default: native
}

fn isGpuTarget(target: []const u8) bool {
    return std.mem.startsWith(u8, target, "gpu-") or std.mem.eql(u8, target, "gpu-auto");
}

// ── Codegen stub / real import ────────────────────────────────────────────────
// codegen.zig lives alongside this file.  If it does not exist yet the build
// will fail with a clear "file not found" rather than a cryptic message.
// We import it unconditionally; the stub below is just for documentation.

const codegen = @import("codegen.zig");

// ── Usage string ─────────────────────────────────────────────────────────────

const USAGE =
    \\zagc — Zag bootstrap compiler  (universal heterogeneous computing edition)
    \\usage:
    \\  zagc check <file.zag>
    \\  zagc build <file.zag> [-o out] [--run] [--emit-c] [--target <target>]
    \\
    \\cpu targets:
    \\  native      (default) host cpu
    \\  x86_64      x86-64 v2 — SSE2 sat ops
    \\  arm64       ARMv8-A — SQADD/UQADD sat ops
    \\  riscv32     RV32IMAC — 32-bit
    \\  riscv64     RV64IMAC — 64-bit
    \\  wasm        WebAssembly SIMD
    \\  ppu32       RISC-V PPU hardware posit
    \\
    \\gpu targets (MLIR backend):
    \\  gpu-nvidia  NVIDIA NVVM/CUDA → PTX
    \\  gpu-amd     AMD ROCDL/HIP → GCN ISA
    \\  gpu-vulkan  Vulkan SPIR-V
    \\  gpu-auto    auto-detect GPU vendor
    \\
;

// ── compile_file ──────────────────────────────────────────────────────────────

const CompileResult = struct {
    decls:  []parse_mod.Parser.NodeRefSlice,   // actually []ast.NodeRef
    sema:   sema_mod.Sema,
    report: sema_mod.Report,
};

// We avoid using ast.NodeRef directly in a named return-type alias; just use
// the concrete types from the modules.

const ast = @import("ast.zig");

/// Full front-end pipeline: lex → parse → sema.  Caller owns the returned
/// sema (call sema.deinit) and the token/AST memory lives in `alloc`.
fn compileFile(
    alloc:    std.mem.Allocator,
    path:     []const u8,
    src_dir:  []const u8,
    decls_out: *[]ast.NodeRef,
    sema_out:  *sema_mod.Sema,
    report_out: *sema_mod.Report,
) !void {
    // 1. Read source
    const src = try std.fs.cwd().readFileAlloc(alloc, path, 10 * 1024 * 1024);

    // 2. Lex
    const toks = try lex_mod.lex(alloc, src);

    // 3. Parse  (reset_imports = true for the root file)
    var parser = parse_mod.Parser.init(toks, alloc, src_dir);
    const decls = try parser.parse(true);

    // 4. Sema
    var s = try sema_mod.Sema.init(alloc, decls);
    try s.checkTypes();
    try s.checkStores();
    const report = try s.checkCapabilities();

    decls_out.*  = decls;
    sema_out.*   = s;
    report_out.* = report;
}

// ── printReport ──────────────────────────────────────────────────────────────

fn printReport(
    writer:   anytype,
    path:     []const u8,
    report:   sema_mod.Report,
    s:        *const sema_mod.Sema,
) void {
    writer.print("== effect/capability report for {s} ==\n", .{path}) catch {};

    if (report.violations.len == 0 and report.annotations.len == 0) {
        writer.print("  (no capability annotations to verify)\n", .{}) catch {};
        return;
    }

    // Print annotation-level results
    for (report.annotations) |a| {
        const mark: []const u8 = if (a.proven) "ok  " else "FAIL";
        writer.print("  {s}  {s} {s}\n", .{ mark, a.fn_name, a.annot }) catch {};
    }

    // Print violations
    for (report.violations) |v| {
        writer.print("  VIOLATED  {s} {s}\n", .{ v.fn_name, v.annot }) catch {};
        writer.print("    effects: ", .{}) catch {};
        for (v.effects, 0..) |e, i| {
            if (i > 0) writer.print(", ", .{}) catch {};
            writer.print("{s}", .{e}) catch {};
        }
        writer.print("\n", .{}) catch {};
        if (v.witness.len > 0) {
            writer.print("    witness: ", .{}) catch {};
            for (v.witness, 0..) |w, i| {
                if (i > 0) writer.print(" -> ", .{}) catch {};
                writer.print("{s}", .{w}) catch {};
            }
            writer.print("\n", .{}) catch {};
        }
    }

    // Note about prover availability (mirror Python behaviour)
    _ = s; // future: check s.proverAvailable() once that method exists
}

// ── cmd_check ─────────────────────────────────────────────────────────────────

fn cmdCheck(alloc: std.mem.Allocator, path: []const u8) u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    // Resolve src_dir
    const abs = std.fs.realpathAlloc(alloc, path) catch {
        stderr.print("{s}: error: file not found\n", .{path}) catch {};
        return 1;
    };
    const src_dir = std.fs.path.dirname(abs) orelse ".";

    var decls:  []ast.NodeRef    = undefined;
    var s:      sema_mod.Sema    = undefined;
    var report: sema_mod.Report  = undefined;

    compileFile(alloc, path, src_dir, &decls, &s, &report) catch |e| {
        stderr.print("{s}: error: {s}\n", .{ path, @errorName(e) }) catch {};
        return 1;
    };
    defer s.deinit();

    printReport(stdout, path, report, &s);

    if (s.errors.items.len > 0) {
        stdout.print("\nerrors:\n", .{}) catch {};
        for (s.errors.items) |msg| {
            stdout.print("  {s}: error: {s}\n", .{ path, msg }) catch {};
        }
        return 1;
    }

    stdout.print("\nOK — all capability claims proven, types check.\n", .{}) catch {};
    return 0;
}

// ── cmd_build_gpu ─────────────────────────────────────────────────────────────

fn cmdBuildGpu(
    alloc:  std.mem.Allocator,
    path:   []const u8,
    out:    ?[]const u8,
    target: []const u8,
) u8 {
    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();
    _ = out;

    const abs = std.fs.realpathAlloc(alloc, path) catch {
        stderr.print("{s}: error: file not found\n", .{path}) catch {};
        return 1;
    };
    const src_dir = std.fs.path.dirname(abs) orelse ".";

    var decls:  []ast.NodeRef   = undefined;
    var s:      sema_mod.Sema   = undefined;
    var report: sema_mod.Report = undefined;

    compileFile(alloc, path, src_dir, &decls, &s, &report) catch |e| {
        stderr.print("{s}: error: {s}\n", .{ path, @errorName(e) }) catch {};
        return 1;
    };
    defer s.deinit();

    printReport(stdout, path, report, &s);

    if (s.errors.items.len > 0) {
        stdout.print("\nbuild failed — capability/type errors:\n", .{}) catch {};
        for (s.errors.items) |msg| {
            stdout.print("  {s}: error: {s}\n", .{ path, msg }) catch {};
        }
        return 1;
    }

    // Resolve gpu-auto
    const resolved_target: []const u8 = blk: {
        if (std.mem.eql(u8, target, "gpu-auto")) {
            stdout.print("  [gpu] auto-detect not yet implemented in Zig driver; defaulting to nvidia\n", .{}) catch {};
            break :blk "nvidia";
        } else if (std.mem.startsWith(u8, target, "gpu-")) {
            break :blk target["gpu-".len..];
        } else {
            break :blk target;
        }
    };

    // Emit MLIR via codegen
    const mlir_text = codegen.genMlir(alloc, decls, &s, resolved_target) catch |e| {
        stderr.print("MLIR codegen error: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };

    // Derive output base path (stem of source file)
    const stem = stemOf(path);
    const mlir_path = std.fmt.allocPrint(alloc, "{s}.mlir", .{stem}) catch {
        stderr.print("OOM\n", .{}) catch {};
        return 1;
    };

    std.fs.cwd().writeFile(.{ .sub_path = mlir_path, .data = mlir_text }) catch |e| {
        stderr.print("could not write {s}: {s}\n", .{ mlir_path, @errorName(e) }) catch {};
        return 1;
    };
    stdout.print("  [gpu-{s}] wrote MLIR: {s}\n", .{ resolved_target, mlir_path }) catch {};
    stdout.print("  run: mlir-opt {s} | mlir-translate --mlir-to-llvmir | llc -march={s}\n",
        .{ mlir_path, resolved_target }) catch {};
    return 0;
}

// ── cmd_build ─────────────────────────────────────────────────────────────────

fn cmdBuild(
    alloc:    std.mem.Allocator,
    path:     []const u8,
    out:      ?[]const u8,
    run_bin:  bool,
    emit_c:   bool,
    target:   []const u8,
) u8 {
    // GPU targets take a separate MLIR path
    if (isGpuTarget(target)) {
        return cmdBuildGpu(alloc, path, out, target);
    }

    const stdout = std.io.getStdOut().writer();
    const stderr = std.io.getStdErr().writer();

    const abs = std.fs.realpathAlloc(alloc, path) catch {
        stderr.print("{s}: error: file not found\n", .{path}) catch {};
        return 1;
    };
    const src_dir = std.fs.path.dirname(abs) orelse ".";

    // ── 1-4: front-end pipeline ───────────────────────────────────────────────
    var decls:  []ast.NodeRef   = undefined;
    var s:      sema_mod.Sema   = undefined;
    var report: sema_mod.Report = undefined;

    compileFile(alloc, path, src_dir, &decls, &s, &report) catch |e| {
        stderr.print("{s}: error: {s}\n", .{ path, @errorName(e) }) catch {};
        return 1;
    };
    defer s.deinit();

    // ── 5: print report ───────────────────────────────────────────────────────
    printReport(stdout, path, report, &s);

    if (s.errors.items.len > 0) {
        stdout.print("\nbuild failed — capability/type errors:\n", .{}) catch {};
        for (s.errors.items) |msg| {
            stdout.print("  {s}: error: {s}\n", .{ path, msg }) catch {};
        }
        return 1;
    }

    // ── 6: codegen → C source ────────────────────────────────────────────────
    const c_src = codegen.gen(alloc, decls, &s, target) catch |e| {
        stderr.print("codegen error: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };

    // Derive paths
    const stem    = stemOf(path);
    const c_path  = std.fmt.allocPrint(alloc, "{s}.c", .{stem}) catch {
        stderr.print("OOM\n", .{}) catch {};
        return 1;
    };
    const bin_path: []const u8 = out orelse stem;

    // ── 7: write .c file ─────────────────────────────────────────────────────
    std.fs.cwd().writeFile(.{ .sub_path = c_path, .data = c_src }) catch |e| {
        stderr.print("could not write {s}: {s}\n", .{ c_path, @errorName(e) }) catch {};
        return 1;
    };

    if (emit_c) {
        if (std.mem.eql(u8, target, "ppu32")) {
            stdout.print("  [ppu32] hardware posit path — padd.s/psub.s/pmul.s/pdiv.s inline asm\n", .{}) catch {};
        }
        stdout.print("\nwrote {s}\n", .{c_path}) catch {};
        return 0;
    }

    // ── 8: invoke cc ────────────────────────────────────────────────────────
    const tinfo = lookupTarget(target);

    // Pick the C compiler
    const cc = pickCc(alloc, target, tinfo) orelse {
        stderr.print("no system cc/gcc found\n", .{}) catch {};
        return 1;
    };

    // Build argv: cc <c_path> -o <bin_path> -lm -w <cc_flags...>
    var argv = std.ArrayList([]const u8).init(alloc);
    defer argv.deinit();
    argv.append(cc)      catch return 1;
    argv.append(c_path)  catch return 1;
    argv.append("-o")    catch return 1;
    argv.append(bin_path) catch return 1;
    argv.append("-lm")   catch return 1;
    argv.append("-w")    catch return 1;
    for (tinfo.cc_flags) |f| argv.append(f) catch return 1;

    var cc_child = std.process.Child.init(argv.items, alloc);
    cc_child.stdout_behavior = .Inherit;
    cc_child.stderr_behavior = .Inherit;
    const cc_term = cc_child.spawnAndWait() catch |e| {
        stderr.print("failed to invoke cc: {s}\n", .{@errorName(e)}) catch {};
        return 1;
    };
    switch (cc_term) {
        .Exited => |code| {
            if (code != 0) {
                stderr.print("C backend failed (exit {d})\n", .{code}) catch {};
                return 1;
            }
        },
        else => {
            stderr.print("cc terminated abnormally\n", .{}) catch {};
            return 1;
        },
    }

    stdout.print("\nbuilt native binary: {s}\n", .{bin_path}) catch {};

    // ── 9: optionally run the binary ─────────────────────────────────────────
    if (run_bin) {
        stdout.print("-- running {s} --\n", .{bin_path}) catch {};
        // Prefix with "./" so the OS finds the local binary instead of searching PATH.
        const run_path = if (std.fs.path.isAbsolute(bin_path) or std.mem.startsWith(u8, bin_path, "./"))
            bin_path
        else
            std.fmt.allocPrint(alloc, "./{s}", .{bin_path}) catch bin_path;
        var run_child = std.process.Child.init(&.{run_path}, alloc);
        run_child.stdout_behavior = .Inherit;
        run_child.stderr_behavior = .Inherit;
        const run_term = run_child.spawnAndWait() catch |e| {
            stderr.print("failed to run {s}: {s}\n", .{ bin_path, @errorName(e) }) catch {};
            return 1;
        };
        const run_code: u8 = switch (run_term) {
            .Exited => |c| c,
            else    => 1,
        };
        stdout.print("-- exit {d} --\n", .{run_code}) catch {};
    }

    return 0;
}

// ── helpers ───────────────────────────────────────────────────────────────────

/// Return the file stem (everything before the last '.'), or the full name.
/// Returns the basename stem only (no directory component) — .c and binary
/// files are created in cwd, matching the Python driver's behaviour.
fn stemOf(path: []const u8) []const u8 {
    const base = std.fs.path.basename(path);
    if (std.mem.lastIndexOfScalar(u8, base, '.')) |dot| {
        return base[0..dot];
    }
    return base;
}

/// Locate a C compiler appropriate for `target`.  Returns an owned slice or a
/// comptime string literal; either is safe to pass to Child.init.
fn pickCc(alloc: std.mem.Allocator, target: []const u8, tinfo: *const TargetInfo) ?[]const u8 {
    _ = alloc;
    // For cross-compilation targets, try the preferred cross-cc first, then
    // fall back to the system cc.  We use std.process.which if available; on
    // Zig 0.14 we rely on the PATH search that Child.init performs, so we
    // just return the tool name and let exec fail with ENOENT if absent.
    if (std.mem.eql(u8, target, "wasm")) {
        // emcc preferred for WebAssembly
        return if (tinfo.cross_cc) |cc| cc else "cc";
    }
    if (tinfo.cross_cc) |cc| {
        // Return the cross-compiler name; the OS will search PATH.
        // Fall back: we always try; if it's not found the spawn will error.
        return cc;
    }
    return "cc";
}

// ── main ──────────────────────────────────────────────────────────────────────

pub fn main() u8 {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const stderr = std.io.getStdErr().writer();

    // Collect argv
    var args_it = std.process.argsWithAllocator(alloc) catch {
        stderr.print("OOM collecting args\n", .{}) catch {};
        return 2;
    };
    defer args_it.deinit();

    // Skip argv[0] (program name)
    _ = args_it.next();

    const cmd = args_it.next() orelse {
        std.io.getStdOut().writeAll(USAGE) catch {};
        return 2;
    };

    if (std.mem.eql(u8, cmd, "check")) {
        const path = args_it.next() orelse {
            stderr.print("usage: zagc check <file.zag>\n", .{}) catch {};
            return 2;
        };
        return cmdCheck(alloc, path);
    }

    if (std.mem.eql(u8, cmd, "build")) {
        const path = args_it.next() orelse {
            stderr.print("usage: zagc build <file.zag> [options]\n", .{}) catch {};
            return 2;
        };

        var out:    ?[]const u8 = null;
        var run_bin = false;
        var emit_c  = false;
        var target: []const u8 = "native";

        // Parse remaining flags
        while (args_it.next()) |arg| {
            if (std.mem.eql(u8, arg, "-o")) {
                out = args_it.next() orelse {
                    stderr.print("-o requires an argument\n", .{}) catch {};
                    return 2;
                };
            } else if (std.mem.eql(u8, arg, "--run")) {
                run_bin = true;
            } else if (std.mem.eql(u8, arg, "--emit-c")) {
                emit_c = true;
            } else if (std.mem.eql(u8, arg, "--target")) {
                target = args_it.next() orelse {
                    stderr.print("--target requires an argument\n", .{}) catch {};
                    return 2;
                };
            }
            // Unknown flags are silently ignored (same as Python driver)
        }

        return cmdBuild(alloc, path, out, run_bin, emit_c, target);
    }

    std.io.getStdOut().writeAll(USAGE) catch {};
    return 2;
}
