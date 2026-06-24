// parse.zig — Zag recursive-descent parser (Zig 0.14)
//
// Takes a []Token produced by lex.zig and produces []NodeRef
// (a flat list of top-level declarations).

const std = @import("std");
const Allocator = std.mem.Allocator;

const lex_mod = @import("lex.zig");
const Token = lex_mod.Token;
const TokenKind = lex_mod.TokenKind;

const ast = @import("ast.zig");
const Node = ast.Node;
const NodeRef = ast.NodeRef;
const Param = ast.Param;
const FieldInit = ast.FieldInit;
const SwitchArm = ast.SwitchArm;

// ── Global import-dedup set (reset per top-level parse call) ──────────────────
// We use a simple heap-allocated string set.  The owning allocator must outlive
// the parse call; we just use the same allocator that is passed to the parser.
var g_import_seen: ?std.StringHashMap(void) = null;

// Set of C runtime files (e.g. std/runtime.c) discovered next to imported
// modules. main.zig links these into the final binary.
var g_link_c: ?std.StringHashMap(void) = null;

fn importSeenInit(alloc: Allocator) void {
    if (g_import_seen == null) {
        g_import_seen = std.StringHashMap(void).init(alloc);
    }
    if (g_link_c == null) {
        g_link_c = std.StringHashMap(void).init(alloc);
    }
}

fn importSeenReset(alloc: Allocator) void {
    if (g_import_seen) |*m| {
        m.deinit();
    }
    g_import_seen = std.StringHashMap(void).init(alloc);
    if (g_link_c) |*m| {
        m.deinit();
    }
    g_link_c = std.StringHashMap(void).init(alloc);
}

/// Return the list of C files to link (collected from imported modules' dirs).
pub fn linkCFiles(alloc: Allocator) [][]const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    if (g_link_c) |m| {
        var it = m.keyIterator();
        while (it.next()) |k| out.append(k.*) catch {};
    }
    return out.toOwnedSlice() catch &[_][]const u8{};
}

fn importSeenContains(path: []const u8) bool {
    if (g_import_seen) |m| return m.contains(path);
    return false;
}

fn importSeenAdd(path: []const u8) !void {
    if (g_import_seen) |*m| {
        try m.put(path, {});
    }
}

// ── Error reporting ───────────────────────────────────────────────────────────

fn parseErr(line: u32, comptime fmt: []const u8, args: anytype) noreturn {
    const stderr = std.io.getStdErr().writer();
    stderr.print("line {d}: error: " ++ fmt ++ "\n", .{line} ++ args) catch {};
    std.process.exit(1);
}

// ── Parser ────────────────────────────────────────────────────────────────────

