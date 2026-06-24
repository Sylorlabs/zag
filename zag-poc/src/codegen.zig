// codegen.zig — Zag C code generator (Zig 0.14)
//
// Pipeline: AST + Sema → C source text

const std = @import("std");
const ast = @import("ast.zig");
const sema_mod = @import("sema.zig");
const types = @import("types.zig");

// ── Embedded prelude ──────────────────────────────────────────────────────────
const NUMERIC_C = @embedFile("numeric_prelude.c");

fn getPrelude() []const u8 {
    var count: u32 = 0;
    var i: usize = 0;
    while (i < NUMERIC_C.len) : (i += 1) {
        if (NUMERIC_C[i] == '\n') {
            count += 1;
            if (count == 407) {
                return NUMERIC_C[0 .. i + 1];
            }
        }
    }
    return NUMERIC_C;
}

// ── Type mapping ─────────────────────────────────────────────────────────────

fn ctype(alloc: std.mem.Allocator, zty_raw: []const u8) anyerror![]const u8 {
    // Strip effect annotations: "f32@realtime" → "f32", "f32!pure" → "f32"
    // But NOT "!i32" (error union prefix at position 0)
    const zty = blk: {
        var best: usize = zty_raw.len;
        for (zty_raw, 0..) |c, j| {
            // '@' anywhere strips from that point
            if (c == '@' and j + 1 < zty_raw.len and std.ascii.isAlphabetic(zty_raw[j + 1])) {
                best = j;
                break;
            }
            // '!' strips only if NOT at position 0 (position 0 = error union prefix)
            if (c == '!' and j > 0 and j + 1 < zty_raw.len and std.ascii.isAlphabetic(zty_raw[j + 1])) {
                best = j;
                break;
            }
        }
        break :blk zty_raw[0..best];
    };

    const exact_map = .{
        .{ "i8", "int8_t" },
        .{ "i16", "int16_t" },
        .{ "i32", "int32_t" },
        .{ "i64", "int64_t" },
        .{ "u8", "uint8_t" },
        .{ "u16", "uint16_t" },
        .{ "u32", "uint32_t" },
        .{ "u64", "uint64_t" },
        .{ "f32", "float" },
        .{ "f64", "double" },
        .{ "bool", "int32_t" },
        .{ "void", "void" },
        .{ "usize", "uint64_t" },
        .{ "[]u8", "ZagSliceU8" },
        .{ "[]f32", "ZagSliceF32" },
        .{ "[]i32", "ZagSliceI32" },
        .{ "[]u16", "ZagSliceU16" },
        .{ "[]u32", "ZagSliceU32" },
        .{ "[]u64", "ZagSliceU64" },
        .{ "[]i64", "ZagSliceI64" },
        .{ "p8", "uint8_t" },
        .{ "p16", "uint16_t" },
        .{ "p32", "uint32_t" },
        .{ "p64", "uint64_t" },
        .{ "quire", "ZagQuire" },
        .{ "sat_i8", "int8_t" },
        .{ "sat_i16", "int16_t" },
        .{ "sat_i32", "int32_t" },
        .{ "sat_i64", "int64_t" },
        .{ "sat_u8", "uint8_t" },
        .{ "sat_u16", "uint16_t" },
        .{ "sat_u32", "uint32_t" },
        .{ "sat_u64", "uint64_t" },
        .{ "rns_3", "ZagRns" },
        .{ "rns_4", "ZagRns" },
        .{ "rns_5", "ZagRns" },
        .{ "u_any", "unsigned __int128" },
        .{ "i_any", "__int128" },
        .{ "[]sat_i8", "ZagSlice_sat_i8" },
        .{ "[]sat_i16", "ZagSlice_sat_i16" },
        .{ "[]sat_i32", "ZagSlice_sat_i32" },
        .{ "[]sat_u8", "ZagSlice_sat_u8" },
        .{ "[]sat_u16", "ZagSlice_sat_u16" },
        .{ "[]sat_u32", "ZagSlice_sat_u32" },
        .{ "[]fixed_8_8", "ZagSlice_fixed_8_8" },
        .{ "[]fixed_16_16", "ZagSlice_fixed_16_16" },
        .{ "[]rns_3", "ZagSlice_rns_3" },
    };

    inline for (exact_map) |pair| {
        if (std.mem.eql(u8, zty, pair[0])) return pair[1];
    }

    if (zty.len > 1 and zty[0] == '?') {
        const inner = zty[1..];
        const ct = try ctype(alloc, inner);
        const mangle = try mangleType(alloc, ct);
        return std.fmt.allocPrint(alloc, "ZagOpt_{s}", .{mangle});
    }

    if (zty.len > 1 and zty[0] == '!') {
        const inner = zty[1..];
        const ct = try ctype(alloc, inner);
        const mangle = try mangleType(alloc, ct);
        return std.fmt.allocPrint(alloc, "ZagResult_{s}", .{mangle});
    }

    // *T → T*  (pointer type)
    if (zty.len > 1 and zty[0] == '*') {
        const inner = zty[1..];
        const inner_ct = try ctype(alloc, inner);
        return std.fmt.allocPrint(alloc, "{s}*", .{inner_ct});
    }

    if (std.mem.startsWith(u8, zty, "fn(")) {
        return ctypeClosure(alloc, zty);
    }

    if (std.mem.indexOfScalar(u8, zty, '.')) |_| {
        const result = try alloc.dupe(u8, zty);
        for (result) |*c| {
            if (c.* == '.') c.* = '_';
        }
        return result;
    }

    if (std.mem.startsWith(u8, zty, "fixed_")) return "int32_t";
    if (std.mem.startsWith(u8, zty, "rns_")) return "ZagRns";

    if (zty.len >= 2 and zty[0] == 'u') {
        const n = std.fmt.parseInt(u32, zty[1..], 10) catch 0;
        if (n >= 3 and n <= 8) return "uint8_t";
        if (n >= 9 and n <= 16) return "uint16_t";
        if (n >= 17 and n <= 32) return "uint32_t";
        if (n >= 33 and n <= 64) return "uint64_t";
    }
    if (zty.len >= 2 and zty[0] == 'i') {
        const n = std.fmt.parseInt(u32, zty[1..], 10) catch 0;
        if (n >= 3 and n <= 8) return "int8_t";
        if (n >= 9 and n <= 16) return "int16_t";
        if (n >= 17 and n <= 32) return "int32_t";
        if (n >= 33 and n <= 64) return "int64_t";
    }

    // Generic type application: Box[i32] → Box_i32, Box[f32] → Box_f32
    // Use raw Zag arg names (same as sema's naming convention)
    if (std.mem.indexOfScalar(u8, zty, '[')) |bracket_idx| {
        if (zty[zty.len - 1] == ']') {
            const base = zty[0..bracket_idx];
            const args_str = zty[bracket_idx + 1 .. zty.len - 1];
            // Split args and mangle them using raw Zag names
            var result = std.ArrayList(u8).init(alloc);
            defer result.deinit();
            try result.appendSlice(base);
            var start: usize = 0;
            var dep: i32 = 0;
            for (args_str, 0..) |c, j| {
                if (c == '[') dep += 1
                else if (c == ']') dep -= 1
                else if (c == ',' and dep == 0) {
                    const seg = std.mem.trim(u8, args_str[start..j], " ");
                    try result.append('_');
                    try appendMangledArg(&result, seg);
                    start = j + 1;
                }
            }
            const seg = std.mem.trim(u8, args_str[start..], " ");
            if (seg.len > 0) {
                try result.append('_');
                try appendMangledArg(&result, seg);
            }
            return result.toOwnedSlice();
        }
    }

    return zty;
}

/// Append a generic type argument to a C struct name, sanitizing characters
/// that are illegal in C identifiers. Deterministic so the same Zag type always
/// yields the same C name (e.g. "*Node" → "pNode", "Box[i32]" → "Box_i32").
fn appendMangledArg(result: *std.ArrayList(u8), seg: []const u8) !void {
    for (seg) |c| {
        switch (c) {
            '*' => try result.append('p'),
            '?' => try result.append('o'),
            '!' => try result.append('e'),
            '[', ',', '.', '<' => try result.append('_'),
            ']', '>', ' ' => {}, // dropped
            else => try result.append(c),
        }
    }
}

fn ctypeClosure(alloc: std.mem.Allocator, zty: []const u8) anyerror![]const u8 {
    // Zag fn types: "fn(P1,P2,...)RET" (no "->")
    // Find the closing paren of the parameter list (depth-aware)
    if (!std.mem.startsWith(u8, zty, "fn(")) return zty;
    var depth: i32 = 0;
    var close: usize = 3; // start after "fn("
    var i: usize = 3;
    while (i < zty.len) : (i += 1) {
        if (zty[i] == '(') depth += 1
        else if (zty[i] == ')') {
            if (depth == 0) { close = i; break; }
            depth -= 1;
        }
    }
    const params_str = zty[3..close];
    // ret is everything after the closing paren, strip effect suffixes
    var ret_str = if (close + 1 < zty.len) zty[close + 1 ..] else "void";
    // strip effect suffix starting with @ or !
    for (ret_str, 0..) |c, j| {
        if (c == '@' or (c == '!' and j > 0)) { ret_str = ret_str[0..j]; break; }
        if (c == '!' and j == 0) {
            // error union return: keep it
            break;
        }
    }
    if (ret_str.len == 0) ret_str = "void";

    const ret_c = try ctype(alloc, ret_str);
    const ret_m = try mangleType(alloc, ret_c);

    var param_buf = std.ArrayList(u8).init(alloc);
    defer param_buf.deinit();
    if (params_str.len > 0) {
        // Split params by comma at depth 0
        var cur_start: usize = 0;
        var d: i32 = 0;
        for (params_str, 0..) |c, j| {
            if (c == '(' or c == '[') d += 1
            else if (c == ')' or c == ']') d -= 1
            else if (c == ',' and d == 0) {
                const seg = std.mem.trim(u8, params_str[cur_start..j], " ");
                if (seg.len > 0) {
                    const pc = try ctype(alloc, seg);
                    const pm = try mangleType(alloc, pc);
                    try param_buf.append('_');
                    try param_buf.appendSlice(pm);
                }
                cur_start = j + 1;
            }
        }
        const seg = std.mem.trim(u8, params_str[cur_start..], " ");
        if (seg.len > 0) {
            const pc = try ctype(alloc, seg);
            const pm = try mangleType(alloc, pc);
            try param_buf.append('_');
            try param_buf.appendSlice(pm);
        }
    }
    return std.fmt.allocPrint(alloc, "ZagClo_{s}_{s}", .{ ret_m, param_buf.items });
}

/// Return a string of (indent * 4) spaces for pre-statement emission.
fn indentStr(alloc: std.mem.Allocator, indent: u32) ![]const u8 {
    const spaces = indent * 4;
    const s = try alloc.alloc(u8, spaces);
    @memset(s, ' ');
    return s;
}

fn mangleType(alloc: std.mem.Allocator, ct: []const u8) ![]const u8 {
    var result = try alloc.alloc(u8, ct.len);
    for (ct, 0..) |c, i| {
        if (std.ascii.isAlphanumeric(c) or c == '_') {
            result[i] = c;
        } else {
            result[i] = '_';
        }
    }
    return result;
}

// ── Context ───────────────────────────────────────────────────────────────────

