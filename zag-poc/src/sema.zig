// sema.zig — Semantic analysis pass (type checker + effect checker) for Zag
// Ported from zagc.py Sema class (lines 1013-2008).

const std = @import("std");
const ast = @import("ast.zig");
const types = @import("types.zig");

// ── Public result types ───────────────────────────────────────────────────────

pub const EffectViolation = struct {
    fn_name: []const u8,
    annot:   []const u8,
    effects: [][]const u8,
    witness: [][]const u8,
};

pub const AnnotationEntry = struct {
    fn_name: []const u8,
    annot:   []const u8,
    proven:  bool,
};

pub const Report = struct {
    violations:  []EffectViolation,
    annotations: []AnnotationEntry,
};

/// A proven (interface, concrete-type) satisfaction recorded during type
/// checking.  Codegen turns each one into a vtable + adapter thunks.
pub const IfaceImpl = struct {
    iface:    []const u8,
    concrete: []const u8,
};

// ── Scope: name → type string ─────────────────────────────────────────────────

pub const Scope = std.StringHashMap([]const u8);

// ── Sema ──────────────────────────────────────────────────────────────────────

pub const Sema = struct {
    alloc:           std.mem.Allocator,
    generic_fns:     std.StringHashMap(ast.NodeRef),
    generic_structs: std.StringHashMap(ast.NodeRef),
    fns:             std.StringHashMap(ast.NodeRef),
    structs:         std.StringHashMap(ast.NodeRef),
    enums:           std.StringHashMap(ast.NodeRef),
    unions:          std.StringHashMap(ast.NodeRef),
    /// key = "RecvType_methodName"
    methods:         std.StringHashMap(ast.NodeRef),
    /// interface name → InterfaceDecl node
    interfaces:      std.StringHashMap(ast.NodeRef),
    /// (interface, concrete) pairs proven to satisfy structurally — codegen
    /// emits one vtable + thunk set per entry.
    iface_impls:     std.ArrayList(IfaceImpl),
    /// type name → OperatorDecl node (operator contracts: +/-/* → named fn)
    operators:       std.StringHashMap(ast.NodeRef),
    /// alias → module prefix string
    modules:         std.StringHashMap([]const u8),
    err_names:       std.ArrayList([]const u8),
    errors:          std.ArrayList([]const u8),
    /// type-of memoization (fn name → return-type string, cached during analysis)
    memo:            std.StringHashMap([]const u8),
    /// names of concrete fns already type-checked
    checked:         std.StringHashMap(void),
    /// fn name → owned slice of effect-name strings
    fn_effects:      std.StringHashMap([][]const u8),

    // ── init ─────────────────────────────────────────────────────────────────

    pub fn init(alloc: std.mem.Allocator, decls: []ast.NodeRef) !Sema {
        var s = Sema{
            .alloc           = alloc,
            .generic_fns     = std.StringHashMap(ast.NodeRef).init(alloc),
            .generic_structs = std.StringHashMap(ast.NodeRef).init(alloc),
            .fns             = std.StringHashMap(ast.NodeRef).init(alloc),
            .structs         = std.StringHashMap(ast.NodeRef).init(alloc),
            .enums           = std.StringHashMap(ast.NodeRef).init(alloc),
            .unions          = std.StringHashMap(ast.NodeRef).init(alloc),
            .methods         = std.StringHashMap(ast.NodeRef).init(alloc),
            .interfaces      = std.StringHashMap(ast.NodeRef).init(alloc),
            .iface_impls     = std.ArrayList(IfaceImpl).init(alloc),
            .operators       = std.StringHashMap(ast.NodeRef).init(alloc),
            .modules         = std.StringHashMap([]const u8).init(alloc),
            .err_names       = std.ArrayList([]const u8).init(alloc),
            .errors          = std.ArrayList([]const u8).init(alloc),
            .memo            = std.StringHashMap([]const u8).init(alloc),
            .checked         = std.StringHashMap(void).init(alloc),
            .fn_effects      = std.StringHashMap([][]const u8).init(alloc),
        };

        for (decls) |n| {
            switch (n.*) {
                .fn_decl => |*f| {
                    if (f.tparams.len > 0) {
                        try s.generic_fns.put(f.name, n);
                    } else {
                        try s.fns.put(f.name, n);
                        if (f.recv_type != null) {
                            const key = try std.fmt.allocPrint(alloc, "{s}_{s}", .{
                                f.recv_type.?, f.method_name orelse f.name,
                            });
                            try s.methods.put(key, n);
                        }
                    }
                },
                .struct_decl => |*sd| {
                    if (sd.tparams.len > 0) {
                        try s.generic_structs.put(sd.name, n);
                    } else {
                        try s.structs.put(sd.name, n);
                    }
                },
                .enum_decl   => |*ed| try s.enums.put(ed.name, n),
                .union_decl  => |*ud| try s.unions.put(ud.name, n),
                .interface_decl => |*id| try s.interfaces.put(id.name, n),
                .operator_decl => |*od| try s.operators.put(od.type_name, n),
                .error_decl  => |*ed| {
                    for (ed.names) |nm| {
                        var found = false;
                        for (s.err_names.items) |en| {
                            if (std.mem.eql(u8, en, nm)) { found = true; break; }
                        }
                        if (!found) try s.err_names.append(nm);
                    }
                },
                .mod_alias => |*ma| {
                    if (ma.alias.len > 0) try s.modules.put(ma.alias, ma.prefix);
                },
                else => {},
            }
        }
        return s;
    }

    pub fn deinit(self: *Sema) void {
        self.generic_fns.deinit();
        self.generic_structs.deinit();
        self.fns.deinit();
        self.structs.deinit();
        self.enums.deinit();
        self.unions.deinit();
        self.methods.deinit();
        self.interfaces.deinit();
        self.iface_impls.deinit();
        self.modules.deinit();
        self.err_names.deinit();
        self.errors.deinit();
        self.memo.deinit();
        self.checked.deinit();
        self.fn_effects.deinit();
    }

    // ── error helpers ────────────────────────────────────────────────────────

    fn err(self: *Sema, line: u32, msg: []const u8) void {
        const full = std.fmt.allocPrint(self.alloc, "line {d}: {s}", .{ line, msg }) catch msg;
        self.errors.append(full) catch {};
    }

    fn errFmt(self: *Sema, line: u32, comptime fmt: []const u8, args: anytype) void {
        const msg = std.fmt.allocPrint(self.alloc, fmt, args) catch "error";
        self.err(line, msg);
    }

    // ── type resolution helpers ───────────────────────────────────────────────

    /// Instantiates generic types referenced inside a type string.
    pub fn resolveType(self: *Sema, ty: []const u8) []const u8 {
        if (ty.len == 0) return ty;
        if (std.mem.startsWith(u8, ty, "[]")) {
            const inner = self.resolveType(ty[2..]);
            const r = std.fmt.allocPrint(self.alloc, "[]{s}", .{inner}) catch ty;
            return r;
        }
        // Pointer / optional prefixes: resolve the pointee, re-attach the prefix.
        if (ty[0] == '*' or ty[0] == '?' or ty[0] == '!') {
            const inner = self.resolveType(ty[1..]);
            return std.fmt.allocPrint(self.alloc, "{c}{s}", .{ ty[0], inner }) catch ty;
        }
        if (types.isFnType(ty)) {
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const tmp = fba.allocator();
            const parts = types.fnParts(tmp, ty) catch return ty;
            var ps = std.ArrayList([]const u8).init(self.alloc);
            defer ps.deinit();
            for (parts.params) |p| ps.append(self.resolveType(p)) catch {};
            const param_str = std.mem.join(self.alloc, ",", ps.items) catch return ty;
            const ret_str = self.resolveType(parts.ret);
            return std.fmt.allocPrint(self.alloc, "fn({s}){s}{s}", .{ param_str, ret_str, parts.suffix }) catch ty;
        }
        // Check for generic application "Base[T1,T2,...]"
        {
            var buf: [4096]u8 = undefined;
            var fba2 = std.heap.FixedBufferAllocator.init(&buf);
            const tmp2 = fba2.allocator();
            const sa = splitApp(tmp2, ty) catch return ty;
            if (sa.args) |args| {
                var cargs = std.ArrayList([]const u8).init(self.alloc);
                defer cargs.deinit();
                for (args) |a| cargs.append(self.resolveType(a)) catch {};
                if (self.generic_structs.contains(sa.base)) {
                    return self.instStruct(sa.base, cargs.items);
                }
                self.errFmt(0, "unknown generic type '{s}'", .{sa.base});
                return ty;
            }
        }
        return ty;
    }

    /// Instantiate a generic struct: Base[T1,T2] -> "Base[T1,T2]" (canonical form).
    pub fn instStruct(self: *Sema, base: []const u8, cargs: [][]const u8) []const u8 {
        const applied = fmtApplied(self.alloc, base, cargs) catch base;
        if (self.structs.contains(applied)) return applied;
        const g_node = self.generic_structs.get(base) orelse return base;
        const g = &g_node.*.struct_decl;
        // Build substitution map
        var mp = std.StringHashMap([]const u8).init(self.alloc);
        defer mp.deinit();
        for (g.tparams, 0..) |tp, i| {
            if (i < cargs.len) mp.put(tp, cargs[i]) catch {};
        }
        // Placeholder so recursive references terminate
        const placeholder = self.alloc.create(ast.Node) catch return applied;
        placeholder.* = ast.Node{ .struct_decl = .{
            .name    = applied,
            .fields  = &.{},
            .line    = g.line,
            .tparams = &.{},
        }};
        self.structs.put(applied, placeholder) catch {};
        // Build instantiated fields
        var new_fields = std.ArrayList(ast.Param).init(self.alloc);
        for (g.fields) |f| {
            const subst = types.substType(self.alloc, f.pty, mp) catch f.pty;
            const resolved = self.resolveType(subst);
            new_fields.append(.{ .name = f.name, .pty = resolved }) catch {};
        }
        const fields_slice = new_fields.toOwnedSlice() catch blk: {
            var empty = [_]ast.Param{};
            break :blk empty[0..];
        };
        placeholder.struct_decl.fields = fields_slice;
        return applied;
    }

    /// Instantiate a generic fn: Base[T1,T2] -> "Base[T1,T2]".
    pub fn instFn(self: *Sema, base: []const u8, cargs: [][]const u8) []const u8 {
        const applied = fmtApplied(self.alloc, base, cargs) catch base;
        if (self.fns.contains(applied)) return applied;
        const g_node = self.generic_fns.get(base) orelse return base;
        const g = &g_node.*.fn_decl;
        // Build substitution map
        var mp = std.StringHashMap([]const u8).init(self.alloc);
        defer mp.deinit();
        for (g.tparams, 0..) |tp, i| {
            if (i < cargs.len) mp.put(tp, cargs[i]) catch {};
        }
        // Build instantiated params
        var new_params = std.ArrayList(ast.Param).init(self.alloc);
        for (g.params) |p| {
            const subst = types.substType(self.alloc, p.pty, mp) catch p.pty;
            new_params.append(.{ .name = p.name, .pty = self.resolveType(subst) }) catch {};
        }
        const params_slice = new_params.toOwnedSlice() catch blk: {
            var empty = [_]ast.Param{};
            break :blk empty[0..];
        };
        const ret_subst = types.substType(self.alloc, g.ret, mp) catch g.ret;
        const ret = self.resolveType(ret_subst);
        // Clone body with substitution
        const new_body: ?[]ast.NodeRef = if (g.body) |b| self.cloneStmts(b, &mp) else null;
        // Copy annots
        var new_annots = std.ArrayList([]const u8).init(self.alloc);
        for (g.annots) |a| new_annots.append(a) catch {};
        const annots_slice: [][]const u8 = new_annots.toOwnedSlice() catch blk: {
            var empty = [_][]const u8{};
            break :blk empty[0..];
        };
        const inst_node = self.alloc.create(ast.Node) catch return applied;
        inst_node.* = ast.Node{ .fn_decl = .{
            .name      = applied,
            .params    = params_slice,
            .ret       = ret,
            .annots    = annots_slice,
            .body      = new_body,
            .line      = g.line,
            .is_extern = g.is_extern,
            .tparams   = &.{},
            .recv_type = g.recv_type,
        }};
        self.fns.put(applied, inst_node) catch {};
        self.checkFn(inst_node);
        return applied;
    }

    // ── fn type helper ────────────────────────────────────────────────────────

    fn fnTypeOfNamed(self: *Sema, name: []const u8) ?[]const u8 {
        if (self.fns.get(name)) |n| {
            const f = &n.*.fn_decl;
            var ps = std.ArrayList([]const u8).init(self.alloc);
            defer ps.deinit();
            for (f.params) |p| ps.append(p.pty) catch {};
            const param_str = std.mem.join(self.alloc, ",", ps.items) catch return null;
            return std.fmt.allocPrint(self.alloc, "fn({s}){s}", .{ param_str, f.ret }) catch null;
        }
        if (types.getBuiltin(name)) |b| {
            const param_str = std.mem.join(self.alloc, ",", b.params) catch return null;
            return std.fmt.allocPrint(self.alloc, "fn({s}){s}", .{ param_str, b.ret }) catch null;
        }
        return null;
    }

    pub fn fieldTypeOf(self: *const Sema, struct_name: []const u8, fname: []const u8) ?[]const u8 {
        const sn = self.structs.get(struct_name) orelse return null;
        for (sn.*.struct_decl.fields) |p| {
            if (std.mem.eql(u8, p.name, fname)) return p.pty;
        }
        return null;
    }

    // ── operator contracts ────────────────────────────────────────────────────
    fn isArithOp(op: []const u8) bool {
        return std.mem.eql(u8, op, "+") or std.mem.eql(u8, op, "-") or
            std.mem.eql(u8, op, "*") or std.mem.eql(u8, op, "/");
    }

    /// The OperatorDecl for type `ty`, resolving a generic application to its
    /// base (so `Box[i32]` still finds `operator Box { .. }`), or null.
    pub fn opContractNode(self: *const Sema, ty: []const u8) ?ast.NodeRef {
        if (self.operators.get(ty)) |n| return n;
        if (std.mem.indexOfScalar(u8, ty, '[')) |i| {
            if (self.operators.get(ty[0..i])) |n| return n;
        }
        return null;
    }

    /// The decode-fn name mapped to `op` for `ty` under its contract, or null.
    pub fn opContractFn(self: *const Sema, ty: []const u8, op: []const u8) ?[]const u8 {
        const node = self.opContractNode(ty) orelse return null;
        for (node.*.operator_decl.ops) |e| {
            if (std.mem.eql(u8, e.op, op)) return e.fn_name;
        }
        return null;
    }

    /// Validate each `operator T { + => f, .. }`: T must exist and every named
    /// fn must be a real (T, T) -> T function. This makes the contract checked.
    fn checkOperatorContracts(self: *Sema) void {
        var it = self.operators.valueIterator();
        while (it.next()) |np| {
            const od = &np.*.*.operator_decl;
            self.checkTypeExists(od.type_name, od.line);
            for (od.ops) |e| {
                const ft = self.fnTypeOfNamed(e.fn_name) orelse {
                    self.errFmt(od.line, "operator '{s}' for {s}: unknown function '{s}'", .{ e.op, od.type_name, e.fn_name });
                    continue;
                };
                var fba_buf: [512]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&fba_buf);
                const parts = types.fnParts(fba.allocator(), ft) catch continue;
                if (parts.params.len != 2 or
                    !types.assignable(od.type_name, parts.params[0]) or
                    !types.assignable(od.type_name, parts.params[1]))
                    self.errFmt(od.line, "operator '{s}' for {s}: '{s}' must take ({s}, {s})", .{ e.op, od.type_name, e.fn_name, od.type_name, od.type_name });
                if (!types.assignable(od.type_name, parts.ret))
                    self.errFmt(od.line, "operator '{s}' for {s}: '{s}' must return {s} (got {s})", .{ e.op, od.type_name, e.fn_name, od.type_name, parts.ret });
            }
        }
    }

    // ── _checkTypeExists ──────────────────────────────────────────────────────

    fn checkTypeExists(self: *Sema, ty: []const u8, line: u32) void {
        if (types.isPointer(ty))    { self.checkTypeExists(types.pointerInner(ty), line); return; }
        if (types.isErrorUnion(ty)) { self.checkTypeExists(types.errorInner(ty), line); return; }
        if (types.isOptional(ty))   { self.checkTypeExists(types.optionalInner(ty), line); return; }
        if (types.isFnType(ty)) {
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const parts = types.fnParts(fba.allocator(), ty) catch return;
            for (parts.params) |p| self.checkTypeExists(p, line);
            self.checkTypeExists(parts.ret, line);
            return;
        }
        const base: []const u8 = if (std.mem.startsWith(u8, ty, "[]")) ty[2..] else ty;
        // Accept all known scalar families
        for (&types.INT_TYPES) |s| { if (std.mem.eql(u8, s, base)) return; }
        for (&types.FLOAT_TYPES) |s| { if (std.mem.eql(u8, s, base)) return; }
        for (&types.POSIT_TYPES) |s| { if (std.mem.eql(u8, s, base)) return; }
        for (&types.LNS_TYPES) |s|  { if (std.mem.eql(u8, s, base)) return; }
        for (&types.BF16_TYPES) |s| { if (std.mem.eql(u8, s, base)) return; }
        for (&types.MX_TYPES) |s|   { if (std.mem.eql(u8, s, base)) return; }
        if (std.mem.eql(u8, base, "bool") or
            std.mem.eql(u8, base, "void") or
            std.mem.eql(u8, base, "quire")) return;
        if (types.isArbInt(base)) return;
        if (types.isFixed(base))  return;
        if (types.isRns(base))    return;
        if (types.isVsaType(base)) return;
        if (types.isGpuBuf(base)) return;
        if (types.isSat(base))    return;
        if (types.isBignum(base)) return;
        if (self.structs.contains(base)) return;
        if (self.enums.contains(base))   return;
        if (self.unions.contains(base))  return;
        if (self.interfaces.contains(base)) return;
        self.errFmt(line, "unknown type '{s}'", .{ty});
    }

    // ── Structural ("duck") typing ───────────────────────────────────────────

    /// Look up an interface's method signature by name, or null.
    fn ifaceMethod(self: *Sema, iface: []const u8, mname: []const u8) ?ast.IfaceMethod {
        const node = self.interfaces.get(iface) orelse return null;
        for (node.*.interface_decl.methods) |m| {
            if (std.mem.eql(u8, m.name, mname)) return m;
        }
        return null;
    }

    /// Two types are compatible for structural matching when they are equal
    /// after literal-default normalization, or mutually assignable.
    fn typeCompatible(a: []const u8, b: []const u8) bool {
        if (std.mem.eql(u8, a, b)) return true;
        const da = types.defaultTy(a);
        const db = types.defaultTy(b);
        if (std.mem.eql(u8, da, db)) return true;
        return types.assignable(a, b) and types.assignable(b, a);
    }

    /// Does concrete type `concrete` structurally satisfy interface `iface`?
    /// When it does NOT and `report_line != 0`, emit a precise diagnostic
    /// naming the missing/mismatched method.  On success, record the impl for
    /// codegen (deduplicated).
    pub fn structurallySatisfies(self: *Sema, concrete: []const u8, iface: []const u8, report_line: u32) bool {
        const inode = self.interfaces.get(iface) orelse return false;
        const idecl = inode.*.interface_decl;

        var ok = true;
        for (idecl.methods) |m| {
            const key = std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ concrete, m.name }) catch continue;
            const meth_node = self.methods.get(key) orelse {
                ok = false;
                if (report_line != 0)
                    self.errFmt(report_line,
                        "type '{s}' does not satisfy interface '{s}': missing method '{s}(self) {s}'",
                        .{ concrete, iface, m.name, m.ret });
                continue;
            };
            const meth = &meth_node.*.fn_decl;
            // Arity (excluding the receiver, which neither side counts in params).
            if (meth.params.len != m.params.len) {
                ok = false;
                if (report_line != 0)
                    self.errFmt(report_line,
                        "type '{s}' does not satisfy interface '{s}': method '{s}' has {d} params, interface requires {d}",
                        .{ concrete, iface, m.name, meth.params.len, m.params.len });
                continue;
            }
            // Param types.
            var sig_ok = true;
            for (m.params, meth.params) |ip, cp| {
                if (!typeCompatible(ip.pty, cp.pty)) {
                    sig_ok = false;
                    if (report_line != 0)
                        self.errFmt(report_line,
                            "type '{s}' does not satisfy interface '{s}': method '{s}' param '{s}' is {s}, interface requires {s}",
                            .{ concrete, iface, m.name, cp.name, cp.pty, ip.pty });
                }
            }
            // Return type.
            if (!typeCompatible(m.ret, meth.ret)) {
                sig_ok = false;
                if (report_line != 0)
                    self.errFmt(report_line,
                        "type '{s}' does not satisfy interface '{s}': method '{s}' returns {s}, interface requires {s}",
                        .{ concrete, iface, m.name, meth.ret, m.ret });
            }
            if (!sig_ok) ok = false;
        }

        if (ok) self.recordImpl(iface, concrete);
        return ok;
    }

    fn recordImpl(self: *Sema, iface: []const u8, concrete: []const u8) void {
        for (self.iface_impls.items) |it| {
            if (std.mem.eql(u8, it.iface, iface) and std.mem.eql(u8, it.concrete, concrete)) return;
        }
        self.iface_impls.append(.{ .iface = iface, .concrete = concrete }) catch {};
    }

    // ── checkTypes: top-level type-check pass ────────────────────────────────

    pub fn checkTypes(self: *Sema) !void {
        self.checkOperatorContracts();
        // Canonicalize struct field types
        var sit = self.structs.iterator();
        while (sit.next()) |kv| {
            const sd = &kv.value_ptr.*.*.struct_decl;
            for (sd.fields) |*p| p.pty = self.resolveType(p.pty);
        }
        // Canonicalize fn param/ret types
        var fit = self.fns.iterator();
        while (fit.next()) |kv| {
            const f = &kv.value_ptr.*.*.fn_decl;
            for (f.params) |*p| p.pty = self.resolveType(p.pty);
            f.ret = self.resolveType(f.ret);
        }
        // Check struct field types exist
        var sit2 = self.structs.iterator();
        while (sit2.next()) |kv| {
            const sd = &kv.value_ptr.*.*.struct_decl;
            for (sd.fields) |p| self.checkTypeExists(p.pty, sd.line);
        }
        // Type-check all concrete fns.
        //
        // checkFn → instFn adds monomorphized instances to self.fns. Mutating the
        // map while iterating it corrupts the iterator and can silently skip
        // functions, leaving their generic calls without an inst_name (codegen
        // then emits a bare, undefined name). So snapshot the current functions
        // first; newly-created instantiations are checked by instFn directly.
        var to_check = std.ArrayList(ast.NodeRef).init(self.alloc);
        defer to_check.deinit();
        var fit2 = self.fns.iterator();
        while (fit2.next()) |kv| {
            to_check.append(kv.value_ptr.*) catch {};
        }
        for (to_check.items) |node| {
            self.checkFn(node);
        }
    }

    fn checkFn(self: *Sema, node: ast.NodeRef) void {
        const f = &node.*.fn_decl;
        if (self.checked.contains(f.name)) return;
        self.checked.put(f.name, {}) catch {};
        for (f.params) |p| self.checkTypeExists(p.pty, f.line);
        self.checkTypeExists(f.ret, f.line);
        if (f.is_extern) return;
        const body = f.body orelse return;
        var scope = Scope.init(self.alloc);
        defer scope.deinit();
        for (f.params) |p| scope.put(p.name, p.pty) catch {};
        if (f.recv_type) |rt| scope.put("self", rt) catch {};
        self.checkBlock(body, &scope, node);
    }

    // ── typeOf: the type inference engine ────────────────────────────────────

    pub fn typeOf(self: *Sema, e: ast.NodeRef, scope: *Scope) []const u8 {
        const t = self.typeOfInner(e, scope);
        ast.setNodeType(e, t);
        return t;
    }

    fn typeOfInner(self: *Sema, e: ast.NodeRef, scope: *Scope) []const u8 {
        switch (e.*) {
            .null_lit => return "null",

            .force_unwrap => |inner_ref| {
                const opt_ty = self.typeOf(inner_ref, scope);
                if (!types.isOptional(opt_ty)) {
                    self.errFmt(0, "'.?' applied to non-optional type '{s}'", .{opt_ty});
                }
                const T = if (types.isOptional(opt_ty)) types.optionalInner(opt_ty) else opt_ty;
                ast.setNodeType(e, T);
                return T;
            },

            .or_else => |*oe| {
                const opt_ty = self.typeOf(oe.expr, scope);
                if (!types.isOptional(opt_ty)) {
                    self.errFmt(oe.line, "'orelse' applied to non-optional type '{s}'", .{opt_ty});
                }
                const T = if (types.isOptional(opt_ty)) types.optionalInner(opt_ty) else opt_ty;
                const def_ty = self.typeOf(oe.default, scope);
                if (!types.assignable(T, def_ty) and !types.assignable(def_ty, T)) {
                    self.errFmt(oe.line, "'orelse' default type '{s}' doesn't match inner type '{s}'", .{ def_ty, T });
                }
                return T;
            },

            .err_lit => |*el| {
                // Register the error name
                var found = false;
                for (self.err_names.items) |en| {
                    if (std.mem.eql(u8, en, el.errname)) { found = true; break; }
                }
                if (!found) self.err_names.append(el.errname) catch {};
                return "err";
            },

            .try_ => |inner_ref| {
                const inner_ty = self.typeOf(inner_ref, scope);
                if (!types.isErrorUnion(inner_ty)) {
                    self.errFmt(0, "'try' applied to non-error-union type {s}", .{inner_ty});
                    return inner_ty;
                }
                return types.errorInner(inner_ty);
            },

            .catch_ => |*c| {
                const inner_ty = self.typeOf(c.expr, scope);
                if (!types.isErrorUnion(inner_ty)) {
                    self.errFmt(c.line, "'catch' applied to non-error-union type {s}", .{inner_ty});
                }
                const T = if (types.isErrorUnion(inner_ty)) types.errorInner(inner_ty) else inner_ty;
                var def_scope = Scope.init(self.alloc);
                defer def_scope.deinit();
                var it = scope.iterator();
                while (it.next()) |kv| def_scope.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
                if (c.cap) |cap| def_scope.put(cap, "u32") catch {};
                _ = self.typeOf(c.default, &def_scope);
                return T;
            },

            .lit => |*l| {
                if (l.lty == .str) return "[]u8";
                return switch (l.lty) {
                    .int_lit   => "int_lit",
                    .float_lit => "float_lit",
                    .bool_     => "bool",
                    .str       => "[]u8",
                };
            },

            .switch_ => |*sw| {
                // switch used as an expression value
                if (sw.switch_ty != null) return sw.switch_ty.?;
                const st = self.typeOf(sw.subject, scope);
                var arm_tys = std.ArrayList([]const u8).init(self.alloc);
                defer arm_tys.deinit();

                if (self.enums.get(st)) |enum_node| {
                    const ed = &enum_node.*.enum_decl;
                    var covered = std.StringHashMap(void).init(self.alloc);
                    defer covered.deinit();
                    for (sw.arms) |arm| {
                        for (arm.tags) |tag| {
                            var member_found = false;
                            for (ed.members) |m| {
                                if (std.mem.eql(u8, m, tag)) { member_found = true; break; }
                            }
                            if (!member_found)
                                self.errFmt(sw.line, "enum '{s}' has no member '{s}'", .{ st, tag });
                            covered.put(tag, {}) catch {};
                        }
                        if (sw.is_expr and arm.body.len > 0) {
                            arm_tys.append(self.typeOf(arm.body[0], scope)) catch {};
                        } else {
                            var arm_scope = self.cloneScope(scope);
                            defer arm_scope.deinit();
                            self.checkBlock(arm.body, &arm_scope, null);
                        }
                    }
                    if (sw.els == null) {
                        for (ed.members) |m| {
                            if (!covered.contains(m)) {
                                self.errFmt(sw.line, "non-exhaustive switch on enum '{s}': missing '{s}'", .{ st, m });
                            }
                        }
                    }
                } else if (self.unions.get(st)) |union_node| {
                    const ud = &union_node.*.union_decl;
                    var vt = std.StringHashMap([]const u8).init(self.alloc);
                    defer vt.deinit();
                    for (ud.fields) |f| vt.put(f.name, f.pty) catch {};
                    var covered = std.StringHashMap(void).init(self.alloc);
                    defer covered.deinit();
                    for (sw.arms) |arm| {
                        for (arm.tags) |tag| covered.put(tag, {}) catch {};
                        var arm_scope = self.cloneScope(scope);
                        defer arm_scope.deinit();
                        if (arm.cap) |cap| {
                            const vpty = if (arm.tags.len > 0) vt.get(arm.tags[0]) orelse "i32" else "i32";
                            arm_scope.put(cap, vpty) catch {};
                        }
                        if (sw.is_expr and arm.body.len > 0) {
                            arm_tys.append(self.typeOf(arm.body[0], &arm_scope)) catch {};
                        } else {
                            self.checkBlock(arm.body, &arm_scope, null);
                        }
                    }
                    if (sw.els == null) {
                        var vit = vt.iterator();
                        while (vit.next()) |kv| {
                            if (!covered.contains(kv.key_ptr.*))
                                self.errFmt(sw.line, "non-exhaustive switch on union '{s}': missing '{s}'", .{ st, kv.key_ptr.* });
                        }
                    }
                } else {
                    // integer switch
                    var is_int_type = false;
                    for (&types.INT_TYPES) |s| {
                        if (std.mem.eql(u8, s, st)) { is_int_type = true; break; }
                    }
                    if (is_int_type) {
                        for (sw.arms) |arm| {
                            var arm_scope = self.cloneScope(scope);
                            defer arm_scope.deinit();
                            if (sw.is_expr and arm.body.len > 0) {
                                arm_tys.append(self.typeOf(arm.body[0], scope)) catch {};
                            } else {
                                self.checkBlock(arm.body, &arm_scope, null);
                            }
                        }
                        if (sw.els == null)
                            self.errFmt(sw.line, "integer switch requires an else arm", .{});
                    } else {
                        self.errFmt(sw.line, "switch subject must be an enum, union, or integer, got '{s}'", .{st});
                    }
                }
                if (sw.els) |els_body| {
                    var els_scope = self.cloneScope(scope);
                    defer els_scope.deinit();
                    if (sw.is_expr and els_body.len > 0) {
                        arm_tys.append(self.typeOf(els_body[0], scope)) catch {};
                    } else {
                        self.checkBlock(els_body, &els_scope, null);
                    }
                }
                const ty0: []const u8 = if (arm_tys.items.len > 0) arm_tys.items[0] else "void";
                e.*.switch_.switch_ty = ty0;
                return ty0;
            },

            .var_ => |*v| {
                if (scope.get(v.name)) |t| return t;
                if (self.modules.contains(v.name)) {
                    return std.fmt.allocPrint(self.alloc, "module:{s}", .{v.name}) catch "module";
                }
                if (self.fnTypeOfNamed(v.name)) |ft| return ft;
                self.errFmt(v.line, "undefined name '{s}'", .{v.name});
                return "i32";
            },

            .un => |*u| {
                const t = self.typeOf(u.e, scope);
                if (std.mem.eql(u8, u.op, "!")) return "bool";
                if (std.mem.eql(u8, u.op, "&"))
                    return std.fmt.allocPrint(self.alloc, "*{s}", .{t}) catch t;
                return t;
            },

            .bin => |*b| return self.typeOfBin(b, scope),

            .index => |*idx| {
                const bt = self.typeOf(idx.base, scope);
                const el: []const u8 = if (std.mem.startsWith(u8, bt, "[]"))
                    bt[2..]
                else if (types.isPointer(bt))
                    types.pointerInner(bt)
                else {
                    self.errFmt(idx.line, "cannot index non-slice type {s}", .{bt});
                    return "i32";
                };
                const idx_ty = self.typeOf(idx.idx, scope);
                if (!types.isInt(idx_ty))
                    self.errFmt(idx.line, "index must be an integer", .{});
                return el;
            },

            .cast => |*c| {
                _ = self.typeOf(c.expr, scope); // type inner for node-type recording
                return self.resolveType(c.target);
            },

            .slice => |*sl| {
                const bt = self.typeOf(sl.base, scope);
                _ = self.typeOf(sl.lo, scope);
                _ = self.typeOf(sl.hi, scope);
                // []T[a..b] -> []T ; *T[a..b] -> []T
                if (std.mem.startsWith(u8, bt, "[]")) return bt;
                if (types.isPointer(bt))
                    return std.fmt.allocPrint(self.alloc, "[]{s}", .{types.pointerInner(bt)}) catch bt;
                self.errFmt(sl.line, "cannot slice non-sliceable type {s}", .{bt});
                return "[]u8";
            },

            .field => |*f| return self.typeOfField(f, scope),

            .struct_lit => |*sl| return self.typeOfStructLit(sl, scope),

            .closure => |*cl| {
                var cap_scope = Scope.init(self.alloc);
                defer cap_scope.deinit();
                for (cl.caps) |cap| {
                    if (scope.get(cap)) |ct| {
                        cap_scope.put(cap, ct) catch {};
                    } else {
                        self.errFmt(cl.line, "closure captures undefined name '{s}'", .{cap});
                        cap_scope.put(cap, "i32") catch {};
                    }
                }
                // Fill cap_types for codegen
                var cap_it = cap_scope.iterator();
                while (cap_it.next()) |kv| {
                    cl.cap_types.put(self.alloc, kv.key_ptr.*, kv.value_ptr.*) catch {};
                }
                var body_scope = self.cloneScope(&cap_scope);
                defer body_scope.deinit();
                for (cl.params) |p| body_scope.put(p.name, p.pty) catch {};
                // Create a temporary fn node for checkBlock context
                const shim = self.alloc.create(ast.Node) catch {
                    return std.fmt.allocPrint(self.alloc, "fn({s}){s}",
                        .{ self.joinParamTypes(cl.params), cl.ret }) catch "fn()void";
                };
                shim.* = ast.Node{ .fn_decl = .{
                    .name   = "<closure>",
                    .params = cl.params,
                    .ret    = cl.ret,
                    .annots = &.{},
                    .body   = cl.body,
                    .line   = cl.line,
                }};
                self.checkBlock(cl.body, &body_scope, shim);
                return std.fmt.allocPrint(self.alloc, "fn({s}){s}",
                    .{ self.joinParamTypes(cl.params), cl.ret }) catch "fn()void";
            },

            .call => |*c| return self.typeOfCall(c, e, scope),

            // expr_stmt wrapping — used by switch expression arms
            .expr_stmt => |*es| return self.typeOf(es.expr, scope),

            // top-level declarations don't have types as expressions
            else => return "i32",
        }
    }

    fn typeOfBin(self: *Sema, b: *ast.Bin, scope: *Scope) []const u8 {
        const lt = self.typeOf(b.l, scope);
        const rt = self.typeOf(b.r, scope);
        const cmp_ops = [_][]const u8{ "==", "!=", "<", ">", "<=", ">=", "&&", "||" };
        for (&cmp_ops) |op| {
            if (std.mem.eql(u8, b.op, op)) return "bool";
        }
        // Operator contract: `operator T { + => f, .. }` makes +/-/*// on T dispatch
        // to f. Checked first so a custom unit (even a fresh struct) gets real
        // arithmetic. (typeOf only needs to know the result is T.)
        if (std.mem.eql(u8, lt, rt) and isArithOp(b.op)) {
            if (self.opContractFn(lt, b.op) != null) return lt;
        }
        // Bignum arithmetic
        if (types.isBignum(lt) or types.isBignum(rt)) {
            const ty = if (types.isBignum(lt)) lt else rt;
            const arith_ops = [_][]const u8{ "+", "-", "*", "/" };
            for (&arith_ops) |op| if (std.mem.eql(u8, b.op, op)) return ty;
            return ty;
        }
        // Integer arithmetic
        if (types.isInt(lt) and types.isInt(rt)) {
            if (std.mem.eql(u8, lt, "int_lit")) return rt;
            if (std.mem.eql(u8, rt, "int_lit")) return lt;
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "type mismatch: {s} {s} {s}", .{ lt, b.op, rt });
            return lt;
        }
        // Float arithmetic
        if (types.isFloat(lt) and types.isFloat(rt)) {
            if (std.mem.eql(u8, lt, "float_lit")) return rt;
            if (std.mem.eql(u8, rt, "float_lit")) return lt;
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "type mismatch: {s} {s} {s}", .{ lt, b.op, rt });
            return lt;
        }
        // Posit arithmetic
        if (types.isPosit(lt) and types.isPosit(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "posit type mismatch: {s} {s} {s}", .{ lt, b.op, rt });
            const posit_arith = [_][]const u8{ "+", "-", "*", "/" };
            for (&posit_arith) |op| if (std.mem.eql(u8, b.op, op)) return lt;
            self.errFmt(b.line, "operator '{s}' not supported on posits", .{b.op});
            return lt;
        }
        // LNS arithmetic
        if (types.isLns(lt) and types.isLns(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "LNS type mismatch: {s} {s} {s}", .{ lt, b.op, rt });
            const lns_arith = [_][]const u8{ "+", "-", "*", "/" };
            for (&lns_arith) |op| if (std.mem.eql(u8, b.op, op)) return lt;
            const lns_cmp = [_][]const u8{ "==", "!=", "<", ">", "<=", ">=" };
            for (&lns_cmp) |op| if (std.mem.eql(u8, b.op, op)) return "bool";
            self.errFmt(b.line, "operator '{s}' not supported on LNS types", .{b.op});
            return lt;
        }
        // bf16 arithmetic
        var lt_is_bf16 = false; var rt_is_bf16 = false;
        for (&types.BF16_TYPES) |s| { if (std.mem.eql(u8, s, lt)) lt_is_bf16 = true; }
        for (&types.BF16_TYPES) |s| { if (std.mem.eql(u8, s, rt)) rt_is_bf16 = true; }
        if (lt_is_bf16 and rt_is_bf16) {
            const bf16_arith = [_][]const u8{ "+", "-", "*", "/" };
            for (&bf16_arith) |op| if (std.mem.eql(u8, b.op, op)) return lt;
            return "bool";
        }
        // MX float
        if (types.isMx(lt) and types.isMx(rt)) {
            const mx_arith = [_][]const u8{ "+", "-", "*", "/" };
            for (&mx_arith) |op| if (std.mem.eql(u8, b.op, op)) return lt;
            return "bool";
        }
        // Arbitrary-width integers
        if (types.isArbInt(lt) and types.isArbInt(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "arbitrary-int width mismatch: {s} vs {s} (use explicit cast)", .{ lt, rt });
            return lt;
        }
        if (types.isArbInt(lt) and std.mem.eql(u8, rt, "int_lit")) return lt;
        if (std.mem.eql(u8, lt, "int_lit") and types.isArbInt(rt)) return rt;
        // Saturating types
        if (types.isSat(lt) and types.isSat(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "saturating type mismatch: {s} vs {s}", .{ lt, rt });
            const sat_cmp = [_][]const u8{ "==", "!=", "<", ">", "<=", ">=" };
            for (&sat_cmp) |op| if (std.mem.eql(u8, b.op, op)) return "bool";
            return lt;
        }
        if (types.isSat(lt) and std.mem.eql(u8, rt, "int_lit")) return lt;
        if (std.mem.eql(u8, lt, "int_lit") and types.isSat(rt)) return rt;
        // Fixed-point
        if (types.isFixed(lt) and types.isFixed(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "fixed-point format mismatch: {s} vs {s}", .{ lt, rt });
            const fp_cmp = [_][]const u8{ "==", "!=", "<", ">", "<=", ">=" };
            for (&fp_cmp) |op| if (std.mem.eql(u8, b.op, op)) return "bool";
            return lt;
        }
        if (types.isFixed(lt) and std.mem.eql(u8, rt, "int_lit")) return lt;
        // RNS
        if (types.isRns(lt) and types.isRns(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "RNS channel mismatch: {s} vs {s}", .{ lt, rt });
            const rns_arith = [_][]const u8{ "+", "-", "*" };
            for (&rns_arith) |op| if (std.mem.eql(u8, b.op, op)) return lt;
            self.errFmt(b.line, "RNS comparison/division requires CRT reconstruction — not yet supported", .{});
            return lt;
        }
        if (types.isRns(lt) and std.mem.eql(u8, rt, "int_lit")) return lt;
        // VSA
        if (types.isVsaType(lt) and types.isVsaType(rt)) {
            if (!std.mem.eql(u8, lt, rt))
                self.errFmt(b.line, "VSA dimension mismatch: {s} vs {s}", .{ lt, rt });
            const vsa_ops = [_][]const u8{ "^", "|", "&" };
            for (&vsa_ops) |op| if (std.mem.eql(u8, b.op, op)) return lt;
            self.errFmt(b.line, "operator '{s}' not supported on VSA types", .{b.op});
            return lt;
        }
        self.errFmt(b.line, "type mismatch: {s} {s} {s}", .{ lt, b.op, rt });
        return lt;
    }

    fn typeOfField(self: *Sema, f: *ast.Field, scope: *Scope) []const u8 {
        // Module field access
        if (f.base.* == .var_) {
            const vname = f.base.*.var_.name;
            if (self.modules.get(vname)) |_| {
                const prefix = self.modules.get(vname).?;
                const mangled = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, f.fname }) catch f.fname;
                if (self.fnTypeOfNamed(mangled)) |ft| {
                    ast.setNodeType(f.base, std.fmt.allocPrint(self.alloc, "module:{s}", .{vname}) catch "module");
                    return ft;
                }
                self.errFmt(f.line, "module '{s}' has no exported name '{s}'", .{ vname, f.fname });
                return "i32";
            }
            // Enum member: Color.Red
            if (self.enums.get(vname)) |enum_node| {
                const ed = &enum_node.*.enum_decl;
                var found = false;
                for (ed.members) |m| if (std.mem.eql(u8, m, f.fname)) { found = true; break; };
                if (!found)
                    self.errFmt(f.line, "enum '{s}' has no member '{s}'", .{ vname, f.fname });
                return vname;
            }
        }
        const bt = self.typeOf(f.base, scope);
        // Pointer deref: ptr.*
        if (std.mem.eql(u8, f.fname, "*")) {
            if (!types.isPointer(bt)) {
                self.errFmt(f.line, "'.* applied to non-pointer type '{s}'", .{bt});
                return "i32";
            }
            return types.pointerInner(bt);
        }
        // Auto-deref through pointer
        var bt2 = bt;
        if (types.isPointer(bt2)) bt2 = types.pointerInner(bt2);
        if (std.mem.startsWith(u8, bt2, "[]")) {
            if (std.mem.eql(u8, f.fname, "len")) return "i32";
            self.errFmt(f.line, "slice has no field '{s}'", .{f.fname});
            return "i32";
        }
        // RNS field access
        if (types.isRns(bt2)) {
            const n = types.rnsChannels(bt2);
            var valid = true;
            if (f.fname.len < 2 or f.fname[0] != 'r') {
                valid = false;
            } else {
                const num = std.fmt.parseInt(u32, f.fname[1..], 10) catch 0;
                if (num < 1 or num > n) valid = false;
            }
            if (!valid)
                self.errFmt(f.line, "rns_{d} has no field '{s}'", .{ n, f.fname });
            return "u32";
        }
        if (self.fieldTypeOf(bt2, f.fname)) |ft| return ft;
        self.errFmt(f.line, "type {s} has no field '{s}'", .{ bt, f.fname });
        return "i32";
    }

    fn typeOfStructLit(self: *Sema, sl: *ast.StructLit, scope: *Scope) []const u8 {
        // Tagged-union construction
        if (self.unions.get(sl.sname)) |union_node| {
            const ud = &union_node.*.union_decl;
            sl.inst_sname = sl.sname;
            if (sl.fields.len != 1)
                self.errFmt(sl.line, "union '{s}' construction must set exactly one variant", .{sl.sname});
            for (sl.fields) |fi| {
                const vt = self.typeOf(fi.val, scope);
                var pt: ?[]const u8 = null;
                for (ud.fields) |f| if (std.mem.eql(u8, f.name, fi.name)) { pt = f.pty; break; };
                if (pt == null) {
                    self.errFmt(sl.line, "union '{s}' has no variant '{s}'", .{ sl.sname, fi.name });
                } else if (!types.assignable(pt.?, vt)) {
                    self.errFmt(sl.line, "variant '{s}': expected {s}, got {s}", .{ fi.name, pt.?, vt });
                }
            }
            return sl.sname;
        }
        // Generic struct instantiation
        if (sl.targs.len > 0 or self.generic_structs.contains(sl.sname)) {
            var cargs = std.ArrayList([]const u8).init(self.alloc);
            defer cargs.deinit();
            for (sl.targs) |a| cargs.append(self.resolveType(a)) catch {};
            sl.inst_sname = self.instStruct(sl.sname, cargs.items);
        } else {
            sl.inst_sname = sl.sname;
        }
        const inst = sl.inst_sname.?;
        const sn = self.structs.get(inst) orelse {
            self.errFmt(sl.line, "unknown struct '{s}'", .{sl.sname});
            return inst;
        };
        const sd = &sn.*.struct_decl;
        for (sl.fields) |fi| {
            const vt = self.typeOf(fi.val, scope);
            var pt: ?[]const u8 = null;
            for (sd.fields) |f| if (std.mem.eql(u8, f.name, fi.name)) { pt = f.pty; break; };
            if (pt == null) {
                self.errFmt(sl.line, "struct '{s}' has no field '{s}'", .{ inst, fi.name });
            } else if (!types.assignable(pt.?, vt)) {
                self.errFmt(sl.line, "field '{s}': expected {s}, got {s}", .{ fi.name, pt.?, vt });
            }
        }
        return inst;
    }

    fn typeOfCall(self: *Sema, c: *ast.Call, call_node: ast.NodeRef, scope: *Scope) []const u8 {
        const callee = c.callee;
        // @sizeOf[T]() — compile-time byte size of T, returns i32
        if (callee.* == .var_ and std.mem.eql(u8, callee.*.var_.name, "@sizeOf")) {
            ast.setNodeType(call_node, "i32");
            return "i32";
        }
        // Module call: mod.fn(args)
        if (callee.* == .field) {
            const fld = &callee.*.field;
            if (fld.base.* == .var_) {
                const vname = fld.base.*.var_.name;
                if (self.modules.get(vname)) |_| {
                    const prefix = self.modules.get(vname).?;
                    const mangled = std.fmt.allocPrint(self.alloc, "{s}{s}", .{ prefix, fld.fname }) catch fld.fname;
                    ast.setNodeType(fld.base, std.fmt.allocPrint(self.alloc, "module:{s}", .{vname}) catch "module");
                    // Generic module fn: mod.fn[T](args) or mod.fn(args) with inference
                    if (self.generic_fns.get(mangled)) |g_node| {
                        const g = &g_node.*.fn_decl;
                        for (c.args) |a| _ = self.typeOf(a, scope);
                        var cargs = std.ArrayList([]const u8).init(self.alloc);
                        defer cargs.deinit();
                        if (c.targs.len > 0) {
                            for (c.targs) |ta| cargs.append(self.resolveType(ta)) catch {};
                        } else {
                            var argtys = std.ArrayList([]const u8).init(self.alloc);
                            defer argtys.deinit();
                            for (c.args) |a| argtys.append(ast.nodeType(a) orelse "i32") catch {};
                            var sub = std.StringHashMap([]const u8).init(self.alloc);
                            defer sub.deinit();
                            for (g.params, 0..) |p, i| {
                                if (i < argtys.items.len)
                                    types.unify(self.alloc, p.pty, argtys.items[i], g.tparams, &sub);
                            }
                            for (g.tparams) |tp| {
                                if (sub.get(tp)) |ct| cargs.append(ct) catch {}
                                else {
                                    self.errFmt(c.line, "cannot infer type parameter '{s}' of '{s}'", .{ tp, fld.fname });
                                    cargs.append("i32") catch {};
                                }
                            }
                        }
                        const inst_name = self.instFn(mangled, cargs.items);
                        c.inst_name = inst_name;
                        const ret = self.fns.get(inst_name).?.*.fn_decl.ret;
                        ast.setNodeType(call_node, ret);
                        return ret;
                    }
                    if (self.fns.get(mangled)) |decl_node| {
                        const decl = &decl_node.*.fn_decl;
                        for (c.args) |a| _ = self.typeOf(a, scope);
                        if (decl.params.len != c.args.len) {
                            self.errFmt(c.line, "module fn '{s}' expects {d} args, got {d}",
                                .{ fld.fname, decl.params.len, c.args.len });
                        } else {
                            for (c.args, decl.params) |a, p| {
                                if (!types.assignable(p.pty, ast.nodeType(a) orelse "i32"))
                                    self.errFmt(c.line, "arg '{s}': expected {s}, got {s}",
                                        .{ p.name, p.pty, ast.nodeType(a) orelse "i32" });
                            }
                        }
                        ast.setNodeType(call_node, decl.ret);
                        return decl.ret;
                    }
                    self.errFmt(c.line, "module '{s}' has no fn '{s}'", .{ vname, fld.fname });
                    return "i32";
                }
            }
            // Method call: obj.method(args)
            const base_ty = self.typeOf(fld.base, scope);
            // Interface dynamic dispatch: base is an interface fat-pointer.
            if (self.interfaces.contains(base_ty)) {
                for (c.args) |a| _ = self.typeOf(a, scope);
                if (self.ifaceMethod(base_ty, fld.fname)) |m| {
                    if (m.params.len != c.args.len)
                        self.errFmt(c.line, "interface method '{s}.{s}' expects {d} args, got {d}",
                            .{ base_ty, fld.fname, m.params.len, c.args.len });
                    ast.setNodeType(call_node, m.ret);
                    return m.ret;
                }
                self.errFmt(c.line, "interface '{s}' has no method '{s}'", .{ base_ty, fld.fname });
                ast.setNodeType(call_node, "i32");
                return "i32";
            }
            const method_key = std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ base_ty, fld.fname }) catch fld.fname;
            if (self.methods.get(method_key)) |meth_node| {
                const meth = &meth_node.*.fn_decl;
                for (c.args) |a| _ = self.typeOf(a, scope);
                if (meth.params.len != c.args.len) {
                    self.errFmt(c.line, "method '{s}.{s}' expects {d} args, got {d}",
                        .{ base_ty, fld.fname, meth.params.len, c.args.len });
                } else {
                    for (c.args, meth.params) |a, p| {
                        if (!types.assignable(p.pty, ast.nodeType(a) orelse "i32"))
                            self.errFmt(c.line, "arg '{s}': expected {s}, got {s}",
                                .{ p.name, p.pty, ast.nodeType(a) orelse "i32" });
                    }
                }
                ast.setNodeType(call_node, meth.ret);
                return meth.ret;
            }
        }
        // new() / delete() builtins
        if (callee.* == .var_) {
            const vname_nd = callee.*.var_.name;
            if (std.mem.eql(u8, vname_nd, "new")) {
                if (c.args.len > 0) {
                    const inner_ty = self.typeOf(c.args[0], scope);
                    const ptr_ty = std.fmt.allocPrint(self.alloc, "*{s}", .{inner_ty}) catch "*void";
                    ast.setNodeType(call_node, ptr_ty);
                    return ptr_ty;
                }
                ast.setNodeType(call_node, "*void");
                return "*void";
            }
            if (std.mem.eql(u8, vname_nd, "delete")) {
                for (c.args) |a| _ = self.typeOf(a, scope);
                ast.setNodeType(call_node, "void");
                return "void";
            }
        }
        // Generic fn call
        if (callee.* == .var_) {
            const vname = callee.*.var_.name;
            if (self.generic_fns.get(vname)) |g_node| {
                const g = &g_node.*.fn_decl;
                for (c.args) |a| _ = self.typeOf(a, scope);
                var cargs = std.ArrayList([]const u8).init(self.alloc);
                defer cargs.deinit();
                if (c.targs.len > 0) {
                    // Explicit instantiation: foo[T1,T2](args)
                    if (c.targs.len != g.tparams.len)
                        self.errFmt(c.line, "fn '{s}' expects {d} type args, got {d}",
                            .{ vname, g.tparams.len, c.targs.len });
                    for (c.targs) |ta| cargs.append(self.resolveType(ta)) catch {};
                } else {
                    // Infer type params from value-argument types.
                    var argtys = std.ArrayList([]const u8).init(self.alloc);
                    defer argtys.deinit();
                    for (c.args) |a| argtys.append(ast.nodeType(a) orelse "i32") catch {};
                    var sub = std.StringHashMap([]const u8).init(self.alloc);
                    defer sub.deinit();
                    for (g.params, 0..) |p, i| {
                        if (i < argtys.items.len)
                            types.unify(self.alloc, p.pty, argtys.items[i], g.tparams, &sub);
                    }
                    for (g.tparams) |tp| {
                        if (sub.get(tp)) |ct| {
                            cargs.append(ct) catch {};
                        } else {
                            self.errFmt(c.line, "cannot infer type parameter '{s}' of '{s}'", .{ tp, vname });
                            cargs.append("i32") catch {};
                        }
                    }
                }
                const inst_name = self.instFn(vname, cargs.items);
                c.inst_name = inst_name;
                const ret = self.fns.get(inst_name).?.*.fn_decl.ret;
                ast.setNodeType(call_node, ret);
                return ret;
            }
            // Direct named fn call
            if (self.fns.get(vname)) |decl_node| {
                const decl = &decl_node.*.fn_decl;
                for (c.args) |a| _ = self.typeOf(a, scope);
                if (decl.params.len == c.args.len) {
                    for (c.args, decl.params) |a, p| {
                        const arg_ty = ast.nodeType(a) orelse "i32";
                        // Structural ("duck") coercion: a concrete type may be
                        // passed where an interface is expected if it implements it.
                        if (self.interfaces.contains(p.pty)) {
                            if (!types.assignable(p.pty, arg_ty)) {
                                _ = self.structurallySatisfies(arg_ty, p.pty, c.line);
                            }
                            continue;
                        }
                        annotateOptionalArg(a, p.pty, arg_ty);
                        if (!types.assignable(p.pty, arg_ty))
                            self.errFmt(c.line, "arg '{s}': expected {s}, got {s}", .{ p.name, p.pty, arg_ty });
                    }
                } else if (c.args.len != 0) {
                    self.errFmt(c.line, "fn '{s}' expects {d} args, got {d}",
                        .{ vname, decl.params.len, c.args.len });
                }
                ast.setNodeType(call_node, decl.ret);
                return decl.ret;
            }
        }
        // Fallback: type the callee and use fn type
        const ct = self.typeOf(callee, scope);
        for (c.args) |a| _ = self.typeOf(a, scope);
        if (types.isFnType(ct)) {
            var buf: [4096]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const parts = types.fnParts(fba.allocator(), ct) catch {
                ast.setNodeType(call_node, "i32");
                return "i32";
            };
            if (parts.params.len != c.args.len)
                self.errFmt(c.line, "call expects {d} args, got {d}", .{ parts.params.len, c.args.len });
            for (c.args, 0..) |a, i| {
                if (i < parts.params.len) {
                    const arg_ty = ast.nodeType(a) orelse "i32";
                    annotateOptionalArg(a, parts.params[i], arg_ty);
                    if (!types.assignable(parts.params[i], arg_ty))
                        self.errFmt(c.line, "arg type mismatch: expected {s}, got {s}",
                            .{ parts.params[i], arg_ty });
                }
            }
            ast.setNodeType(call_node, parts.ret);
            return parts.ret;
        }
        self.errFmt(c.line, "called a non-function value", .{});
        return "i32";
    }

    // ── checkBlock ────────────────────────────────────────────────────────────

    pub fn checkBlock(self: *Sema, stmts: []ast.NodeRef, scope: *Scope, fn_node: ?ast.NodeRef) void {
        for (stmts) |s| {
            switch (s.*) {
                .let => |*l| {
                    if (l.dty) |dty| l.dty = self.resolveType(dty);
                    const t = self.typeOf(l.expr, scope);
                    if (l.dty) |dty| {
                        if (!types.assignable(dty, t))
                            self.errFmt(l.line, "let {s}: declared {s} but initializer is {s}", .{ l.name, dty, t });
                        // Propagate context type to NullLit
                        if (std.mem.eql(u8, t, "null") and types.isOptional(dty) and l.expr.* == .null_lit)
                            l.expr.*.null_lit.ty = dty;
                        scope.put(l.name, dty) catch {};
                    } else {
                        scope.put(l.name, types.defaultTy(t)) catch {};
                    }
                },
                .assign => |*a| {
                    const tt = self.typeOf(a.target, scope);
                    const et = self.typeOf(a.expr, scope);
                    if (!types.assignable(tt, et))
                        self.errFmt(a.line, "assignment type mismatch: {s} = {s}", .{ tt, et });
                },
                .return_ => |*r| {
                    const rt = if (r.expr) |re| self.typeOf(re, scope) else "void";
                    const fn_ret = if (fn_node) |fn_n| fn_n.*.fn_decl.ret else "void";
                    // Propagate context type to NullLit
                    if (r.expr) |re| {
                        if (std.mem.eql(u8, rt, "null") and types.isOptional(fn_ret) and re.* == .null_lit)
                            re.*.null_lit.ty = fn_ret;
                    }
                    const fn_name = if (fn_node) |fn_n| fn_n.*.fn_decl.name else "<anonymous>";
                    if (types.isErrorUnion(fn_ret)) {
                        const T = types.errorInner(fn_ret);
                        if (!std.mem.eql(u8, rt, "err") and !types.assignable(fn_ret, rt) and !types.assignable(T, rt))
                            self.errFmt(r.line, "return type mismatch in '{s}': expected {s} or {s}, got {s}",
                                .{ fn_name, fn_ret, T, rt });
                    } else if (types.isOptional(fn_ret)) {
                        const T = types.optionalInner(fn_ret);
                        if (!std.mem.eql(u8, rt, "null") and !types.assignable(fn_ret, rt) and !types.assignable(T, rt))
                            self.errFmt(r.line, "return type mismatch in '{s}': expected {s} or {s}, got {s}",
                                .{ fn_name, fn_ret, T, rt });
                    } else if (!types.assignable(fn_ret, rt)) {
                        self.errFmt(r.line, "return type mismatch in '{s}': expected {s}, got {s}",
                            .{ fn_name, fn_ret, rt });
                    }
                },
                .if_ => |*i| {
                    const cond_ty = self.typeOf(i.cond, scope);
                    var then_scope = self.cloneScope(scope);
                    defer then_scope.deinit();
                    if (i.cap) |cap| {
                        if (!types.isOptional(cond_ty))
                            self.errFmt(i.line, "if |cap| requires optional condition, got '{s}'", .{cond_ty});
                        const inner = if (types.isOptional(cond_ty)) types.optionalInner(cond_ty) else cond_ty;
                        then_scope.put(cap, inner) catch {};
                    }
                    self.checkBlock(i.then, &then_scope, fn_node);
                    if (i.els) |els| {
                        var els_scope = self.cloneScope(scope);
                        defer els_scope.deinit();
                        self.checkBlock(els, &els_scope, fn_node);
                    }
                },
                .while_ => |*w| {
                    const cond_ty = self.typeOf(w.cond, scope);
                    var body_scope = self.cloneScope(scope);
                    defer body_scope.deinit();
                    if (w.cap) |cap| {
                        if (!types.isOptional(cond_ty))
                            self.errFmt(w.line, "while |cap| requires optional condition, got '{s}'", .{cond_ty});
                        const inner = if (types.isOptional(cond_ty)) types.optionalInner(cond_ty) else cond_ty;
                        body_scope.put(cap, inner) catch {};
                    }
                    self.checkBlock(w.body, &body_scope, fn_node);
                },
                .switch_ => |*sw| {
                    const st = self.typeOf(sw.subject, scope);
                    var arm_tys = std.ArrayList([]const u8).init(self.alloc);
                    defer arm_tys.deinit();

                    if (self.enums.get(st)) |enum_node| {
                        const ed = &enum_node.*.enum_decl;
                        var covered = std.StringHashMap(void).init(self.alloc);
                        defer covered.deinit();
                        for (sw.arms) |arm| {
                            for (arm.tags) |tag| {
                                var found = false;
                                for (ed.members) |m| if (std.mem.eql(u8, m, tag)) { found = true; break; };
                                if (!found) self.errFmt(sw.line, "enum '{s}' has no member '{s}'", .{ st, tag });
                                covered.put(tag, {}) catch {};
                            }
                            if (arm.cap != null)
                                self.errFmt(sw.line, "enum arm '.{s}' takes no capture", .{arm.tags[0]});
                            var arm_scope = self.cloneScope(scope);
                            defer arm_scope.deinit();
                            self.checkBlock(arm.body, &arm_scope, fn_node);
                            if (sw.is_expr and arm.body.len > 0)
                                arm_tys.append(self.typeOf(arm.body[0], scope)) catch {};
                        }
                        if (sw.els == null) {
                            for (ed.members) |m| {
                                if (!covered.contains(m))
                                    self.errFmt(sw.line, "non-exhaustive switch on enum '{s}': missing '{s}'", .{ st, m });
                            }
                        }
                    } else if (self.unions.get(st)) |union_node| {
                        const ud = &union_node.*.union_decl;
                        var vt = std.StringHashMap([]const u8).init(self.alloc);
                        defer vt.deinit();
                        for (ud.fields) |f| vt.put(f.name, f.pty) catch {};
                        var covered = std.StringHashMap(void).init(self.alloc);
                        defer covered.deinit();
                        for (sw.arms) |arm| {
                            for (arm.tags) |tag| {
                                if (!vt.contains(tag))
                                    self.errFmt(sw.line, "union '{s}' has no variant '{s}'", .{ st, tag });
                                covered.put(tag, {}) catch {};
                            }
                            var arm_scope = self.cloneScope(scope);
                            defer arm_scope.deinit();
                            if (arm.cap) |cap| {
                                const vpty = if (arm.tags.len > 0) vt.get(arm.tags[0]) orelse "i32" else "i32";
                                arm_scope.put(cap, vpty) catch {};
                            }
                            self.checkBlock(arm.body, &arm_scope, fn_node);
                            if (sw.is_expr and arm.body.len > 0)
                                arm_tys.append(self.typeOf(arm.body[0], &arm_scope)) catch {};
                        }
                        if (sw.els == null) {
                            var vit = vt.iterator();
                            while (vit.next()) |kv| {
                                if (!covered.contains(kv.key_ptr.*))
                                    self.errFmt(sw.line, "non-exhaustive switch on union '{s}': missing '{s}'", .{ st, kv.key_ptr.* });
                            }
                        }
                    } else {
                        var is_int = false;
                        for (&types.INT_TYPES) |s2| if (std.mem.eql(u8, s2, st)) { is_int = true; break; };
                        if (is_int) {
                            for (sw.arms) |arm| {
                                for (arm.tags) |tag| {
                                    _ = std.fmt.parseInt(i64, tag, 10) catch {
                                        self.errFmt(sw.line, "switch on integer: expected literal, got '.{s}'", .{tag});
                                    };
                                }
                                if (arm.cap != null)
                                    self.errFmt(sw.line, "integer arm takes no capture", .{});
                                var arm_scope = self.cloneScope(scope);
                                defer arm_scope.deinit();
                                self.checkBlock(arm.body, &arm_scope, fn_node);
                                if (sw.is_expr and arm.body.len > 0)
                                    arm_tys.append(self.typeOf(arm.body[0], scope)) catch {};
                            }
                            if (sw.els == null)
                                self.errFmt(sw.line, "integer switch requires an else arm", .{});
                        } else {
                            self.errFmt(sw.line, "switch subject must be an enum, union, or integer, got '{s}'", .{st});
                        }
                    }
                    if (sw.els) |els| {
                        var els_scope = self.cloneScope(scope);
                        defer els_scope.deinit();
                        self.checkBlock(els, &els_scope, fn_node);
                        if (sw.is_expr and els.len > 0)
                            arm_tys.append(self.typeOf(els[0], scope)) catch {};
                    }
                    // Expression switch: check arm types agree
                    if (sw.is_expr and arm_tys.items.len > 0) {
                        const ty0 = arm_tys.items[0];
                        for (arm_tys.items[1..]) |aty| {
                            if (!types.assignable(ty0, aty) and !types.assignable(aty, ty0))
                                self.errFmt(sw.line, "expression switch arm types disagree: {s} vs {s}", .{ ty0, aty });
                        }
                        sw.switch_ty = ty0;
                    }
                },
                .expr_stmt => |*es| _ = self.typeOf(es.expr, scope),
                else => {},
            }
        }
    }

    // ── Effect analysis ───────────────────────────────────────────────────────

    /// Effect witness map: effect name → list of strings forming a call chain.
    const WitMap = std.StringHashMap([][]const u8);

    /// Latent entry: the bound (eff, wit) for a function-typed local/parameter.
    const LatEntry = struct {
        eff: std.StringHashMap(void),
        wit: WitMap,
    };

    /// Map from fn-param name → its latent effects at this call site.
    const LatMap = std.StringHashMap(LatEntry);

    pub fn checkCapabilities(self: *Sema) !Report {
        var violations = std.ArrayList(EffectViolation).init(self.alloc);
        var proven_list = std.ArrayList(AnnotationEntry).init(self.alloc);

        var fit = self.fns.iterator();
        while (fit.next()) |kv| {
            const fn_node = kv.value_ptr.*;
            const f = &fn_node.*.fn_decl;
            if (f.is_extern or f.annots.len == 0) continue;
            var eff_set = std.StringHashMap(void).init(self.alloc);
            defer eff_set.deinit();
            var wit_map = WitMap.init(self.alloc);
            defer wit_map.deinit();
            self.analyzeFn(f.name, &eff_set, &wit_map);

            // Collect forbidden effects for all annotations
            var forbidden = std.StringHashMap(void).init(self.alloc);
            defer forbidden.deinit();
            for (f.annots) |a| {
                for (types.forbids(a)) |fe| forbidden.put(fe, {}) catch {};
            }

            // Find violations
            var viol_effs = std.ArrayList([]const u8).init(self.alloc);
            var viol_wit  = std.ArrayList([]const u8).init(self.alloc);
            var eit = eff_set.iterator();
            while (eit.next()) |ekv| {
                if (forbidden.contains(ekv.key_ptr.*)) {
                    viol_effs.append(ekv.key_ptr.*) catch {};
                }
            }

            // @total: try Z3/ghost_engine to discharge Panic
            if (viol_effs.items.len > 0) {
                for (f.annots) |a| {
                    const first_viol = viol_effs.items[0];
                    // Find the annotation that forbids this effect
                    for (types.forbids(a)) |fe| {
                        if (std.mem.eql(u8, fe, first_viol)) {
                            if (wit_map.get(first_viol)) |w| {
                                for (w) |ws| viol_wit.append(ws) catch {};
                            }
                            const msg = std.fmt.allocPrint(self.alloc,
                                "capability violation: '{s}' is {s} but may {s}:\n            {s}   [introduces {s}]",
                                .{ f.name, a, first_viol,
                                   std.mem.join(self.alloc, " → ", viol_wit.items) catch first_viol,
                                   first_viol }) catch "capability violation";
                            self.errors.append(msg) catch {};
                            break;
                        }
                    }
                }
                try violations.append(.{
                    .fn_name = f.name,
                    .annot   = f.annots[0],
                    .effects = try viol_effs.toOwnedSlice(),
                    .witness = try viol_wit.toOwnedSlice(),
                });
            }
        }

        return Report{
            .violations  = try violations.toOwnedSlice(),
            .annotations = try proven_list.toOwnedSlice(),
        };
    }

    /// Public accessor: the inferred latent effect set of a named function, as
    /// a freshly-allocated, sorted slice of effect-name strings.  Used by the
    /// AI-native dependency-graph emitter (`zagc deps`).
    pub fn effectsOfFn(self: *Sema, name: []const u8) [][]const u8 {
        var eff_set = std.StringHashMap(void).init(self.alloc);
        defer eff_set.deinit();
        var wit_map = WitMap.init(self.alloc);
        defer wit_map.deinit();
        self.analyzeFn(name, &eff_set, &wit_map);

        var out = std.ArrayList([]const u8).init(self.alloc);
        // Emit in the canonical ALL_EFFECTS order for stable output.
        for (types.ALL_EFFECTS) |e| {
            if (eff_set.contains(e)) out.append(e) catch {};
        }
        return out.toOwnedSlice() catch &.{};
    }

    /// Analyze a named function's effects (no call-site env; uses memo cache).
    fn analyzeFn(self: *Sema, name: []const u8, eff_set: *std.StringHashMap(void), wit_map: *WitMap) void {
        // Check builtins
        if (types.getBuiltin(name)) |b| {
            for (b.eff) |e| {
                eff_set.put(e, {}) catch {};
                if (!wit_map.contains(e)) {
                    const chain = self.alloc.alloc([]const u8, 1) catch continue;
                    chain[0] = std.fmt.allocPrint(self.alloc, "{s}()", .{name}) catch name;
                    wit_map.put(e, chain) catch {};
                }
            }
            return;
        }
        const fn_node = self.fns.get(name) orelse return;
        const f = &fn_node.*.fn_decl;
        if (f.is_extern or f.body == null) return;
        // Cycle guard via memo
        if (self.fn_effects.contains(name)) {
            if (self.fn_effects.get(name)) |cached| {
                for (cached) |e| eff_set.put(e, {}) catch {};
            }
            return;
        }
        // Mark as being visited (empty sentinel)
        self.fn_effects.put(name, &.{}) catch {};
        var local_effs = std.StringHashMap(void).init(self.alloc);
        defer local_effs.deinit();
        var local_wit = WitMap.init(self.alloc);
        defer local_wit.deinit();
        var local_lat = LatMap.init(self.alloc);
        defer {
            var it = local_lat.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.eff.deinit();
                kv.value_ptr.wit.deinit();
            }
            local_lat.deinit();
        }
        // Pre-populate local_lat with fn-type parameters using their declared row
        for (f.params) |p| {
            if (types.isFnType(p.pty)) {
                // Create a synthetic Var node pointing to this param
                var dummy_var = ast.Node{ .var_ = .{
                    .name = p.name,
                    .line = f.line,
                    .ty   = p.pty,
                }};
                const entry = self.latentExprEntry(&dummy_var, &local_lat);
                local_lat.put(p.name, entry) catch {};
            }
        }
        self.effectsBlock(f.body.?, name, &local_effs, &local_wit, &local_lat);
        // Copy to output
        var eit = local_effs.iterator();
        while (eit.next()) |ekv| {
            eff_set.put(ekv.key_ptr.*, {}) catch {};
            if (local_wit.get(ekv.key_ptr.*)) |chain| {
                if (!wit_map.contains(ekv.key_ptr.*))
                    wit_map.put(ekv.key_ptr.*, chain) catch {};
            }
        }
        // Cache
        var cached_effs = std.ArrayList([]const u8).init(self.alloc);
        var eit2 = local_effs.iterator();
        while (eit2.next()) |ekv| cached_effs.append(ekv.key_ptr.*) catch {};
        const cached_slice: [][]const u8 = cached_effs.toOwnedSlice() catch blk: {
            var empty = [_][]const u8{};
            break :blk empty[0..];
        };
        self.fn_effects.put(name, cached_slice) catch {};
    }

    /// Analyze with a per-call-site env mapping fn-param names to their latent effects.
    fn analyzeFnWithEnv(
        self: *Sema,
        name: []const u8,
        env: *LatMap,
        eff_set: *std.StringHashMap(void),
        wit_map: *WitMap,
    ) void {
        // Check builtins
        if (types.getBuiltin(name)) |b| {
            for (b.eff) |e| {
                eff_set.put(e, {}) catch {};
                if (!wit_map.contains(e)) {
                    const chain = self.alloc.alloc([]const u8, 1) catch continue;
                    chain[0] = std.fmt.allocPrint(self.alloc, "{s}()", .{name}) catch name;
                    wit_map.put(e, chain) catch {};
                }
            }
            return;
        }
        const fn_node = self.fns.get(name) orelse return;
        const f = &fn_node.*.fn_decl;
        if (f.is_extern or f.body == null) return;
        // If env is empty, use the memoized version
        if (env.count() == 0) {
            self.analyzeFn(name, eff_set, wit_map);
            return;
        }
        // With a non-empty env, analyze the body directly (no memoization since it's call-site specific)
        var local_effs = std.StringHashMap(void).init(self.alloc);
        defer local_effs.deinit();
        var local_wit = WitMap.init(self.alloc);
        defer local_wit.deinit();
        // Start from the provided env (call-site bindings for fn-type params)
        var local_lat = LatMap.init(self.alloc);
        defer {
            // Only deinit entries we added (not the ones from env that we copied)
            var it = local_lat.iterator();
            while (it.next()) |kv| {
                kv.value_ptr.eff.deinit();
                kv.value_ptr.wit.deinit();
            }
            local_lat.deinit();
        }
        // Copy env entries into local_lat; we need our own copies since we'll deinit
        var env_it = env.iterator();
        while (env_it.next()) |kv| {
            var entry = LatEntry{
                .eff = std.StringHashMap(void).init(self.alloc),
                .wit = WitMap.init(self.alloc),
            };
            var eit = kv.value_ptr.eff.iterator();
            while (eit.next()) |ekv| entry.eff.put(ekv.key_ptr.*, {}) catch {};
            var wit_it = kv.value_ptr.wit.iterator();
            while (wit_it.next()) |wkv| entry.wit.put(wkv.key_ptr.*, wkv.value_ptr.*) catch {};
            local_lat.put(kv.key_ptr.*, entry) catch {};
        }
        // Pre-populate local_lat with fn-type parameters NOT overridden by env
        for (f.params) |p| {
            if (types.isFnType(p.pty) and !local_lat.contains(p.name)) {
                var dummy_var = ast.Node{ .var_ = .{
                    .name = p.name,
                    .line = f.line,
                    .ty   = p.pty,
                }};
                const entry = self.latentExprEntry(&dummy_var, &local_lat);
                local_lat.put(p.name, entry) catch {};
            }
        }
        self.effectsBlock(f.body.?, name, &local_effs, &local_wit, &local_lat);
        var eit2 = local_effs.iterator();
        while (eit2.next()) |ekv| {
            eff_set.put(ekv.key_ptr.*, {}) catch {};
            if (local_wit.get(ekv.key_ptr.*)) |chain| {
                if (!wit_map.contains(ekv.key_ptr.*))
                    wit_map.put(ekv.key_ptr.*, chain) catch {};
            }
        }
    }

    /// Compute the latent effects of a function-valued expression into a LatEntry.
    fn latentExprEntry(self: *Sema, e: ast.NodeRef, local_lat: *LatMap) LatEntry {
        var entry = LatEntry{
            .eff = std.StringHashMap(void).init(self.alloc),
            .wit = WitMap.init(self.alloc),
        };
        switch (e.*) {
            .var_ => |*v| {
                // Check if it's in local_lat (a fn-valued param bound at this call site)
                if (local_lat.get(v.name)) |lat| {
                    var eit = lat.eff.iterator();
                    while (eit.next()) |ekv| entry.eff.put(ekv.key_ptr.*, {}) catch {};
                    var wit_it = lat.wit.iterator();
                    while (wit_it.next()) |wkv| entry.wit.put(wkv.key_ptr.*, wkv.value_ptr.*) catch {};
                    return entry;
                }
                // Check if it's a known fn
                if (self.fns.contains(v.name) or types.getBuiltin(v.name) != null) {
                    self.analyzeFn(v.name, &entry.eff, &entry.wit);
                    return entry;
                }
                // Opaque fn-type param or variable: use declared row
                const ty = v.ty orelse "";
                if (types.isFnType(ty)) {
                    // Use latent_when_opaque: for bound annotations, effects are ALL_EFFECTS minus forbidden
                    // For plain fn type, all effects
                    const row = types.rowOf(ty);
                    if (row) |r| {
                        switch (r.kind) {
                            .bound => {
                                // May do anything NOT forbidden
                                outer: for (&types.ALL_EFFECTS) |eff| {
                                    for (r.effects) |fe| {
                                        if (std.mem.eql(u8, eff, fe)) continue :outer;
                                    }
                                    entry.eff.put(eff, {}) catch {};
                                    if (!entry.wit.contains(eff)) {
                                        const chain = self.alloc.alloc([]const u8, 1) catch continue;
                                        chain[0] = std.fmt.allocPrint(self.alloc, "opaque callback '{s}' (bound)", .{v.name}) catch v.name;
                                        entry.wit.put(eff, chain) catch {};
                                    }
                                }
                            },
                            .row => {
                                // Exactly the declared latent effects
                                for (r.effects) |eff| {
                                    entry.eff.put(eff, {}) catch {};
                                }
                            },
                            .variable => {
                                // Effect variable: conservative
                                for (&types.ALL_EFFECTS) |eff| {
                                    entry.eff.put(eff, {}) catch {};
                                }
                            },
                        }
                    } else {
                        // Plain fn type: all effects
                        for (&types.ALL_EFFECTS) |eff| {
                            entry.eff.put(eff, {}) catch {};
                            if (!entry.wit.contains(eff)) {
                                const chain = self.alloc.alloc([]const u8, 1) catch continue;
                                chain[0] = std.fmt.allocPrint(self.alloc, "opaque callback '{s}'", .{v.name}) catch v.name;
                                entry.wit.put(eff, chain) catch {};
                            }
                        }
                    }
                    return entry;
                }
                // Opaque non-fn: all effects
                for (&types.ALL_EFFECTS) |eff| {
                    entry.eff.put(eff, {}) catch {};
                }
                return entry;
            },
            .closure => |*cl| {
                var inner_lat = LatMap.init(self.alloc);
                defer {
                    var it = inner_lat.iterator();
                    while (it.next()) |kv| {
                        kv.value_ptr.eff.deinit();
                        kv.value_ptr.wit.deinit();
                    }
                    inner_lat.deinit();
                }
                self.effectsBlock(cl.body, "<closure>", &entry.eff, &entry.wit, &inner_lat);
                return entry;
            },
            else => {
                // Conservative: all effects
                for (&types.ALL_EFFECTS) |eff| {
                    entry.eff.put(eff, {}) catch {};
                    if (!entry.wit.contains(eff)) {
                        const chain = self.alloc.alloc([]const u8, 1) catch continue;
                        chain[0] = "unknown function value";
                        entry.wit.put(eff, chain) catch {};
                    }
                }
                return entry;
            },
        }
    }

    fn effectsBlock(
        self: *Sema,
        stmts: []ast.NodeRef,
        label: []const u8,
        eff_set: *std.StringHashMap(void),
        wit_map: *WitMap,
        local_lat: *LatMap,
    ) void {
        for (stmts) |s| self.effectsStmt(s, label, eff_set, wit_map, local_lat);
    }

    fn addEffect(
        self: *Sema,
        ename: []const u8,
        chain: []const u8,
        label: []const u8,
        eff_set: *std.StringHashMap(void),
        wit_map: *WitMap,
    ) void {
        eff_set.put(ename, {}) catch {};
        if (!wit_map.contains(ename)) {
            const c = self.alloc.alloc([]const u8, 2) catch return;
            c[0] = label;
            c[1] = chain;
            wit_map.put(ename, c) catch {};
        }
    }

    fn effectsExpr(
        self: *Sema,
        x: ast.NodeRef,
        label: []const u8,
        eff_set: *std.StringHashMap(void),
        wit_map: *WitMap,
        local_lat: *LatMap,
    ) void {
        switch (x.*) {
            .bin => |*b| {
                const lt = ast.nodeType(b.l) orelse "";
                const rt = ast.nodeType(b.r) orelse "";
                // Operator contract: +/-/*// on a contracted type inherits the
                // effect of the named decode fn — so a contract naming an
                // allocating decoder breaks @realtime with a precise witness.
                if (lt.len > 0 and std.mem.eql(u8, lt, rt)) {
                    if (self.opContractFn(lt, b.op)) |decode| {
                        for (self.effectsOfFn(decode)) |ef| {
                            const chain = std.fmt.allocPrint(self.alloc,
                                "'{s}' on {s} → {s}() at line {d}", .{ b.op, lt, decode, b.line }) catch decode;
                            self.addEffect(ef, chain, label, eff_set, wit_map);
                        }
                    }
                }
                // bignum arithmetic may heap-allocate
                if (types.isBignum(lt) or types.isBignum(rt)) {
                    const chain = std.fmt.allocPrint(self.alloc,
                        "bignum arithmetic at line {d} (may heap-promote on overflow)", .{b.line}) catch "bignum";
                    self.addEffect("Alloc", chain, label, eff_set, wit_map);
                }
                // integer division/modulo: Panic unless divisor is a nonzero literal
                if (std.mem.eql(u8, b.op, "/") or std.mem.eql(u8, b.op, "%")) {
                    const is_sat = types.isSat(lt) or types.isSat(rt);
                    const is_float = types.isFloat(lt) or types.isFloat(rt);
                    const safe = blk: {
                        if (b.r.* == .lit) {
                            const lv = &b.r.*.lit;
                            if (lv.lty == .int_lit) {
                                const n = std.fmt.parseInt(i64, lv.val, 10) catch break :blk false;
                                break :blk n != 0;
                            }
                        }
                        break :blk false;
                    };
                    if (!safe and !is_float and !is_sat) {
                        const chain = std.fmt.allocPrint(self.alloc,
                            "'{s}' at line {d} (divisor not provably nonzero)", .{ b.op, b.line }) catch "division";
                        self.addEffect("Panic", chain, label, eff_set, wit_map);
                    }
                }
                self.effectsExpr(b.l, label, eff_set, wit_map, local_lat);
                self.effectsExpr(b.r, label, eff_set, wit_map, local_lat);
            },
            .un => |*u| self.effectsExpr(u.e, label, eff_set, wit_map, local_lat),
            .index => |*i| {
                self.effectsExpr(i.base, label, eff_set, wit_map, local_lat);
                self.effectsExpr(i.idx, label, eff_set, wit_map, local_lat);
            },
            .cast => |*c| self.effectsExpr(c.expr, label, eff_set, wit_map, local_lat),
            .slice => |*sl| {
                self.effectsExpr(sl.base, label, eff_set, wit_map, local_lat);
                self.effectsExpr(sl.lo, label, eff_set, wit_map, local_lat);
                self.effectsExpr(sl.hi, label, eff_set, wit_map, local_lat);
            },
            .field => |*f| self.effectsExpr(f.base, label, eff_set, wit_map, local_lat),
            .struct_lit => |*sl| {
                for (sl.fields) |fi| self.effectsExpr(fi.val, label, eff_set, wit_map, local_lat);
            },
            .err_lit, .null_lit => {},
            .try_ => |inner| self.effectsExpr(inner, label, eff_set, wit_map, local_lat),
            .catch_ => |*c| {
                self.effectsExpr(c.expr, label, eff_set, wit_map, local_lat);
                self.effectsExpr(c.default, label, eff_set, wit_map, local_lat);
            },
            .or_else => |*oe| {
                self.effectsExpr(oe.expr, label, eff_set, wit_map, local_lat);
                self.effectsExpr(oe.default, label, eff_set, wit_map, local_lat);
            },
            .force_unwrap => |inner| self.effectsExpr(inner, label, eff_set, wit_map, local_lat),
            .closure => {}, // Defining a closure has no immediate effect
            .call => |*c| {
                for (c.args) |a| self.effectsExpr(a, label, eff_set, wit_map, local_lat);
                const callee = c.callee;
                // Resolve callee name
                var cn: ?[]const u8 = c.inst_name;
                if (cn == null) {
                    if (callee.* == .var_) cn = callee.*.var_.name;
                }
                // Method calls
                if (cn == null and callee.* == .field) {
                    const base_ty = ast.nodeType(callee.*.field.base) orelse "";
                    if (base_ty.len > 0) {
                        const mk = std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ base_ty, callee.*.field.fname }) catch "";
                        if (self.methods.get(mk)) |mn| cn = mn.*.fn_decl.name;
                    }
                }
                if (cn) |cname| {
                    // new() / delete() builtins
                    if (std.mem.eql(u8, cname, "new")) {
                        const chain_new = std.fmt.allocPrint(self.alloc,
                            "new() at line {d} (heap allocation, may OOM)", .{c.line}) catch "new()";
                        self.addEffect("Alloc", chain_new, label, eff_set, wit_map);
                        self.addEffect("Panic", chain_new, label, eff_set, wit_map);
                        return;
                    }
                    if (std.mem.eql(u8, cname, "delete")) {
                        const chain_del = std.fmt.allocPrint(self.alloc,
                            "delete() at line {d} (heap deallocation)", .{c.line}) catch "delete()";
                        self.addEffect("Alloc", chain_del, label, eff_set, wit_map);
                        return;
                    }
                    // 1. If callee is a fn-valued local/param bound in local_lat, use its effects directly.
                    if (local_lat.get(cname)) |lat_entry| {
                        var eit = lat_entry.eff.iterator();
                        while (eit.next()) |ekv| {
                            eff_set.put(ekv.key_ptr.*, {}) catch {};
                            if (lat_entry.wit.get(ekv.key_ptr.*)) |chain| {
                                if (!wit_map.contains(ekv.key_ptr.*)) {
                                    var new_chain = std.ArrayList([]const u8).init(self.alloc);
                                    new_chain.append(label) catch {};
                                    for (chain) |cs| new_chain.append(cs) catch {};
                                    wit_map.put(ekv.key_ptr.*, new_chain.toOwnedSlice() catch chain) catch {};
                                }
                            }
                        }
                        return;
                    }
                    // 1b. Extern fn: latent effects are DECLARED via annotations
                    //     (@alloc/@panic/@io/@lock). There is no body to analyze.
                    if (self.fns.get(cname)) |decl_node| {
                        const decl = &decl_node.*.fn_decl;
                        if (decl.is_extern) {
                            for (decl.annots) |an| {
                                if (externEffectName(an)) |e| {
                                    const chain = std.fmt.allocPrint(self.alloc,
                                        "extern '{s}' at line {d} declares {s}", .{ cname, c.line, e }) catch "extern";
                                    self.addEffect(e, chain, label, eff_set, wit_map);
                                }
                            }
                            return;
                        }
                    }
                    // 2. Call into known fn or builtin — build callsite env from fn-type args.
                    if (self.fns.contains(cname) or types.getBuiltin(cname) != null) {
                        var sub_eff = std.StringHashMap(void).init(self.alloc);
                        defer sub_eff.deinit();
                        var sub_wit = WitMap.init(self.alloc);
                        defer sub_wit.deinit();
                        // Build callsite_lat: for each fn-type parameter of cname, compute
                        // the latent effects of the corresponding argument.
                        var callsite_lat = LatMap.init(self.alloc);
                        defer {
                            var it = callsite_lat.iterator();
                            while (it.next()) |kv| {
                                kv.value_ptr.eff.deinit();
                                kv.value_ptr.wit.deinit();
                            }
                            callsite_lat.deinit();
                        }
                        if (self.fns.get(cname)) |decl_node| {
                            const decl = &decl_node.*.fn_decl;
                            for (decl.params, 0..) |p, i| {
                                if (types.isFnType(p.pty) and i < c.args.len) {
                                    const entry = self.latentExprEntry(c.args[i], local_lat);
                                    callsite_lat.put(p.name, entry) catch {};
                                }
                            }
                        }
                        self.analyzeFnWithEnv(cname, &callsite_lat, &sub_eff, &sub_wit);
                        var eit = sub_eff.iterator();
                        while (eit.next()) |ekv| {
                            eff_set.put(ekv.key_ptr.*, {}) catch {};
                            if (sub_wit.get(ekv.key_ptr.*)) |chain| {
                                if (!wit_map.contains(ekv.key_ptr.*)) {
                                    var new_chain = std.ArrayList([]const u8).init(self.alloc);
                                    new_chain.append(label) catch {};
                                    for (chain) |cs| new_chain.append(cs) catch {};
                                    wit_map.put(ekv.key_ptr.*, new_chain.toOwnedSlice() catch chain) catch {};
                                }
                            }
                        }
                        return;
                    }
                }
                // Field callee: use declared type's row if available
                if (callee.* == .field) {
                    const field_ty = ast.nodeType(callee) orelse "";
                    if (types.isFnType(field_ty)) {
                        const row = types.rowOf(field_ty);
                        if (row) |r| {
                            switch (r.kind) {
                                .bound => {
                                    // May do anything NOT forbidden by the annotation
                                    outer: for (&types.ALL_EFFECTS) |eff| {
                                        for (r.effects) |fe| {
                                            if (std.mem.eql(u8, eff, fe)) continue :outer;
                                        }
                                        const chain = std.fmt.allocPrint(self.alloc,
                                            "call through field '{s}' at line {d}", .{ callee.*.field.fname, c.line }) catch "field call";
                                        self.addEffect(eff, chain, label, eff_set, wit_map);
                                    }
                                    return;
                                },
                                .row => {
                                    // Exactly the declared latent effects
                                    for (r.effects) |eff| {
                                        const chain = std.fmt.allocPrint(self.alloc,
                                            "call through field '{s}' at line {d}", .{ callee.*.field.fname, c.line }) catch "field call";
                                        self.addEffect(eff, chain, label, eff_set, wit_map);
                                    }
                                    return;
                                },
                                .variable => {
                                    // Effect variable: conservative (fall through)
                                },
                            }
                        }
                        // Plain fn type with no row: fall through to conservative
                        const chain = std.fmt.allocPrint(self.alloc,
                            "call through field '{s}' at line {d} (no row constraint)", .{ callee.*.field.fname, c.line }) catch "field call";
                        for (&types.ALL_EFFECTS) |eff| {
                            self.addEffect(eff, chain, label, eff_set, wit_map);
                        }
                        return;
                    }
                }
                // Opaque callee: conservative — all effects
                for (&types.ALL_EFFECTS) |eff| {
                    const chain = std.fmt.allocPrint(self.alloc, "opaque call at line {d}", .{c.line}) catch "opaque";
                    self.addEffect(eff, chain, label, eff_set, wit_map);
                }
            },
            else => {},
        }
    }

    fn effectsStmt(
        self: *Sema,
        s: ast.NodeRef,
        label: []const u8,
        eff_set: *std.StringHashMap(void),
        wit_map: *WitMap,
        local_lat: *LatMap,
    ) void {
        switch (s.*) {
            .let => |*l| {
                self.effectsExpr(l.expr, label, eff_set, wit_map, local_lat);
                // Track fn-typed locals in local_lat
                const lt = l.dty orelse if (ast.nodeType(l.expr)) |t| t else null;
                if (lt) |lty| {
                    if (types.isFnType(lty)) {
                        // If the declared type has a row constraint, use it (it's a contract).
                        // Otherwise, compute from the expression.
                        const row = types.rowOf(lty);
                        const entry = if (row != null) blk: {
                            // The declared type provides the bound; use latentExprEntry on
                            // a synthetic var with this type so it goes through rowOf logic.
                            var dummy_var = ast.Node{ .var_ = .{
                                .name = l.name,
                                .line = l.line,
                                .ty   = lty,
                            }};
                            break :blk self.latentExprEntry(&dummy_var, local_lat);
                        } else self.latentExprEntry(l.expr, local_lat);
                        local_lat.put(l.name, entry) catch {};
                    }
                }
            },
            .assign => |*a| {
                self.effectsExpr(a.target, label, eff_set, wit_map, local_lat);
                self.effectsExpr(a.expr, label, eff_set, wit_map, local_lat);
            },
            .return_ => |*r| {
                if (r.expr) |re| self.effectsExpr(re, label, eff_set, wit_map, local_lat);
            },
            .if_ => |*i| {
                self.effectsExpr(i.cond, label, eff_set, wit_map, local_lat);
                self.effectsBlock(i.then, label, eff_set, wit_map, local_lat);
                if (i.els) |els| self.effectsBlock(els, label, eff_set, wit_map, local_lat);
            },
            .while_ => |*w| {
                self.effectsExpr(w.cond, label, eff_set, wit_map, local_lat);
                self.effectsBlock(w.body, label, eff_set, wit_map, local_lat);
            },
            .switch_ => |*sw| {
                self.effectsExpr(sw.subject, label, eff_set, wit_map, local_lat);
                for (sw.arms) |arm| {
                    self.effectsBlock(arm.body, label, eff_set, wit_map, local_lat);
                }
                if (sw.els) |els| self.effectsBlock(els, label, eff_set, wit_map, local_lat);
            },
            .expr_stmt => |*es| self.effectsExpr(es.expr, label, eff_set, wit_map, local_lat),
            else => {},
        }
    }

    // ── checkStores ───────────────────────────────────────────────────────────

    pub fn checkStores(self: *Sema) !void {
        var fit = self.fns.iterator();
        while (fit.next()) |kv| {
            const fn_node = kv.value_ptr.*;
            const f = &fn_node.*.fn_decl;
            if (f.is_extern or f.body == null) continue;
            var local_lat = std.StringHashMap(void).init(self.alloc);
            defer local_lat.deinit();
            self.storeBlock(f.body.?, &local_lat, fn_node);
        }
    }

    fn storeBlock(self: *Sema, stmts: []ast.NodeRef, local_lat: *std.StringHashMap(void), fn_node: ast.NodeRef) void {
        for (stmts) |s| self.storeStmt(s, local_lat, fn_node);
    }

    fn storeStmt(self: *Sema, s: ast.NodeRef, local_lat: *std.StringHashMap(void), fn_node: ast.NodeRef) void {
        const f = &fn_node.*.fn_decl;
        switch (s.*) {
            .let => |*l| {
                self.storeExpr(l.expr, local_lat);
                const slot = l.dty;
                if (slot) |sl| {
                    if (types.isFnType(sl)) {
                        // Check that the stored fn value satisfies the slot's row constraint
                        var eff_set = std.StringHashMap(void).init(self.alloc);
                        defer eff_set.deinit();
                        var wit_map = WitMap.init(self.alloc);
                        defer wit_map.deinit();
                        self.latentExpr(l.expr, &eff_set, &wit_map);
                        // Check satisfies — use rowOf to get forbidden set from full type
                        const row_sl = types.rowOf(sl);
                        if (row_sl) |r| {
                            const forbidden: []const []const u8 = switch (r.kind) {
                                .bound => r.effects,
                                .row, .variable => &.{},
                            };
                            var eit = eff_set.iterator();
                            while (eit.next()) |ekv| {
                                const ename = ekv.key_ptr.*;
                                for (forbidden) |fe| {
                                    if (std.mem.eql(u8, fe, ename)) {
                                        const chain = if (wit_map.get(ename)) |w|
                                            std.mem.join(self.alloc, " → ", w) catch ename
                                        else ename;
                                        self.errFmt(l.line,
                                            "effect violation: storing into '{s}: {s}' but value may {s}:\n            {s}   [introduces {s}]",
                                            .{ l.name, sl, ename, chain, ename });
                                        break;
                                    }
                                }
                            }
                        }
                        local_lat.put(l.name, {}) catch {};
                    }
                }
            },
            .return_ => |*r| {
                if (r.expr) |re| {
                    self.storeExpr(re, local_lat);
                    if (re.* == .closure) {
                        const cl = &re.*.closure;
                        if (cl.caps.len > 0)
                            self.errFmt(r.line,
                                "a closure capturing variables may not escape its scope (returning closures is Phase-1 work)",
                                .{});
                    }
                    if (types.isFnType(f.ret)) {
                        var eff_set = std.StringHashMap(void).init(self.alloc);
                        defer eff_set.deinit();
                        var wit_map = WitMap.init(self.alloc);
                        defer wit_map.deinit();
                        self.latentExpr(re, &eff_set, &wit_map);
                        const row_ret = types.rowOf(f.ret);
                        if (row_ret) |r_ret| {
                            const forbidden_ret: []const []const u8 = switch (r_ret.kind) {
                                .bound => r_ret.effects,
                                .row, .variable => &.{},
                            };
                            var eit = eff_set.iterator();
                            while (eit.next()) |ekv| {
                                const ename = ekv.key_ptr.*;
                                for (forbidden_ret) |fe| {
                                    if (std.mem.eql(u8, fe, ename)) {
                                        const chain = if (wit_map.get(ename)) |w|
                                            std.mem.join(self.alloc, " → ", w) catch ename
                                        else ename;
                                        self.errFmt(r.line,
                                            "effect violation: '{s}' returns {s} but value may {s}:\n            {s}   [introduces {s}]",
                                            .{ f.name, f.ret, ename, chain, ename });
                                        break;
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .assign => |*a| {
                self.storeExpr(a.target, local_lat);
                self.storeExpr(a.expr, local_lat);
            },
            .expr_stmt => |*es| self.storeExpr(es.expr, local_lat),
            .if_ => |*i| {
                self.storeExpr(i.cond, local_lat);
                var then_lat = self.cloneBoolMap(local_lat);
                defer then_lat.deinit();
                self.storeBlock(i.then, &then_lat, fn_node);
                if (i.els) |els| {
                    var els_lat = self.cloneBoolMap(local_lat);
                    defer els_lat.deinit();
                    self.storeBlock(els, &els_lat, fn_node);
                }
            },
            .while_ => |*w| {
                self.storeExpr(w.cond, local_lat);
                var body_lat = self.cloneBoolMap(local_lat);
                defer body_lat.deinit();
                self.storeBlock(w.body, &body_lat, fn_node);
            },
            .switch_ => |*sw| {
                self.storeExpr(sw.subject, local_lat);
                for (sw.arms) |arm| {
                    var arm_lat = self.cloneBoolMap(local_lat);
                    defer arm_lat.deinit();
                    self.storeBlock(arm.body, &arm_lat, fn_node);
                }
                if (sw.els) |els| {
                    var els_lat = self.cloneBoolMap(local_lat);
                    defer els_lat.deinit();
                    self.storeBlock(els, &els_lat, fn_node);
                }
            },
            else => {},
        }
    }

    fn storeExpr(self: *Sema, e: ast.NodeRef, local_lat: *std.StringHashMap(void)) void {
        switch (e.*) {
            .call => |*c| {
                self.storeExpr(c.callee, local_lat);
                const callee = c.callee;
                var cn: ?[]const u8 = c.inst_name;
                if (cn == null and callee.* == .var_) cn = callee.*.var_.name;
                if (cn) |cname| {
                    if (self.fns.get(cname)) |decl_node| {
                        const decl = &decl_node.*.fn_decl;
                        for (c.args, 0..) |a, i| {
                            if (i < decl.params.len) {
                                const p = decl.params[i];
                                if (types.isFnType(p.pty)) {
                                    // Check row constraint
                                    var eff_set = std.StringHashMap(void).init(self.alloc);
                                    defer eff_set.deinit();
                                    var wit_map = WitMap.init(self.alloc);
                                    defer wit_map.deinit();
                                    self.latentExpr(a, &eff_set, &wit_map);
                                    const row_p = types.rowOf(p.pty);
                                    if (row_p) |rp| {
                                        const forbidden_p: []const []const u8 = switch (rp.kind) {
                                            .bound => rp.effects,
                                            .row, .variable => &.{},
                                        };
                                        var eit = eff_set.iterator();
                                        while (eit.next()) |ekv| {
                                            const ename = ekv.key_ptr.*;
                                            for (forbidden_p) |fe| {
                                                if (std.mem.eql(u8, fe, ename)) {
                                                    const chain = if (wit_map.get(ename)) |w|
                                                        std.mem.join(self.alloc, " → ", w) catch ename
                                                    else ename;
                                                    self.errFmt(c.line,
                                                        "callback bound violation: argument to '{s}' param '{s}: {s}' may {s}:\n            {s}   [introduces {s}]",
                                                        .{ cname, p.name, p.pty, ename, chain, ename });
                                                    break;
                                                }
                                            }
                                        }
                                    }
                                }
                                self.storeExpr(a, local_lat);
                            }
                        }
                        return;
                    }
                }
                for (c.args) |a| self.storeExpr(a, local_lat);
            },
            .struct_lit => |*sl| {
                const sn = self.structs.get(sl.inst_sname orelse sl.sname);
                for (sl.fields) |fi| {
                    self.storeExpr(fi.val, local_lat);
                    if (sn) |s_node| {
                        for (s_node.*.struct_decl.fields) |sf| {
                            if (std.mem.eql(u8, sf.name, fi.name) and types.isFnType(sf.pty)) {
                                var eff_set = std.StringHashMap(void).init(self.alloc);
                                defer eff_set.deinit();
                                var wit_map = WitMap.init(self.alloc);
                                defer wit_map.deinit();
                                self.latentExpr(fi.val, &eff_set, &wit_map);
                                const row_sf = types.rowOf(sf.pty);
                                if (row_sf) |rsf| {
                                    const forbidden_sf: []const []const u8 = switch (rsf.kind) {
                                        .bound => rsf.effects,
                                        .row, .variable => &.{},
                                    };
                                    var eit = eff_set.iterator();
                                    while (eit.next()) |ekv| {
                                        const ename = ekv.key_ptr.*;
                                        for (forbidden_sf) |fe| {
                                            if (std.mem.eql(u8, fe, ename)) {
                                                const chain = if (wit_map.get(ename)) |w|
                                                    std.mem.join(self.alloc, " → ", w) catch ename
                                                else ename;
                                                self.errFmt(sl.line,
                                                    "effect violation: field '{s}.{s}: {s}' stored a value that may {s}:\n            {s}   [introduces {s}]",
                                                    .{ sl.sname, fi.name, sf.pty, ename, chain, ename });
                                                break;
                                            }
                                        }
                                    }
                                }
                            }
                        }
                    }
                }
            },
            .bin => |*b| {
                self.storeExpr(b.l, local_lat);
                self.storeExpr(b.r, local_lat);
            },
            .un => |*u| self.storeExpr(u.e, local_lat),
            .index => |*i| {
                self.storeExpr(i.base, local_lat);
                self.storeExpr(i.idx, local_lat);
            },
            .field => |*f| self.storeExpr(f.base, local_lat),
            .try_ => |inner| self.storeExpr(inner, local_lat),
            .catch_ => |*c| {
                self.storeExpr(c.expr, local_lat);
                self.storeExpr(c.default, local_lat);
            },
            else => {},
        }
    }

    /// Compute the latent (worst-case) effects of a function-valued expression.
    fn latentExpr(self: *Sema, e: ast.NodeRef, eff_set: *std.StringHashMap(void), wit_map: *WitMap) void {
        var empty_lat = LatMap.init(self.alloc);
        defer empty_lat.deinit();
        var entry = self.latentExprEntry(e, &empty_lat);
        defer {
            entry.eff.deinit();
            entry.wit.deinit();
        }
        var eit = entry.eff.iterator();
        while (eit.next()) |ekv| eff_set.put(ekv.key_ptr.*, {}) catch {};
        var wit_it = entry.wit.iterator();
        while (wit_it.next()) |wkv| wit_map.put(wkv.key_ptr.*, wkv.value_ptr.*) catch {};
    }

    // ── AST cloning for generic instantiation ─────────────────────────────────

    pub fn cloneExpr(self: *Sema, e: ast.NodeRef, mp: *std.StringHashMap([]const u8)) ast.NodeRef {
        const n = self.alloc.create(ast.Node) catch return e;
        n.* = switch (e.*) {
            .lit => |*l| ast.Node{ .lit = .{ .lty = l.lty, .val = l.val, .line = l.line } },
            .var_ => |*v| ast.Node{ .var_ = .{ .name = v.name, .line = v.line } },
            .un => |*u| ast.Node{ .un = .{
                .op = u.op,
                .e  = self.cloneExpr(u.e, mp),
                .line = u.line,
            }},
            .bin => |*b| ast.Node{ .bin = .{
                .op   = b.op,
                .l    = self.cloneExpr(b.l, mp),
                .r    = self.cloneExpr(b.r, mp),
                .line = b.line,
            }},
            .index => |*i| ast.Node{ .index = .{
                .base = self.cloneExpr(i.base, mp),
                .idx  = self.cloneExpr(i.idx, mp),
                .line = i.line,
            }},
            .cast => |*c| ast.Node{ .cast = .{
                .expr   = self.cloneExpr(c.expr, mp),
                .target = types.substType(self.alloc, c.target, mp.*) catch c.target,
                .line   = c.line,
            }},
            .slice => |*sl| ast.Node{ .slice = .{
                .base   = self.cloneExpr(sl.base, mp),
                .lo     = self.cloneExpr(sl.lo, mp),
                .hi     = self.cloneExpr(sl.hi, mp),
                .has_hi = sl.has_hi,
                .line   = sl.line,
            }},
            .field => |*f| ast.Node{ .field = .{
                .base  = self.cloneExpr(f.base, mp),
                .fname = f.fname,
                .line  = f.line,
            }},
            .struct_lit => |*sl| blk: {
                const new_sname = mp.get(sl.sname) orelse sl.sname;
                var new_fields = self.alloc.alloc(ast.FieldInit, sl.fields.len) catch break :blk e.*;
                for (sl.fields, 0..) |fi, i| {
                    new_fields[i] = .{ .name = fi.name, .val = self.cloneExpr(fi.val, mp) };
                }
                var new_targs = self.alloc.alloc([]const u8, sl.targs.len) catch break :blk e.*;
                for (sl.targs, 0..) |a, i| {
                    new_targs[i] = types.substType(self.alloc, a, mp.*) catch a;
                }
                break :blk ast.Node{ .struct_lit = .{
                    .sname  = new_sname,
                    .fields = new_fields,
                    .line   = sl.line,
                    .targs  = new_targs,
                }};
            },
            .closure => |*cl| blk: {
                var new_params = self.alloc.alloc(ast.Param, cl.params.len) catch break :blk e.*;
                for (cl.params, 0..) |p, i| {
                    new_params[i] = .{
                        .name = p.name,
                        .pty  = types.substType(self.alloc, p.pty, mp.*) catch p.pty,
                    };
                }
                const new_ret = types.substType(self.alloc, cl.ret, mp.*) catch cl.ret;
                break :blk ast.Node{ .closure = .{
                    .caps   = cl.caps,
                    .params = new_params,
                    .ret    = new_ret,
                    .body   = self.cloneStmts(cl.body, mp),
                    .line   = cl.line,
                }};
            },
            .call => |*c| blk: {
                var new_args = self.alloc.alloc(ast.NodeRef, c.args.len) catch break :blk e.*;
                for (c.args, 0..) |a, i| new_args[i] = self.cloneExpr(a, mp);
                var new_targs = self.alloc.alloc([]const u8, c.targs.len) catch break :blk e.*;
                for (c.targs, 0..) |a, i| new_targs[i] = types.substType(self.alloc, a, mp.*) catch a;
                break :blk ast.Node{ .call = .{
                    .callee = self.cloneExpr(c.callee, mp),
                    .args   = new_args,
                    .line   = c.line,
                    .targs  = new_targs,
                }};
            },
            .err_lit => |*el| ast.Node{ .err_lit = .{ .errname = el.errname, .line = el.line } },
            .try_    => |inner| ast.Node{ .try_ = self.cloneExpr(inner, mp) },
            .catch_  => |*c| ast.Node{ .catch_ = .{
                .expr    = self.cloneExpr(c.expr, mp),
                .default = self.cloneExpr(c.default, mp),
                .cap     = c.cap,
                .line    = c.line,
            }},
            .null_lit => |*nl| ast.Node{ .null_lit = .{ .line = nl.line } },
            .or_else  => |*oe| ast.Node{ .or_else = .{
                .expr    = self.cloneExpr(oe.expr, mp),
                .default = self.cloneExpr(oe.default, mp),
                .line    = oe.line,
            }},
            .force_unwrap => |inner| ast.Node{ .force_unwrap = self.cloneExpr(inner, mp) },
            else => e.*,
        };
        return n;
    }

    pub fn cloneStmts(self: *Sema, stmts: []ast.NodeRef, mp: *std.StringHashMap([]const u8)) []ast.NodeRef {
        const out = self.alloc.alloc(ast.NodeRef, stmts.len) catch return stmts;
        for (stmts, 0..) |s, i| out[i] = self.cloneStmt(s, mp);
        return out;
    }

    fn cloneStmt(self: *Sema, s: ast.NodeRef, mp: *std.StringHashMap([]const u8)) ast.NodeRef {
        const n = self.alloc.create(ast.Node) catch return s;
        n.* = switch (s.*) {
            .let => |*l| ast.Node{ .let = .{
                .name = l.name,
                .dty  = if (l.dty) |d| types.substType(self.alloc, d, mp.*) catch d else null,
                .expr = self.cloneExpr(l.expr, mp),
                .line = l.line,
            }},
            .assign => |*a| ast.Node{ .assign = .{
                .target = self.cloneExpr(a.target, mp),
                .expr   = self.cloneExpr(a.expr, mp),
                .line   = a.line,
            }},
            .return_ => |*r| ast.Node{ .return_ = .{
                .expr = if (r.expr) |re| self.cloneExpr(re, mp) else null,
                .line = r.line,
            }},
            .if_ => |*i| ast.Node{ .if_ = .{
                .cond = self.cloneExpr(i.cond, mp),
                .then = self.cloneStmts(i.then, mp),
                .els  = if (i.els) |e| self.cloneStmts(e, mp) else null,
                .line = i.line,
                .cap  = i.cap,
            }},
            .while_ => |*w| ast.Node{ .while_ = .{
                .cond = self.cloneExpr(w.cond, mp),
                .body = self.cloneStmts(w.body, mp),
                .line = w.line,
                .cap  = w.cap,
            }},
            .switch_ => |*sw| blk: {
                var new_arms = self.alloc.alloc(ast.SwitchArm, sw.arms.len) catch break :blk s.*;
                for (sw.arms, 0..) |arm, i| {
                    new_arms[i] = .{
                        .tags = arm.tags,
                        .cap  = arm.cap,
                        .body = self.cloneStmts(arm.body, mp),
                    };
                }
                break :blk ast.Node{ .switch_ = .{
                    .subject = self.cloneExpr(sw.subject, mp),
                    .arms    = new_arms,
                    .els     = if (sw.els) |e| self.cloneStmts(e, mp) else null,
                    .line    = sw.line,
                }};
            },
            .expr_stmt => |*es| ast.Node{ .expr_stmt = .{
                .expr = self.cloneExpr(es.expr, mp),
                .line = es.line,
            }},
            else => s.*,
        };
        return n;
    }

    // ── Utility helpers ───────────────────────────────────────────────────────

    fn cloneScope(self: *Sema, scope: *Scope) Scope {
        var new_scope = Scope.init(self.alloc);
        var it = scope.iterator();
        while (it.next()) |kv| new_scope.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
        return new_scope;
    }

    fn cloneBoolMap(self: *Sema, m: *std.StringHashMap(void)) std.StringHashMap(void) {
        var out = std.StringHashMap(void).init(self.alloc);
        var it = m.iterator();
        while (it.next()) |kv| out.put(kv.key_ptr.*, {}) catch {};
        return out;
    }

    fn joinParamTypes(self: *Sema, params: []ast.Param) []const u8 {
        var ps = std.ArrayList([]const u8).init(self.alloc);
        defer ps.deinit();
        for (params) |p| ps.append(p.pty) catch {};
        return std.mem.join(self.alloc, ",", ps.items) catch "";
    }
};

// ── Module-level helpers ──────────────────────────────────────────────────────

/// Map an effect-declaration annotation (used on extern fns) to its effect name.
fn externEffectName(annot: []const u8) ?[]const u8 {
    if (std.mem.eql(u8, annot, "@alloc")) return "Alloc";
    if (std.mem.eql(u8, annot, "@panic")) return "Panic";
    if (std.mem.eql(u8, annot, "@io")) return "IO";
    if (std.mem.eql(u8, annot, "@lock")) return "Lock";
    return null;
}

/// When param expects ?T and arg is NullLit or bare T, annotate the arg node.
fn annotateOptionalArg(arg_node: ast.NodeRef, param_ty: []const u8, arg_ty: []const u8) void {
    if (!types.isOptional(param_ty)) return;
    if (arg_node.* == .null_lit) {
        arg_node.*.null_lit.ty = param_ty;
        return;
    }
    if (!types.isOptional(arg_ty)) {
        // Mark that this arg must be wrapped at codegen
        switch (arg_node.*) {
            .call => |*c| c.opt_wrap = param_ty,
            else   => {},
        }
    }
}

/// Format "Base[T1,T2,...]" from a base name and arg slice.
fn fmtApplied(alloc: std.mem.Allocator, base: []const u8, cargs: [][]const u8) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    try buf.appendSlice(base);
    try buf.append('[');
    for (cargs, 0..) |a, i| {
        if (i > 0) try buf.append(',');
        try buf.appendSlice(a);
    }
    try buf.append(']');
    return buf.toOwnedSlice();
}

/// Split "Base[T1,T2]" into (.base = "Base", .args = &.{"T1","T2"}).
/// Returns .args = null for non-application types.
fn splitApp(alloc: std.mem.Allocator, ty: []const u8) !struct { base: []const u8, args: ?[][]const u8 } {
    if (std.mem.startsWith(u8, ty, "[]") or std.mem.startsWith(u8, ty, "fn(")) {
        return .{ .base = ty, .args = null };
    }
    const bracket = std.mem.indexOfScalar(u8, ty, '[') orelse return .{ .base = ty, .args = null };
    if (ty[ty.len - 1] != ']') return .{ .base = ty, .args = null };
    const base = ty[0..bracket];
    const inner = ty[bracket + 1 .. ty.len - 1];
    var args = std.ArrayList([]const u8).init(alloc);
    var cur_start: usize = 0;
    var d: i32 = 0;
    for (inner, 0..) |ch, idx| {
        switch (ch) {
            '(', '[', '{' => d += 1,
            ')', ']', '}' => d -= 1,
            ',' => if (d == 0) {
                const seg = std.mem.trim(u8, inner[cur_start..idx], " ");
                try args.append(seg);
                cur_start = idx + 1;
            },
            else => {},
        }
    }
    const last = std.mem.trim(u8, inner[cur_start..], " ");
    if (last.len > 0) try args.append(last);
    return .{ .base = base, .args = try args.toOwnedSlice() };
}