pub const Parser = struct {
    toks: []const Token,
    i: usize,
    alloc: Allocator,
    src_dir: []const u8,

    pub fn init(toks: []const Token, alloc: Allocator, src_dir: []const u8) Parser {
        return .{
            .toks = toks,
            .i = 0,
            .alloc = alloc,
            .src_dir = src_dir,
        };
    }

    // ── token helpers ─────────────────────────────────────────────────────────

    fn peek(self: *Parser) Token {
        return self.toks[self.i];
    }

    fn nxt(self: *Parser) Token {
        return self.toks[self.i + 1];
    }

    /// True if the current token has the given kind (and optionally a specific val).
    fn at(self: *Parser, kind: TokenKind, val: ?[]const u8) bool {
        const t = self.toks[self.i];
        if (t.kind != kind) return false;
        if (val) |v| return std.mem.eql(u8, t.val, v);
        return true;
    }

    /// True if the current token has any of the given kinds.
    fn atKind(self: *Parser, kind: TokenKind) bool {
        return self.toks[self.i].kind == kind;
    }

    /// Consume the current token, asserting kind (and optional val). Returns the token.
    fn eat(self: *Parser, kind: TokenKind, val: ?[]const u8) Token {
        const t = self.toks[self.i];
        if (t.kind != kind) {
            if (val) |v| {
                parseErr(t.line, "expected '{s}', got '{s}'", .{ v, t.val });
            } else {
                parseErr(t.line, "expected token kind {}, got '{s}'", .{ kind, t.val });
            }
        }
        if (val) |v| {
            if (!std.mem.eql(u8, t.val, v)) {
                parseErr(t.line, "expected '{s}', got '{s}'", .{ v, t.val });
            }
        }
        self.i += 1;
        return t;
    }

    fn mkNode(self: *Parser, n: Node) !NodeRef {
        const p = try self.alloc.create(Node);
        p.* = n;
        return p;
    }

    // ── top-level parse ───────────────────────────────────────────────────────

    /// Parse a token stream into top-level declarations.
    /// Resets the global import-seen set on the very first call (when reset=true).
    pub fn parse(self: *Parser, reset_imports: bool) anyerror![]NodeRef {
        if (reset_imports) {
            importSeenReset(self.alloc);
        } else {
            importSeenInit(self.alloc);
        }

        var decls = std.ArrayList(NodeRef).init(self.alloc);
        while (!self.atKind(.eof)) {
            if (self.atKind(.kw_struct)) {
                try decls.append(try self.parseStruct());
            } else if (self.atKind(.kw_enum)) {
                try decls.append(try self.parseEnum());
            } else if (self.atKind(.kw_union)) {
                try decls.append(try self.parseUnion());
            } else if (self.atKind(.kw_error)) {
                try decls.append(try self.parseErrorDecl());
            } else if (self.at(.ident, "@import")) {
                const imported = try self.importDecl();
                try decls.appendSlice(imported);
            } else {
                try decls.append(try self.parseFn());
            }
        }
        return decls.toOwnedSlice();
    }

    // ── import ────────────────────────────────────────────────────────────────

    fn importDecl(self: *Parser) ![]NodeRef {
        const ln = self.eat(.ident, "@import").line;
        _ = self.eat(.lp, null);
        const path_tok = self.eat(.str, null);
        const path_str = path_tok.val;
        _ = self.eat(.rp, null);

        var qual: ?[]const u8 = null;
        if (self.at(.ident, "as")) {
            _ = self.eat(.ident, "as");
            qual = self.eat(.ident, null).val;
        }

        return self.loadModule(path_str, qual, ln);
    }

    fn loadModule(self: *Parser, path_str: []const u8, qual: ?[]const u8, line: u32) ![]NodeRef {
        // Resolve path relative to src_dir
        const full_path = blk: {
            if (std.fs.path.isAbsolute(path_str)) {
                break :blk try self.alloc.dupe(u8, path_str);
            }
            break :blk try std.fs.path.resolve(self.alloc, &.{ self.src_dir, path_str });
        };

        // Dedup check
        if (importSeenContains(full_path)) {
            return &[_]NodeRef{};
        }
        try importSeenAdd(full_path);

        // Read the file
        const src = std.fs.cwd().readFileAlloc(self.alloc, full_path, 10 * 1024 * 1024) catch |e| {
            parseErr(line, "@import: cannot open '{s}': {}", .{ full_path, e });
        };

        // Determine the child src_dir
        const child_dir = std.fs.path.dirname(full_path) orelse ".";

        // If this module's directory has a runtime.c, mark it for linking.
        if (g_link_c) |*m| {
            const rt = std.fs.path.resolve(self.alloc, &.{ child_dir, "runtime.c" }) catch null;
            if (rt) |rtp| {
                if (std.fs.cwd().access(rtp, .{})) |_| {
                    m.put(rtp, {}) catch {};
                } else |_| {}
            }
        }

        // Lex
        const child_toks = lex_mod.lex(self.alloc, src) catch |e| {
            parseErr(line, "@import: lex error in '{s}': {}", .{ full_path, e });
        };

        // Parse (recursive; do NOT reset the import set)
        var child_parser = Parser.init(child_toks, self.alloc, child_dir);
        const child_decls = try child_parser.parse(false);

        if (qual == null) {
            return child_decls;
        }

        // Qualify all decl names with the module prefix
        const prefix = try std.fmt.allocPrint(self.alloc, "{s}__", .{qual.?});
        const renamed = try qualifyDecls(self.alloc, child_decls, prefix);

        // Append a ModAlias node
        var result = std.ArrayList(NodeRef).init(self.alloc);
        try result.appendSlice(renamed);
        const alias_node = try self.mkNode(.{ .mod_alias = .{
            .alias = try self.alloc.dupe(u8, qual.?),
            .prefix = prefix,
            .line = line,
        } });
        try result.append(alias_node);
        return result.toOwnedSlice();
    }

    // ── struct ────────────────────────────────────────────────────────────────

    fn parseTparams(self: *Parser) ![][]const u8 {
        var tps = std.ArrayList([]const u8).init(self.alloc);
        if (self.atKind(.lbracket)) {
            _ = self.eat(.lbracket, null);
            while (!self.atKind(.rbracket)) {
                try tps.append(try self.alloc.dupe(u8, self.eat(.ident, null).val));
                if (self.atKind(.comma)) _ = self.eat(.comma, null);
            }
            _ = self.eat(.rbracket, null);
        }
        return tps.toOwnedSlice();
    }

    fn parseStruct(self: *Parser) !NodeRef {
        const ln = self.eat(.kw_struct, null).line;
        const name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
        const tparams = try self.parseTparams();
        _ = self.eat(.lbrace, null);
        var fields = std.ArrayList(Param).init(self.alloc);
        while (!self.atKind(.rbrace)) {
            const fn_ = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            _ = self.eat(.colon, null);
            const ft = try self.parseType();
            try fields.append(.{ .name = fn_, .pty = ft });
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rbrace, null);
        return self.mkNode(.{ .struct_decl = .{
            .name = name,
            .fields = try fields.toOwnedSlice(),
            .line = ln,
            .tparams = tparams,
        } });
    }

    // ── enum ──────────────────────────────────────────────────────────────────

    fn parseEnum(self: *Parser) !NodeRef {
        const ln = self.eat(.kw_enum, null).line;
        const name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
        _ = self.eat(.lbrace, null);
        var members = std.ArrayList([]const u8).init(self.alloc);
        while (!self.atKind(.rbrace)) {
            try members.append(try self.alloc.dupe(u8, self.eat(.ident, null).val));
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rbrace, null);
        return self.mkNode(.{ .enum_decl = .{
            .name = name,
            .members = try members.toOwnedSlice(),
            .line = ln,
        } });
    }

    // ── union ─────────────────────────────────────────────────────────────────

    fn parseUnion(self: *Parser) !NodeRef {
        const ln = self.eat(.kw_union, null).line;
        const name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
        _ = self.eat(.lbrace, null);
        var fields = std.ArrayList(Param).init(self.alloc);
        while (!self.atKind(.rbrace)) {
            const fn_ = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            _ = self.eat(.colon, null);
            const ft = try self.parseType();
            try fields.append(.{ .name = fn_, .pty = ft });
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rbrace, null);
        return self.mkNode(.{ .union_decl = .{
            .name = name,
            .fields = try fields.toOwnedSlice(),
            .line = ln,
        } });
    }

    // ── error decl ────────────────────────────────────────────────────────────

    fn parseErrorDecl(self: *Parser) !NodeRef {
        const ln = self.eat(.kw_error, null).line;
        _ = self.eat(.lbrace, null);
        var names = std.ArrayList([]const u8).init(self.alloc);
        while (!self.atKind(.rbrace)) {
            try names.append(try self.alloc.dupe(u8, self.eat(.ident, null).val));
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rbrace, null);
        return self.mkNode(.{ .error_decl = .{
            .names = try names.toOwnedSlice(),
            .line = ln,
        } });
    }

    // ── fn decl ───────────────────────────────────────────────────────────────

    fn parseFn(self: *Parser) !NodeRef {
        var is_extern = false;
        if (self.atKind(.kw_extern)) {
            _ = self.eat(.kw_extern, null);
            is_extern = true;
        }
        const ln = self.eat(.kw_fn, null).line;

        var recv_type: ?[]const u8 = null;
        if (self.atKind(.lp)) {
            // method receiver: fn (self: T) name(...)
            _ = self.eat(.lp, null);
            _ = self.eat(.ident, null); // receiver param name
            _ = self.eat(.colon, null);
            recv_type = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            _ = self.eat(.rp, null);
        }

        const raw_name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
        var method_name: ?[]const u8 = null;
        const name: []const u8 = if (recv_type) |rt| blk: {
            method_name = raw_name;
            break :blk try std.fmt.allocPrint(self.alloc, "{s}_{s}", .{ rt, raw_name });
        } else raw_name;

        const tparams = try self.parseTparams();

        _ = self.eat(.lp, null);
        var params = std.ArrayList(Param).init(self.alloc);
        while (!self.atKind(.rp)) {
            const pn = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            _ = self.eat(.colon, null);
            const pt = try self.parseType();
            try params.append(.{ .name = pn, .pty = pt });
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rp, null);

        const ret = try self.parseType();

        var annots = std.ArrayList([]const u8).init(self.alloc);
        while (self.atKind(.annot)) {
            try annots.append(try self.alloc.dupe(u8, self.eat(.annot, null).val));
        }

        const body: ?[]NodeRef = if (is_extern) blk: {
            _ = self.eat(.semi, null);
            break :blk null;
        } else try self.parseBlock();

        return self.mkNode(.{ .fn_decl = .{
            .name = name,
            .params = try params.toOwnedSlice(),
            .ret = ret,
            .annots = try annots.toOwnedSlice(),
            .body = body,
            .line = ln,
            .is_extern = is_extern,
            .tparams = tparams,
            .recv_type = recv_type,
            .method_name = method_name,
        } });
    }

    // ── type parser ───────────────────────────────────────────────────────────

    fn parseType(self: *Parser) ![]const u8 {
        const t = self.peek();

        // !T — error union type
        if (t.kind == .op and std.mem.eql(u8, t.val, "!")) {
            _ = self.eat(.op, "!");
            const inner = try self.parseType();
            return std.fmt.allocPrint(self.alloc, "!{s}", .{inner});
        }

        // ?T — optional type
        if (t.kind == .op and std.mem.eql(u8, t.val, "?")) {
            _ = self.eat(.op, "?");
            const inner = try self.parseType();
            return std.fmt.allocPrint(self.alloc, "?{s}", .{inner});
        }

        // []T — slice type
        if (t.kind == .lbracket) {
            _ = self.eat(.lbracket, null);
            _ = self.eat(.rbracket, null);
            const inner = try self.parseType();
            return std.fmt.allocPrint(self.alloc, "[]{s}", .{inner});
        }

        // fn(...) ret — function type
        if (t.kind == .kw_fn) {
            _ = self.eat(.kw_fn, null);
            _ = self.eat(.lp, null);
            var ps = std.ArrayList([]const u8).init(self.alloc);
            while (!self.atKind(.rp)) {
                try ps.append(try self.parseType());
                if (self.atKind(.comma)) _ = self.eat(.comma, null);
            }
            _ = self.eat(.rp, null);
            const ret = try self.parseType();
            const params_str = try std.mem.join(self.alloc, ",", ps.items);
            var s = try std.fmt.allocPrint(self.alloc, "fn({s}){s}", .{ params_str, ret });

            // optional bound annotation @realtime / @noalloc / etc.
            if (self.atKind(.annot)) {
                const ann = self.eat(.annot, null).val;
                s = try std.fmt.allocPrint(self.alloc, "{s}{s}", .{ s, ann });
            } else if (self.at(.op, "!")) {
                // latent effect row: ! pure / ! {Alloc,...} / ! effectVar
                _ = self.eat(.op, "!");
                if (self.atKind(.lbrace)) {
                    _ = self.eat(.lbrace, null);
                    var items = std.ArrayList([]const u8).init(self.alloc);
                    while (!self.atKind(.rbrace)) {
                        try items.append(try self.alloc.dupe(u8, self.eat(.ident, null).val));
                        if (self.atKind(.comma)) _ = self.eat(.comma, null);
                    }
                    _ = self.eat(.rbrace, null);
                    const items_str = try std.mem.join(self.alloc, ",", items.items);
                    s = try std.fmt.allocPrint(self.alloc, "{s}!{{{s}}}", .{ s, items_str });
                } else {
                    const eff_name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                    s = try std.fmt.allocPrint(self.alloc, "{s}!{s}", .{ s, eff_name });
                }
            }
            return s;
        }

        // *T — pointer type
        if (t.kind == .op and std.mem.eql(u8, t.val, "*")) {
            _ = self.eat(.op, "*");
            const inner = try self.parseType();
            return std.fmt.allocPrint(self.alloc, "*{s}", .{inner});
        }

        // Named type (possibly module-qualified or generic)
        var name = try self.alloc.dupe(u8, self.eat(.ident, null).val);

        // Check for module-qualified: mod.TypeName → mod__TypeName
        // Only if next is '.' and the token after that is not '['
        if (self.atKind(.dot)) {
            if (self.i + 1 < self.toks.len and self.toks[self.i + 1].kind != .lbracket) {
                _ = self.eat(.dot, null);
                const type_name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                name = try std.fmt.allocPrint(self.alloc, "{s}__{s}", .{ name, type_name });
            }
        }

        // Generic type application: Name[T1,T2]
        if (self.atKind(.lbracket)) {
            _ = self.eat(.lbracket, null);
            var args = std.ArrayList([]const u8).init(self.alloc);
            while (!self.atKind(.rbracket)) {
                try args.append(try self.parseType());
                if (self.atKind(.comma)) _ = self.eat(.comma, null);
            }
            _ = self.eat(.rbracket, null);
            const args_str = try std.mem.join(self.alloc, ",", args.items);
            return std.fmt.allocPrint(self.alloc, "{s}[{s}]", .{ name, args_str });
        }

        return name;
    }

    // ── block ─────────────────────────────────────────────────────────────────

    fn parseBlock(self: *Parser) anyerror![]NodeRef {
        _ = self.eat(.lbrace, null);
        var stmts = std.ArrayList(NodeRef).init(self.alloc);
        while (!self.atKind(.rbrace)) {
            try stmts.append(try self.parseStmt());
        }
        _ = self.eat(.rbrace, null);
        return stmts.toOwnedSlice();
    }

    // ── statement ─────────────────────────────────────────────────────────────

    fn parseStmt(self: *Parser) !NodeRef {
        const t = self.peek();

        // let
        if (t.kind == .kw_let) {
            _ = self.eat(.kw_let, null);
            const name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            var ty: ?[]const u8 = null;
            if (self.atKind(.colon)) {
                _ = self.eat(.colon, null);
                ty = try self.parseType();
            }
            _ = self.eat(.op, "=");
            const e = try self.parseExpr();
            _ = self.eat(.semi, null);
            return self.mkNode(.{ .let = .{
                .name = name,
                .dty = ty,
                .expr = e,
                .line = t.line,
            } });
        }

        // return
        if (t.kind == .kw_return) {
            _ = self.eat(.kw_return, null);
            const e: ?NodeRef = if (self.atKind(.semi)) null else try self.parseExpr();
            _ = self.eat(.semi, null);
            return self.mkNode(.{ .return_ = .{
                .expr = e,
                .line = t.line,
            } });
        }

        // if
        if (t.kind == .kw_if) {
            _ = self.eat(.kw_if, null);
            _ = self.eat(.lp, null);
            const cond = try self.parseExpr();
            _ = self.eat(.rp, null);
            var cap: ?[]const u8 = null;
            if (self.atKind(.pipe)) {
                _ = self.eat(.pipe, null);
                cap = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                _ = self.eat(.pipe, null);
            }
            const then = try self.parseBlock();
            var els: ?[]NodeRef = null;
            if (self.atKind(.kw_else)) {
                _ = self.eat(.kw_else, null);
                els = try self.parseBlock();
            }
            return self.mkNode(.{ .if_ = .{
                .cond = cond,
                .then = then,
                .els = els,
                .line = t.line,
                .cap = cap,
            } });
        }

        // while
        if (t.kind == .kw_while) {
            _ = self.eat(.kw_while, null);
            _ = self.eat(.lp, null);
            const cond = try self.parseExpr();
            _ = self.eat(.rp, null);
            var wcap: ?[]const u8 = null;
            if (self.atKind(.pipe)) {
                _ = self.eat(.pipe, null);
                wcap = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                _ = self.eat(.pipe, null);
            }
            const body = try self.parseBlock();
            return self.mkNode(.{ .while_ = .{
                .cond = cond,
                .body = body,
                .line = t.line,
                .cap = wcap,
            } });
        }

        // switch
        if (t.kind == .kw_switch) {
            return self.parseSwitch();
        }

        // expr, possibly followed by = (assignment) or ; (expr_stmt)
        const e = try self.parseExpr();
        if (self.at(.op, "=")) {
            _ = self.eat(.op, "=");
            const rhs = try self.parseExpr();
            _ = self.eat(.semi, null);
            return self.mkNode(.{ .assign = .{
                .target = e,
                .expr = rhs,
                .line = t.line,
            } });
        }
        _ = self.eat(.semi, null);
        return self.mkNode(.{ .expr_stmt = .{
            .expr = e,
            .line = t.line,
        } });
    }

    // ── switch ────────────────────────────────────────────────────────────────

    fn parseSwitch(self: *Parser) !NodeRef {
        const ln = self.eat(.kw_switch, null).line;
        _ = self.eat(.lp, null);
        const subject = try self.parseExpr();
        _ = self.eat(.rp, null);
        _ = self.eat(.lbrace, null);

        var arms = std.ArrayList(SwitchArm).init(self.alloc);
        var els_body: ?[]NodeRef = null;
        var is_expr: ?bool = null;

        while (!self.atKind(.rbrace)) {
            // else arm
            if (self.atKind(.kw_else)) {
                _ = self.eat(.kw_else, null);
                _ = self.eat(.op, "=>");
                const arm_is_block = self.atKind(.lbrace);
                const body: []NodeRef = if (arm_is_block) try self.parseBlock() else build_else: {
                    const e = try self.parseExpr();
                    const arr = try self.alloc.alloc(NodeRef, 1);
                    arr[0] = try self.mkNode(.{ .expr_stmt = .{ .expr = e, .line = ln } });
                    if (self.atKind(.comma)) _ = self.eat(.comma, null);
                    break :build_else arr;
                };
                els_body = body;
                if (is_expr == null) is_expr = !arm_is_block;
                continue;
            }

            // pattern list: .Tag or integer literal, comma-separated
            var tags = std.ArrayList([]const u8).init(self.alloc);
            while (true) {
                if (self.atKind(.dot)) {
                    _ = self.eat(.dot, null);
                    try tags.append(try self.alloc.dupe(u8, self.eat(.ident, null).val));
                } else if (self.atKind(.int)) {
                    try tags.append(try self.alloc.dupe(u8, self.eat(.int, null).val));
                } else {
                    const pt = self.peek();
                    parseErr(pt.line, "expected pattern in switch arm, got '{s}'", .{pt.val});
                }
                if (self.atKind(.comma)) {
                    // peek ahead: if next is "=>" this comma is arm separator, not pattern
                    if (self.i + 1 < self.toks.len and
                        self.toks[self.i + 1].kind == .op and
                        std.mem.eql(u8, self.toks[self.i + 1].val, "=>"))
                    {
                        _ = self.eat(.comma, null);
                        break;
                    }
                    // also break if we see another dot or int (multi-pattern separator)
                    // peek: comma followed by dot or int = multi-pattern
                    if (self.i + 1 < self.toks.len and
                        (self.toks[self.i + 1].kind == .dot or
                            self.toks[self.i + 1].kind == .int))
                    {
                        _ = self.eat(.comma, null);
                        // continue loop to read next pattern
                    } else {
                        _ = self.eat(.comma, null);
                        break;
                    }
                } else {
                    break;
                }
            }

            _ = self.eat(.op, "=>");

            var cap: ?[]const u8 = null;
            if (self.atKind(.pipe)) {
                _ = self.eat(.pipe, null);
                cap = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                _ = self.eat(.pipe, null);
            }

            const arm_is_block = self.atKind(.lbrace);
            const body: []NodeRef = if (arm_is_block) try self.parseBlock() else blk: {
                const e = try self.parseExpr();
                const arr = try self.alloc.alloc(NodeRef, 1);
                arr[0] = try self.mkNode(.{ .expr_stmt = .{ .expr = e, .line = ln } });
                if (self.atKind(.comma)) _ = self.eat(.comma, null);
                break :blk arr;
            };

            if (is_expr == null) {
                is_expr = !arm_is_block;
            } else if (is_expr.? == arm_is_block) {
                parseErr(ln, "cannot mix block arms and expression arms in one switch", .{});
            }

            try arms.append(.{
                .tags = try tags.toOwnedSlice(),
                .cap = cap,
                .body = body,
            });
        }

        _ = self.eat(.rbrace, null);

        return self.mkNode(.{ .switch_ = .{
            .subject = subject,
            .arms = try arms.toOwnedSlice(),
            .els = els_body,
            .line = ln,
            .is_expr = is_expr orelse false,
        } });
    }

    // ── expression hierarchy ──────────────────────────────────────────────────

    fn parseExpr(self: *Parser) anyerror!NodeRef {
        return self.parseCatchExpr();
    }

    fn parseCatchExpr(self: *Parser) !NodeRef {
        // try expr
        if (self.atKind(.kw_try)) {
            const ln_tok = self.eat(.kw_try, null);
            const inner = try self.parseCatchExpr();
            const p = try self.alloc.create(Node);
            p.* = .{ .try_ = inner };
            _ = ln_tok;
            return p;
        }

        const e = try self.parseBinExpr(0);

        // expr catch [|cap|] default
        if (self.atKind(.kw_catch)) {
            const ln = self.eat(.kw_catch, null).line;
            var cap: ?[]const u8 = null;
            if (self.atKind(.pipe)) {
                _ = self.eat(.pipe, null);
                cap = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                _ = self.eat(.pipe, null);
            }
            const def = try self.parseBinExpr(0);
            return self.mkNode(.{ .catch_ = .{
                .expr = e,
                .default = def,
                .cap = cap,
                .line = ln,
            } });
        }

        // opt orelse default
        if (self.atKind(.kw_orelse)) {
            const ln = self.eat(.kw_orelse, null).line;
            const def = try self.parseBinExpr(0);
            return self.mkNode(.{ .or_else = .{
                .expr = e,
                .default = def,
                .line = ln,
            } });
        }

        return e;
    }

    // PREC table: || = 1, && = 2, == != < > <= >= | ^ & = 3/4, + - = 5, * / % = 6
    fn opPrec(op: []const u8) ?u8 {
        if (std.mem.eql(u8, op, "||")) return 1;
        if (std.mem.eql(u8, op, "&&")) return 2;
        if (std.mem.eql(u8, op, "==")) return 3;
        if (std.mem.eql(u8, op, "!=")) return 3;
        if (std.mem.eql(u8, op, "<")) return 4;
        if (std.mem.eql(u8, op, ">")) return 4;
        if (std.mem.eql(u8, op, "<=")) return 4;
        if (std.mem.eql(u8, op, ">=")) return 4;
        if (std.mem.eql(u8, op, "|")) return 4;
        if (std.mem.eql(u8, op, "^")) return 4;
        if (std.mem.eql(u8, op, "&")) return 4;
        if (std.mem.eql(u8, op, "+")) return 5;
        if (std.mem.eql(u8, op, "-")) return 5;
        if (std.mem.eql(u8, op, "*")) return 6;
        if (std.mem.eql(u8, op, "/")) return 6;
        if (std.mem.eql(u8, op, "%")) return 6;
        return null;
    }

    fn parseBinExpr(self: *Parser, min_prec: u8) !NodeRef {
        var left = try self.parseUnary();
        while (true) {
            const t = self.peek();
            if (t.kind != .op) break;
            const prec = opPrec(t.val) orelse break;
            if (prec < min_prec) break;
            const op_tok = self.eat(.op, null);
            const right = try self.parseBinExpr(prec + 1);
            left = try self.mkNode(.{ .bin = .{
                .op = try self.alloc.dupe(u8, op_tok.val),
                .l = left,
                .r = right,
                .line = op_tok.line,
            } });
        }
        return left;
    }

    fn parseUnary(self: *Parser) !NodeRef {
        const t = self.peek();
        // address-of: &expr  (prefix '&'; infix '&' is bitwise-and, handled in parseBinExpr)
        if (t.kind == .op and std.mem.eql(u8, t.val, "&")) {
            const op_tok = self.eat(.op, null);
            const inner = try self.parseUnary();
            return self.mkNode(.{ .un = .{
                .op = try self.alloc.dupe(u8, op_tok.val),
                .e = inner,
                .line = op_tok.line,
            } });
        }
        if (t.kind == .op and (std.mem.eql(u8, t.val, "-") or std.mem.eql(u8, t.val, "!"))) {
            const op_tok = self.eat(.op, null);
            const inner = try self.parseUnary();
            return self.mkNode(.{ .un = .{
                .op = try self.alloc.dupe(u8, op_tok.val),
                .e = inner,
                .line = op_tok.line,
            } });
        }
        return self.parsePostfix();
    }

    /// Given the index of a '[' token, return the index of its matching ']'
    /// (accounting for nesting), or null if unmatched.
    fn matchingBracket(self: *Parser, open: usize) ?usize {
        var depth: i32 = 0;
        var k = open;
        while (k < self.toks.len) : (k += 1) {
            switch (self.toks[k].kind) {
                .lbracket => depth += 1,
                .rbracket => {
                    depth -= 1;
                    if (depth == 0) return k;
                },
                .eof => return null,
                else => {},
            }
        }
        return null;
    }

    fn parsePostfix(self: *Parser) !NodeRef {
        var e = try self.parsePrimary();
        while (true) {
            // cast: expr as Type
            if (self.at(.ident, "as")) {
                const ln = self.eat(.ident, "as").line;
                const ty = try self.parseType();
                e = try self.mkNode(.{ .cast = .{
                    .expr = e,
                    .target = ty,
                    .line = ln,
                } });
                continue;
            }
            // function call
            if (self.atKind(.lp)) {
                const ln = self.eat(.lp, null).line;
                var args = std.ArrayList(NodeRef).init(self.alloc);
                while (!self.atKind(.rp)) {
                    try args.append(try self.parseExpr());
                    if (self.atKind(.comma)) _ = self.eat(.comma, null);
                }
                _ = self.eat(.rp, null);
                e = try self.mkNode(.{ .call = .{
                    .callee = e,
                    .args = try args.toOwnedSlice(),
                    .line = ln,
                } });
            } else if (self.atKind(.lbracket)) {
                // Disambiguate generic-call `foo[T1,T2](args)` from index `arr[i]`:
                // if the matching ']' is immediately followed by '(', it's a generic call.
                if (self.matchingBracket(self.i)) |close| {
                    if (close + 1 < self.toks.len and self.toks[close + 1].kind == .lp) {
                        _ = self.eat(.lbracket, null);
                        var targs = std.ArrayList([]const u8).init(self.alloc);
                        while (!self.atKind(.rbracket)) {
                            try targs.append(try self.parseType());
                            if (self.atKind(.comma)) _ = self.eat(.comma, null);
                        }
                        _ = self.eat(.rbracket, null);
                        const ln = self.eat(.lp, null).line;
                        var cargs = std.ArrayList(NodeRef).init(self.alloc);
                        while (!self.atKind(.rp)) {
                            try cargs.append(try self.parseExpr());
                            if (self.atKind(.comma)) _ = self.eat(.comma, null);
                        }
                        _ = self.eat(.rp, null);
                        e = try self.mkNode(.{ .call = .{
                            .callee = e,
                            .args = try cargs.toOwnedSlice(),
                            .line = ln,
                            .targs = try targs.toOwnedSlice(),
                        } });
                        continue;
                    }
                }
                // index
                const ln = self.eat(.lbracket, null).line;
                const idx = try self.parseExpr();
                _ = self.eat(.rbracket, null);
                e = try self.mkNode(.{ .index = .{
                    .base = e,
                    .idx = idx,
                    .line = ln,
                } });
            } else if (self.atKind(.dot)) {
                // check for .? (force unwrap)
                if (self.i + 1 < self.toks.len and
                    self.toks[self.i + 1].kind == .op and
                    std.mem.eql(u8, self.toks[self.i + 1].val, "?"))
                {
                    const ln = self.peek().line;
                    self.i += 2; // consume '.' and '?'
                    const inner = e;
                    const wrap = try self.alloc.create(Node);
                    wrap.* = .{ .force_unwrap = inner };
                    _ = ln;
                    e = wrap;
                } else if (self.i + 1 < self.toks.len and
                    self.toks[self.i + 1].kind == .op and
                    std.mem.eql(u8, self.toks[self.i + 1].val, "*"))
                {
                    // ptr.* — pointer deref
                    const ln = self.peek().line;
                    _ = self.eat(.dot, null);
                    _ = self.eat(.op, "*");
                    e = try self.mkNode(.{ .field = .{
                        .base = e,
                        .fname = "*",
                        .line = ln,
                    } });
                } else {
                    // field access
                    const ln = self.peek().line;
                    _ = self.eat(.dot, null);
                    const fname = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                    e = try self.mkNode(.{ .field = .{
                        .base = e,
                        .fname = fname,
                        .line = ln,
                    } });
                }
            } else {
                break;
            }
        }
        return e;
    }

    // ── primary ───────────────────────────────────────────────────────────────

    fn parsePrimary(self: *Parser) anyerror!NodeRef {
        const t = self.peek();

        // switch as expression
        if (t.kind == .kw_switch) {
            return self.parseSwitch();
        }

        // null literal
        if (t.kind == .kw_null) {
            _ = self.eat(.kw_null, null);
            return self.mkNode(.{ .null_lit = .{ .line = t.line } });
        }

        // closure: fn[caps](params) ret { body }
        if (t.kind == .kw_fn) {
            return self.parseClosure();
        }

        // error.Name literal
        if (t.kind == .kw_error) {
            _ = self.eat(.kw_error, null);
            if (self.atKind(.dot)) {
                _ = self.eat(.dot, null);
                const name = try self.alloc.dupe(u8, self.eat(.ident, null).val);
                return self.mkNode(.{ .err_lit = .{ .errname = name, .line = t.line } });
            }
            parseErr(t.line, "expected 'error.Name'", .{});
        }

        // string literal
        if (t.kind == .str) {
            _ = self.eat(.str, null);
            return self.mkNode(.{ .lit = .{
                .lty = .str,
                .val = try self.alloc.dupe(u8, t.val),
                .line = t.line,
            } });
        }

        // integer literal
        if (t.kind == .int) {
            _ = self.eat(.int, null);
            return self.mkNode(.{ .lit = .{
                .lty = .int_lit,
                .val = try self.alloc.dupe(u8, t.val),
                .line = t.line,
            } });
        }

        // float literal
        if (t.kind == .float) {
            _ = self.eat(.float, null);
            return self.mkNode(.{ .lit = .{
                .lty = .float_lit,
                .val = try self.alloc.dupe(u8, t.val),
                .line = t.line,
            } });
        }

        // bool literal
        if (t.kind == .kw_true or t.kind == .kw_false) {
            self.i += 1;
            return self.mkNode(.{ .lit = .{
                .lty = .bool_,
                .val = try self.alloc.dupe(u8, t.val),
                .line = t.line,
            } });
        }

        // parenthesised expression
        if (t.kind == .lp) {
            _ = self.eat(.lp, null);
            const e = try self.parseExpr();
            _ = self.eat(.rp, null);
            return e;
        }

        // ident-prefixed forms
        if (t.kind == .ident) {
            // mod.TypeName{ .f = v } — module-qualified struct literal
            // Pattern: ident '.' ident '{'
            if (self.i + 3 < self.toks.len and
                self.toks[self.i + 1].kind == .dot and
                self.toks[self.i + 2].kind == .ident and
                self.toks[self.i + 3].kind == .lbrace)
            {
                const mod_tok = self.eat(.ident, null);
                _ = self.eat(.dot, null);
                const typ_tok = self.eat(.ident, null);
                const mangled = try std.fmt.allocPrint(self.alloc, "{s}__{s}", .{ mod_tok.val, typ_tok.val });
                return self.parseStructLit(mangled, mod_tok.line, &[_][]const u8{});
            }

            // Name{ .f = v } — struct literal
            if (self.i + 1 < self.toks.len and self.toks[self.i + 1].kind == .lbrace) {
                const name_tok = self.eat(.ident, null);
                return self.parseStructLit(
                    try self.alloc.dupe(u8, name_tok.val),
                    name_tok.line,
                    &[_][]const u8{},
                );
            }

            // Name[T]{ .f = v } — generic struct literal
            if (self.i + 1 < self.toks.len and
                self.toks[self.i + 1].kind == .lbracket and
                self.genericCtorAhead())
            {
                const name_tok = self.eat(.ident, null);
                _ = self.eat(.lbracket, null);
                var targs = std.ArrayList([]const u8).init(self.alloc);
                while (!self.atKind(.rbracket)) {
                    try targs.append(try self.parseType());
                    if (self.atKind(.comma)) _ = self.eat(.comma, null);
                }
                _ = self.eat(.rbracket, null);
                return self.parseStructLit(
                    try self.alloc.dupe(u8, name_tok.val),
                    name_tok.line,
                    try targs.toOwnedSlice(),
                );
            }

            // plain variable
            _ = self.eat(.ident, null);
            return self.mkNode(.{ .var_ = .{
                .name = try self.alloc.dupe(u8, t.val),
                .line = t.line,
            } });
        }

        parseErr(t.line, "unexpected '{s}' in expression", .{t.val});
    }

    fn parseStructLit(self: *Parser, sname: []const u8, line: u32, targs: []const []const u8) !NodeRef {
        _ = self.eat(.lbrace, null);
        var fields = std.ArrayList(FieldInit).init(self.alloc);
        while (!self.atKind(.rbrace)) {
            _ = self.eat(.dot, null);
            const fn_ = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            _ = self.eat(.op, "=");
            const val = try self.parseExpr();
            try fields.append(.{ .name = fn_, .val = val });
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rbrace, null);

        // Copy targs into owned memory
        const owned_targs = try self.alloc.dupe([]const u8, targs);

        return self.mkNode(.{ .struct_lit = .{
            .sname = sname,
            .fields = try fields.toOwnedSlice(),
            .line = line,
            .targs = owned_targs,
        } });
    }

    fn parseClosure(self: *Parser) !NodeRef {
        const ln = self.eat(.kw_fn, null).line;
        _ = self.eat(.lbracket, null);
        var caps = std.ArrayList([]const u8).init(self.alloc);
        while (!self.atKind(.rbracket)) {
            try caps.append(try self.alloc.dupe(u8, self.eat(.ident, null).val));
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rbracket, null);
        _ = self.eat(.lp, null);
        var params = std.ArrayList(Param).init(self.alloc);
        while (!self.atKind(.rp)) {
            const pn = try self.alloc.dupe(u8, self.eat(.ident, null).val);
            _ = self.eat(.colon, null);
            const pt = try self.parseType();
            try params.append(.{ .name = pn, .pty = pt });
            if (self.atKind(.comma)) _ = self.eat(.comma, null);
        }
        _ = self.eat(.rp, null);
        const ret = try self.parseType();
        const body = try self.parseBlock();
        return self.mkNode(.{ .closure = .{
            .caps = try caps.toOwnedSlice(),
            .params = try params.toOwnedSlice(),
            .ret = ret,
            .body = body,
            .line = ln,
        } });
    }

    // ── generic constructor lookahead ─────────────────────────────────────────
    // At current position, i points to an ident and i+1 is '['.
    // Returns true iff the matching ']' is immediately followed by '{'.
    fn genericCtorAhead(self: *Parser) bool {
        var j = self.i + 1; // points at '['
        var depth: usize = 0;
        while (j < self.toks.len) {
            const k = self.toks[j].kind;
            if (k == .lbracket) {
                depth += 1;
            } else if (k == .rbracket) {
                depth -= 1;
                if (depth == 0) {
                    return j + 1 < self.toks.len and self.toks[j + 1].kind == .lbrace;
                }
            } else if (k == .eof) {
                return false;
            }
            j += 1;
        }
        return false;
    }
};

