const std = @import("std");

pub const TokenKind = enum {
    eof,
    ident,
    annot,
    op,
    str,
    int,
    float,
    kw_fn,
    kw_extern,
    kw_let,
    kw_return,
    kw_if,
    kw_else,
    kw_while,
    kw_true,
    kw_false,
    kw_struct,
    kw_enum,
    kw_union,
    kw_switch,
    kw_error,
    kw_try,
    kw_catch,
    kw_null,
    kw_orelse,
    lp,       // (
    rp,       // )
    lbrace,   // {
    rbrace,   // }
    lbracket, // [
    rbracket, // ]
    comma,    // ,
    semi,     // ;
    colon,    // :
    dot,      // .
    pipe,     // |
};

pub const Token = struct {
    kind: TokenKind,
    val: []const u8, // slice into source (or alloc'd for string literals)
    line: u32,
};

pub const LexError = error{ UnexpectedChar, UnterminatedString, OutOfMemory };

/// Map a keyword string to its TokenKind.  Returns null if not a keyword.
fn keywordKind(word: []const u8) ?TokenKind {
    const map = std.StaticStringMap(TokenKind).initComptime(.{
        .{ "fn",     .kw_fn     },
        .{ "extern", .kw_extern },
        .{ "let",    .kw_let    },
        .{ "return", .kw_return },
        .{ "if",     .kw_if     },
        .{ "else",   .kw_else   },
        .{ "while",  .kw_while  },
        .{ "true",   .kw_true   },
        .{ "false",  .kw_false  },
        .{ "struct", .kw_struct },
        .{ "enum",   .kw_enum   },
        .{ "union",  .kw_union  },
        .{ "switch", .kw_switch },
        .{ "error",  .kw_error  },
        .{ "try",    .kw_try    },
        .{ "catch",  .kw_catch  },
        .{ "null",   .kw_null   },
        .{ "orelse", .kw_orelse },
    });
    return map.get(word);
}

/// Check whether an @-prefixed word is a known capability annotation.
fn isAnnotation(word: []const u8) bool {
    // word includes the leading '@'
    const annots = std.StaticStringMap(void).initComptime(.{
        .{ "@realtime", {} },
        .{ "@noalloc",  {} },
        .{ "@total",    {} },
        .{ "@pure",     {} },
        .{ "@kernel",   {} },
        .{ "@device",   {} },
        // effect-declaration annotations (used on extern fns to declare latent effects)
        .{ "@alloc",    {} },
        .{ "@panic",    {} },
        .{ "@io",       {} },
        .{ "@lock",     {} },
    });
    return annots.has(word);
}