const Ctx = struct {
    buf: std.ArrayList(u8),
    alloc: std.mem.Allocator,
    s: *const sema_mod.Sema,
    target: []const u8,
    sw_counter: u32,
    clos_counter: u32,
    try_counter: u32,
    or_counter: u32,
    fu_counter: u32,
    tmp_counter: u32,   // for new() temp var names
    indent: u32,
    cur_fn_ret: []const u8,
    opt_types: std.StringHashMap([]const u8),
    result_types: std.StringHashMap([]const u8),
    closures_fwd: std.ArrayList(u8),
    closures_impl: std.ArrayList(u8),
    clo_typedefs: std.ArrayList(u8),  // ZagClo_ and __ClosEnv_ typedefs
    emitted_clo_types: std.StringHashMap(void),  // dedup
    thunks: std.ArrayList(u8),        // __thunk_fnname wrappers
    emitted_thunks: std.StringHashMap(void),     // dedup
    pre_stmts: std.ArrayList(u8),     // statements to emit before the current statement
    new_type_hint: ?[]const u8,       // hint for new() type when declared type is available

    fn init(alloc: std.mem.Allocator, s: *const sema_mod.Sema, target: []const u8) Ctx {
        return .{
            .buf = std.ArrayList(u8).init(alloc),
            .alloc = alloc,
            .s = s,
            .target = target,
            .sw_counter = 0,
            .clos_counter = 0,
            .try_counter = 0,
            .or_counter = 0,
            .fu_counter = 0,
            .tmp_counter = 0,
            .indent = 0,
            .cur_fn_ret = "void",
            .opt_types = std.StringHashMap([]const u8).init(alloc),
            .result_types = std.StringHashMap([]const u8).init(alloc),
            .closures_fwd = std.ArrayList(u8).init(alloc),
            .closures_impl = std.ArrayList(u8).init(alloc),
            .clo_typedefs = std.ArrayList(u8).init(alloc),
            .emitted_clo_types = std.StringHashMap(void).init(alloc),
            .thunks = std.ArrayList(u8).init(alloc),
            .emitted_thunks = std.StringHashMap(void).init(alloc),
            .pre_stmts = std.ArrayList(u8).init(alloc),
            .new_type_hint = null,
        };
    }

    fn deinit(self: *Ctx) void {
        self.buf.deinit();
        self.opt_types.deinit();
        self.result_types.deinit();
        self.closures_fwd.deinit();
        self.closures_impl.deinit();
        self.clo_typedefs.deinit();
        self.emitted_clo_types.deinit();
        self.thunks.deinit();
        self.emitted_thunks.deinit();
        self.pre_stmts.deinit();
    }

    /// Flush any accumulated pre-statements into buf (called before emitting a statement).
    fn flushPreStmts(self: *Ctx) !void {
        if (self.pre_stmts.items.len > 0) {
            try self.buf.appendSlice(self.pre_stmts.items);
            self.pre_stmts.clearRetainingCapacity();
        }
    }

    fn w(self: *Ctx, s: []const u8) !void {
        try self.buf.appendSlice(s);
    }

    fn wf(self: *Ctx, comptime fmt: []const u8, args: anytype) !void {
        const s = try std.fmt.allocPrint(self.alloc, fmt, args);
        defer self.alloc.free(s);
        try self.buf.appendSlice(s);
    }

    fn wIndent(self: *Ctx) !void {
        var i: u32 = 0;
        while (i < self.indent) : (i += 1) {
            try self.buf.appendSlice("    ");
        }
    }

    fn registerOpt(self: *Ctx, inner_c: []const u8) !void {
        const mangle = try mangleType(self.alloc, inner_c);
        const key = try std.fmt.allocPrint(self.alloc, "ZagOpt_{s}", .{mangle});
        try self.opt_types.put(key, try self.alloc.dupe(u8, inner_c));
    }

    fn registerResult(self: *Ctx, inner_c: []const u8) !void {
        const mangle = try mangleType(self.alloc, inner_c);
        const key = try std.fmt.allocPrint(self.alloc, "ZagResult_{s}", .{mangle});
        try self.result_types.put(key, try self.alloc.dupe(u8, inner_c));
    }

    /// Ensure a special slice typedef like ZagSlice_sat_i16 is emitted
    fn ensureSpecialSliceTypedef(self: *Ctx, zag_slice_ty: []const u8) !void {
        if (!std.mem.startsWith(u8, zag_slice_ty, "[]")) return;
        const elem_ty = zag_slice_ty[2..]; // strip "[]"
        // Only skip types that are already in the prelude (ZagSliceU8, ZagSliceF32, ZagSliceI32)
        const is_prelude = std.mem.eql(u8, elem_ty, "u8") or
            std.mem.eql(u8, elem_ty, "f32") or std.mem.eql(u8, elem_ty, "i32");
        if (is_prelude) return;
        // Generate typedef name
        const elem_ct = try ctype(self.alloc, elem_ty);
        const slice_name = try ctype(self.alloc, zag_slice_ty);
        if (self.emitted_clo_types.contains(slice_name)) return; // reuse set for dedup
        try self.emitted_clo_types.put(try self.alloc.dupe(u8, slice_name), {});
        const td = self.clo_typedefs.writer();
        try td.print("typedef struct {{ {s}* ptr; int32_t len; }} {s};\n", .{ elem_ct, slice_name });
    }

    /// Ensure a ZagClo_ typedef is emitted for a fn(...)RET type string
    fn ensureClosureTypedef(self: *Ctx, fn_ty: []const u8) ![]const u8 {
        const clo_ty = try ctypeClosure(self.alloc, fn_ty);
        if (self.emitted_clo_types.contains(clo_ty)) return clo_ty;
        try self.emitted_clo_types.put(try self.alloc.dupe(u8, clo_ty), {});

        // Parse fn_ty "fn(P1,P2,...)RET"
        const paren_start = std.mem.indexOfScalar(u8, fn_ty, '(') orelse return clo_ty;
        const paren_end = blk: {
            var depth: i32 = 0;
            var j: usize = paren_start;
            while (j < fn_ty.len) : (j += 1) {
                if (fn_ty[j] == '(') depth += 1
                else if (fn_ty[j] == ')') {
                    depth -= 1;
                    if (depth == 0) break :blk j;
                }
            }
            return clo_ty;
        };
        const params_str = fn_ty[paren_start + 1 .. paren_end];
        const ret_zty = fn_ty[paren_end + 1 ..];
        const ret_ct = try ctype(self.alloc, ret_zty);

        const td = self.clo_typedefs.writer();
        try td.print("typedef struct {{ {s} (*fn)(void*", .{ret_ct});
        if (params_str.len > 0) {
            var idx: usize = 0;
            var depth2: i32 = 0;
            var seg_start: usize = 0;
            while (idx <= params_str.len) : (idx += 1) {
                const ch = if (idx < params_str.len) params_str[idx] else ',';
                if (ch == '(' or ch == '[') depth2 += 1
                else if (ch == ')' or ch == ']') depth2 -= 1
                else if (ch == ',' and depth2 == 0) {
                    const seg = std.mem.trim(u8, params_str[seg_start..idx], " ");
                    if (seg.len > 0) {
                        const pc = try ctype(self.alloc, seg);
                        try td.print(", {s}", .{pc});
                    }
                    seg_start = idx + 1;
                }
            }
        }
        try td.print("); void* env; }} {s};\n", .{clo_ty});
        return clo_ty;
    }
};

// ── Expression codegen ────────────────────────────────────────────────────────

fn genExpr(ctx: *Ctx, node: ast.NodeRef) anyerror!void {
    switch (node.*) {
        .lit => |l| try genLit(ctx, l),
        .var_ => |v| try genVar(ctx, v),
        .bin => |b| try genBin(ctx, b),
        .un => |u| try genUn(ctx, u),
        .call => |c| try genCall(ctx, c),
        .field => |f| try genField(ctx, f),
        .index => |idx| try genIndex(ctx, idx),
        .slice => |sl| try genSlice(ctx, sl),
        .cast => |c| try genCast(ctx, c),
        .struct_lit => |sl| try genStructLit(ctx, sl),
        .null_lit => |nl| try genNullLit(ctx, nl),
        .err_lit => |el| try genErrLit(ctx, el),
        .try_ => |inner| try genTry(ctx, inner),
        .catch_ => |c| try genCatch(ctx, c),
        .or_else => |oe| try genOrElse(ctx, oe),
        .force_unwrap => |inner| try genForceUnwrap(ctx, inner),
        .closure => |cl| try genClosureExpr(ctx, cl),
        .switch_ => |sw| {
            if (sw.is_expr) {
                try genSwitchExpr(ctx, sw);
            } else {
                try ctx.w("0");
            }
        },
        else => try ctx.w("/*unsupported_expr*/0"),
    }
}

fn genLit(ctx: *Ctx, l: ast.Lit) !void {
    switch (l.lty) {
        .int_lit, .float_lit => try ctx.w(l.val),
        .bool_ => {
            if (std.mem.eql(u8, l.val, "true")) {
                try ctx.w("1");
            } else {
                try ctx.w("0");
            }
        },
        .str => {
            // l.val may or may not have surrounding quotes, normalize
            const raw = l.val;
            const inner: []const u8 = if (raw.len >= 2 and raw[0] == '"' and raw[raw.len - 1] == '"')
                raw[1 .. raw.len - 1]
            else
                raw;
            const slen = countStrLen(inner);
            // Always emit with quotes
            try ctx.wf("(ZagSliceU8){{(const uint8_t*)\"{s}\", {d}}}", .{ inner, slen });
        },
    }
}

fn countStrLen(s: []const u8) usize {
    var i: usize = 0;
    var count: usize = 0;
    while (i < s.len) {
        if (s[i] == '\\' and i + 1 < s.len) {
            i += 2;
        } else {
            i += 1;
        }
        count += 1;
    }
    return count;
}

fn genVar(ctx: *Ctx, v: ast.Var) !void {
    if (std.mem.indexOfScalar(u8, v.name, '.')) |_| {
        const mangled = try ctx.alloc.dupe(u8, v.name);
        defer ctx.alloc.free(mangled);
        for (mangled) |*c| {
            if (c.* == '.') c.* = '_';
        }
        try ctx.w(mangled);
    } else {
        try ctx.w(v.name);
    }
}

fn genBin(ctx: *Ctx, b: ast.Bin) !void {
    // RNS arithmetic: rns_3 + rns_3 → zag_rns_add(a, b)
    const lty = ast.nodeType(b.l) orelse "";
    const rty = ast.nodeType(b.r) orelse "";
    const is_rns = std.mem.startsWith(u8, lty, "rns_") or std.mem.startsWith(u8, rty, "rns_");
    if (is_rns) {
        const fn_name: []const u8 = if (std.mem.eql(u8, b.op, "+")) "zag_rns_add"
            else if (std.mem.eql(u8, b.op, "-")) "zag_rns_sub"
            else if (std.mem.eql(u8, b.op, "*")) "zag_rns_mul"
            else "zag_rns_add"; // fallback
        try ctx.wf("{s}(", .{fn_name});
        try genExpr(ctx, b.l);
        try ctx.w(", ");
        try genExpr(ctx, b.r);
        try ctx.w(")");
        return;
    }

    // fixed_16_16 multiply: a * b → (int32_t)(((int64_t)a * b) >> 16)
    const is_fixed = std.mem.startsWith(u8, lty, "fixed_") or std.mem.startsWith(u8, rty, "fixed_");
    if (is_fixed and std.mem.eql(u8, b.op, "*")) {
        try ctx.w("((int32_t)(((int64_t)");
        try genExpr(ctx, b.l);
        try ctx.w(" * ");
        try genExpr(ctx, b.r);
        try ctx.w(") >> 16))");
        return;
    }

    const op: []const u8 = if (std.mem.eql(u8, b.op, "and"))
        "&&"
    else if (std.mem.eql(u8, b.op, "or"))
        "||"
    else
        b.op;

    try ctx.w("(");
    try genExpr(ctx, b.l);
    try ctx.w(" ");
    try ctx.w(op);
    try ctx.w(" ");
    try genExpr(ctx, b.r);
    try ctx.w(")");
}

fn genUn(ctx: *Ctx, u: ast.Un) !void {
    if (std.mem.eql(u8, u.op, "not") or std.mem.eql(u8, u.op, "!")) {
        try ctx.w("(!");
        try genExpr(ctx, u.e);
        try ctx.w(")");
    } else {
        try ctx.w("(");
        try ctx.w(u.op);
        try genExpr(ctx, u.e);
        try ctx.w(")");
    }
}