// ── Module qualification helpers ──────────────────────────────────────────────

/// Rename every top-level declaration with `prefix`, substituting internal
/// type references. Returns a new slice of qualified NodeRef values.
fn qualifyDecls(alloc: Allocator, decls: []NodeRef, prefix: []const u8) ![]NodeRef {
    // Build a name map: original → prefixed
    var names = std.StringHashMap([]const u8).init(alloc);
    defer names.deinit();

    for (decls) |nr| {
        switch (nr.*) {
            // extern fns keep their literal FFI symbol name — never qualified.
            .fn_decl => |f| if (!f.is_extern)
                try names.put(f.name, try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, f.name })),
            .struct_decl => |s| try names.put(s.name, try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, s.name })),
            .enum_decl => |e| try names.put(e.name, try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, e.name })),
            .union_decl => |u| try names.put(u.name, try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, u.name })),
            else => {},
        }
    }

    var result = std.ArrayList(NodeRef).init(alloc);
    for (decls) |nr| {
        switch (nr.*) {
            .fn_decl => |f| {
                const new_name = if (f.is_extern)
                    f.name
                else
                    names.get(f.name) orelse try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, f.name });
                var new_params = try alloc.alloc(Param, f.params.len);
                for (f.params, 0..) |p, i| {
                    new_params[i] = .{
                        .name = p.name,
                        .pty = substType(alloc, p.pty, &names) catch p.pty,
                    };
                }
                const new_ret = substType(alloc, f.ret, &names) catch f.ret;
                const new_recv = if (f.recv_type) |rt| substType(alloc, rt, &names) catch rt else null;
                // Build a body-rename map that EXCLUDES names shadowed by this
                // fn's params or locals, so e.g. a param `cap` is not rewritten
                // to the sibling function `mod__cap`.
                var body_names = std.StringHashMap([]const u8).init(alloc);
                defer body_names.deinit();
                {
                    var nit = names.iterator();
                    while (nit.next()) |kv| body_names.put(kv.key_ptr.*, kv.value_ptr.*) catch {};
                    for (f.params) |p| _ = body_names.remove(p.name);
                    if (f.body) |b| removeBoundLetNames(b, &body_names);
                }
                const new_body = if (f.body) |b| try cloneStmts(alloc, b, &body_names) else null;
                const np = try alloc.create(Node);
                np.* = .{ .fn_decl = .{
                    .name = new_name,
                    .params = new_params,
                    .ret = new_ret,
                    .annots = f.annots,
                    .body = new_body,
                    .line = f.line,
                    .is_extern = f.is_extern,
                    .tparams = f.tparams,
                    .recv_type = new_recv,
                    .method_name = f.method_name,
                } };
                try result.append(np);
            },
            .struct_decl => |s| {
                const new_name = names.get(s.name) orelse try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, s.name });
                var new_fields = try alloc.alloc(Param, s.fields.len);
                for (s.fields, 0..) |p, i| {
                    new_fields[i] = .{
                        .name = p.name,
                        .pty = substType(alloc, p.pty, &names) catch p.pty,
                    };
                }
                const np = try alloc.create(Node);
                np.* = .{ .struct_decl = .{
                    .name = new_name,
                    .fields = new_fields,
                    .line = s.line,
                    .tparams = s.tparams,
                } };
                try result.append(np);
            },
            .enum_decl => |e| {
                const new_name = names.get(e.name) orelse try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, e.name });
                const np = try alloc.create(Node);
                np.* = .{ .enum_decl = .{
                    .name = new_name,
                    .members = e.members,
                    .line = e.line,
                } };
                try result.append(np);
            },
            .union_decl => |u| {
                const new_name = names.get(u.name) orelse try std.fmt.allocPrint(alloc, "{s}{s}", .{ prefix, u.name });
                var new_fields = try alloc.alloc(Param, u.fields.len);
                for (u.fields, 0..) |p, i| {
                    new_fields[i] = .{
                        .name = p.name,
                        .pty = substType(alloc, p.pty, &names) catch p.pty,
                    };
                }
                const np = try alloc.create(Node);
                np.* = .{ .union_decl = .{
                    .name = new_name,
                    .fields = new_fields,
                    .line = u.line,
                } };
                try result.append(np);
            },
            else => try result.append(nr), // ErrorDecl, ModAlias — pass through
        }
    }

    return result.toOwnedSlice();
}

