// jsonout.zig — AI-native structured diagnostics (complaint #2).
//
// Legacy toolchains emit human-prose errors and AST/graph data only through
// ad-hoc text dumps.  An LLM driving the compiler has to scrape stderr with
// regexes.  Zag instead emits first-class, machine-readable JSON for the three
// things an agent actually needs to reason about a build:
//
//   * diagnostics  — every error/violation with line, code, severity, and the
//                    full effect *witness chain* (why a capability claim failed),
//   * the AST      — `zagc ast file.zag --json`, type-annotated post-sema,
//   * the dep graph— `zagc deps file.zag --json`, the call graph plus each
//                    function's declared annotations and *inferred* effects.
//
// Schemas are stable and versioned via the "schema" field so tools can pin.

const std = @import("std");
const ast = @import("ast.zig");
const sema_mod = @import("sema.zig");
const version = @import("version.zig");

// ── low-level JSON helpers ───────────────────────────────────────────────────

fn esc(w: anytype, s: []const u8) !void {
    for (s) |c| {
        switch (c) {
            '"' => try w.writeAll("\\\""),
            '\\' => try w.writeAll("\\\\"),
            '\n' => try w.writeAll("\\n"),
            '\r' => try w.writeAll("\\r"),
            '\t' => try w.writeAll("\\t"),
            else => {
                if (c < 0x20) {
                    try w.print("\\u{x:0>4}", .{c});
                } else {
                    try w.writeByte(c);
                }
            },
        }
    }
}

fn jstr(w: anytype, s: []const u8) !void {
    try w.writeByte('"');
    try esc(w, s);
    try w.writeByte('"');
}

/// "key": "value",
fn kvStr(w: anytype, key: []const u8, val: []const u8) !void {
    try jstr(w, key);
    try w.writeAll(": ");
    try jstr(w, val);
}

fn strArray(w: anytype, items: []const []const u8) !void {
    try w.writeByte('[');
    for (items, 0..) |it, i| {
        if (i > 0) try w.writeAll(", ");
        try jstr(w, it);
    }
    try w.writeByte(']');
}

fn compilerObj(w: anytype) !void {
    try w.writeAll("{");
    try kvStr(w, "version", version.ZAG_VERSION);
    try w.writeAll(", ");
    try kvStr(w, "edition", version.ZAG_EDITION);
    try w.writeAll(", ");
    try kvStr(w, "commit", version.ZAG_COMMIT);
    try w.writeAll("}");
}

/// Split a sema error string of the form "line N: message" into (line, msg).
fn splitLineMsg(s: []const u8) struct { line: ?u32, msg: []const u8 } {
    if (std.mem.startsWith(u8, s, "line ")) {
        const rest = s[5..];
        if (std.mem.indexOf(u8, rest, ": ")) |colon| {
            const num = rest[0..colon];
            if (std.fmt.parseInt(u32, num, 10)) |n| {
                return .{ .line = n, .msg = rest[colon + 2 ..] };
            } else |_| {}
        }
    }
    return .{ .line = null, .msg = s };
}

// ── 1. Diagnostics + capabilities report ─────────────────────────────────────

