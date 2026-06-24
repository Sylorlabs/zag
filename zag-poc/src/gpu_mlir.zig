// gpu_mlir.zig — Zag → MLIR textual IR emitter (Zig port of gpu/mlir_emitter.py)
//
// Walks a type-annotated Zag AST (output of Sema) and emits a complete,
// self-contained MLIR module that mlir-opt can lower to a target-specific
// representation. Faithful port of the Python reference emitter:
//
//   - SSA value counter with type-prefixed fresh names (%c1, %b2, %slot5, …)
//   - scope map  name → { mlir_val, is_alloca, zag_ty }
//   - mutated-variable detection: reassigned locals become memref.alloca slots
//     bridged with memref.load / memref.store
//   - kernel (gpu.func … kernel) vs host (func.func) split
//   - statement emission (let/assign/return/if/while/switch/exprstmt)
//   - expression emission (lit/var/bin/un/index/field/structlit/call)
//   - GPU intrinsics (@gpuThreadIdx → gpu.thread_id, etc.)
//   - posit / lns / mx_fp8 / vsa op routing
//   - per-target header (nvidia / amd / vulkan)
//
// Custom type encoding (see zagToMlir):
//   p32     → carried as i32; arithmetic routed to @zag_p32_{add,sub,mul,div}
//   l32     → carried as i32; arithmetic routed to @zag_l32_{add,sub,mul,div}
//   mx_fp8  → carried as f8E4M3FN (native MLIR type)
//   vsa_b<N>→ carried as vector<Nxi1>; bind = XOR, bundle = OR
//   bf16    → native bf16
//   quire   → memref<8xi64>

const std = @import("std");
const ast = @import("ast.zig");
const sema_mod = @import("sema.zig");

// ── type predicates (mirror gpu/mlir_emitter.py helpers) ──────────────────────