/// Substitute known type names within a type string.
fn substType(alloc: Allocator, ty: []const u8, names: *const std.StringHashMap([]const u8)) ![]const u8 {
    // Direct lookup
    if (names.get(ty)) |replacement| return replacement;

    // Handle prefix characters: !, ?, *, []
    if (ty.len > 0 and (ty[0] == '!' or ty[0] == '?' or ty[0] == '*')) {
        const inner = try substType(alloc, ty[1..], names);
        return std.fmt.allocPrint(alloc, "{c}{s}", .{ ty[0], inner });
    }
    if (ty.len > 2 and ty[0] == '[' and ty[1] == ']') {
        const inner = try substType(alloc, ty[2..], names);
        return std.fmt.allocPrint(alloc, "[]{s}", .{inner});
    }

    // Try to substitute the base name of a generic type like Name[T]
    if (std.mem.indexOfScalar(u8, ty, '[')) |bracket_pos| {
        const base = ty[0..bracket_pos];
        if (names.get(base)) |new_base| {
            return std.fmt.allocPrint(alloc, "{s}{s}", .{ new_base, ty[bracket_pos..] });
        }
    }

    return ty;
}

/// Shallow clone a statement list, substituting type strings in Let nodes.
/// A full deep clone is complex; here we substitute type annotations only —
/// this mirrors what the Python compiler does (it only subs types in params/ret).
/// Remove from `names` every identifier bound by a `let` anywhere in `stmts`
/// (including nested blocks). Used so module qualification never rewrites a
/// local that shadows a sibling top-level declaration.
fn removeBoundLetNames(stmts: []NodeRef, names: *std.StringHashMap([]const u8)) void {
    for (stmts) |nr| {
        switch (nr.*) {
            .let => |*l| {
                _ = names.remove(l.name);
            },
            .if_ => |*i| {
                removeBoundLetNames(i.then, names);
                if (i.els) |e| removeBoundLetNames(e, names);
                if (i.cap) |c| _ = names.remove(c);
            },
            .while_ => |*w| {
                removeBoundLetNames(w.body, names);
                if (w.cap) |c| _ = names.remove(c);
            },
            .switch_ => |*sw| {
                for (sw.arms) |arm| {
                    removeBoundLetNames(arm.body, names);
                    if (arm.cap) |c| _ = names.remove(c);
                }
                if (sw.els) |e| removeBoundLetNames(e, names);
            },
            else => {},
        }
    }
}