pub fn emitReport(
    alloc: std.mem.Allocator,
    file: []const u8,
    errors: []const []const u8,
    report: sema_mod.Report,
    decls: []ast.NodeRef,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    const ok = errors.len == 0 and report.violations.len == 0;

    try w.writeAll("{\n  ");
    try kvStr(w, "schema", "zag.diagnostics/v1");
    try w.writeAll(",\n  \"compiler\": ");
    try compilerObj(w);
    try w.writeAll(",\n  ");
    try kvStr(w, "file", file);
    try w.print(",\n  \"ok\": {s},\n", .{if (ok) "true" else "false"});

    // diagnostics array
    try w.writeAll("  \"diagnostics\": [");
    var first = true;
    for (errors) |e| {
        const lm = splitLineMsg(e);
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\n    {");
        try kvStr(w, "severity", "error");
        try w.writeAll(", ");
        try kvStr(w, "code", "ZAG-SEMA");
        try w.writeAll(", \"line\": ");
        if (lm.line) |ln| {
            try w.print("{d}", .{ln});
        } else {
            try w.writeAll("null");
        }
        try w.writeAll(", ");
        try kvStr(w, "message", lm.msg);
        try w.writeAll("}");
    }
    // capability violations as diagnostics too (with a dedicated code)
    for (report.violations) |v| {
        if (!first) try w.writeAll(",");
        first = false;
        try w.writeAll("\n    {");
        try kvStr(w, "severity", "error");
        try w.writeAll(", ");
        try kvStr(w, "code", "ZAG-CAP");
        try w.writeAll(", ");
        try kvStr(w, "function", v.fn_name);
        try w.writeAll(", ");
        try kvStr(w, "annotation", v.annot);
        try w.writeAll(", \"effects\": ");
        try strArray(w, v.effects);
        try w.writeAll(", \"witness\": ");
        try strArray(w, v.witness);
        try w.writeAll("}");
    }
    try w.writeAll(if (first) "],\n" else "\n  ],\n");

    // capabilities summary: every annotated fn, proven or not
    try w.writeAll("  \"capabilities\": [");
    var cfirst = true;
    for (decls) |n| {
        if (n.* != .fn_decl) continue;
        const f = n.fn_decl;
        if (f.annots.len == 0) continue;
        // proven = no violation entry references this function
        var proven = true;
        for (report.violations) |v| {
            if (std.mem.eql(u8, v.fn_name, f.name)) {
                proven = false;
                break;
            }
        }
        if (!cfirst) try w.writeAll(",");
        cfirst = false;
        try w.writeAll("\n    {");
        try kvStr(w, "function", f.name);
        try w.writeAll(", \"line\": ");
        try w.print("{d}", .{f.line});
        try w.writeAll(", \"annotations\": ");
        try strArray(w, f.annots);
        try w.print(", \"proven\": {s}", .{if (proven) "true" else "false"});
        try w.writeAll("}");
    }
    try w.writeAll(if (cfirst) "]\n}" else "\n  ]\n}");
    try w.writeAll("\n");

    return buf.toOwnedSlice();
}

// ── 2. AST serialization ─────────────────────────────────────────────────────

fn typeField(w: anytype, n: ast.NodeRef) !void {
    if (ast.nodeType(n)) |t| {
        try w.writeAll(", ");
        try kvStr(w, "type", t);
    }
}

fn writeParams(w: anytype, params: []ast.Param) !void {
    try w.writeByte('[');
    for (params, 0..) |p, i| {
        if (i > 0) try w.writeAll(", ");
        try w.writeAll("{");
        try kvStr(w, "name", p.name);
        try w.writeAll(", ");
        try kvStr(w, "type", p.pty);
        try w.writeAll("}");
    }
    try w.writeByte(']');
}

fn writeNodeList(w: anytype, nodes: []ast.NodeRef) anyerror!void {
    try w.writeByte('[');
    for (nodes, 0..) |n, i| {
        if (i > 0) try w.writeAll(", ");
        try writeNode(w, n);
    }
    try w.writeByte(']');
}

/// Recursively serialize an AST node to JSON.
fn writeNode(w: anytype, n: ast.NodeRef) anyerror!void {
    switch (n.*) {
        .fn_decl => |f| {
            try w.writeAll("{");
            try kvStr(w, "kind", "fn_decl");
            try w.writeAll(", ");
            try kvStr(w, "name", f.name);
            try w.print(", \"line\": {d}", .{f.line});
            try w.writeAll(", \"params\": ");
            try writeParams(w, f.params);
            try w.writeAll(", ");
            try kvStr(w, "ret", f.ret);
            try w.writeAll(", \"annotations\": ");
            try strArray(w, f.annots);
            if (f.tparams.len > 0) {
                try w.writeAll(", \"tparams\": ");
                try strArray(w, f.tparams);
            }
            if (f.recv_type) |rt| {
                try w.writeAll(", ");
                try kvStr(w, "receiver", rt);
            }
            try w.print(", \"extern\": {s}", .{if (f.is_extern) "true" else "false"});
            if (f.body) |body| {
                try w.writeAll(", \"body\": ");
                try writeNodeList(w, body);
            } else {
                try w.writeAll(", \"body\": null");
            }
            try w.writeAll("}");
        },
        .struct_decl => |sd| {
            try w.writeAll("{");
            try kvStr(w, "kind", "struct_decl");
            try w.writeAll(", ");
            try kvStr(w, "name", sd.name);
            try w.print(", \"line\": {d}", .{sd.line});
            try w.writeAll(", \"fields\": ");
            try writeParams(w, sd.fields);
            if (sd.tparams.len > 0) {
                try w.writeAll(", \"tparams\": ");
                try strArray(w, sd.tparams);
            }
            try w.writeAll("}");
        },
        .enum_decl => |ed| {
            try w.writeAll("{");
            try kvStr(w, "kind", "enum_decl");
            try w.writeAll(", ");
            try kvStr(w, "name", ed.name);
            try w.print(", \"line\": {d}", .{ed.line});
            try w.writeAll(", \"members\": ");
            try strArray(w, ed.members);
            try w.writeAll("}");
        },
        .union_decl => |ud| {
            try w.writeAll("{");
            try kvStr(w, "kind", "union_decl");
            try w.writeAll(", ");
            try kvStr(w, "name", ud.name);
            try w.print(", \"line\": {d}", .{ud.line});
            try w.writeAll(", \"variants\": ");
            try writeParams(w, ud.fields);
            try w.writeAll("}");
        },
        .interface_decl => |id| {
            try w.writeAll("{");
            try kvStr(w, "kind", "interface_decl");
            try w.writeAll(", ");
            try kvStr(w, "name", id.name);
            try w.print(", \"line\": {d}", .{id.line});
            try w.writeAll(", \"methods\": [");
            for (id.methods, 0..) |m, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("{");
                try kvStr(w, "name", m.name);
                try w.writeAll(", \"params\": ");
                try writeParams(w, m.params);
                try w.writeAll(", ");
                try kvStr(w, "ret", m.ret);
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        },
        .error_decl => |ed| {
            try w.writeAll("{");
            try kvStr(w, "kind", "error_decl");
            try w.print(", \"line\": {d}", .{ed.line});
            try w.writeAll(", \"names\": ");
            try strArray(w, ed.names);
            try w.writeAll("}");
        },
        .mod_alias => |ma| {
            try w.writeAll("{");
            try kvStr(w, "kind", "mod_alias");
            try w.writeAll(", ");
            try kvStr(w, "alias", ma.alias);
            try w.writeAll(", ");
            try kvStr(w, "prefix", ma.prefix);
            try w.writeAll("}");
        },
        .let => |l| {
            try w.writeAll("{");
            try kvStr(w, "kind", "let");
            try w.writeAll(", ");
            try kvStr(w, "name", l.name);
            try w.print(", \"line\": {d}", .{l.line});
            if (l.dty) |d| {
                try w.writeAll(", ");
                try kvStr(w, "declared_type", d);
            }
            try w.writeAll(", \"value\": ");
            try writeNode(w, l.expr);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .assign => |a| {
            try w.writeAll("{");
            try kvStr(w, "kind", "assign");
            try w.print(", \"line\": {d}", .{a.line});
            try w.writeAll(", \"target\": ");
            try writeNode(w, a.target);
            try w.writeAll(", \"value\": ");
            try writeNode(w, a.expr);
            try w.writeAll("}");
        },
        .return_ => |r| {
            try w.writeAll("{");
            try kvStr(w, "kind", "return");
            try w.print(", \"line\": {d}", .{r.line});
            if (r.expr) |e| {
                try w.writeAll(", \"value\": ");
                try writeNode(w, e);
            }
            try w.writeAll("}");
        },
        .if_ => |iff| {
            try w.writeAll("{");
            try kvStr(w, "kind", "if");
            try w.print(", \"line\": {d}", .{iff.line});
            try w.writeAll(", \"cond\": ");
            try writeNode(w, iff.cond);
            try w.writeAll(", \"then\": ");
            try writeNodeList(w, iff.then);
            if (iff.els) |e| {
                try w.writeAll(", \"else\": ");
                try writeNodeList(w, e);
            }
            try w.writeAll("}");
        },
        .while_ => |wl| {
            try w.writeAll("{");
            try kvStr(w, "kind", "while");
            try w.print(", \"line\": {d}", .{wl.line});
            try w.writeAll(", \"cond\": ");
            try writeNode(w, wl.cond);
            try w.writeAll(", \"body\": ");
            try writeNodeList(w, wl.body);
            try w.writeAll("}");
        },
        .expr_stmt => |e| {
            try w.writeAll("{");
            try kvStr(w, "kind", "expr_stmt");
            try w.print(", \"line\": {d}", .{e.line});
            try w.writeAll(", \"expr\": ");
            try writeNode(w, e.expr);
            try w.writeAll("}");
        },
        .switch_ => |sw| {
            try w.writeAll("{");
            try kvStr(w, "kind", "switch");
            try w.print(", \"line\": {d}", .{sw.line});
            try w.print(", \"is_expr\": {s}", .{if (sw.is_expr) "true" else "false"});
            try w.writeAll(", \"subject\": ");
            try writeNode(w, sw.subject);
            try w.writeAll(", \"arms\": [");
            for (sw.arms, 0..) |arm, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("{\"tags\": ");
                try strArray(w, arm.tags);
                if (arm.cap) |cap| {
                    try w.writeAll(", ");
                    try kvStr(w, "capture", cap);
                }
                try w.writeAll(", \"body\": ");
                try writeNodeList(w, arm.body);
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        },
        .lit => |l| {
            try w.writeAll("{");
            try kvStr(w, "kind", "lit");
            try w.writeAll(", ");
            try kvStr(w, "literal", @tagName(l.lty));
            try w.writeAll(", ");
            try kvStr(w, "value", l.val);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .var_ => |v| {
            try w.writeAll("{");
            try kvStr(w, "kind", "var");
            try w.writeAll(", ");
            try kvStr(w, "name", v.name);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .bin => |b| {
            try w.writeAll("{");
            try kvStr(w, "kind", "bin");
            try w.writeAll(", ");
            try kvStr(w, "op", b.op);
            try w.writeAll(", \"lhs\": ");
            try writeNode(w, b.l);
            try w.writeAll(", \"rhs\": ");
            try writeNode(w, b.r);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .un => |u| {
            try w.writeAll("{");
            try kvStr(w, "kind", "un");
            try w.writeAll(", ");
            try kvStr(w, "op", u.op);
            try w.writeAll(", \"operand\": ");
            try writeNode(w, u.e);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .call => |c| {
            try w.writeAll("{");
            try kvStr(w, "kind", "call");
            try w.writeAll(", \"callee\": ");
            try writeNode(w, c.callee);
            if (c.inst_name) |inm| {
                try w.writeAll(", ");
                try kvStr(w, "instance", inm);
            }
            try w.writeAll(", \"args\": ");
            try writeNodeList(w, c.args);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .index => |ix| {
            try w.writeAll("{");
            try kvStr(w, "kind", "index");
            try w.writeAll(", \"base\": ");
            try writeNode(w, ix.base);
            try w.writeAll(", \"index\": ");
            try writeNode(w, ix.idx);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .slice => |sl| {
            try w.writeAll("{");
            try kvStr(w, "kind", "slice");
            try w.writeAll(", \"base\": ");
            try writeNode(w, sl.base);
            try w.writeAll(", \"lo\": ");
            try writeNode(w, sl.lo);
            try w.writeAll(", \"hi\": ");
            try writeNode(w, sl.hi);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .cast => |c| {
            try w.writeAll("{");
            try kvStr(w, "kind", "cast");
            try w.writeAll(", ");
            try kvStr(w, "target", c.target);
            try w.writeAll(", \"expr\": ");
            try writeNode(w, c.expr);
            try w.writeAll("}");
        },
        .field => |f| {
            try w.writeAll("{");
            try kvStr(w, "kind", "field");
            try w.writeAll(", ");
            try kvStr(w, "field", f.fname);
            try w.writeAll(", \"base\": ");
            try writeNode(w, f.base);
            try typeField(w, n);
            try w.writeAll("}");
        },
        .struct_lit => |sl| {
            try w.writeAll("{");
            try kvStr(w, "kind", "struct_lit");
            try w.writeAll(", ");
            try kvStr(w, "struct", sl.inst_sname orelse sl.sname);
            try w.writeAll(", \"fields\": [");
            for (sl.fields, 0..) |fi, i| {
                if (i > 0) try w.writeAll(", ");
                try w.writeAll("{");
                try kvStr(w, "name", fi.name);
                try w.writeAll(", \"value\": ");
                try writeNode(w, fi.val);
                try w.writeAll("}");
            }
            try w.writeAll("]}");
        },
        .closure => |cl| {
            try w.writeAll("{");
            try kvStr(w, "kind", "closure");
            try w.writeAll(", \"captures\": ");
            try strArray(w, cl.caps);
            try w.writeAll(", \"params\": ");
            try writeParams(w, cl.params);
            try w.writeAll(", ");
            try kvStr(w, "ret", cl.ret);
            try w.writeAll(", \"body\": ");
            try writeNodeList(w, cl.body);
            try w.writeAll("}");
        },
        .err_lit => |el| {
            try w.writeAll("{");
            try kvStr(w, "kind", "err_lit");
            try w.writeAll(", ");
            try kvStr(w, "name", el.errname);
            try w.writeAll("}");
        },
        .try_ => |inner| {
            try w.writeAll("{");
            try kvStr(w, "kind", "try");
            try w.writeAll(", \"expr\": ");
            try writeNode(w, inner);
            try w.writeAll("}");
        },
        .catch_ => |c| {
            try w.writeAll("{");
            try kvStr(w, "kind", "catch");
            try w.writeAll(", \"expr\": ");
            try writeNode(w, c.expr);
            try w.writeAll(", \"default\": ");
            try writeNode(w, c.default);
            try w.writeAll("}");
        },
        .null_lit => {
            try w.writeAll("{");
            try kvStr(w, "kind", "null");
            try w.writeAll("}");
        },
        .or_else => |oe| {
            try w.writeAll("{");
            try kvStr(w, "kind", "orelse");
            try w.writeAll(", \"expr\": ");
            try writeNode(w, oe.expr);
            try w.writeAll(", \"default\": ");
            try writeNode(w, oe.default);
            try w.writeAll("}");
        },
        .force_unwrap => |inner| {
            try w.writeAll("{");
            try kvStr(w, "kind", "force_unwrap");
            try w.writeAll(", \"expr\": ");
            try writeNode(w, inner);
            try w.writeAll("}");
        },
    }
}

pub fn emitAst(alloc: std.mem.Allocator, file: []const u8, decls: []ast.NodeRef) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();
    try w.writeAll("{\n  ");
    try kvStr(w, "schema", "zag.ast/v1");
    try w.writeAll(",\n  \"compiler\": ");
    try compilerObj(w);
    try w.writeAll(",\n  ");
    try kvStr(w, "file", file);
    try w.writeAll(",\n  \"decls\": ");
    try writeNodeList(w, decls);
    try w.writeAll("\n}\n");
    return buf.toOwnedSlice();
}

// ── 3. Dependency / call graph ───────────────────────────────────────────────

/// Render a shallow label for a call target.
fn calleeLabel(alloc: std.mem.Allocator, callee: ast.NodeRef) ?[]const u8 {
    return switch (callee.*) {
        .var_ => |v| v.name,
        .field => |f| blk: {
            if (f.base.* == .var_) {
                break :blk std.fmt.allocPrint(alloc, "{s}.{s}", .{ f.base.var_.name, f.fname }) catch f.fname;
            }
            break :blk f.fname;
        },
        else => null,
    };
}

fn collectCalls(alloc: std.mem.Allocator, n: ast.NodeRef, out: *std.ArrayList([]const u8)) void {
    switch (n.*) {
        .call => |c| {
            if (calleeLabel(alloc, c.callee)) |label| {
                // dedup
                var seen = false;
                for (out.items) |it| {
                    if (std.mem.eql(u8, it, label)) {
                        seen = true;
                        break;
                    }
                }
                if (!seen) out.append(label) catch {};
            }
            collectCalls(alloc, c.callee, out);
            for (c.args) |a| collectCalls(alloc, a, out);
        },
        .let => |l| collectCalls(alloc, l.expr, out),
        .assign => |a| {
            collectCalls(alloc, a.target, out);
            collectCalls(alloc, a.expr, out);
        },
        .return_ => |r| if (r.expr) |e| collectCalls(alloc, e, out),
        .expr_stmt => |e| collectCalls(alloc, e.expr, out),
        .if_ => |iff| {
            collectCalls(alloc, iff.cond, out);
            for (iff.then) |s| collectCalls(alloc, s, out);
            if (iff.els) |els| for (els) |s| collectCalls(alloc, s, out);
        },
        .while_ => |wl| {
            collectCalls(alloc, wl.cond, out);
            for (wl.body) |s| collectCalls(alloc, s, out);
        },
        .switch_ => |sw| {
            collectCalls(alloc, sw.subject, out);
            for (sw.arms) |arm| for (arm.body) |s| collectCalls(alloc, s, out);
            if (sw.els) |els| for (els) |s| collectCalls(alloc, s, out);
        },
        .bin => |b| {
            collectCalls(alloc, b.l, out);
            collectCalls(alloc, b.r, out);
        },
        .un => |u| collectCalls(alloc, u.e, out),
        .index => |ix| {
            collectCalls(alloc, ix.base, out);
            collectCalls(alloc, ix.idx, out);
        },
        .slice => |sl| {
            collectCalls(alloc, sl.base, out);
            collectCalls(alloc, sl.lo, out);
            collectCalls(alloc, sl.hi, out);
        },
        .cast => |c| collectCalls(alloc, c.expr, out),
        .field => |f| collectCalls(alloc, f.base, out),
        .struct_lit => |sl| for (sl.fields) |fi| collectCalls(alloc, fi.val, out),
        .closure => |cl| for (cl.body) |s| collectCalls(alloc, s, out),
        .try_ => |inner| collectCalls(alloc, inner, out),
        .catch_ => |c| {
            collectCalls(alloc, c.expr, out);
            collectCalls(alloc, c.default, out);
        },
        .or_else => |oe| {
            collectCalls(alloc, oe.expr, out);
            collectCalls(alloc, oe.default, out);
        },
        .force_unwrap => |inner| collectCalls(alloc, inner, out),
        else => {},
    }
}

pub fn emitDeps(
    alloc: std.mem.Allocator,
    file: []const u8,
    decls: []ast.NodeRef,
    s: *sema_mod.Sema,
) ![]const u8 {
    var buf = std.ArrayList(u8).init(alloc);
    const w = buf.writer();

    try w.writeAll("{\n  ");
    try kvStr(w, "schema", "zag.depgraph/v1");
    try w.writeAll(",\n  \"compiler\": ");
    try compilerObj(w);
    try w.writeAll(",\n  ");
    try kvStr(w, "file", file);

    // modules
    try w.writeAll(",\n  \"modules\": [");
    var mfirst = true;
    for (decls) |n| {
        if (n.* != .mod_alias) continue;
        if (!mfirst) try w.writeAll(", ");
        mfirst = false;
        try w.writeAll("{");
        try kvStr(w, "alias", n.mod_alias.alias);
        try w.writeAll(", ");
        try kvStr(w, "prefix", n.mod_alias.prefix);
        try w.writeAll("}");
    }
    try w.writeAll("],");

    // functions
    try w.writeAll("\n  \"functions\": [");
    var ffirst = true;
    for (decls) |n| {
        if (n.* != .fn_decl) continue;
        const f = n.fn_decl;
        if (!ffirst) try w.writeAll(",");
        ffirst = false;

        var calls = std.ArrayList([]const u8).init(alloc);
        if (f.body) |body| {
            for (body) |st| collectCalls(alloc, st, &calls);
        }
        const effects = s.effectsOfFn(f.name);

        try w.writeAll("\n    {");
        try kvStr(w, "name", f.name);
        try w.print(", \"line\": {d}", .{f.line});
        if (f.recv_type) |rt| {
            try w.writeAll(", ");
            try kvStr(w, "receiver", rt);
        }
        try w.writeAll(", \"params\": ");
        try writeParams(w, f.params);
        try w.writeAll(", ");
        try kvStr(w, "ret", f.ret);
        try w.print(", \"extern\": {s}", .{if (f.is_extern) "true" else "false"});
        if (f.tparams.len > 0) {
            try w.writeAll(", \"generic\": true, \"tparams\": ");
            try strArray(w, f.tparams);
        }
        try w.writeAll(", \"annotations\": ");
        try strArray(w, f.annots);
        try w.writeAll(", \"effects\": ");
        try strArray(w, effects);
        try w.writeAll(", \"calls\": ");
        try strArray(w, calls.items);
        try w.writeAll("}");
    }
    try w.writeAll(if (ffirst) "]" else "\n  ]");
    try w.writeAll("\n}\n");

    return buf.toOwnedSlice();
}