fn genCall(ctx: *Ctx, c: ast.Call) !void {
    // Builtin
    if (c.callee.* == .var_) {
        const name = c.callee.var_.name;

        // new(expr) — heap-allocate a value of type T, return *T
        if (std.mem.eql(u8, name, "new") and c.args.len == 1) {
            const arg = c.args[0];
            // Determine type T from multiple sources (priority order):
            // 1. ctx.new_type_hint (set by genLet from the declared *T type)
            // 2. Call's own sema type "*T" → strip leading "*"
            // 3. Arg has a concrete (non-raw-literal) type
            // 4. Struct literal: use sname
            // 5. Fall back to int32_t
            const arg_ty: []const u8 = blk: {
                // Highest priority: type hint from enclosing let
                if (ctx.new_type_hint) |hint| {
                    break :blk hint;
                }
                // Use call's own type "*T" → strip leading "*" to get T
                if (c.ty) |call_ty| {
                    if (call_ty.len > 1 and call_ty[0] == '*') {
                        const inner = call_ty[1..];
                        // Skip if still a raw literal kind
                        if (!std.mem.eql(u8, inner, "int_lit") and
                            !std.mem.eql(u8, inner, "float_lit"))
                        {
                            break :blk inner;
                        }
                    }
                }
                // Use arg type but skip raw literal kinds
                if (ast.nodeType(arg)) |t| {
                    if (!std.mem.eql(u8, t, "int_lit") and
                        !std.mem.eql(u8, t, "float_lit") and
                        !std.mem.eql(u8, t, "bool_") and
                        !std.mem.eql(u8, t, "str"))
                    {
                        break :blk t;
                    }
                }
                // Struct literal: use struct name
                if (arg.* == .struct_lit) {
                    break :blk (arg.struct_lit.inst_sname orelse arg.struct_lit.sname);
                }
                // Fallback
                break :blk "int32_t";
            };
            const arg_ct = try ctype(ctx.alloc, arg_ty);
            const n = ctx.tmp_counter;
            ctx.tmp_counter += 1;
            const tmp_name = try std.fmt.allocPrint(ctx.alloc, "__zag_new_{d}", .{n});
            // Emit pre-statement: T* __zag_new_N = (T*)malloc(sizeof(T));
            const ind = try indentStr(ctx.alloc, ctx.indent);
            try ctx.pre_stmts.writer().print(
                "{s}{s}* {s} = ({s}*)malloc(sizeof({s})); if (!{s}) {{ fprintf(stderr, \"OOM\\n\"); abort(); }} *{s} = ",
                .{ ind, arg_ct, tmp_name, arg_ct, arg_ct, tmp_name, tmp_name },
            );
            // emit the value expression into pre_stmts temporarily
            const saved_buf = ctx.buf;
            ctx.buf = ctx.pre_stmts;
            try genExpr(ctx, arg);
            ctx.pre_stmts = ctx.buf;
            ctx.buf = saved_buf;
            try ctx.pre_stmts.writer().print(";\n", .{});
            // The expression result is just the pointer name
            try ctx.w(tmp_name);
            return;
        }

        // delete(ptr) — free a heap pointer
        if (std.mem.eql(u8, name, "delete") and c.args.len == 1) {
            try ctx.w("free(");
            try genExpr(ctx, c.args[0]);
            try ctx.w(")");
            return;
        }

        if (std.mem.startsWith(u8, name, "@")) {
            const builtin = name[1..];
            // @sizeOf[T]() — compile-time byte size of T
            if (std.mem.eql(u8, builtin, "sizeOf")) {
                const t = if (c.targs.len > 0) c.targs[0] else "i32";
                const ct = try ctype(ctx.alloc, t);
                try ctx.wf("((int32_t)sizeof({s}))", .{ct});
                return;
            }
            // Map Zag builtins to C runtime functions
            const c_fn: []const u8 = blk: {
                if (std.mem.eql(u8, builtin, "strEq")) break :blk "_zag_str_eq";
                if (std.mem.eql(u8, builtin, "strLen")) break :blk "_zag_str_len";
                if (std.mem.eql(u8, builtin, "intToPosit")) break :blk "zag_p32_from_i64";
                if (std.mem.eql(u8, builtin, "floatToPosit")) break :blk "zag_f64_to_p32";
                if (std.mem.eql(u8, builtin, "positToFloat")) break :blk "zag_p32_to_f64";
                if (std.mem.eql(u8, builtin, "positToBits")) break :blk "zag_p32_bits";
                if (std.mem.eql(u8, builtin, "intToP8")) break :blk "zag_p8_from_i64";
                if (std.mem.eql(u8, builtin, "intToP16")) break :blk "zag_p16_from_i64";
                if (std.mem.eql(u8, builtin, "intToP64")) break :blk "zag_p64_from_i64";
                if (std.mem.eql(u8, builtin, "floatToP8")) break :blk "zag_f64_to_p8";
                if (std.mem.eql(u8, builtin, "floatToP16")) break :blk "zag_f64_to_p16";
                if (std.mem.eql(u8, builtin, "floatToP64")) break :blk "zag_ld_to_p64";
                if (std.mem.eql(u8, builtin, "p8ToFloat")) break :blk "zag_p8_to_f64";
                if (std.mem.eql(u8, builtin, "p16ToFloat")) break :blk "zag_p16_to_f64";
                if (std.mem.eql(u8, builtin, "p64ToFloat")) break :blk "zag_p64_to_f64";
                if (std.mem.eql(u8, builtin, "p8ToBits")) break :blk "zag_p8_bits";
                if (std.mem.eql(u8, builtin, "p16ToBits")) break :blk "zag_p16_bits";
                if (std.mem.eql(u8, builtin, "p64ToBits")) break :blk "zag_p64_bits";
                if (std.mem.eql(u8, builtin, "quireZero")) break :blk "zag_quire_zero";
                if (std.mem.eql(u8, builtin, "quireFMA")) break :blk "zag_quire_fma";
                if (std.mem.eql(u8, builtin, "quireToPosit")) break :blk "zag_quire_to_p32";
                if (std.mem.eql(u8, builtin, "intCast") or std.mem.eql(u8, builtin, "floatCast") or std.mem.eql(u8, builtin, "truncate")) {
                    // Just emit the argument directly
                    try genExpr(ctx, c.args[0]);
                    return;
                }
                if (std.mem.eql(u8, builtin, "len")) {
                    // @len(x) -> x.len
                    try ctx.w("(");
                    try genExpr(ctx, c.args[0]);
                    try ctx.w(").len");
                    return;
                }
                break :blk builtin;
            };
            try ctx.w(c_fn);
            try ctx.w("(");
            for (c.args, 0..) |arg, i| {
                if (i > 0) try ctx.w(", ");
                try genExpr(ctx, arg);
            }
            try ctx.w(")");
            return;
        }
    }

    // Method call: callee is field access
    if (c.callee.* == .field) {
        const f = c.callee.field;
        // Check module alias FIRST (before method dispatch)
        if (f.base.* == .var_) {
            const mod_name = f.base.var_.name;
            if (ctx.s.modules.get(mod_name)) |_| {
                // Generic module fn: use the monomorphized name sema computed.
                if (c.inst_name) |iname| {
                    try ctx.w(try mangleGenericName(ctx.alloc, iname));
                } else {
                    try ctx.wf("{s}__{s}", .{ mod_name, f.fname });
                }
                try ctx.w("(");
                for (c.args, 0..) |arg, i| {
                    if (i > 0) try ctx.w(", ");
                    try genExpr(ctx, arg);
                }
                try ctx.w(")");
                return;
            }
        }
        // Method dispatch: TypeName_methodName(self, args...)
        const base_ty = ast.nodeType(f.base);
        if (base_ty) |bty| {
            // Check if fname is a closure field (not a method) — if so, call via closure protocol
            const field_ty = f.ty orelse "";
            if (std.mem.startsWith(u8, field_ty, "fn(")) {
                // Closure field call: (base.field).fn((base.field).env, args...)
                try ctx.w("(");
                try genExpr(ctx, f.base);
                try ctx.wf(".{s}).fn((", .{f.fname});
                try genExpr(ctx, f.base);
                try ctx.wf(".{s}).env", .{f.fname});
                for (c.args) |arg| {
                    try ctx.w(", ");
                    try genExpr(ctx, arg);
                }
                try ctx.w(")");
                return;
            }
            // For pointer types *T, strip the * for method dispatch (method is on T, not *T)
            const effective_bty = if (bty.len > 1 and bty[0] == '*') bty[1..] else bty;
            const ct = try ctype(ctx.alloc, effective_bty);
            try ctx.wf("{s}_{s}(", .{ ct, f.fname });
            try genExpr(ctx, f.base);
            for (c.args) |arg| {
                try ctx.w(", ");
                try genExpr(ctx, arg);
            }
            try ctx.w(")");
            return;
        }
        try genExpr(ctx, f.base);
        try ctx.wf(".{s}(", .{f.fname});
        for (c.args, 0..) |arg, i| {
            if (i > 0) try ctx.w(", ");
            try genExpr(ctx, arg);
        }
        try ctx.w(")");
        return;
    }

    // Generic instantiation
    if (c.inst_name) |iname| {
        // Convert generic name "unbox[i32]" → "unbox_i32"
        const c_iname = try mangleGenericName(ctx.alloc, iname);
        try ctx.w(c_iname);
        try ctx.w("(");
        // Look up the instantiated fn for param types
        const inst_fn_node = ctx.s.fns.get(iname) orelse ctx.s.fns.get(c_iname);
        for (c.args, 0..) |arg, i| {
            if (i > 0) try ctx.w(", ");
            // Check if named function being passed as closure param
            if (arg.* == .var_) {
                const vname = arg.var_.name;
                const arg_ty = ast.nodeType(arg) orelse "";
                if (std.mem.startsWith(u8, arg_ty, "fn(") and ctx.s.fns.get(vname) != null) {
                    const clo_ty = try ctypeClosure(ctx.alloc, arg_ty);
                    try emitThunk(ctx, vname, arg_ty, clo_ty);
                    try ctx.wf("({s}){{ &__thunk_{s}, (void*)0 }}", .{ clo_ty, vname });
                    continue;
                }
            }
            // Check if param is ?T and arg is non-optional
            if (inst_fn_node) |fn_node| {
                if (fn_node.* == .fn_decl) {
                    const fd = fn_node.fn_decl;
                    if (i < fd.params.len) {
                        const param_ty = fd.params[i].pty;
                        if (std.mem.startsWith(u8, param_ty, "?")) {
                            const inner = param_ty[1..];
                            const arg_ty = ast.nodeType(arg) orelse "";
                            const ct = try ctype(ctx.alloc, inner);
                            const mangle = try mangleType(ctx.alloc, ct);
                            try ctx.registerOpt(ct);
                            if (arg.* == .null_lit) {
                                try ctx.wf("(ZagOpt_{s}){{0, {{0}}}}", .{mangle});
                                continue;
                            } else if (!std.mem.startsWith(u8, arg_ty, "?")) {
                                try ctx.wf("(ZagOpt_{s}){{1, ", .{mangle});
                                try genExpr(ctx, arg);
                                try ctx.w("}");
                                continue;
                            }
                        }
                    }
                }
            }
            try genExpr(ctx, arg);
        }
        try ctx.w(")");
        return;
    }

    // Closure call: only for local variables holding closure fat-pointers,
    // NOT for named functions or builtins that happen to have fn(...) type.
    const callee_ty = ast.nodeType(c.callee);
    if (callee_ty) |cty| {
        if (std.mem.startsWith(u8, cty, "fn(")) {
            // Check if callee is a var_ pointing to a known named fn or builtin
            const is_named_fn = blk: {
                if (c.callee.* == .var_) {
                    const vname = c.callee.var_.name;
                    if (ctx.s.fns.get(vname) != null) break :blk true;
                    if (ctx.s.methods.get(vname) != null) break :blk true;
                    if (types.getBuiltin(vname) != null) break :blk true;
                }
                break :blk false;
            };
            if (!is_named_fn) {
                // fn(f32)f32 parameter — call via closure fat-pointer dispatch
                try ctx.w("(");
                try genExpr(ctx, c.callee);
                try ctx.w(").fn((");
                try genExpr(ctx, c.callee);
                try ctx.w(").env");
                for (c.args) |arg| {
                    try ctx.w(", ");
                    try genExpr(ctx, arg);
                }
                try ctx.w(")");
                return;
            }
        }
    }

    // Regular call
    try genExpr(ctx, c.callee);
    try ctx.w("(");
    for (c.args, 0..) |arg, i| {
        if (i > 0) try ctx.w(", ");
        if (c.opt_wrap) |wrap_ty| {
            const ct = try ctype(ctx.alloc, wrap_ty);
            const mangle = try mangleType(ctx.alloc, ct);
            try ctx.wf("(ZagOpt_{s}){{1, ", .{mangle});
            try genExpr(ctx, arg);
            try ctx.w("}");
        } else {
            // Check if named function being passed as closure param
            if (arg.* == .var_) {
                const vname = arg.var_.name;
                const arg_ty = ast.nodeType(arg) orelse "";
                if (std.mem.startsWith(u8, arg_ty, "fn(") and ctx.s.fns.get(vname) != null) {
                    // Generate a thunk wrapper
                    const clo_ty = try ctypeClosure(ctx.alloc, arg_ty);
                    try emitThunk(ctx, vname, arg_ty, clo_ty);
                    try ctx.wf("({s}){{ &__thunk_{s}, (void*)0 }}", .{ clo_ty, vname });
                    continue;
                }
            }
            // Check if callee expects ?T parameter and arg is non-optional
            if (c.callee.* == .var_) {
                const callee_name = c.callee.var_.name;
                if (ctx.s.fns.get(callee_name)) |fn_node| {
                    if (fn_node.* == .fn_decl) {
                        const fd = fn_node.fn_decl;
                        if (i < fd.params.len) {
                            const param_ty = fd.params[i].pty;
                            if (std.mem.startsWith(u8, param_ty, "?")) {
                                const inner = param_ty[1..];
                                const arg_ty = ast.nodeType(arg) orelse "";
                                const ct = try ctype(ctx.alloc, inner);
                                const mangle = try mangleType(ctx.alloc, ct);
                                try ctx.registerOpt(ct);
                                if (arg.* == .null_lit) {
                                    try ctx.wf("(ZagOpt_{s}){{0, {{0}}}}", .{mangle});
                                } else if (!std.mem.startsWith(u8, arg_ty, "?")) {
                                    try ctx.wf("(ZagOpt_{s}){{1, ", .{mangle});
                                    try genExpr(ctx, arg);
                                    try ctx.w("}");
                                } else {
                                    try genExpr(ctx, arg);
                                }
                                continue;
                            }
                        }
                    }
                }
            }
            try genExpr(ctx, arg);
        }
    }
    try ctx.w(")");
}