pub fn lex(alloc: std.mem.Allocator, src: []const u8) LexError![]Token {
    var tokens = std.ArrayList(Token).init(alloc);
    errdefer tokens.deinit();

    var i: usize = 0;
    var line: u32 = 1;
    const n = src.len;

    while (i < n) {
        const c = src[i];

        // ── whitespace ────────────────────────────────────────────────
        if (c == '\n') {
            line += 1;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\r') {
            i += 1;
            continue;
        }

        // ── line comment ──────────────────────────────────────────────
        if (c == '/' and i + 1 < n and src[i + 1] == '/') {
            while (i < n and src[i] != '\n') : (i += 1) {}
            continue;
        }

        // ── ^ XOR / VSA-bind ─────────────────────────────────────────
        if (c == '^') {
            try tokens.append(.{ .kind = .op, .val = src[i .. i + 1], .line = line });
            i += 1;
            continue;
        }

        // ── & bitwise AND ─────────────────────────────────────────────
        if (c == '&') {
            try tokens.append(.{ .kind = .op, .val = src[i .. i + 1], .line = line });
            i += 1;
            continue;
        }

        // ── @ annotation or built-in ident ───────────────────────────
        if (c == '@') {
            var j = i + 1;
            while (j < n and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) : (j += 1) {}
            const word = src[i..j];
            const kind: TokenKind = if (isAnnotation(word)) .annot else .ident;
            try tokens.append(.{ .kind = kind, .val = word, .line = line });
            i = j;
            continue;
        }

        // ── identifier / keyword ──────────────────────────────────────
        if (std.ascii.isAlphabetic(c) or c == '_') {
            var j = i + 1;
            while (j < n and (std.ascii.isAlphanumeric(src[j]) or src[j] == '_')) : (j += 1) {}
            const word = src[i..j];
            const kind: TokenKind = keywordKind(word) orelse .ident;
            try tokens.append(.{ .kind = kind, .val = word, .line = line });
            i = j;
            continue;
        }

        // ── string literal ────────────────────────────────────────────
        if (c == '"') {
            var j = i + 1;
            var buf = std.ArrayList(u8).init(alloc);
            errdefer buf.deinit();

            while (j < n and src[j] != '"') {
                if (src[j] == '\\' and j + 1 < n) {
                    const esc = src[j + 1];
                    switch (esc) {
                        'n'  => try buf.appendSlice("\\n"),
                        't'  => try buf.appendSlice("\\t"),
                        'r'  => try buf.appendSlice("\\r"),
                        '\\' => try buf.appendSlice("\\\\"),
                        '"'  => try buf.appendSlice("\\\""),
                        '0'  => try buf.appendSlice("\\0"),
                        else => {
                            try buf.append('\\');
                            try buf.append(esc);
                        },
                    }
                    j += 2;
                } else if (src[j] == '\n') {
                    buf.deinit();
                    return LexError.UnterminatedString;
                } else {
                    try buf.append(src[j]);
                    j += 1;
                }
            }
            if (j >= n) {
                buf.deinit();
                return LexError.UnterminatedString;
            }
            const owned = try buf.toOwnedSlice();
            try tokens.append(.{ .kind = .str, .val = owned, .line = line });
            i = j + 1; // skip closing '"'
            continue;
        }

        // ── numeric literal ───────────────────────────────────────────
        if (std.ascii.isDigit(c)) {
            var j = i + 1;
            var is_float = false;
            while (j < n) {
                const d = src[j];
                if (std.ascii.isDigit(d)) {
                    j += 1;
                } else if (d == '.' and j + 1 < n and std.ascii.isDigit(src[j + 1])) {
                    is_float = true;
                    j += 1;
                } else if (d == 'e' or d == 'E') {
                    is_float = true;
                    j += 1;
                } else {
                    break;
                }
            }
            const kind: TokenKind = if (is_float) .float else .int;
            try tokens.append(.{ .kind = kind, .val = src[i..j], .line = line });
            i = j;
            continue;
        }

        // ── two-char operators ────────────────────────────────────────
        if (i + 1 < n) {
            const two = src[i .. i + 2];
            if (std.mem.eql(u8, two, "==") or
                std.mem.eql(u8, two, "!=") or
                std.mem.eql(u8, two, "<=") or
                std.mem.eql(u8, two, ">=") or
                std.mem.eql(u8, two, "&&") or
                std.mem.eql(u8, two, "||") or
                std.mem.eql(u8, two, "=>"))
            {
                try tokens.append(.{ .kind = .op, .val = two, .line = line });
                i += 2;
                continue;
            }
        }

        // ── single-char tokens ────────────────────────────────────────
        // Chars that get their own distinct kind:
        switch (c) {
            '(' => { try tokens.append(.{ .kind = .lp,       .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            ')' => { try tokens.append(.{ .kind = .rp,       .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            '{' => { try tokens.append(.{ .kind = .lbrace,   .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            '}' => { try tokens.append(.{ .kind = .rbrace,   .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            '[' => { try tokens.append(.{ .kind = .lbracket, .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            ']' => { try tokens.append(.{ .kind = .rbracket, .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            ',' => { try tokens.append(.{ .kind = .comma,    .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            ';' => { try tokens.append(.{ .kind = .semi,     .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            ':' => { try tokens.append(.{ .kind = .colon,    .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            '.' => { try tokens.append(.{ .kind = .dot,      .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            '|' => { try tokens.append(.{ .kind = .pipe,     .val = src[i .. i + 1], .line = line }); i += 1; continue; },
            // Chars classified as "op":
            '+', '-', '*', '/', '%', '<', '>', '=', '!', '?' => {
                try tokens.append(.{ .kind = .op, .val = src[i .. i + 1], .line = line });
                i += 1;
                continue;
            },
            else => {},
        }

        // ── unknown character ─────────────────────────────────────────
        return LexError.UnexpectedChar;
    }

    // ── EOF sentinel ──────────────────────────────────────────────────
    try tokens.append(.{ .kind = .eof, .val = "", .line = line });

    return tokens.toOwnedSlice();
}