fn isPosit(ty: []const u8) bool {
    return eq(ty, "p8") or eq(ty, "p16") or eq(ty, "p32") or eq(ty, "p64");
}
fn isLns(ty: []const u8) bool {
    return eq(ty, "l16") or eq(ty, "l32");
}
fn isFloat(ty: []const u8) bool {
    return eq(ty, "f32") or eq(ty, "f64") or eq(ty, "bf16") or
        eq(ty, "mx_fp8") or eq(ty, "mx_fp4") or eq(ty, "float_lit");
}
fn eq(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
fn startsWith(s: []const u8, p: []const u8) bool {
    return std.mem.startsWith(u8, s, p);
}

fn isVsaType(ty: []const u8) bool {
    return startsWith(ty, "vsa_b<") and std.mem.endsWith(u8, ty, ">");
}
fn vsaDim(ty: []const u8) []const u8 {
    // 'vsa_b<10000>' -> '10000'
    return ty["vsa_b<".len .. ty.len - 1];
}
fn isGpuBuf(ty: []const u8) bool {
    return startsWith(ty, "gpu_buf<") and std.mem.endsWith(u8, ty, ">");
}
fn gpuBufElem(ty: []const u8) []const u8 {
    return ty["gpu_buf<".len .. ty.len - 1];
}

// ── Zag → MLIR type mapping (mirror gpu/types.py zag_to_mlir) ──────────────────

fn zagToMlir(alloc: std.mem.Allocator, ty: []const u8) ![]const u8 {
    const base = .{
        .{ "void", "" },
        .{ "bool", "i1" },
        .{ "i8", "i8" },   .{ "i16", "i16" },  .{ "i32", "i32" },  .{ "i64", "i64" },
        .{ "u8", "i8" },   .{ "u16", "i16" },  .{ "u32", "i32" },  .{ "u64", "i64" },
        .{ "usize", "index" },
        .{ "f32", "f32" }, .{ "f64", "f64" },
        .{ "bf16", "bf16" },
        .{ "p8", "i8" },   .{ "p16", "i16" },  .{ "p32", "i32" },  .{ "p64", "i64" },
        .{ "l16", "i16" }, .{ "l32", "i32" },
        .{ "mx_fp8", "f8E4M3FN" },
        .{ "mx_fp4", "f4E2M1FN" },
        .{ "quire", "memref<8xi64>" },
    };
    inline for (base) |pair| {
        if (eq(ty, pair[0])) return pair[1];
    }
    if (startsWith(ty, "[]")) {
        const elem = try zagToMlir(alloc, ty[2..]);
        return std.fmt.allocPrint(alloc, "memref<?x{s}>", .{elem});
    }
    if (isVsaType(ty)) {
        return std.fmt.allocPrint(alloc, "vector<{s}xi1>", .{vsaDim(ty)});
    }
    if (isGpuBuf(ty)) {
        const elem = try zagToMlir(alloc, gpuBufElem(ty));
        return std.fmt.allocPrint(alloc, "memref<?x{s}, 1>", .{elem});
    }
    // struct / enum / union names: lower to an llvm struct passthrough
    const mangled = try mangle(alloc, ty);
    return std.fmt.allocPrint(alloc, "!llvm.struct<{s}>", .{mangled});
}

// Mangle a type/symbol name: [ ] , @ stripped/replaced (mirror _mangle / zag_to_mlir)
fn mangle(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    for (name) |c| {
        switch (c) {
            '[' => try buf.append('_'),
            ']' => {},
            ',' => try buf.append('_'),
            '@' => {},
            else => try buf.append(c),
        }
    }
    return buf.toOwnedSlice();
}

// ── arithmetic op name helpers ────────────────────────────────────────────────

fn floatArith(op: []const u8) []const u8 {
    if (eq(op, "+")) return "addf";
    if (eq(op, "-")) return "subf";
    if (eq(op, "*")) return "mulf";
    if (eq(op, "/")) return "divf";
    return "addf";
}
fn cmpPredF(op: []const u8) []const u8 {
    if (eq(op, "==")) return "oeq";
    if (eq(op, "!=")) return "one";
    if (eq(op, "<")) return "olt";
    if (eq(op, ">")) return "ogt";
    if (eq(op, "<=")) return "ole";
    if (eq(op, ">=")) return "oge";
    return "oeq";
}
fn cmpPredI(op: []const u8) []const u8 {
    if (eq(op, "==")) return "eq";
    if (eq(op, "!=")) return "ne";
    if (eq(op, "<")) return "slt";
    if (eq(op, ">")) return "sgt";
    if (eq(op, "<=")) return "sle";
    if (eq(op, ">=")) return "sge";
    return "eq";
}

const POSIT_OPS = [_]struct { op: []const u8, sym: []const u8 }{
    .{ .op = "+", .sym = "zag_p32_add" },
    .{ .op = "-", .sym = "zag_p32_sub" },
    .{ .op = "*", .sym = "zag_p32_mul" },
    .{ .op = "/", .sym = "zag_p32_div" },
};
const LNS_OPS = [_]struct { op: []const u8, sym: []const u8 }{
    .{ .op = "*", .sym = "zag_l32_mul" },
    .{ .op = "/", .sym = "zag_l32_div" },
    .{ .op = "+", .sym = "zag_l32_add" },
    .{ .op = "-", .sym = "zag_l32_sub" },
};

fn positOp(op: []const u8) ?[]const u8 {
    for (POSIT_OPS) |e| if (eq(e.op, op)) return e.sym;
    return null;
}
fn lnsOp(op: []const u8) ?[]const u8 {
    for (LNS_OPS) |e| if (eq(e.op, op)) return e.sym;
    return null;
}

// GPU dimension names {0:x, 1:y, 2:z}
fn gpuDimName(lit: ?[]const u8) []const u8 {
    if (lit) |l| {
        if (eq(l, "0")) return "x";
        if (eq(l, "1")) return "y";
        if (eq(l, "2")) return "z";
    }
    return "x";
}

// ── scope entry ───────────────────────────────────────────────────────────────

const Scope = std.StringHashMap(ScopeEntry);
const ScopeEntry = struct {
    val: []const u8,
    is_alloca: bool,
    zty: []const u8,
};

fn cloneScope(alloc: std.mem.Allocator, src: *const Scope) !Scope {
    var dst = Scope.init(alloc);
    var it = src.iterator();
    while (it.next()) |kv| try dst.put(kv.key_ptr.*, kv.value_ptr.*);
    return dst;
}

// ── emitter ───────────────────────────────────────────────────────────────────

const Emitter = struct {
    alloc: std.mem.Allocator,
    sema: *const sema_mod.Sema,
    decls: []ast.NodeRef,
    target: []const u8,
    ctr: usize = 0,
    indent: usize = 0,
    lines: std.ArrayList([]const u8),
    types_used: std.StringHashMap(void),

    fn init(alloc: std.mem.Allocator, decls: []ast.NodeRef, s: *const sema_mod.Sema, target: []const u8) Emitter {
        return .{
            .alloc = alloc,
            .sema = s,
            .decls = decls,
            .target = target,
            .lines = std.ArrayList([]const u8).init(alloc),
            .types_used = std.StringHashMap(void).init(alloc),
        };
    }

    // ── output helpers ────────────────────────────────────────────────────────

    fn out(self: *Emitter, line: []const u8) !void {
        const pad = try self.alloc.alloc(u8, self.indent * 2);
        @memset(pad, ' ');
        const full = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ pad, line });
        try self.lines.append(full);
    }

    fn outf(self: *Emitter, comptime fmt: []const u8, args: anytype) !void {
        const line = try std.fmt.allocPrint(self.alloc, fmt, args);
        try self.out(line);
    }

    fn fresh(self: *Emitter, prefix: []const u8) ![]const u8 {
        self.ctr += 1;
        return std.fmt.allocPrint(self.alloc, "%{s}{d}", .{ prefix, self.ctr });
    }

    fn mtype(self: *Emitter, zag_ty: []const u8) ![]const u8 {
        return zagToMlir(self.alloc, zag_ty);
    }

    // ── public entry ──────────────────────────────────────────────────────────

    fn emitModule(self: *Emitter) ![]const u8 {
        try self.collectTypes();
        try self.emitHeader();
        try self.out("module attributes {gpu.container_module} {");
        self.indent += 1;

        // Runtime helper declarations (posit, lns, etc.)
        try self.emitRuntimeDecls();

        // Separate kernels from host fns, in source (decls) order.
        var kernels = std.ArrayList(*ast.FnDecl).init(self.alloc);
        var host_fns = std.ArrayList(*ast.FnDecl).init(self.alloc);
        for (self.decls) |n| {
            if (n.* != .fn_decl) continue;
            const f = &n.*.fn_decl;
            if (f.is_extern) continue;
            if (hasAnnot(f, "@kernel") or hasAnnot(f, "@device")) {
                try kernels.append(f);
            } else {
                try host_fns.append(f);
            }
        }

        if (kernels.items.len > 0) {
            try self.out("gpu.module @zag_kernels {");
            self.indent += 1;
            for (kernels.items) |f| try self.emitKernelFn(f);
            self.indent -= 1;
            try self.out("} // gpu.module @zag_kernels");
            try self.out("");
        }

        for (host_fns.items) |f| try self.emitHostFn(f);

        self.indent -= 1;
        try self.out("} // module");

        // Join lines with "\n" and append trailing newline.
        var total: usize = 0;
        for (self.lines.items) |l| total += l.len + 1;
        var buf = try self.alloc.alloc(u8, total);
        var i: usize = 0;
        for (self.lines.items) |l| {
            @memcpy(buf[i .. i + l.len], l);
            i += l.len;
            buf[i] = '\n';
            i += 1;
        }
        return buf;
    }

    fn collectTypes(self: *Emitter) !void {
        var it = self.sema.fns.valueIterator();
        while (it.next()) |np| {
            const f = &np.*.*.fn_decl;
            for (f.params) |p| try self.types_used.put(p.pty, {});
            try self.types_used.put(f.ret, {});
        }
    }

    fn typeUsed(self: *Emitter, names: []const []const u8) bool {
        for (names) |t| if (self.types_used.contains(t)) return true;
        return false;
    }

    fn emitRuntimeDecls(self: *Emitter) !void {
        if (self.typeUsed(&.{ "p8", "p16", "p32", "p64" })) {
            for (POSIT_OPS) |e| {
                try self.outf("func.func private @{s}(i32, i32) -> i32", .{e.sym});
            }
            try self.out("func.func private @zag_p32_to_f64(i32) -> f64");
            try self.out("func.func private @zag_f64_to_p32(f64) -> i32");
        }
        if (self.typeUsed(&.{ "l16", "l32" })) {
            for (LNS_OPS) |e| {
                try self.outf("func.func private @{s}(i32, i32) -> i32", .{e.sym});
            }
            try self.out("func.func private @zag_l32_to_f32(i32) -> f32");
            try self.out("func.func private @zag_f32_to_l32(f32) -> i32");
        }
    }

    // ── function emission ─────────────────────────────────────────────────────

    fn emitHostFn(self: *Emitter, f: *ast.FnDecl) !void {
        const ret_ty = try self.mtype(f.ret);
        const ret_part = if (ret_ty.len > 0)
            try std.fmt.allocPrint(self.alloc, " -> {s}", .{ret_ty})
        else
            "";
        const params = try self.paramList(f.params);

        // Attributes: carry capability annotations for documentation.
        var attrs: []const u8 = "";
        if (f.annots.len > 0) {
            var ann = std.ArrayList(u8).init(self.alloc);
            for (f.annots, 0..) |a, i| {
                if (i > 0) try ann.appendSlice(", ");
                try ann.writer().print("\"{s}\"", .{a});
            }
            attrs = try std.fmt.allocPrint(self.alloc, " attributes {{zag.caps = [{s}]}}", .{ann.items});
        }

        const mn = try mangle(self.alloc, f.name);
        try self.outf("func.func @{s}({s}){s}{s} {{", .{ mn, params, ret_part, attrs });
        self.indent += 1;

        var scope = try self.paramScope(f.params);
        try self.allocaMutated(f.body orelse &.{}, &scope);
        try self.emitBlock(f.body orelse &.{}, &scope, f.ret);
        if (eq(f.ret, "void")) try self.out("return");

        self.indent -= 1;
        try self.outf("}} // func.func @{s}", .{mn});
        try self.out("");
    }

    fn emitKernelFn(self: *Emitter, f: *ast.FnDecl) !void {
        const params = try self.paramList(f.params);
        const mn = try mangle(self.alloc, f.name);
        try self.outf("gpu.func @{s}({s}) kernel {{", .{ mn, params });
        self.indent += 1;

        var scope = try self.paramScope(f.params);
        try self.allocaMutated(f.body orelse &.{}, &scope);
        try self.emitBlock(f.body orelse &.{}, &scope, "void");
        try self.out("gpu.return");

        self.indent -= 1;
        try self.outf("}} // gpu.func @{s}", .{mn});
        try self.out("");
    }

    fn paramList(self: *Emitter, params: []ast.Param) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.alloc);
        for (params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.writer().print("%{s}: {s}", .{ p.name, try self.mtype(p.pty) });
        }
        return buf.toOwnedSlice();
    }

    fn paramScope(self: *Emitter, params: []ast.Param) !Scope {
        var scope = Scope.init(self.alloc);
        for (params) |p| {
            const v = try std.fmt.allocPrint(self.alloc, "%{s}", .{p.name});
            try scope.put(p.name, .{ .val = v, .is_alloca = false, .zty = p.pty });
        }
        return scope;
    }

    // Alloca-up-front for every mutated (reassigned) local, in source order.
    fn allocaMutated(self: *Emitter, body: []ast.NodeRef, scope: *Scope) !void {
        var ordered = std.ArrayList([]const u8).init(self.alloc);
        var seen = std.StringHashMap(void).init(self.alloc);
        try collectMutated(body, &ordered, &seen);
        for (ordered.items) |vname| {
            const ty = findLetType(body, vname) orelse continue;
            const slot = try self.fresh("slot");
            try self.outf("{s} = memref.alloca() : memref<{s}>", .{ slot, try self.mtype(ty) });
            try scope.put(vname, .{ .val = slot, .is_alloca = true, .zty = ty });
        }
    }

    // ── statement emission ────────────────────────────────────────────────────

    fn emitBlock(self: *Emitter, stmts: []ast.NodeRef, scope: *Scope, ret_ty: []const u8) anyerror!void {
        for (stmts) |s| try self.emitStmt(s, scope, ret_ty);
    }

    fn emitStmt(self: *Emitter, s: ast.NodeRef, scope: *Scope, ret_ty: []const u8) anyerror!void {
        switch (s.*) {
            .let => |*lt| {
                const r = try self.emitExpr(lt.expr, scope);
                const declared_ty = lt.dty orelse r.zty;
                if (scope.get(lt.name)) |e| {
                    if (e.is_alloca) {
                        try self.outf("memref.store {s}, {s}[] : memref<{s}>", .{ r.val, e.val, try self.mtype(declared_ty) });
                        return;
                    }
                }
                try scope.put(lt.name, .{ .val = r.val, .is_alloca = false, .zty = declared_ty });
            },

            .assign => |*asn| {
                const r = try self.emitExpr(asn.expr, scope);
                if (asn.target.* == .index) {
                    const ix = &asn.target.*.index;
                    const base = try self.emitExpr(ix.base, scope);
                    const idx = try self.emitExpr(ix.idx, scope);
                    const elem_ty = if (startsWith(base.zty, "[]")) base.zty[2..] else "i32";
                    try self.outf("memref.store {s}, {s}[{s}] : memref<?x{s}>", .{ r.val, base.val, idx.val, try self.mtype(elem_ty) });
                } else if (varName(asn.target)) |tname| {
                    if (scope.get(tname)) |e| {
                        if (e.is_alloca) {
                            try self.outf("memref.store {s}, {s}[] : memref<{s}>", .{ r.val, e.val, try self.mtype(e.zty) });
                        } else {
                            try scope.put(tname, .{ .val = r.val, .is_alloca = false, .zty = e.zty });
                        }
                    } else {
                        try self.out("// unhandled assign target: var");
                    }
                } else {
                    try self.out("// unhandled assign target");
                }
            },

            .return_ => |*rt| {
                if (rt.expr) |ex| {
                    const r = try self.emitExpr(ex, scope);
                    const t = if (r.zty.len > 0) r.zty else ret_ty;
                    try self.outf("return {s} : {s}", .{ r.val, try self.mtype(t) });
                } else {
                    try self.out("return");
                }
            },

            .if_ => |*iff| {
                const c = try self.emitExpr(iff.cond, scope);
                // Mirror the Python emitter: it always consumes a fresh "if"
                // counter slot before branching (used only in the value form).
                const then_res = try self.fresh("if");
                if (eq(ret_ty, "void")) {
                    try self.outf("scf.if {s} {{", .{c.val});
                    self.indent += 1;
                    var th = try cloneScope(self.alloc, scope);
                    try self.emitBlock(iff.then, &th, ret_ty);
                    self.indent -= 1;
                    if (iff.els) |els| {
                        try self.out("} else {");
                        self.indent += 1;
                        var es = try cloneScope(self.alloc, scope);
                        try self.emitBlock(els, &es, ret_ty);
                        self.indent -= 1;
                    }
                    try self.out("}");
                } else {
                    const mty = try self.mtype(ret_ty);
                    try self.outf("{s} = scf.if {s} -> {s} {{", .{ then_res, c.val, mty });
                    self.indent += 1;
                    var th = try cloneScope(self.alloc, scope);
                    try self.emitBlock(iff.then, &th, ret_ty);
                    self.indent -= 1;
                    if (iff.els) |els| {
                        try self.out("} else {");
                        self.indent += 1;
                        var es = try cloneScope(self.alloc, scope);
                        try self.emitBlock(els, &es, ret_ty);
                        self.indent -= 1;
                    }
                    try self.out("}");
                }
            },

            .while_ => |*wl| {
                // scf.while: before-region tests cond, after-region is the body.
                _ = try self.emitExpr(wl.cond, scope);
                try self.out("scf.while : () -> () {");
                self.indent += 1;
                const c2 = try self.emitExpr(wl.cond, scope);
                try self.outf("scf.condition({s})", .{c2.val});
                self.indent -= 1;
                try self.out("} do {");
                self.indent += 1;
                var bs = try cloneScope(self.alloc, scope);
                try self.emitBlock(wl.body, &bs, "void");
                try self.out("scf.yield");
                self.indent -= 1;
                try self.out("}");
            },

            .switch_ => |*sw| try self.emitSwitch(sw, scope),

            .expr_stmt => |*es| {
                _ = try self.emitExpr(es.expr, scope);
            },

            else => {},
        }
    }

    fn emitSwitch(self: *Emitter, sw: *ast.Switch, scope: *Scope) anyerror!void {
        const subj = try self.emitExpr(sw.subject, scope);
        if (self.sema.enums.get(subj.zty)) |enum_node| {
            const members = enum_node.*.enum_decl.members;
            for (sw.arms) |arm| {
                // Use the first tag (Python iterates single tag per arm).
                const tag = arm.tags[0];
                const tag_idx = indexOf(members, tag) orelse 0;
                const tag_const = try self.fresh("tag");
                try self.outf("{s} = arith.constant {d} : i32", .{ tag_const, tag_idx });
                const e = try self.fresh("eq");
                try self.outf("{s} = arith.cmpi eq, {s}, {s} : i32", .{ e, subj.val, tag_const });
                try self.outf("scf.if {s} {{", .{e});
                self.indent += 1;
                var as = try cloneScope(self.alloc, scope);
                try self.emitBlock(arm.body, &as, "void");
                self.indent -= 1;
                try self.out("}");
            }
        } else if (self.sema.unions.get(subj.zty)) |union_node| {
            const fields = union_node.*.union_decl.fields;
            const tag_field = try self.fresh("tag");
            try self.outf("{s} = llvm.extractvalue {s}[0] : !llvm.struct<...>", .{ tag_field, subj.val });
            for (sw.arms, 0..) |arm, i| {
                const tag_const = try self.fresh("tc");
                try self.outf("{s} = arith.constant {d} : i32", .{ tag_const, i });
                const e = try self.fresh("eq");
                try self.outf("{s} = arith.cmpi eq, {s}, {s} : i32", .{ e, tag_field, tag_const });
                try self.outf("scf.if {s} {{", .{e});
                self.indent += 1;
                var as = try cloneScope(self.alloc, scope);
                if (arm.cap) |cap| {
                    const payload = try self.fresh("payload");
                    try self.outf("{s} = llvm.extractvalue {s}[1, {d}] : !llvm.struct<...>", .{ payload, subj.val, i });
                    const pty = if (i < fields.len) fields[i].pty else "i32";
                    try as.put(cap, .{ .val = payload, .is_alloca = false, .zty = pty });
                }
                try self.emitBlock(arm.body, &as, "void");
                self.indent -= 1;
                try self.out("}");
            }
        } else {
            try self.outf("// switch on non-enum/union type {s} (unimplemented)", .{subj.zty});
        }
    }

    // ── expression emission ───────────────────────────────────────────────────

    const ExprRes = struct { val: []const u8, zty: []const u8 };

    fn emitExpr(self: *Emitter, e: ast.NodeRef, scope: *Scope) anyerror!ExprRes {
        switch (e.*) {
            .lit => |*l| return self.emitLit(l),

            .var_ => |*v| {
                if (scope.get(v.name)) |entry| {
                    if (entry.is_alloca) {
                        const loaded = try self.fresh("ld");
                        try self.outf("{s} = memref.load {s}[] : memref<{s}>", .{ loaded, entry.val, try self.mtype(entry.zty) });
                        return .{ .val = loaded, .zty = entry.zty };
                    }
                    return .{ .val = entry.val, .zty = entry.zty };
                }
                // Named function used as a value — emit a func.constant.
                if (self.sema.fns.get(v.name)) |fn_node| {
                    const f = &fn_node.*.fn_decl;
                    const vv = try self.fresh("fn");
                    const ps = try self.typeList(f.params);
                    const rt = try self.mtype(f.ret);
                    const mn = try mangle(self.alloc, v.name);
                    try self.outf("{s} = func.constant @{s} : ({s}) -> {s}", .{ vv, mn, ps, rt });
                    const fty = try self.fnTypeString(f);
                    return .{ .val = vv, .zty = fty };
                }
                const fallback = try std.fmt.allocPrint(self.alloc, "%{s}", .{v.name});
                return .{ .val = fallback, .zty = v.ty orelse "i32" };
            },

            .bin => |*b| return self.emitBin(b, scope),

            .un => |*u| {
                const r = try self.emitExpr(u.e, scope);
                const res = try self.fresh("u");
                if (eq(u.op, "!")) {
                    const t = try self.fresh("t");
                    try self.outf("{s} = arith.constant true : i1", .{t});
                    try self.outf("{s} = arith.xori {s}, {s} : i1", .{ res, r.val, t });
                    return .{ .val = res, .zty = "bool" };
                }
                if (eq(u.op, "-")) {
                    if (isFloat(r.zty)) {
                        try self.outf("{s} = arith.negf {s} : {s}", .{ res, r.val, try self.mtype(r.zty) });
                    } else {
                        try self.outf("{s} = arith.negsi {s} : {s}", .{ res, r.val, try self.mtype(r.zty) });
                    }
                    return .{ .val = res, .zty = r.zty };
                }
                return .{ .val = r.val, .zty = r.zty };
            },

            .index => |*ix| {
                const base = try self.emitExpr(ix.base, scope);
                const idx = try self.emitExpr(ix.idx, scope);
                const res = try self.fresh("el");
                if (startsWith(base.zty, "[]")) {
                    const elem_ty = base.zty[2..];
                    try self.outf("{s} = memref.load {s}[{s}] : memref<?x{s}>", .{ res, base.val, idx.val, try self.mtype(elem_ty) });
                    return .{ .val = res, .zty = elem_ty };
                }
                try self.outf("// index into unsupported base type {s}", .{base.zty});
                return .{ .val = res, .zty = "i32" };
            },

            .field => |*fl| return self.emitField(fl, scope),

            .struct_lit => |*sl| return self.emitStructLit(sl, scope),

            .closure => {
                try self.out("// closure in GPU context: use @device fn instead of closure");
                return .{ .val = "%closure_unsupported", .zty = "void" };
            },

            .call => |*c| return self.emitCall(c, scope),

            else => {
                const res = try self.fresh("unk");
                try self.out("// unknown expr kind");
                return .{ .val = res, .zty = "i32" };
            },
        }
    }

    fn emitLit(self: *Emitter, l: *ast.Lit) !ExprRes {
        const res = try self.fresh("c");
        switch (l.lty) {
            .int_lit => {
                try self.outf("{s} = arith.constant {s} : i32", .{ res, l.val });
                return .{ .val = res, .zty = "i32" };
            },
            .float_lit => {
                try self.outf("{s} = arith.constant {s} : f32", .{ res, l.val });
                return .{ .val = res, .zty = "f32" };
            },
            .bool_ => {
                const bval: []const u8 = if (eq(l.val, "true")) "true" else "false";
                try self.outf("{s} = arith.constant {s} : i1", .{ res, bval });
                return .{ .val = res, .zty = "bool" };
            },
            .str => {
                try self.outf("{s} = arith.constant {s} : i32  // fallback for str", .{ res, l.val });
                return .{ .val = res, .zty = "i32" };
            },
        }
    }

    fn emitField(self: *Emitter, fl: *ast.Field, scope: *Scope) anyerror!ExprRes {
        // Enum member access: EnumName.Member → constant index.
        if (fl.base.* == .var_) {
            const bn = fl.base.*.var_.name;
            if (self.sema.enums.get(bn)) |enum_node| {
                const members = enum_node.*.enum_decl.members;
                const idx = indexOf(members, fl.fname) orelse 0;
                const v = try self.fresh("enum");
                try self.outf("{s} = arith.constant {d} : i32", .{ v, idx });
                return .{ .val = v, .zty = bn };
            }
        }
        const base = try self.emitExpr(fl.base, scope);
        if (base.zty.len > 0 and startsWith(base.zty, "[]") and eq(fl.fname, "len")) {
            const res = try self.fresh("len");
            try self.outf("{s} = memref.dim {s}, %c0 : memref<?x{s}>", .{ res, base.val, try self.mtype(base.zty[2..]) });
            return .{ .val = res, .zty = "i32" };
        }
        const res = try self.fresh("field");
        if (self.sema.structs.get(base.zty)) |struct_node| {
            const sfields = struct_node.*.struct_decl.fields;
            var fidx: usize = 0;
            for (sfields, 0..) |p, i| {
                if (eq(p.name, fl.fname)) {
                    fidx = i;
                    break;
                }
            }
            const fty = self.sema.fieldTypeOf(base.zty, fl.fname) orelse "i32";
            try self.outf("{s} = llvm.extractvalue {s}[{d}] : {s}", .{ res, base.val, fidx, try self.mtype(base.zty) });
            return .{ .val = res, .zty = fty };
        }
        return .{ .val = res, .zty = "i32" };
    }

    fn emitStructLit(self: *Emitter, sl: *ast.StructLit, scope: *Scope) anyerror!ExprRes {
        const nm = sl.inst_sname orelse sl.sname;
        var vals = std.ArrayList([]const u8).init(self.alloc);
        for (sl.fields) |fi| {
            const r = try self.emitExpr(fi.val, scope);
            try vals.append(r.val);
        }
        var res = try self.fresh("st");
        if (self.sema.structs.get(nm)) |struct_node| {
            const sfields = struct_node.*.struct_decl.fields;
            const mlir_ty = try self.mtype(nm);
            try self.outf("{s} = llvm.mlir.undef : {s}", .{ res, mlir_ty });
            var i: usize = 0;
            while (i < vals.items.len and i < sfields.len) : (i += 1) {
                const tmp = try self.fresh("ins");
                try self.outf("{s} = llvm.insertvalue {s}, {s}[{d}] : {s}", .{ tmp, vals.items[i], res, i, mlir_ty });
                res = tmp;
            }
        }
        return .{ .val = res, .zty = nm };
    }

    // ── binary op emission ────────────────────────────────────────────────────

    fn emitBin(self: *Emitter, e: *ast.Bin, scope: *Scope) anyerror!ExprRes {
        const lr = try self.emitExpr(e.l, scope);
        const rr = try self.emitExpr(e.r, scope);
        // Mirror Python: ty = e.l.ty or e.r.ty or "i32" (operand-derived).
        const ty = ast.nodeType(e.l) orelse ast.nodeType(e.r) orelse "i32";
        const res = try self.fresh("b");

        // ── posit ops ──
        if (isPosit(ty)) {
            if (positOp(e.op)) |sym| {
                try self.outf("{s} = func.call @{s}({s}, {s}) : (i32, i32) -> i32", .{ res, sym, lr.val, rr.val });
                return .{ .val = res, .zty = ty };
            }
            const lf = try self.fresh("pf");
            const rf = try self.fresh("pf");
            try self.outf("{s} = func.call @zag_p32_to_f64({s}) : (i32) -> f64", .{ lf, lr.val });
            try self.outf("{s} = func.call @zag_p32_to_f64({s}) : (i32) -> f64", .{ rf, rr.val });
            try self.outf("{s} = arith.cmpf {s}, {s}, {s} : f64", .{ res, cmpPredF(e.op), lf, rf });
            return .{ .val = res, .zty = "bool" };
        }

        // ── LNS ops ──
        if (isLns(ty)) {
            if (lnsOp(e.op)) |sym| {
                try self.outf("{s} = func.call @{s}({s}, {s}) : (i32, i32) -> i32", .{ res, sym, lr.val, rr.val });
                return .{ .val = res, .zty = ty };
            }
            const lf = try self.fresh("lf");
            const rf = try self.fresh("lf");
            try self.outf("{s} = func.call @zag_l32_to_f32({s}) : (i32) -> f32", .{ lf, lr.val });
            try self.outf("{s} = func.call @zag_l32_to_f32({s}) : (i32) -> f32", .{ rf, rr.val });
            try self.outf("{s} = arith.cmpf {s}, {s}, {s} : f32", .{ res, cmpPredF(e.op), lf, rf });
            return .{ .val = res, .zty = "bool" };
        }

        // ── VSA ops ──
        if (isVsaType(ty)) {
            const vty = try std.fmt.allocPrint(self.alloc, "vector<{s}xi1>", .{vsaDim(ty)});
            if (eq(e.op, "^")) {
                try self.outf("{s} = arith.xori {s}, {s} : {s}", .{ res, lr.val, rr.val, vty });
            } else if (eq(e.op, "|")) {
                try self.outf("{s} = arith.ori {s}, {s} : {s}", .{ res, lr.val, rr.val, vty });
            } else {
                try self.outf("{s} = arith.xori {s}, {s} : {s}  // fallback for {s}", .{ res, lr.val, rr.val, vty, e.op });
            }
            return .{ .val = res, .zty = ty };
        }

        // ── mx_fp8 ──
        if (eq(ty, "mx_fp8")) {
            const lu = try self.fresh("fp32");
            const ru = try self.fresh("fp32");
            try self.outf("{s} = arith.extf {s} : f8E4M3FN to f32", .{ lu, lr.val });
            try self.outf("{s} = arith.extf {s} : f8E4M3FN to f32", .{ ru, rr.val });
            const mid = try self.fresh("m");
            try self.outf("{s} = arith.{s} {s}, {s} : f32", .{ mid, floatArith(e.op), lu, ru });
            try self.outf("{s} = arith.truncf {s} : f32 to f8E4M3FN", .{ res, mid });
            return .{ .val = res, .zty = "mx_fp8" };
        }

        // ── standard float ──
        if (isFloat(ty)) {
            const mty = try self.mtype(ty);
            if (eq(e.op, "+") or eq(e.op, "-") or eq(e.op, "*") or eq(e.op, "/")) {
                try self.outf("{s} = arith.{s} {s}, {s} : {s}", .{ res, floatArith(e.op), lr.val, rr.val, mty });
                return .{ .val = res, .zty = ty };
            }
            try self.outf("{s} = arith.cmpf {s}, {s}, {s} : {s}", .{ res, cmpPredF(e.op), lr.val, rr.val, mty });
            return .{ .val = res, .zty = "bool" };
        }

        // ── standard integer ──
        const mty = try self.mtype(ty);
        if (eq(e.op, "+")) {
            try self.outf("{s} = arith.addi {s}, {s} : {s}", .{ res, lr.val, rr.val, mty });
        } else if (eq(e.op, "-")) {
            try self.outf("{s} = arith.subi {s}, {s} : {s}", .{ res, lr.val, rr.val, mty });
        } else if (eq(e.op, "*")) {
            try self.outf("{s} = arith.muli {s}, {s} : {s}", .{ res, lr.val, rr.val, mty });
        } else if (eq(e.op, "/")) {
            try self.outf("{s} = arith.divsi {s}, {s} : {s}", .{ res, lr.val, rr.val, mty });
        } else if (eq(e.op, "%")) {
            try self.outf("{s} = arith.remsi {s}, {s} : {s}", .{ res, lr.val, rr.val, mty });
        } else if (eq(e.op, "==") or eq(e.op, "!=") or eq(e.op, "<") or eq(e.op, ">") or eq(e.op, "<=") or eq(e.op, ">=")) {
            try self.outf("{s} = arith.cmpi {s}, {s}, {s} : {s}", .{ res, cmpPredI(e.op), lr.val, rr.val, mty });
            return .{ .val = res, .zty = "bool" };
        } else if (eq(e.op, "&&")) {
            try self.outf("{s} = arith.andi {s}, {s} : i1", .{ res, lr.val, rr.val });
            return .{ .val = res, .zty = "bool" };
        } else if (eq(e.op, "||")) {
            try self.outf("{s} = arith.ori {s}, {s} : i1", .{ res, lr.val, rr.val });
            return .{ .val = res, .zty = "bool" };
        } else {
            try self.outf("// unsupported op {s}", .{e.op});
        }
        return .{ .val = res, .zty = ty };
    }

    // ── call emission ─────────────────────────────────────────────────────────

    fn emitCall(self: *Emitter, e: *ast.Call, scope: *Scope) anyerror!ExprRes {
        // Resolve callee name (Var name, possibly overridden by inst_name).
        var cname: ?[]const u8 = null;
        if (e.callee.* == .var_) {
            cname = e.inst_name orelse e.callee.*.var_.name;
        }

        if (cname) |cn| {
            // GPU thread/block index intrinsics.
            if (eq(cn, "@gpuThreadIdx") or eq(cn, "@gpuBlockIdx") or eq(cn, "@gpuBlockDim") or eq(cn, "@gpuGridDim")) {
                _ = try self.emitExpr(e.args[0], scope);
                const dim_lit = extractIntLit(e.args[0]);
                const dim_str = gpuDimName(dim_lit);
                const intrinsic = if (eq(cn, "@gpuThreadIdx"))
                    "gpu.thread_id"
                else if (eq(cn, "@gpuBlockIdx"))
                    "gpu.block_id"
                else if (eq(cn, "@gpuBlockDim"))
                    "gpu.block_dim"
                else
                    "gpu.grid_dim";
                const res = try self.fresh("tid");
                try self.outf("{s} = {s} {s} : index", .{ res, intrinsic, dim_str });
                const cast = try self.fresh("cast");
                try self.outf("{s} = arith.index_cast {s} : index to i32", .{ cast, res });
                return .{ .val = cast, .zty = "i32" };
            }

            if (eq(cn, "@gpuSyncThreads")) {
                try self.out("gpu.barrier");
                return .{ .val = "", .zty = "void" };
            }

            // Posit cast builtins.
            if (eq(cn, "@floatToPosit")) {
                const a = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("p");
                try self.outf("{s} = func.call @zag_f64_to_p32({s}) : (f64) -> i32", .{ res, a.val });
                return .{ .val = res, .zty = "p32" };
            }
            if (eq(cn, "@positToFloat")) {
                const a = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("f");
                try self.outf("{s} = func.call @zag_p32_to_f64({s}) : (i32) -> f64", .{ res, a.val });
                return .{ .val = res, .zty = "f64" };
            }

            // Host-side GPU memory.
            if (eq(cn, "@gpuAlloc")) {
                const n = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("gbuf");
                try self.outf("{s} = gpu.alloc({s}) : memref<?xf32, 1>", .{ res, n.val });
                return .{ .val = res, .zty = "[]f32" };
            }
            if (eq(cn, "@gpuFree")) {
                const buf = try self.emitExpr(e.args[0], scope);
                const elem = if (startsWith(buf.zty, "[]")) buf.zty[2..] else "f32";
                try self.outf("gpu.dealloc {s} : memref<?x{s}, 1>", .{ buf.val, try self.mtype(elem) });
                return .{ .val = "", .zty = "void" };
            }

            // MX cast builtins.
            if (eq(cn, "@floatToMxFp8")) {
                const a = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("mx");
                try self.outf("{s} = arith.truncf {s} : f32 to f8E4M3FN", .{ res, a.val });
                return .{ .val = res, .zty = "mx_fp8" };
            }
            if (eq(cn, "@mxFp8ToFloat")) {
                const a = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("f32");
                try self.outf("{s} = arith.extf {s} : f8E4M3FN to f32", .{ res, a.val });
                return .{ .val = res, .zty = "f32" };
            }

            // LNS cast builtins.
            if (eq(cn, "@floatToLog")) {
                const a = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("l");
                try self.outf("{s} = func.call @zag_f32_to_l32({s}) : (f32) -> i32", .{ res, a.val });
                return .{ .val = res, .zty = "l32" };
            }
            if (eq(cn, "@logToFloat")) {
                const a = try self.emitExpr(e.args[0], scope);
                const res = try self.fresh("f");
                try self.outf("{s} = func.call @zag_l32_to_f32({s}) : (i32) -> f32", .{ res, a.val });
                return .{ .val = res, .zty = "f32" };
            }

            // print_* builtins — extern C functions, emit as func.call.
            if (startsWith(cn, "print_")) {
                const args = try self.emitArgs(e.args, scope);
                try self.outf("func.call @{s}({s}) : ({s}) -> ()", .{ cn, args.vals, args.tys });
                return .{ .val = "", .zty = "void" };
            }

            // @gpuLaunch(gx,gy,gz,bx,by,bz, extra…).
            if (eq(cn, "@gpuLaunch")) {
                var avals = std.ArrayList(ExprRes).init(self.alloc);
                for (e.args) |a| try avals.append(try self.emitExpr(a, scope));
                if (avals.items.len >= 6) {
                    try self.out("// gpu.launch_func @zag_kernels::<kernel>");
                    try self.outf("//     blocks in ({s}, {s}, {s})", .{ avals.items[0].val, avals.items[1].val, avals.items[2].val });
                    try self.outf("//     threads in ({s}, {s}, {s})", .{ avals.items[3].val, avals.items[4].val, avals.items[5].val });
                    if (avals.items.len > 6) {
                        var extra = std.ArrayList(u8).init(self.alloc);
                        var i: usize = 6;
                        while (i < avals.items.len) : (i += 1) {
                            if (i > 6) try extra.appendSlice(", ");
                            try extra.writer().print("{s} : {s}", .{ avals.items[i].val, try self.mtype(avals.items[i].zty) });
                        }
                        try self.outf("//     args({s})", .{extra.items});
                    }
                } else {
                    try self.out("// @gpuLaunch: insufficient args (need gx,gy,gz,bx,by,bz)");
                }
                return .{ .val = "", .zty = "void" };
            }

            // Standard named function call.
            if (self.sema.fns.get(cn)) |fn_node| {
                const f_decl = &fn_node.*.fn_decl;
                const args = try self.emitArgs(e.args, scope);
                const ret_ty = f_decl.ret;
                const mn = try mangle(self.alloc, cn);
                if (eq(ret_ty, "void")) {
                    try self.outf("func.call @{s}({s}) : ({s}) -> ()", .{ mn, args.vals, args.tys });
                    return .{ .val = "", .zty = "void" };
                }
                const mret = try self.mtype(ret_ty);
                const res = try self.fresh("r");
                try self.outf("{s} = func.call @{s}({s}) : ({s}) -> {s}", .{ res, mn, args.vals, args.tys, mret });
                return .{ .val = res, .zty = ret_ty };
            }
        }

        // Fat-pointer call (function value in a local).
        const args = try self.emitArgs(e.args, scope);
        const cv = try self.emitExpr(e.callee, scope);
        const ret_ty = e.ty orelse "i32";
        const res = try self.fresh("r");
        try self.outf("{s} = func.call_indirect {s}({s}) : ({s}) -> {s}", .{ res, cv.val, args.vals, args.tys, try self.mtype(ret_ty) });
        return .{ .val = res, .zty = ret_ty };
    }

    const ArgStrs = struct { vals: []const u8, tys: []const u8 };

    fn emitArgs(self: *Emitter, args: []ast.NodeRef, scope: *Scope) !ArgStrs {
        var vals = std.ArrayList(u8).init(self.alloc);
        var tys = std.ArrayList(u8).init(self.alloc);
        for (args, 0..) |a, i| {
            const r = try self.emitExpr(a, scope);
            if (i > 0) {
                try vals.appendSlice(", ");
                try tys.appendSlice(", ");
            }
            try vals.appendSlice(r.val);
            try tys.appendSlice(try self.mtype(r.zty));
        }
        return .{ .vals = try vals.toOwnedSlice(), .tys = try tys.toOwnedSlice() };
    }

    // ── utilities ─────────────────────────────────────────────────────────────

    fn typeList(self: *Emitter, params: []ast.Param) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.alloc);
        for (params, 0..) |p, i| {
            if (i > 0) try buf.appendSlice(", ");
            try buf.appendSlice(try self.mtype(p.pty));
        }
        return buf.toOwnedSlice();
    }

    fn fnTypeString(self: *Emitter, f: *ast.FnDecl) ![]const u8 {
        var buf = std.ArrayList(u8).init(self.alloc);
        try buf.appendSlice("fn(");
        for (f.params, 0..) |p, i| {
            if (i > 0) try buf.append(',');
            try buf.appendSlice(p.pty);
        }
        try buf.append(')');
        try buf.appendSlice(f.ret);
        return buf.toOwnedSlice();
    }

    fn emitHeader(self: *Emitter) !void {
        const target_comment = if (eq(self.target, "nvidia"))
            "NVIDIA NVVM/CUDA (nvvm + gpu + llvm dialects)"
        else if (eq(self.target, "amd"))
            "AMD ROCDL/HIP (rocdl + gpu + llvm dialects)"
        else if (eq(self.target, "vulkan"))
            "Vulkan SPIR-V portability fallback (spirv dialect)"
        else
            self.target;

        try self.out("// Zag MLIR — generated by zagc gpu backend");
        try self.outf("// Target: {s}", .{target_comment});
        try self.out("//");
        try self.out("// Lower with:");
        if (eq(self.target, "nvidia")) {
            try self.out("//   mlir-opt --pass-pipeline='builtin.module(gpu-kernel-outlining,");
            try self.out("//     convert-gpu-to-nvvm,gpu-to-llvm,convert-func-to-llvm)' \\");
            try self.out("//     | mlir-translate --mlir-to-llvmir | llc -march=nvptx64");
        } else if (eq(self.target, "amd")) {
            try self.out("//   mlir-opt --pass-pipeline='builtin.module(gpu-kernel-outlining,");
            try self.out("//     convert-gpu-to-rocdl,gpu-to-llvm,convert-func-to-llvm)' \\");
            try self.out("//     | mlir-translate --mlir-to-llvmir");
        } else if (eq(self.target, "vulkan")) {
            try self.out("//   mlir-opt --convert-gpu-to-spirv --serialize-spirv \\");
            try self.out("//     | spirv-dis  (or load the .spv binary directly)");
        }
        try self.out("");
    }
};