fn genField(ctx: *Ctx, f: ast.Field) !void {
    // Pointer dereference: expr.* → (*expr)
    if (std.mem.eql(u8, f.fname, "*")) {
        try ctx.w("(*");
        try genExpr(ctx, f.base);
        try ctx.w(")");
        return;
    }

    if (f.base.* == .var_) {
        const base_name = f.base.var_.name;
        if (ctx.s.enums.get(base_name)) |_| {
            try ctx.wf("{s}_{s}", .{ base_name, f.fname });
            return;
        }
    }

    // Auto-deref: if base has pointer type *T, use -> instead of .
    const base_ty = ast.nodeType(f.base) orelse "";
    if (base_ty.len > 1 and base_ty[0] == '*') {
        try genExpr(ctx, f.base);
        try ctx.wf("->{s}", .{f.fname});
        return;
    }

    try ctx.w("(");
    try genExpr(ctx, f.base);
    try ctx.wf(").{s}", .{f.fname});
}

fn genIndex(ctx: *Ctx, idx: ast.Index) !void {
    const bt = ast.nodeType(idx.base) orelse "";
    // Pointer indexing: C pointers index natively, no .ptr field.
    if (bt.len > 0 and bt[0] == '*') {
        try ctx.w("(");
        try genExpr(ctx, idx.base);
        try ctx.w(")[(");
        try genExpr(ctx, idx.idx);
        try ctx.w(")]");
        return;
    }
    // Slice indexing: slices are { ptr, len } structs.
    try ctx.w("(");
    try genExpr(ctx, idx.base);
    try ctx.w(").ptr[(");
    try genExpr(ctx, idx.idx);
    try ctx.w(")]");
}

/// Register ZagOpt_/ZagResult_ typedefs implied by a fn signature's
/// `?T` / `!T` return and parameter types.
fn registerSigOptResult(ctx: *Ctx, ret: []const u8, params: []const ast.Param) !void {
    if (std.mem.startsWith(u8, ret, "!")) {
        try ctx.registerResult(try ctype(ctx.alloc, ret[1..]));
    } else if (std.mem.startsWith(u8, ret, "?")) {
        try ctx.registerOpt(try ctype(ctx.alloc, ret[1..]));
    }
    for (params) |p| {
        if (std.mem.startsWith(u8, p.pty, "!")) {
            try ctx.registerResult(try ctype(ctx.alloc, p.pty[1..]));
        } else if (std.mem.startsWith(u8, p.pty, "?")) {
            try ctx.registerOpt(try ctype(ctx.alloc, p.pty[1..]));
        }
    }
}

fn genSlice(ctx: *Ctx, sl: ast.Slice) !void {
    const bt = ast.nodeType(sl.base) orelse "[]u8";
    const is_ptr = bt.len > 0 and bt[0] == '*';
    const result_zty = if (is_ptr)
        try std.fmt.allocPrint(ctx.alloc, "[]{s}", .{bt[1..]})
    else
        bt;
    try ctx.ensureSpecialSliceTypedef(result_zty);
    const slice_ct = try ctype(ctx.alloc, result_zty);
    try ctx.wf("({s}){{ (", .{slice_ct});
    try genExpr(ctx, sl.base);
    if (is_ptr) try ctx.w(")") else try ctx.w(").ptr");
    try ctx.w(" + (");
    try genExpr(ctx, sl.lo);
    try ctx.w("), (");
    if (sl.has_hi) {
        try genExpr(ctx, sl.hi);
    } else {
        // open-ended base[lo..] → length is base.len - lo (slices only)
        try ctx.w("(");
        try genExpr(ctx, sl.base);
        try ctx.w(").len");
    }
    try ctx.w(") - (");
    try genExpr(ctx, sl.lo);
    try ctx.w(") }");
}

fn genCast(ctx: *Ctx, c: ast.Cast) !void {
    const ct = try ctype(ctx.alloc, c.target);
    try ctx.wf("(({s})(", .{ct});
    try genExpr(ctx, c.expr);
    try ctx.w("))");
}

fn genStructLit(ctx: *Ctx, sl: ast.StructLit) !void {
    const sname = sl.inst_sname orelse sl.sname;
    // Resolve generic type applications and dot-separated names
    const c_sname = blk: {
        // If the name contains '[', it's a generic application - use ctype to resolve
        if (std.mem.indexOfScalar(u8, sname, '[') != null) {
            break :blk try ctype(ctx.alloc, sname);
        }
        const dup = try ctx.alloc.dupe(u8, sname);
        for (dup) |*c| {
            if (c.* == '.') c.* = '_';
        }
        break :blk dup;
    };

    // Check if this is a union — if so, emit special tagged union literal
    if (ctx.s.unions.get(c_sname)) |_| {
        // Union literal: fields should be exactly one field (the variant)
        if (sl.fields.len == 1) {
            const fi = sl.fields[0];
            try ctx.wf("({s}){{ .tag = {s}_{s}, .u = {{ .{s} = ", .{ c_sname, c_sname, fi.name, fi.name });
            try genExpr(ctx, fi.val);
            try ctx.w(" } }");
            return;
        }
    }

    try ctx.wf("({s}){{", .{c_sname});
    for (sl.fields, 0..) |fi, i| {
        if (i > 0) try ctx.w(", ");
        try ctx.wf(" .{s} = ", .{fi.name});
        // If the field type is ?T and the expression is not null/optional, auto-wrap in Some
        const field_zty = ctx.s.fieldTypeOf(sname, fi.name);
        const needs_opt_wrap = blk: {
            const fzty = field_zty orelse break :blk false;
            if (fzty.len < 2 or fzty[0] != '?') break :blk false;
            // The value itself: if it's a null literal it already handles wrapping
            const val_ty = ast.nodeType(fi.val);
            if (val_ty) |vt| {
                if (vt.len > 0 and vt[0] == '?') break :blk false; // already optional
            }
            if (fi.val.* == .null_lit) break :blk false; // handled by genNullLit
            break :blk true;
        };
        if (needs_opt_wrap) {
            const fzty = field_zty.?;
            const inner_zty = fzty[1..]; // strip '?'
            const inner_c = try ctype(ctx.alloc, inner_zty);
            const mangle = try mangleType(ctx.alloc, inner_c);
            try ctx.registerOpt(inner_c);
            try ctx.wf("(ZagOpt_{s}){{1, ", .{mangle});
            try genExpr(ctx, fi.val);
            try ctx.w("}");
        } else {
            try genExpr(ctx, fi.val);
        }
    }
    try ctx.w(" }");
}

fn genNullLit(ctx: *Ctx, nl: ast.NullLit) !void {
    if (nl.ty) |ty| {
        if (ty.len > 1 and ty[0] == '?') {
            const inner = ty[1..];
            const ct = try ctype(ctx.alloc, inner);
            const mangle = try mangleType(ctx.alloc, ct);
            try ctx.registerOpt(ct);
            try ctx.wf("(ZagOpt_{s}){{0, {{0}}}}", .{mangle});
            return;
        }
    }
    try ctx.w("0");
}

fn genErrLit(ctx: *Ctx, el: ast.ErrLit) !void {
    try ctx.wf("ZAG_ERR_{s}", .{el.errname});
}

fn genTry(ctx: *Ctx, inner: ast.NodeRef) !void {
    const n = ctx.try_counter;
    ctx.try_counter += 1;

    // The inner expression has type "!T". The result struct type is ZagResult_<ctype(T)>.
    const inner_ty = ast.nodeType(inner);
    var result_ct: []const u8 = "ZagResult_int32_t";
    if (inner_ty) |ity| {
        // ity is "!T" or just "T" depending on sema. Normalize.
        const unwrapped = if (ity.len > 0 and ity[0] == '!') ity[1..] else ity;
        const ct = try ctype(ctx.alloc, unwrapped);
        const mangle = try mangleType(ctx.alloc, ct);
        result_ct = try std.fmt.allocPrint(ctx.alloc, "ZagResult_{s}", .{mangle});
        try ctx.registerResult(ct);
    }

    try ctx.wf("({{ {s} __try{d} = ", .{ result_ct, n });
    try genExpr(ctx, inner);
    if (std.mem.startsWith(u8, ctx.cur_fn_ret, "!")) {
        // Propagate error up: return a ZagResult wrapping the error
        const ret_inner = ctx.cur_fn_ret[1..];
        const ret_inner_ct = try ctype(ctx.alloc, ret_inner);
        const ret_mangle = try mangleType(ctx.alloc, ret_inner_ct);
        try ctx.wf("; if (__try{d}._err) return (ZagResult_{s}){{__try{d}._err, {{0}}}}; __try{d}._val; }})", .{ n, ret_mangle, n, n });
    } else {
        // Not in an error-returning function: panic on error
        try ctx.wf("; if (__try{d}._err) {{ fprintf(stderr, \"error: %d\\n\", __try{d}._err); exit(1); }} __try{d}._val; }})", .{ n, n, n });
    }
}

fn genCatch(ctx: *Ctx, c: ast.Catch) !void {
    const n = ctx.try_counter;
    ctx.try_counter += 1;

    const inner_ty = ast.nodeType(c.expr);
    var result_ct: []const u8 = "ZagResult_int32_t";
    if (inner_ty) |ity| {
        const unwrapped = if (ity.len > 0 and ity[0] == '!') ity[1..] else ity;
        const ct = try ctype(ctx.alloc, unwrapped);
        const mangle = try mangleType(ctx.alloc, ct);
        result_ct = try std.fmt.allocPrint(ctx.alloc, "ZagResult_{s}", .{mangle});
        try ctx.registerResult(ct);
    }

    try ctx.wf("({{ {s} __try{d} = ", .{ result_ct, n });
    try genExpr(ctx, c.expr);
    try ctx.w("; ");

    if (c.cap) |cap| {
        try ctx.wf("__try{d}._err ? ({{ ZagErrCode {s} = __try{d}._err; ", .{ n, cap, n });
        try genExpr(ctx, c.default);
        try ctx.wf("; }}) : __try{d}._val; }})", .{n});
    } else {
        try ctx.wf("__try{d}._err ? (", .{n});
        try genExpr(ctx, c.default);
        try ctx.wf(") : __try{d}._val; }})", .{n});
    }
}

fn genOrElse(ctx: *Ctx, oe: ast.OrElse) !void {
    const n = ctx.or_counter;
    ctx.or_counter += 1;

    const inner_ty = ast.nodeType(oe.expr);
    var opt_ct: []const u8 = "ZagOpt_int32_t";
    if (inner_ty) |ity| {
        const unwrapped = if (ity.len > 0 and ity[0] == '?') ity[1..] else ity;
        const ct = try ctype(ctx.alloc, unwrapped);
        const mangle = try mangleType(ctx.alloc, ct);
        opt_ct = try std.fmt.allocPrint(ctx.alloc, "ZagOpt_{s}", .{mangle});
        try ctx.registerOpt(ct);
    }

    try ctx.wf("({{ {s} __or{d} = ", .{ opt_ct, n });
    try genExpr(ctx, oe.expr);
    try ctx.wf("; __or{d}._has ? __or{d}._val : (", .{ n, n });
    try genExpr(ctx, oe.default);
    try ctx.w("); })");
}

fn genForceUnwrap(ctx: *Ctx, inner: ast.NodeRef) !void {
    const n = ctx.fu_counter;
    ctx.fu_counter += 1;

    const inner_ty = ast.nodeType(inner);
    var opt_ct: []const u8 = "ZagOpt_int32_t";
    if (inner_ty) |ity| {
        const unwrapped = if (ity.len > 0 and ity[0] == '?') ity[1..] else ity;
        const ct = try ctype(ctx.alloc, unwrapped);
        const mangle = try mangleType(ctx.alloc, ct);
        opt_ct = try std.fmt.allocPrint(ctx.alloc, "ZagOpt_{s}", .{mangle});
        try ctx.registerOpt(ct);
    }

    try ctx.wf("({{ {s} __fu{d} = ", .{ opt_ct, n });
    try genExpr(ctx, inner);
    try ctx.wf("; assert(__fu{d}._has && \"force unwrap of null\"); __fu{d}._val; }})", .{ n, n });
}