fn cloneStmts(alloc: Allocator, stmts: []NodeRef, names: *const std.StringHashMap([]const u8)) anyerror![]NodeRef {
    var out = try alloc.alloc(NodeRef, stmts.len);
    for (stmts, 0..) |nr, i| {
        out[i] = try cloneNode(alloc, nr, names);
    }
    return out;
}

fn cloneExpr(alloc: Allocator, nr: NodeRef, names: *const std.StringHashMap([]const u8)) anyerror!NodeRef {
    const np = try alloc.create(Node);
    np.* = switch (nr.*) {
        .lit         => |*l| Node{ .lit = .{ .lty = l.lty, .val = l.val, .line = l.line } },
        // Rename references to module-qualified top-level decls (fn/struct/...).
        // `names` only contains top-level names, so locals/params pass through.
        .var_        => |*v| Node{ .var_ = .{ .name = names.get(v.name) orelse v.name, .line = v.line } },
        .un          => |*u| Node{ .un = .{
            .op   = u.op,
            .e    = try cloneExpr(alloc, u.e, names),
            .line = u.line,
        }},
        .bin         => |*b| Node{ .bin = .{
            .op   = b.op,
            .l    = try cloneExpr(alloc, b.l, names),
            .r    = try cloneExpr(alloc, b.r, names),
            .line = b.line,
        }},
        .index       => |*i| Node{ .index = .{
            .base = try cloneExpr(alloc, i.base, names),
            .idx  = try cloneExpr(alloc, i.idx, names),
            .line = i.line,
        }},
        .cast        => |*c| Node{ .cast = .{
            .expr   = try cloneExpr(alloc, c.expr, names),
            .target = substType(alloc, c.target, names) catch c.target,
            .line   = c.line,
        }},
        .field       => |*f| Node{ .field = .{
            .base  = try cloneExpr(alloc, f.base, names),
            .fname = f.fname,
            .line  = f.line,
        }},
        .struct_lit  => |*sl| blk: {
            // Rename the struct name using the qualification map
            const new_sname = names.get(sl.sname) orelse sl.sname;
            var new_fields = try alloc.alloc(ast.FieldInit, sl.fields.len);
            for (sl.fields, 0..) |fi, idx| {
                new_fields[idx] = .{ .name = fi.name, .val = try cloneExpr(alloc, fi.val, names) };
            }
            var new_targs = try alloc.alloc([]const u8, sl.targs.len);
            for (sl.targs, 0..) |a, idx| {
                new_targs[idx] = substType(alloc, a, names) catch a;
            }
            break :blk Node{ .struct_lit = .{
                .sname  = new_sname,
                .fields = new_fields,
                .line   = sl.line,
                .targs  = new_targs,
            }};
        },
        .call        => |*c| blk: {
            var new_args = try alloc.alloc(NodeRef, c.args.len);
            for (c.args, 0..) |a, idx| new_args[idx] = try cloneExpr(alloc, a, names);
            var new_targs = try alloc.alloc([]const u8, c.targs.len);
            for (c.targs, 0..) |a, idx| new_targs[idx] = substType(alloc, a, names) catch a;
            break :blk Node{ .call = .{
                .callee = try cloneExpr(alloc, c.callee, names),
                .args   = new_args,
                .line   = c.line,
                .targs  = new_targs,
            }};
        },
        .err_lit     => |*el| Node{ .err_lit = .{ .errname = el.errname, .line = el.line } },
        .try_        => |inner| Node{ .try_ = try cloneExpr(alloc, inner, names) },
        .catch_      => |*c| Node{ .catch_ = .{
            .expr    = try cloneExpr(alloc, c.expr, names),
            .default = try cloneExpr(alloc, c.default, names),
            .cap     = c.cap,
            .line    = c.line,
        }},
        .null_lit    => |*nl| Node{ .null_lit = .{ .line = nl.line } },
        .or_else     => |*oe| Node{ .or_else = .{
            .expr    = try cloneExpr(alloc, oe.expr, names),
            .default = try cloneExpr(alloc, oe.default, names),
            .line    = oe.line,
        }},
        .force_unwrap => |inner| Node{ .force_unwrap = try cloneExpr(alloc, inner, names) },
        else          => nr.*,
    };
    return np;
}