// ── free-standing helpers ─────────────────────────────────────────────────────

fn hasAnnot(f: *ast.FnDecl, name: []const u8) bool {
    for (f.annots) |a| if (eq(a, name)) return true;
    return false;
}

fn varName(n: ast.NodeRef) ?[]const u8 {
    if (n.* == .var_) return n.*.var_.name;
    return null;
}

fn extractIntLit(n: ast.NodeRef) ?[]const u8 {
    if (n.* == .lit and n.*.lit.lty == .int_lit) return n.*.lit.val;
    return null;
}

fn indexOf(haystack: [][]const u8, needle: []const u8) ?usize {
    for (haystack, 0..) |h, i| if (eq(h, needle)) return i;
    return null;
}

// Collect reassigned (mutated) variable names in first-seen source order.
fn collectMutated(
    stmts: []ast.NodeRef,
    ordered: *std.ArrayList([]const u8),
    seen: *std.StringHashMap(void),
) anyerror!void {
    for (stmts) |s| {
        switch (s.*) {
            .assign => |*a| {
                if (varName(a.target)) |t| {
                    if (!seen.contains(t)) {
                        try seen.put(t, {});
                        try ordered.append(t);
                    }
                }
            },
            .if_ => |*iff| {
                try collectMutated(iff.then, ordered, seen);
                if (iff.els) |els| try collectMutated(els, ordered, seen);
            },
            .while_ => |*wl| try collectMutated(wl.body, ordered, seen),
            .switch_ => |*sw| {
                for (sw.arms) |arm| try collectMutated(arm.body, ordered, seen);
                if (sw.els) |els| try collectMutated(els, ordered, seen);
            },
            else => {},
        }
    }
}

fn findLetType(stmts: []ast.NodeRef, name: []const u8) ?[]const u8 {
    for (stmts) |s| {
        if (s.* == .let and eq(s.*.let.name, name)) {
            const lt = &s.*.let;
            return lt.dty orelse ast.nodeType(lt.expr) orelse "i32";
        }
    }
    return null;
}

// ── public entry point ────────────────────────────────────────────────────────

pub fn genMlir(
    alloc: std.mem.Allocator,
    decls: []ast.NodeRef,
    s: *const sema_mod.Sema,
    target: []const u8,
) ![]const u8 {
    var em = Emitter.init(alloc, decls, s, target);
    return em.emitModule();
}