/// If node is an expr_stmt, return the inner expression; otherwise return node itself.
fn extractExprFromStmt(node: ast.NodeRef) ast.NodeRef {
    if (node.* == .expr_stmt) return node.expr_stmt.expr;
    if (node.* == .return_) {
        if (node.return_.expr) |e| return e;
    }
    return node;
}

fn genSwitchExpr(ctx: *Ctx, sw: ast.Switch) !void {
    const n = ctx.sw_counter;
    ctx.sw_counter += 1;

    const raw_ty = sw.switch_ty orelse "int32_t";
    const result_ty = types.defaultTy(raw_ty);
    const result_ct = try ctype(ctx.alloc, result_ty);
    const subj_ty = ast.nodeType(sw.subject);
    const subj_ct = if (subj_ty) |sty| try ctype(ctx.alloc, sty) else "int32_t";

    const is_union_sw = if (subj_ty) |sty| ctx.s.unions.get(sty) != null else false;

    try ctx.wf("(__extension__({{ {s} __sw{d} = ", .{ subj_ct, n });
    try genExpr(ctx, sw.subject);
    if (is_union_sw) {
        try ctx.wf("; {s} __swval{d}; switch (__sw{d}.tag) {{ ", .{ result_ct, n, n });
    } else {
        try ctx.wf("; {s} __swval{d}; switch (__sw{d}) {{ ", .{ result_ct, n, n });
    }

    for (sw.arms) |arm| {
        for (arm.tags) |tag| {
            if (subj_ty) |sty| {
                if (ctx.s.enums.get(sty)) |_| {
                    try ctx.wf("case {s}_{s}: ", .{ sty, tag });
                } else if (ctx.s.unions.get(sty)) |_| {
                    try ctx.wf("case {s}_{s}: ", .{ sty, tag });
                } else {
                    try ctx.wf("case {s}: ", .{tag});
                }
            } else {
                try ctx.wf("case {s}: ", .{tag});
            }
        }
        // arm.body may contain an expr_stmt wrapping the value, or a bare expr
        if (arm.cap != null) {
            // Switch expression with capture — emit block with capture binding
            if (arm.cap) |cap_name| {
                if (subj_ty) |sty| {
                    if (ctx.s.unions.get(sty)) |union_node| {
                        const ud = union_node.union_decl;
                        const tag0 = arm.tags[0];
                        // Find field type for this variant
                        var field_ct: []const u8 = subj_ct;
                        for (ud.fields) |f| {
                            if (std.mem.eql(u8, f.name, tag0)) {
                                field_ct = try ctype(ctx.alloc, f.pty);
                                break;
                            }
                        }
                        try ctx.wf("{{ {s} {s} = __sw{d}.u.{s}; ", .{ field_ct, cap_name, n, tag0 });
                        // emit assignment to result from body
                        if (arm.body.len > 0) {
                            const expr_node = extractExprFromStmt(arm.body[arm.body.len - 1]);
                            try ctx.wf("__swval{d} = ", .{n});
                            try genExpr(ctx, expr_node);
                            try ctx.w(";");
                        }
                        try ctx.w(" break; } ");
                        continue;
                    }
                }
                // Non-union with capture
                try ctx.wf("{{ {s} {s} = __sw{d}; ", .{ subj_ct, cap_name, n });
            }
        }
        try ctx.wf("{{ __swval{d} = ", .{n});
        if (arm.body.len > 0) {
            const expr_node = extractExprFromStmt(arm.body[arm.body.len - 1]);
            try genExpr(ctx, expr_node);
        } else {
            try ctx.w("0");
        }
        try ctx.w("; break; } ");
    }
    if (sw.els) |els_body| {
        try ctx.wf("default: {{ __swval{d} = ", .{n});
        if (els_body.len > 0) {
            const expr_node = extractExprFromStmt(els_body[els_body.len - 1]);
            try genExpr(ctx, expr_node);
        } else {
            try ctx.w("0");
        }
        try ctx.w("; break; } ");
    }
    try ctx.wf("}} __swval{d}; }}))", .{n});
}

fn genClosureExpr(ctx: *Ctx, cl: ast.Closure) !void {
    const n = ctx.clos_counter;
    ctx.clos_counter += 1;

    try emitClosureDef(ctx, cl, n);

    const ret_ct = try ctype(ctx.alloc, cl.ret);
    var param_m = std.ArrayList(u8).init(ctx.alloc);
    defer param_m.deinit();
    for (cl.params) |p| {
        const pc = try ctype(ctx.alloc, p.pty);
        const pm = try mangleType(ctx.alloc, pc);
        try param_m.append('_');
        try param_m.appendSlice(pm);
    }
    const ret_m = try mangleType(ctx.alloc, ret_ct);
    const clo_ty = try std.fmt.allocPrint(ctx.alloc, "ZagClo_{s}_{s}", .{ ret_m, param_m.items });

    // Stack-allocated closure env (compound literal address)
    try ctx.wf("({s}){{ &__clos_{d}_fn, &(__ClosEnv_{d}){{", .{ clo_ty, n, n });
    for (cl.caps, 0..) |cap, ci| {
        if (ci > 0) try ctx.w(", ");
        try ctx.wf(" .{s} = {s}", .{ cap, cap });
    }
    try ctx.w(" } }");
}

fn emitClosureDef(ctx: *Ctx, cl: ast.Closure, n: u32) !void {
    const fwd_writer = ctx.closures_fwd.writer();
    const impl_writer = ctx.closures_impl.writer();

    const ret_ct = try ctype(ctx.alloc, cl.ret);

    // Build closure type name
    var param_m = std.ArrayList(u8).init(ctx.alloc);
    defer param_m.deinit();
    for (cl.params) |p| {
        const pc = try ctype(ctx.alloc, p.pty);
        const pm = try mangleType(ctx.alloc, pc);
        try param_m.append('_');
        try param_m.appendSlice(pm);
    }
    const ret_m = try mangleType(ctx.alloc, ret_ct);
    const clo_ty_name = try std.fmt.allocPrint(ctx.alloc, "ZagClo_{s}_{s}", .{ ret_m, param_m.items });

    // Emit: typedef struct { RetType (*fn)(void*, Params...); void* env; } ZagClo_ret_params;
    // Dedup: only emit once per unique type name
    if (!ctx.emitted_clo_types.contains(clo_ty_name)) {
        try ctx.emitted_clo_types.put(try ctx.alloc.dupe(u8, clo_ty_name), {});
        const td_writer = ctx.clo_typedefs.writer();
        try td_writer.print("typedef struct {{ {s} (*fn)(void*", .{ret_ct});
        for (cl.params) |p| {
            const pc = try ctype(ctx.alloc, p.pty);
            try td_writer.print(", {s}", .{pc});
        }
        try td_writer.print("); void* env; }} {s};\n", .{clo_ty_name});
    }

    // Emit env struct
    try fwd_writer.print("typedef struct {{", .{});
    for (cl.caps) |cap| {
        var it2 = cl.cap_types.iterator();
        while (it2.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, cap)) {
                const ct = try ctype(ctx.alloc, entry.value_ptr.*);
                try fwd_writer.print(" {s} {s};", .{ ct, cap });
                break;
            }
        }
    }
    // If cap_types is empty but caps exist, use int32_t as fallback
    if (cl.cap_types.count() == 0 and cl.caps.len > 0) {
        for (cl.caps) |cap| {
            try fwd_writer.print(" int32_t {s};", .{cap});
        }
    }
    try fwd_writer.print(" }} __ClosEnv_{d};\n", .{n});

    // Forward decl for the closure function
    try fwd_writer.print("static {s} __clos_{d}_fn(void*", .{ ret_ct, n });
    for (cl.params) |p| {
        const pc = try ctype(ctx.alloc, p.pty);
        try fwd_writer.print(", {s}", .{pc});
    }
    try fwd_writer.print(");\n", .{});

    // Closure function implementation
    try impl_writer.print("static {s} __clos_{d}_fn(void* __envp", .{ ret_ct, n });
    for (cl.params) |p| {
        const pc = try ctype(ctx.alloc, p.pty);
        try impl_writer.print(", {s} {s}", .{ pc, p.name });
    }
    try impl_writer.print(") {{\n    __ClosEnv_{d}* __e = (__ClosEnv_{d}*)__envp;\n", .{ n, n });

    for (cl.caps) |cap| {
        var it2 = cl.cap_types.iterator();
        var found = false;
        while (it2.next()) |entry| {
            if (std.mem.eql(u8, entry.key_ptr.*, cap)) {
                const ct = try ctype(ctx.alloc, entry.value_ptr.*);
                try impl_writer.print("    {s} {s} = __e->{s};\n", .{ ct, cap, cap });
                found = true;
                break;
            }
        }
        if (!found) {
            try impl_writer.print("    int32_t {s} = __e->{s};\n", .{ cap, cap });
        }
    }

    const saved_buf = ctx.buf;
    const saved_ret = ctx.cur_fn_ret;
    const saved_indent = ctx.indent;
    ctx.buf = std.ArrayList(u8).init(ctx.alloc);
    ctx.cur_fn_ret = cl.ret;
    ctx.indent = 1;
    for (cl.body) |stmt| {
        try genStmt(ctx, stmt);
    }
    ctx.indent = saved_indent;
    const body_text = try ctx.buf.toOwnedSlice();
    ctx.buf = saved_buf;
    ctx.cur_fn_ret = saved_ret;
    try impl_writer.writeAll(body_text);
    try impl_writer.print("}}\n\n", .{});
}

/// Emit a thunk that wraps a named function as a closure. Example:
///   static float __thunk_softclip(void* __envp, float x) { (void)__envp; return softclip(x); }
fn emitThunk(ctx: *Ctx, fn_name: []const u8, fn_ty: []const u8, clo_ty: []const u8) !void {
    if (ctx.emitted_thunks.contains(fn_name)) return;
    try ctx.emitted_thunks.put(try ctx.alloc.dupe(u8, fn_name), {});

    // Parse fn_ty "fn(P1,P2,...)RET"
    const paren_start = std.mem.indexOfScalar(u8, fn_ty, '(') orelse return;
    const paren_end = blk: {
        var depth: i32 = 0;
        var j: usize = paren_start;
        while (j < fn_ty.len) : (j += 1) {
            if (fn_ty[j] == '(') depth += 1
            else if (fn_ty[j] == ')') {
                depth -= 1;
                if (depth == 0) break :blk j;
            }
        }
        return;
    };
    const params_str = fn_ty[paren_start + 1 .. paren_end];
    const ret_zty = fn_ty[paren_end + 1 ..];
    const ret_ct = try ctype(ctx.alloc, ret_zty);

    const w = ctx.thunks.writer();

    // Forward decl to closures_fwd
    const fwd = ctx.closures_fwd.writer();
    try fwd.print("static {s} __thunk_{s}(void*", .{ ret_ct, fn_name });
    // parse param types
    var param_names = std.ArrayList([]const u8).init(ctx.alloc);
    defer param_names.deinit();
    var param_cts = std.ArrayList([]const u8).init(ctx.alloc);
    defer param_cts.deinit();

    if (params_str.len > 0) {
        var idx: usize = 0;
        var depth: i32 = 0;
        var seg_start: usize = 0;
        while (idx <= params_str.len) : (idx += 1) {
            const ch = if (idx < params_str.len) params_str[idx] else ',';
            if (ch == '(' or ch == '[') depth += 1
            else if (ch == ')' or ch == ']') depth -= 1
            else if (ch == ',' and depth == 0) {
                const seg = std.mem.trim(u8, params_str[seg_start..idx], " ");
                if (seg.len > 0) {
                    const pct = try ctype(ctx.alloc, seg);
                    const pname = try std.fmt.allocPrint(ctx.alloc, "p{d}", .{param_names.items.len});
                    try param_cts.append(pct);
                    try param_names.append(pname);
                }
                seg_start = idx + 1;
            }
        }
    }

    for (param_cts.items) |pct| {
        try fwd.print(", {s}", .{pct});
    }
    try fwd.print(");\n", .{});

    // Emit typedef for clo type if needed
    if (!ctx.emitted_clo_types.contains(clo_ty)) {
        try ctx.emitted_clo_types.put(try ctx.alloc.dupe(u8, clo_ty), {});
        const td = ctx.clo_typedefs.writer();
        try td.print("typedef struct {{ {s} (*fn)(void*", .{ret_ct});
        for (param_cts.items) |pct| {
            try td.print(", {s}", .{pct});
        }
        try td.print("); void* env; }} {s};\n", .{clo_ty});
    }

    // Implementation
    try w.print("static {s} __thunk_{s}(void* __envp", .{ ret_ct, fn_name });
    for (param_cts.items, param_names.items) |pct, pn| {
        try w.print(", {s} {s}", .{ pct, pn });
    }
    try w.print(") {{\n    (void)__envp; return {s}(", .{fn_name});
    for (param_names.items, 0..) |pn, k| {
        if (k > 0) try w.print(", ", .{});
        try w.print("{s}", .{pn});
    }
    try w.print(");\n}}\n\n", .{});
}