fn cloneNode(alloc: Allocator, nr: NodeRef, names: *const std.StringHashMap([]const u8)) anyerror!NodeRef {
    const np = try alloc.create(Node);
    np.* = switch (nr.*) {
        .let => |*l| Node{ .let = .{
            .name = l.name,
            .dty  = if (l.dty) |dt| substType(alloc, dt, names) catch dt else null,
            .expr = try cloneExpr(alloc, l.expr, names),
            .line = l.line,
        }},
        .assign => |*a| Node{ .assign = .{
            .target = try cloneExpr(alloc, a.target, names),
            .expr   = try cloneExpr(alloc, a.expr, names),
            .line   = a.line,
        }},
        .return_ => |*r| Node{ .return_ = .{
            .expr = if (r.expr) |re| try cloneExpr(alloc, re, names) else null,
            .line = r.line,
        }},
        .if_ => |*i| Node{ .if_ = .{
            .cond = try cloneExpr(alloc, i.cond, names),
            .then = try cloneStmts(alloc, i.then, names),
            .els  = if (i.els) |e| try cloneStmts(alloc, e, names) else null,
            .line = i.line,
            .cap  = i.cap,
        }},
        .while_ => |*w| Node{ .while_ = .{
            .cond = try cloneExpr(alloc, w.cond, names),
            .body = try cloneStmts(alloc, w.body, names),
            .line = w.line,
            .cap  = w.cap,
        }},
        .switch_ => |*sw| blk: {
            var new_arms = try alloc.alloc(ast.SwitchArm, sw.arms.len);
            for (sw.arms, 0..) |arm, idx| {
                new_arms[idx] = .{
                    .tags = arm.tags,
                    .cap  = arm.cap,
                    .body = try cloneStmts(alloc, arm.body, names),
                };
            }
            break :blk Node{ .switch_ = .{
                .subject = try cloneExpr(alloc, sw.subject, names),
                .arms    = new_arms,
                .els     = if (sw.els) |e| try cloneStmts(alloc, e, names) else null,
                .line    = sw.line,
            }};
        },
        .expr_stmt => |*es| Node{ .expr_stmt = .{
            .expr = try cloneExpr(alloc, es.expr, names),
            .line = es.line,
        }},
        else => nr.*,
    };
    return np;
}

// ── Public entry point ────────────────────────────────────────────────────────

/// Parse a token stream into top-level declarations.
/// `src_dir` is used to resolve @import paths.
/// Set `reset_imports` to true for the outermost call; false for recursive imports.
pub fn parse(
    toks: []const Token,
    alloc: Allocator,
    src_dir: []const u8,
    reset_imports: bool,
) anyerror![]NodeRef {
    var p = Parser.init(toks, alloc, src_dir);
    return p.parse(reset_imports);
}