// ── Statement codegen ─────────────────────────────────────────────────────────

fn genStmt(ctx: *Ctx, node: ast.NodeRef) anyerror!void {
    switch (node.*) {
        .let => |l| try genLet(ctx, l),
        .assign => |a| try genAssign(ctx, a),
        .return_ => |r| try genReturn(ctx, r),
        .if_ => |i| try genIf(ctx, i),
        .while_ => |w| try genWhile(ctx, w),
        .expr_stmt => |e| try genExprStmt(ctx, e),
        .switch_ => |sw| try genSwitchStmt(ctx, sw),
        else => {},
    }
}

fn genLet(ctx: *Ctx, l: ast.Let) !void {
    const ty = l.dty orelse (ast.nodeType(l.expr) orelse "int32_t");
    const resolved_ty = resolveGenericType(ty);
    // For fn(...)RET types, ensure the closure typedef is emitted
    const ct = if (std.mem.startsWith(u8, resolved_ty, "fn("))
        try ctx.ensureClosureTypedef(resolved_ty)
    else
        try ctype(ctx.alloc, resolved_ty);

    // Generate the RHS expression into a scratch buffer so that any new() calls
    // can emit their pre-statements first (before this let line).
    const saved_buf = ctx.buf;
    ctx.buf = std.ArrayList(u8).init(ctx.alloc);

    // Set type hint for new() calls: if declared type is *T, hint T as the alloc type
    const saved_hint = ctx.new_type_hint;
    if (resolved_ty.len > 1 and resolved_ty[0] == '*') {
        ctx.new_type_hint = resolved_ty[1..];
    }

    // Auto-wrap: if let type is ?T and expr is not null/optional, wrap in Some
    if (std.mem.startsWith(u8, resolved_ty, "?")) {
        const inner = resolved_ty[1..];
        const inner_ct = try ctype(ctx.alloc, inner);
        const mangle = try mangleType(ctx.alloc, inner_ct);
        try ctx.registerOpt(inner_ct);
        if (l.expr.* == .null_lit) {
            try ctx.wf("(ZagOpt_{s}){{0, {{0}}}}", .{mangle});
        } else {
            const expr_ty = ast.nodeType(l.expr) orelse "";
            // If expr already has optional type, emit directly
            if (std.mem.startsWith(u8, expr_ty, "?")) {
                try genExpr(ctx, l.expr);
            } else {
                try ctx.wf("(ZagOpt_{s}){{1, ", .{mangle});
                try genExpr(ctx, l.expr);
                try ctx.w("}");
            }
        }
    } else if (std.mem.startsWith(u8, resolved_ty, "rns_")) {
        // RNS type: auto-coerce int literals via zag_rns_from_i64
        const expr_ty = ast.nodeType(l.expr) orelse "";
        if (l.expr.* == .lit or std.mem.eql(u8, expr_ty, "i32") or std.mem.eql(u8, expr_ty, "i64") or std.mem.eql(u8, expr_ty, "int_lit")) {
            try ctx.w("zag_rns_from_i64(");
            try genExpr(ctx, l.expr);
            try ctx.w(")");
        } else {
            try genExpr(ctx, l.expr);
        }
    } else if (std.mem.startsWith(u8, resolved_ty, "fn(")) {
        // Assigning a named fn to a closure variable — auto-wrap with thunk
        if (l.expr.* == .var_) {
            const vname = l.expr.var_.name;
            const expr_ty = ast.nodeType(l.expr) orelse "";
            if (ctx.s.fns.get(vname) != null and std.mem.startsWith(u8, expr_ty, "fn(")) {
                try emitThunk(ctx, vname, expr_ty, ct);
                try ctx.wf("({s}){{ &__thunk_{s}, (void*)0 }}", .{ ct, vname });
            } else {
                try genExpr(ctx, l.expr);
            }
        } else {
            try genExpr(ctx, l.expr);
        }
    } else {
        try genExpr(ctx, l.expr);
    }

    const rhs_text = try ctx.buf.toOwnedSlice();
    ctx.buf = saved_buf;
    ctx.new_type_hint = saved_hint;

    // Flush any pre-statements accumulated during expression codegen (e.g. new())
    try ctx.flushPreStmts();
    try ctx.wIndent();
    try ctx.wf("{s} {s} = {s};\n", .{ ct, l.name, rhs_text });
}

/// Resolve generic type applications like "Box[i32]" → "Box_i32"
fn resolveGenericType(ty: []const u8) []const u8 {
    // If it contains '[' and ends with ']', it's a generic application
    // We can't allocate here without alloc param; caller must handle via ctype
    return ty;
}

/// Convert a generic fn/type name like "unbox[i32]" → "unbox_i32"
/// Replaces '[' with '_', removes ']', replaces ',' with '_'
fn mangleGenericName(alloc: std.mem.Allocator, name: []const u8) ![]const u8 {
    if (std.mem.indexOfScalar(u8, name, '[') == null) return name;
    var result = std.ArrayList(u8).init(alloc);
    defer result.deinit();
    for (name) |c| {
        switch (c) {
            '*' => try result.append('p'),
            '?' => try result.append('o'),
            '!' => try result.append('e'),
            '[', ',', '.', '<' => try result.append('_'),
            ']', '>', ' ' => {}, // dropped
            else => try result.append(c),
        }
    }
    return result.toOwnedSlice();
}

fn genAssign(ctx: *Ctx, a: ast.Assign) !void {
    // Generate into scratch buffer first so new() pre-stmts are flushed before the line
    const saved_buf = ctx.buf;
    ctx.buf = std.ArrayList(u8).init(ctx.alloc);
    try genExpr(ctx, a.target);
    try ctx.w(" = ");
    try genExpr(ctx, a.expr);
    const line_text = try ctx.buf.toOwnedSlice();
    ctx.buf = saved_buf;
    try ctx.flushPreStmts();
    try ctx.wIndent();
    try ctx.wf("{s};\n", .{line_text});
}

fn genReturn(ctx: *Ctx, r: ast.Return) !void {
    if (r.expr) |expr| {
        // Generate the return line into a scratch buffer so new() pre-stmts flush before it
        const saved_buf = ctx.buf;
        ctx.buf = std.ArrayList(u8).init(ctx.alloc);
        if (std.mem.startsWith(u8, ctx.cur_fn_ret, "!")) {
            const inner = ctx.cur_fn_ret[1..];
            const ct = try ctype(ctx.alloc, inner);
            const mangle = try mangleType(ctx.alloc, ct);
            try ctx.registerResult(ct);
            try ctx.wf("return (ZagResult_{s}){{0, ", .{mangle});
            try genExpr(ctx, expr);
            try ctx.w("};");
        } else if (std.mem.startsWith(u8, ctx.cur_fn_ret, "?")) {
            const inner = ctx.cur_fn_ret[1..];
            const ct = try ctype(ctx.alloc, inner);
            const mangle = try mangleType(ctx.alloc, ct);
            try ctx.registerOpt(ct);
            if (expr.* == .null_lit) {
                try ctx.wf("return (ZagOpt_{s}){{0, {{0}}}};", .{mangle});
            } else {
                try ctx.wf("return (ZagOpt_{s}){{1, ", .{mangle});
                try genExpr(ctx, expr);
                try ctx.w("};");
            }
        } else if (std.mem.startsWith(u8, ctx.cur_fn_ret, "fn(")) {
            const clo_ty = try ctx.ensureClosureTypedef(ctx.cur_fn_ret);
            if (expr.* == .var_) {
                const vname = expr.var_.name;
                if (ctx.s.fns.get(vname) != null) {
                    const expr_ty = ast.nodeType(expr) orelse ctx.cur_fn_ret;
                    try emitThunk(ctx, vname, expr_ty, clo_ty);
                    try ctx.wf("return ({s}){{ &__thunk_{s}, (void*)0 }};", .{ clo_ty, vname });
                } else {
                    try ctx.w("return ");
                    try genExpr(ctx, expr);
                    try ctx.w(";");
                }
            } else {
                try ctx.w("return ");
                try genExpr(ctx, expr);
                try ctx.w(";");
            }
        } else {
            try ctx.w("return ");
            try genExpr(ctx, expr);
            try ctx.w(";");
        }
        const line_text = try ctx.buf.toOwnedSlice();
        ctx.buf = saved_buf;
        try ctx.flushPreStmts();
        try ctx.wIndent();
        try ctx.wf("{s}\n", .{line_text});
    } else {
        try ctx.flushPreStmts();
        try ctx.wIndent();
        if (std.mem.eql(u8, ctx.cur_fn_ret, "void")) {
            try ctx.w("return;\n");
        } else {
            try ctx.w("return 0;\n");
        }
    }
}

fn genIf(ctx: *Ctx, i: ast.If) !void {
    try ctx.flushPreStmts();
    try ctx.wIndent();
    if (i.cap) |cap| {
        const cond_ty = ast.nodeType(i.cond) orelse "?void";
        const inner = if (cond_ty.len > 1 and cond_ty[0] == '?') cond_ty[1..] else cond_ty;
        const ct = try ctype(ctx.alloc, inner);
        const cond_ct = try ctype(ctx.alloc, cond_ty);
        try ctx.registerOpt(ct);
        try ctx.wf("{{ {s} __if_opt = ", .{cond_ct});
        try genExpr(ctx, i.cond);
        try ctx.wf("; if (__if_opt._has) {{ {s} {s} = __if_opt._val;\n", .{ ct, cap });
        ctx.indent += 1;
        for (i.then) |stmt| try genStmt(ctx, stmt);
        ctx.indent -= 1;
        try ctx.wIndent();
        try ctx.w("}");
        if (i.els) |els| {
            try ctx.w(" else {\n");
            ctx.indent += 1;
            for (els) |stmt| try genStmt(ctx, stmt);
            ctx.indent -= 1;
            try ctx.wIndent();
            try ctx.w("}");
        }
        try ctx.w(" }\n");
    } else {
        try ctx.w("if (");
        try genExpr(ctx, i.cond);
        try ctx.w(") {\n");
        ctx.indent += 1;
        for (i.then) |stmt| try genStmt(ctx, stmt);
        ctx.indent -= 1;
        try ctx.wIndent();
        try ctx.w("}");
        if (i.els) |els| {
            try ctx.w(" else {\n");
            ctx.indent += 1;
            for (els) |stmt| try genStmt(ctx, stmt);
            ctx.indent -= 1;
            try ctx.wIndent();
            try ctx.w("}");
        }
        try ctx.w("\n");
    }
}

fn genWhile(ctx: *Ctx, w: ast.While) !void {
    try ctx.flushPreStmts();
    try ctx.wIndent();
    if (w.cap) |cap| {
        const cond_ty = ast.nodeType(w.cond) orelse "?void";
        const inner = if (cond_ty.len > 1 and cond_ty[0] == '?') cond_ty[1..] else cond_ty;
        const ct = try ctype(ctx.alloc, inner);
        const cond_ct = try ctype(ctx.alloc, cond_ty);
        try ctx.registerOpt(ct);
        try ctx.wf("{{ {s} __while_opt; while ((__while_opt = ", .{cond_ct});
        try genExpr(ctx, w.cond);
        try ctx.wf(")._has) {{ {s} {s} = __while_opt._val;\n", .{ ct, cap });
        ctx.indent += 1;
        for (w.body) |stmt| try genStmt(ctx, stmt);
        ctx.indent -= 1;
        try ctx.wIndent();
        try ctx.w("} }\n");
    } else {
        try ctx.w("while (");
        try genExpr(ctx, w.cond);
        try ctx.w(") {\n");
        ctx.indent += 1;
        for (w.body) |stmt| try genStmt(ctx, stmt);
        ctx.indent -= 1;
        try ctx.wIndent();
        try ctx.w("}\n");
    }
}

fn genExprStmt(ctx: *Ctx, e: ast.ExprStmt) !void {
    // Generate into scratch buffer first so new() pre-stmts are flushed before the line
    const saved_buf = ctx.buf;
    ctx.buf = std.ArrayList(u8).init(ctx.alloc);
    try genExpr(ctx, e.expr);
    const line_text = try ctx.buf.toOwnedSlice();
    ctx.buf = saved_buf;
    try ctx.flushPreStmts();
    try ctx.wIndent();
    try ctx.wf("{s};\n", .{line_text});
}

fn genSwitchStmt(ctx: *Ctx, sw: ast.Switch) !void {
    try ctx.flushPreStmts();
    try ctx.wIndent();
    const subj_ty = ast.nodeType(sw.subject);
    const is_union = if (subj_ty) |sty| ctx.s.unions.get(sty) != null else false;

    // For union switches: store subject in temp, switch on .tag
    const sw_n = ctx.sw_counter;
    ctx.sw_counter += 1;

    if (is_union) {
        const sty = subj_ty.?;
        const ct = try ctype(ctx.alloc, sty);
        try ctx.wf("{{ {s} __sw{d} = ", .{ ct, sw_n });
        try genExpr(ctx, sw.subject);
        try ctx.wf(";\nswitch (__sw{d}.tag) {{\n", .{sw_n});
    } else {
        try ctx.w("{ ");
        if (subj_ty) |sty| {
            const ct = try ctype(ctx.alloc, sty);
            try ctx.wf("{s} __sw{d} = ", .{ ct, sw_n });
        } else {
            try ctx.wf("int32_t __sw{d} = ", .{sw_n});
        }
        try genExpr(ctx, sw.subject);
        try ctx.wf(";\nswitch (__sw{d}) {{\n", .{sw_n});
    }
    ctx.indent += 1;

    for (sw.arms) |arm| {
        for (arm.tags) |tag| {
            try ctx.wIndent();
            if (subj_ty) |sty| {
                if (ctx.s.enums.get(sty) != null or ctx.s.unions.get(sty) != null) {
                    try ctx.wf("case {s}_{s}:\n", .{ sty, tag });
                } else {
                    try ctx.wf("case {s}:\n", .{tag});
                }
            } else {
                try ctx.wf("case {s}:\n", .{tag});
            }
        }
        ctx.indent += 1;
        try ctx.wIndent();
        try ctx.w("{\n");
        ctx.indent += 1;
        // If union and has capture, bind payload
        if (is_union) {
            if (arm.cap) |cap_name| {
                const tag0 = arm.tags[0];
                if (subj_ty) |sty| {
                    // Find field type for this variant
                    if (ctx.s.unions.get(sty)) |union_node| {
                        const ud = union_node.union_decl;
                        for (ud.fields) |f| {
                            if (std.mem.eql(u8, f.name, tag0)) {
                                const fct = try ctype(ctx.alloc, f.pty);
                                try ctx.wIndent();
                                try ctx.wf("{s} {s} = __sw{d}.u.{s};\n", .{ fct, cap_name, sw_n, tag0 });
                                break;
                            }
                        }
                    }
                }
            }
        }
        for (arm.body) |stmt| try genStmt(ctx, stmt);
        ctx.indent -= 1;
        try ctx.wIndent();
        try ctx.w("}\n");
        try ctx.wIndent();
        try ctx.w("break;\n");
        ctx.indent -= 1;
    }

    if (sw.els) |els_body| {
        try ctx.wIndent();
        try ctx.w("default:\n");
        ctx.indent += 1;
        try ctx.wIndent();
        try ctx.w("{\n");
        ctx.indent += 1;
        for (els_body) |stmt| try genStmt(ctx, stmt);
        ctx.indent -= 1;
        try ctx.wIndent();
        try ctx.w("}\n");
        try ctx.wIndent();
        try ctx.w("break;\n");
        ctx.indent -= 1;
    }

    ctx.indent -= 1;
    try ctx.wIndent();
    try ctx.w("} }\n");
}

// ── Function codegen ──────────────────────────────────────────────────────────

fn isMainFn(f: ast.FnDecl) bool {
    return std.mem.eql(u8, f.name, "main") and f.recv_type == null;
}

fn fnCName(alloc: std.mem.Allocator, f: ast.FnDecl) ![]const u8 {
    if (f.recv_type) |rt| {
        const method = f.method_name orelse f.name;
        const mangled_method = try mangleGenericName(alloc, method);
        const mangled_rt = try mangleGenericName(alloc, rt);
        return std.fmt.allocPrint(alloc, "{s}_{s}", .{ mangled_rt, mangled_method });
    }
    return mangleGenericName(alloc, f.name);
}

fn genFnForwardDecl(ctx: *Ctx, f: ast.FnDecl) !void {
    if (f.tparams.len > 0) return;
    // Extern fn: emit a non-static C prototype with the literal (unmangled) name.
    // The definition is provided by the linked runtime (std/runtime.c) or libc.
    if (f.is_extern) {
        const eret = try ctype(ctx.alloc, f.ret);
        try ctx.wf("extern {s} {s}(", .{ eret, f.name });
        if (f.params.len == 0) {
            try ctx.w("void");
        } else {
            for (f.params, 0..) |p, i| {
                if (i > 0) try ctx.w(", ");
                try ctx.w(try ctype(ctx.alloc, p.pty));
            }
        }
        try ctx.w(");\n");
        return;
    }
    if (f.body == null) return;
    if (isMainFn(f)) return;

    const ret_ct = try ctype(ctx.alloc, f.ret);
    const fn_name = try fnCName(ctx.alloc, f);

    try ctx.wf("static {s} {s}(", .{ ret_ct, fn_name });
    var first = true;
    if (f.recv_type) |rt| {
        const rct = try ctype(ctx.alloc, rt);
        try ctx.w(rct);
        first = false;
    }
    for (f.params) |p| {
        if (!first) try ctx.w(", ");
        first = false;
        const pt = try ctype(ctx.alloc, p.pty);
        try ctx.w(pt);
    }
    if (first) {
        // no params
    }
    try ctx.w(");\n");
}

fn genFnBody(ctx: *Ctx, f: ast.FnDecl) !void {
    if (f.is_extern or f.body == null) return;
    if (f.tparams.len > 0) return;

    const is_main = isMainFn(f);
    const is_static = !is_main;

    // main always returns C int, not int32_t
    const ret_ct = if (is_main) "int" else try ctype(ctx.alloc, f.ret);
    const fn_name = try fnCName(ctx.alloc, f);

    if (is_static) {
        try ctx.wf("static {s} {s}(", .{ ret_ct, fn_name });
    } else {
        try ctx.wf("{s} {s}(", .{ ret_ct, fn_name });
    }

    if (is_main and f.params.len == 0) {
        try ctx.w("void");
    } else {
        if (f.recv_type) |rt| {
            const rct = try ctype(ctx.alloc, rt);
            try ctx.wf("{s} self", .{rct});
            if (f.params.len > 0) try ctx.w(", ");
        }
        for (f.params, 0..) |p, i| {
            if (i > 0) try ctx.w(", ");
            const pt = try ctype(ctx.alloc, p.pty);
            try ctx.wf("{s} {s}", .{ pt, p.name });
        }
    }
    try ctx.w(") {\n");
    ctx.indent = 1;
    ctx.cur_fn_ret = f.ret;

    const body = f.body.?;
    for (body) |stmt| {
        try genStmt(ctx, stmt);
    }

    if (is_main) {
        var has_return = false;
        if (body.len > 0) {
            if (body[body.len - 1].* == .return_) has_return = true;
        }
        if (!has_return) {
            try ctx.wIndent();
            try ctx.w("return 0;\n");
        }
    }

    ctx.indent = 0;
    try ctx.w("}\n\n");
}

// ── Top-level type declarations ────────────────────────────────────────────────

fn genStructDecl(ctx: *Ctx, sd: ast.StructDecl) !void {
    if (sd.tparams.len > 0) return;
    // Pre-emit closure typedefs for fn(...) fields
    for (sd.fields) |f| {
        if (std.mem.startsWith(u8, f.pty, "fn(")) {
            _ = try ctx.ensureClosureTypedef(f.pty);
        }
    }
    // Always emit with a named `<name>_tag` so it matches the forward typedef
    // declared earlier (enables mutually-recursive pointer fields).
    try ctx.wf("typedef struct {s}_tag {{", .{sd.name});
    for (sd.fields) |f| {
        const ct = if (std.mem.startsWith(u8, f.pty, "fn("))
            try ctx.ensureClosureTypedef(f.pty)
        else
            try ctype(ctx.alloc, f.pty);
        try ctx.wf(" {s} {s};", .{ ct, f.name });
    }
    try ctx.wf(" }} {s};\n", .{sd.name});
}

fn genEnumDecl(ctx: *Ctx, ed: ast.EnumDecl) !void {
    try ctx.wf("typedef enum {{", .{});
    for (ed.members, 0..) |m, i| {
        if (i > 0) try ctx.w(", ");
        try ctx.wf(" {s}_{s}", .{ ed.name, m });
    }
    try ctx.wf(" }} {s};\n", .{ed.name});
}

fn genUnionDecl(ctx: *Ctx, ud: ast.UnionDecl) !void {
    // Emit: enum { Name_A, Name_B, ... };
    try ctx.w("enum {");
    for (ud.fields, 0..) |f, i| {
        if (i > 0) try ctx.w(",");
        try ctx.wf(" {s}_{s}", .{ ud.name, f.name });
    }
    try ctx.w(" };\n");

    // Emit: typedef struct Name_tag { int32_t tag; union { Ta A; ... } u; } Name;
    // Named tag matches the forward typedef so other types can hold *Name.
    try ctx.wf("typedef struct {s}_tag {{ int32_t tag; union {{", .{ud.name});
    for (ud.fields) |f| {
        const ct = try ctype(ctx.alloc, f.pty);
        try ctx.wf(" {s} {s};", .{ ct, f.name });
    }
    try ctx.wf(" }} u; }} {s};\n", .{ud.name});
}

fn genErrorEnum(ctx: *Ctx) !void {
    if (ctx.s.err_names.items.len == 0) return;
    try ctx.w("typedef enum { ZAG_OK=0");
    for (ctx.s.err_names.items, 0..) |name, i| {
        try ctx.wf(", ZAG_ERR_{s}={d}", .{ name, i + 1 });
    }
    try ctx.w(" } ZagErrCode;\n");
}

// ── Main entry point ──────────────────────────────────────────────────────────

/// Generate C source for a CPU target.
pub fn gen(
    alloc: std.mem.Allocator,
    decls: []ast.NodeRef,
    s: *const sema_mod.Sema,
    target: []const u8,
) ![]const u8 {
    var ctx = Ctx.init(alloc, s, target);
    defer ctx.deinit();

    // 1. Prelude
    const prelude = getPrelude();
    try ctx.w(prelude);
    try ctx.w("\n");

    // 2. Error enum
    try genErrorEnum(&ctx);

    // 2b. Pre-emit closure typedefs needed by struct fields (must come before struct decls)
    for (decls) |node| {
        if (node.* == .struct_decl) {
            for (node.struct_decl.fields) |f| {
                if (std.mem.startsWith(u8, f.pty, "fn(")) {
                    _ = try ctx.ensureClosureTypedef(f.pty);
                }
            }
        }
    }
    if (ctx.clo_typedefs.items.len > 0) {
        try ctx.buf.appendSlice(ctx.clo_typedefs.items);
        ctx.clo_typedefs.clearRetainingCapacity();
    }

    // 3. Forward typedef declarations for ALL aggregate types (structs + unions),
    // so any *T / ?*T pointer field resolves regardless of declaration order or
    // mutual recursion (e.g. a recursive AST: struct Bin { l: *Node } union Node {...}).
    // Every struct/union body below emits with a matching `<name>_tag` tag.
    for (decls) |node| {
        switch (node.*) {
            .struct_decl => |sd| {
                if (sd.tparams.len > 0) continue;
                try ctx.wf("typedef struct {s}_tag {s};\n", .{ sd.name, sd.name });
            },
            .union_decl => |ud| {
                try ctx.wf("typedef struct {s}_tag {s};\n", .{ ud.name, ud.name });
            },
            else => {},
        }
    }
    // Forward decls for instantiated generic structs from s.structs.
    {
        var sit = s.structs.iterator();
        while (sit.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.* != .struct_decl) continue;
            if (node.struct_decl.tparams.len > 0) continue;
            const c_name = try ctype(ctx.alloc, entry.key_ptr.*);
            try ctx.wf("typedef struct {s}_tag {s};\n", .{ c_name, c_name });
        }
    }

    // 3c. Pre-emit ZagOpt_ typedefs for optional-pointer struct fields
    // These must come before the struct bodies that reference them.
    // Track which opt typedefs were pre-emitted so we don't re-emit them later.
    var pre_emitted_opts = std.StringHashMap(void).init(alloc);
    defer pre_emitted_opts.deinit();
    for (decls) |node| {
        if (node.* == .struct_decl) {
            const sd = node.struct_decl;
            if (sd.tparams.len > 0) continue;
            for (sd.fields) |f| {
                if (f.pty.len > 2 and f.pty[0] == '?' and f.pty[1] == '*') {
                    const inner_zty = f.pty[1..]; // e.g. "*Node"
                    const inner_c = try ctype(alloc, inner_zty); // e.g. "Node*"
                    const mangle = try mangleType(alloc, inner_c); // e.g. "Node_"
                    const opt_name = try std.fmt.allocPrint(alloc, "ZagOpt_{s}", .{mangle});
                    if (!pre_emitted_opts.contains(opt_name)) {
                        try pre_emitted_opts.put(try alloc.dupe(u8, opt_name), {});
                        try ctx.opt_types.put(try alloc.dupe(u8, opt_name), try alloc.dupe(u8, inner_c));
                        try ctx.wf("typedef struct {{ int32_t _has; {s} _val; }} {s};\n", .{ inner_c, opt_name });
                    }
                }
            }
        }
    }

    // 3b. Emit instantiated generic structs from s.structs FIRST — user structs
    // may contain them by value (e.g. struct Block { stmts: ArrayList[*Node] }),
    // so the generic's full definition must precede the user struct. Generics only
    // ever hold their element via *T (pointer), so they have no by-value dependency
    // on user types and are safe to emit before them.
    {
        var emitted_structs = std.StringHashMap(void).init(alloc);
        defer emitted_structs.deinit();
        for (decls) |node| {
            if (node.* == .struct_decl) {
                emitted_structs.put(node.struct_decl.name, {}) catch {};
            }
        }
        var sit = s.structs.iterator();
        while (sit.next()) |entry| {
            const inst_name = entry.key_ptr.*;
            const node = entry.value_ptr.*;
            if (node.* != .struct_decl) continue;
            // Skip if already emitted (non-generic structs already processed from decls)
            if (emitted_structs.contains(inst_name)) continue;
            const sd = node.struct_decl;
            // Convert sema name "Box[i32]" to C name "Box_i32"
            const c_name = try ctype(ctx.alloc, inst_name);
            // Emit with named `_tag` so it matches its forward typedef (enables
            // generic structs with self/mutual pointer fields, e.g. ArrayList[*Node]).
            try ctx.wf("typedef struct {s}_tag {{", .{c_name});
            for (sd.fields) |f| {
                const ft = try ctype(ctx.alloc, f.pty);
                try ctx.wf(" {s} {s};", .{ ft, f.name });
            }
            try ctx.wf(" }} {s};\n", .{c_name});
        }
    }
    // 3b. Type declarations (user structs/enums/unions, after instantiated generics)
    {
        for (decls) |node| {
            switch (node.*) {
                .struct_decl => |sd| try genStructDecl(&ctx, sd),
                .enum_decl => |ed| try genEnumDecl(&ctx, ed),
                .union_decl => |ud| try genUnionDecl(&ctx, ud),
                else => {},
            }
        }
    }

    // 4. Collect optional/result types from fn signatures, and closure typedefs for fn return types
    for (decls) |node| {
        if (node.* == .fn_decl) {
            const f = node.fn_decl;
            // Skip generic fns (tparams not yet substituted)
            if (f.tparams.len == 0) {
                // Pre-collect closure typedefs needed for fn return types
                if (std.mem.startsWith(u8, f.ret, "fn(")) {
                    _ = try ctx.ensureClosureTypedef(f.ret);
                }
                for (f.params) |p| {
                    if (std.mem.startsWith(u8, p.pty, "fn(")) {
                        _ = try ctx.ensureClosureTypedef(p.pty);
                    }
                    // Emit special slice typedefs for non-standard element types
                    if (std.mem.startsWith(u8, p.pty, "[]")) {
                        try ctx.ensureSpecialSliceTypedef(p.pty);
                    }
                }
                if (std.mem.startsWith(u8, f.ret, "[]")) {
                    try ctx.ensureSpecialSliceTypedef(f.ret);
                }
            }
            // Register optional/result typedefs from signature — but ONLY for
            // concrete (non-generic) fns; generic templates carry type-param
            // types like ?V that must never reach C (would emit `V _val`).
            if (f.tparams.len == 0) {
                try registerSigOptResult(&ctx, f.ret, f.params);
            }
        }
    }

    // 4a. Also register optional/result typedefs from instantiated generic fns
    //     in s.fns — these hold the concrete types (?i32 → ZagOpt_int32_t) and
    //     must be collected BEFORE the typedef section is emitted below.
    {
        var fit = s.fns.iterator();
        while (fit.next()) |entry| {
            const fn_node = entry.value_ptr.*;
            if (fn_node.* != .fn_decl) continue;
            const f = fn_node.fn_decl;
            if (f.tparams.len > 0) continue;
            try registerSigOptResult(&ctx, f.ret, f.params);
        }
    }

    // Emit optional typedefs (skip ones already pre-emitted in step 3c)
    var opt_it = ctx.opt_types.iterator();
    while (opt_it.next()) |entry| {
        const full_name = entry.key_ptr.*;
        if (pre_emitted_opts.contains(full_name)) continue;
        const inner_c = entry.value_ptr.*;
        try ctx.wf("typedef struct {{ int32_t _has; {s} _val; }} {s};\n", .{ inner_c, full_name });
    }

    // Emit result typedefs
    var res_it = ctx.result_types.iterator();
    while (res_it.next()) |entry| {
        const full_name = entry.key_ptr.*;
        const inner_c = entry.value_ptr.*;
        try ctx.wf("typedef struct {{ ZagErrCode _err; {s} _val; }} {s};\n", .{ inner_c, full_name });
    }

    // 4b. Pre-pass: collect ZagClo_ typedefs from fn params (closures used as params)
    for (decls) |node| {
        if (node.* == .fn_decl) {
            const f = node.fn_decl;
            if (f.tparams.len > 0) continue; // skip generic fns
            for (f.params) |p| {
                if (std.mem.startsWith(u8, p.pty, "fn(")) {
                    const ct = try ctypeClosure(alloc, p.pty);
                    if (!ctx.emitted_clo_types.contains(ct)) {
                        try ctx.emitted_clo_types.put(try alloc.dupe(u8, ct), {});
                        const td_writer = ctx.clo_typedefs.writer();
                        // parse the fn type to get ret and params
                        // find closing paren depth-aware
                        var dep: i32 = 0;
                        var cl_idx: usize = 3;
                        var ci: usize = 3;
                        while (ci < p.pty.len) : (ci += 1) {
                            if (p.pty[ci] == '(') dep += 1
                            else if (p.pty[ci] == ')') {
                                if (dep == 0) { cl_idx = ci; break; }
                                dep -= 1;
                            }
                        }
                        const pstr = p.pty[3..cl_idx];
                        var rstr = if (cl_idx + 1 < p.pty.len) p.pty[cl_idx + 1..] else "void";
                        for (rstr, 0..) |rc, rj| {
                            if (rc == '@' or (rc == '!' and rj > 0)) { rstr = rstr[0..rj]; break; }
                        }
                        if (rstr.len == 0) rstr = "void";
                        const ret_c = try ctype(alloc, rstr);
                        try td_writer.print("typedef struct {{ {s} (*fn)(void*", .{ret_c});
                        // split params
                        if (pstr.len > 0) {
                            var cur2: usize = 0;
                            var d2: i32 = 0;
                            for (pstr, 0..) |c2, j2| {
                                if (c2 == '(' or c2 == '[') d2 += 1
                                else if (c2 == ')' or c2 == ']') d2 -= 1
                                else if (c2 == ',' and d2 == 0) {
                                    const seg = std.mem.trim(u8, pstr[cur2..j2], " ");
                                    if (seg.len > 0) {
                                        const pc = try ctype(alloc, seg);
                                        try td_writer.print(", {s}", .{pc});
                                    }
                                    cur2 = j2 + 1;
                                }
                            }
                            const seg = std.mem.trim(u8, pstr[cur2..], " ");
                            if (seg.len > 0) {
                                const pc = try ctype(alloc, seg);
                                try td_writer.print(", {s}", .{pc});
                            }
                        }
                        try td_writer.print("); void* env; }} {s};\n", .{ct});
                    }
                }
            }
        }
    }

    // 4c. Also collect closure typedefs from instantiated generic fns in s.fns
    {
        var fit = s.fns.iterator();
        while (fit.next()) |entry| {
            const fn_node = entry.value_ptr.*;
            if (fn_node.* != .fn_decl) continue;
            const f = fn_node.fn_decl;
            if (f.tparams.len > 0) continue;
            if (std.mem.startsWith(u8, f.ret, "fn(")) {
                _ = try ctx.ensureClosureTypedef(f.ret);
            }
            for (f.params) |p| {
                if (std.mem.startsWith(u8, p.pty, "fn(")) {
                    _ = try ctx.ensureClosureTypedef(p.pty);
                }
            }
        }
    }

    // 5. Forward declarations (emit clo_typedefs first so fn fwd decls can reference them)
    try ctx.buf.appendSlice(ctx.clo_typedefs.items);
    ctx.clo_typedefs.clearRetainingCapacity();

    // Collect which fn names are in decls (to avoid double-emitting)
    var emitted_fns = std.StringHashMap(void).init(alloc);
    defer emitted_fns.deinit();

    for (decls) |node| {
        if (node.* == .fn_decl) {
            try emitted_fns.put(node.fn_decl.name, {});
            try genFnForwardDecl(&ctx, node.fn_decl);
        }
    }
    // Emit forward decls for instantiated generic fns from s.fns
    {
        var fit = s.fns.iterator();
        while (fit.next()) |entry| {
            const fn_sema_name = entry.key_ptr.*;
            const fn_node = entry.value_ptr.*;
            if (emitted_fns.contains(fn_sema_name)) continue;
            if (fn_node.* != .fn_decl) continue;
            const fd = fn_node.fn_decl;
            if (fd.tparams.len > 0) continue; // still generic, skip
            try genFnForwardDecl(&ctx, fd);
        }
    }
    try ctx.w("\n");

    // 6. Generate fn bodies; closure defs accumulate in closures_fwd/impl
    const after_fwd = try ctx.buf.toOwnedSlice();
    ctx.buf = std.ArrayList(u8).init(alloc);

    for (decls) |node| {
        if (node.* == .fn_decl) {
            try genFnBody(&ctx, node.fn_decl);
        }
    }
    // Emit bodies for instantiated generic fns from s.fns
    {
        var fit = s.fns.iterator();
        while (fit.next()) |entry| {
            const fn_sema_name = entry.key_ptr.*;
            const fn_node = entry.value_ptr.*;
            if (emitted_fns.contains(fn_sema_name)) continue;
            if (fn_node.* != .fn_decl) continue;
            const fd = fn_node.fn_decl;
            if (fd.tparams.len > 0) continue;
            try genFnBody(&ctx, fd);
        }
    }

    const bodies = try ctx.buf.toOwnedSlice();
    ctx.buf = std.ArrayList(u8).init(alloc);

    // Assemble: prelude+types+typedefs+fwddecls | new clo_typedefs | clo_fwd | clo_impl | fn bodies
    try ctx.buf.appendSlice(after_fwd);
    // Any new closure typedefs discovered during body gen (should be empty if pre-pass caught all)
    if (ctx.clo_typedefs.items.len > 0) {
        try ctx.buf.appendSlice(ctx.clo_typedefs.items);
    }
    try ctx.buf.appendSlice(ctx.closures_fwd.items);
    if (ctx.closures_impl.items.len > 0) {
        try ctx.buf.appendSlice(ctx.closures_impl.items);
    }
    if (ctx.thunks.items.len > 0) {
        try ctx.buf.appendSlice(ctx.thunks.items);
    }
    try ctx.buf.appendSlice(bodies);

    return ctx.buf.toOwnedSlice();
}

/// Generate MLIR text for a GPU target.
pub fn genMlir(
    alloc:  std.mem.Allocator,
    decls:  []ast.NodeRef,
    s:      *const sema_mod.Sema,
    target: []const u8,
) ![]const u8 {
    _ = decls;
    _ = s;
    return try std.fmt.allocPrint(alloc,
        \\// MLIR stub — target: {s}
        \\module {{}}
        \\
    , .{target});
}
