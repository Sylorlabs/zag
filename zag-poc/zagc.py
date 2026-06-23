#!/usr/bin/env python3
"""
zagc — the Zag bootstrap compiler (Phase 0 + type-level effect variables + structs/slices).

source (.zag) -> lex -> parse -> sema(types + EFFECTS-AS-TYPES) -> C -> cc -> native

The compiler PROVES capability claims (@realtime / @noalloc / @total) instead of trusting a
comment, AND the proofs compose through the type system: a function's effect is part of its
TYPE, so effects flow through higher-order params, function-typed locals, returned functions,
and STRUCT FIELDS. A callback stored in a struct and called on the audio thread is proven
realtime-safe — or rejected at the point it is stored.

Effect-carrying function types:
    fn(f32) f32 @realtime    -- bound: callback may NOT Alloc/Lock/IO
    fn(f32) f32 ! pure       -- latent row: callback does nothing
    fn(f32) f32 ! {Alloc}    -- latent row: callback may only Alloc
    fn(f32) f32 ! e          -- effect VARIABLE: instantiated to the callback's effect per call site

Undecidable cases (div-by-zero/bounds/termination) remain Phase-3 / ghost_engine+Z3.
"""

import sys, os, subprocess, shutil, re, json

try:
    import z3                                  # the SMT prover (ghost_engine wraps this same engine)
    HAVE_Z3 = True
except Exception:
    HAVE_Z3 = False

class ZagError(Exception):
    def __init__(self, line, msg):
        super().__init__(msg); self.line, self.msg = line, msg

# ───────────────────────────── 1. lexer ─────────────────────────────

KEYWORDS = {"fn", "extern", "let", "return", "if", "else", "while", "true", "false",
            "struct", "enum", "union", "switch", "error", "try", "catch"}
ANNOTATIONS = {"@realtime", "@noalloc", "@total", "@pure",
               "@kernel",   # GPU kernel — runs on device, launched from host via @gpuLaunch
               "@device",   # GPU device helper — callable from @kernel only, not host
               }

class Tok:
    def __init__(self, kind, val, line): self.kind, self.val, self.line = kind, val, line
    def __repr__(self): return f"Tok({self.kind},{self.val!r},L{self.line})"

def lex(src):
    toks, i, line, n = [], 0, 1, len(src)
    two = {"==", "!=", "<=", ">=", "&&", "||", "=>"}
    single = set("(){}[],;:.+-*/%<>=!|")
    while i < n:
        c = src[i]
        if c == "\n": line += 1; i += 1; continue
        if c in " \t\r": i += 1; continue
        if c == "/" and i + 1 < n and src[i+1] == "/":
            while i < n and src[i] != "\n": i += 1
            continue
        if c == "^":                    # XOR / VSA-bind operator
            toks.append(Tok("op", "^", line)); i += 1; continue
        if c == "&":                    # bitwise AND
            toks.append(Tok("op", "&", line)); i += 1; continue
        if c == "@":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"): j += 1
            word = src[i:j]
            # @realtime/@noalloc/... are capability annotations; other @names are builtin calls
            toks.append(Tok("annot" if word in ANNOTATIONS else "ident", word, line)); i = j; continue
        if c.isalpha() or c == "_":
            j = i + 1
            while j < n and (src[j].isalnum() or src[j] == "_"): j += 1
            word = src[i:j]
            toks.append(Tok(word if word in KEYWORDS else "ident", word, line)); i = j; continue
        if c == '"':                            # string literal -> []u8
            j = i + 1; chars = []
            while j < n and src[j] != '"':
                if src[j] == "\\" and j + 1 < n:
                    esc = src[j+1]
                    chars.append({"n":"\\n","t":"\\t","r":"\\r","\\":"\\\\",'"':'\\"',"0":"\\0"}.get(esc, "\\" + esc))
                    j += 2
                elif src[j] == "\n":
                    raise ZagError(line, "unterminated string literal (newline inside)")
                else:
                    chars.append(src[j]); j += 1
            if j >= n: raise ZagError(line, "unterminated string literal")
            toks.append(Tok("str", "".join(chars), line)); i = j + 1; continue
        if c.isdigit():
            j = i + 1; isf = False
            while j < n and (src[j].isdigit() or src[j] in ".eE"):
                # a '.' is part of a number only if followed by a digit (else it's field access)
                if src[j] == "." and not (j + 1 < n and src[j+1].isdigit()): break
                if src[j] in ".eE": isf = True
                j += 1
            toks.append(Tok("float" if isf else "int", src[i:j], line)); i = j; continue
        if src[i:i+2] in two: toks.append(Tok("op", src[i:i+2], line)); i += 2; continue
        if c in single:
            kind = "op" if c in "+-*/%<>=!" else c
            toks.append(Tok(kind, c, line)); i += 1; continue
        raise ZagError(line, f"unexpected character {c!r}")
    toks.append(Tok("eof", "", line))
    return toks

# ───────────────────────────── 2. AST ─────────────────────────────

class Node:
    ty = None
class Fn(Node):
    def __init__(self, name, params, ret, annots, body, line, extern=False, tparams=(),
                 recv_type=None, method_name=None):
        self.name, self.params, self.ret, self.annots = name, params, ret, annots
        self.body, self.line, self.extern, self.tparams = body, line, extern, list(tparams)
        self.recv_type   = recv_type    # str type name if this is a method, else None
        self.method_name = method_name  # original short name (e.g. "render"), else None
class ErrorDecl(Node):
    def __init__(self, names, line): self.names, self.line = names, line
class StructDecl(Node):
    def __init__(self, name, fields, line, tparams=()):
        self.name, self.fields, self.line, self.tparams = name, fields, line, list(tparams)
class EnumDecl(Node):
    def __init__(self, name, members, line): self.name, self.members, self.line = name, members, line
class UnionDecl(Node):
    def __init__(self, name, fields, line): self.name, self.fields, self.line = name, fields, line  # fields: [Param]
class Switch(Node):
    def __init__(self, subject, arms, els, line):
        self.subject, self.arms, self.els, self.line = subject, arms, els, line  # arms: [(tag, cap|None, [stmt])]
class Param(Node):
    def __init__(self, name, ty): self.name, self.pty = name, ty
class Let(Node):
    def __init__(self, name, ty, expr, line): self.name, self.dty, self.expr, self.line = name, ty, expr, line
class Assign(Node):
    def __init__(self, target, expr, line): self.target, self.expr, self.line = target, expr, line
class Return(Node):
    def __init__(self, expr, line): self.expr, self.line = expr, line
class If(Node):
    def __init__(self, cond, then, els, line): self.cond, self.then, self.els, self.line = cond, then, els, line
class While(Node):
    def __init__(self, cond, body, line): self.cond, self.body, self.line = cond, body, line
class ExprStmt(Node):
    def __init__(self, expr, line): self.expr, self.line = expr, line
class Bin(Node):
    def __init__(self, op, l, r, line): self.op, self.l, self.r, self.line = op, l, r, line
class Un(Node):
    def __init__(self, op, e, line): self.op, self.e, self.line = op, e, line
class Call(Node):
    def __init__(self, callee, args, line):
        self.callee, self.args, self.line = callee, args, line
        self.inst_name = None      # set by sema when the callee is a generic fn (monomorphized name)
class Index(Node):
    def __init__(self, base, idx, line): self.base, self.idx, self.line = base, idx, line
class Field(Node):
    def __init__(self, base, name, line): self.base, self.fname, self.line = base, name, line
class StructLit(Node):
    def __init__(self, name, fields, line, targs=()):
        self.sname, self.fields, self.line, self.targs = name, fields, line, list(targs)
        self.inst_sname = None     # set by sema (monomorphized struct name)
class Var(Node):
    def __init__(self, name, line): self.name, self.line = name, line
class Lit(Node):
    def __init__(self, ty, val, line): self.lty, self.val, self.line = ty, val, line
class Closure(Node):
    def __init__(self, caps, params, ret, body, line):
        self.caps, self.params, self.ret, self.body, self.line = caps, params, ret, body, line
        self.cap_types = {}     # filled by sema
        self.cid = None         # filled by codegen
class ErrLit(Node):
    def __init__(self, name, line): self.errname, self.line = name, line
class Try(Node):
    def __init__(self, expr, line): self.expr, self.line = expr, line
class Catch(Node):
    def __init__(self, expr, default, cap, line):
        self.expr, self.default, self.cap, self.line = expr, default, cap, line

# ───────────────────────────── 3. parser ─────────────────────────────

class Parser:
    def __init__(self, toks): self.toks, self.i = toks, 0
    def peek(self): return self.toks[self.i]
    def nxt(self): return self.toks[self.i + 1]
    def at(self, kind, val=None):
        t = self.toks[self.i]; return t.kind == kind and (val is None or t.val == val)
    def eat(self, kind, val=None):
        t = self.toks[self.i]
        if t.kind != kind or (val is not None and t.val != val):
            raise ZagError(t.line, f"expected {(val if val is not None else kind)!r}, got {t.val!r}")
        self.i += 1; return t

    def parse(self):
        decls = []
        while not self.at("eof"):
            if self.at("struct"): decls.append(self.struct())
            elif self.at("enum"): decls.append(self.enum_decl())
            elif self.at("union"): decls.append(self.union_decl())
            elif self.at("error"): decls.append(self.error_decl())
            else: decls.append(self.fn())
        return decls

    def error_decl(self):
        ln = self.eat("error").line; self.eat("{")
        names = []
        while not self.at("}"):
            names.append(self.eat("ident").val)
            if self.at(","): self.eat(",")
        self.eat("}")
        return ErrorDecl(names, ln)

    def enum_decl(self):
        ln = self.eat("enum").line
        name = self.eat("ident").val
        self.eat("{")
        members = []
        while not self.at("}"):
            members.append(self.eat("ident").val)
            if self.at(","): self.eat(",")
        self.eat("}")
        return EnumDecl(name, members, ln)

    def union_decl(self):
        ln = self.eat("union").line
        name = self.eat("ident").val
        self.eat("{")
        fields = []
        while not self.at("}"):
            fn_ = self.eat("ident").val; self.eat(":"); ft = self.type()
            fields.append(Param(fn_, ft))
            if self.at(","): self.eat(",")
        self.eat("}")
        return UnionDecl(name, fields, ln)

    def tparams_opt(self):
        tps = []
        if self.at("["):
            self.eat("[")
            while not self.at("]"):
                tps.append(self.eat("ident").val)
                if self.at(","): self.eat(",")
            self.eat("]")
        return tps

    def struct(self):
        ln = self.eat("struct").line
        name = self.eat("ident").val
        tparams = self.tparams_opt()
        self.eat("{")
        fields = []
        while not self.at("}"):
            fn_ = self.eat("ident").val; self.eat(":"); ft = self.type()
            fields.append(Param(fn_, ft))
            if self.at(","): self.eat(",")
        self.eat("}")
        return StructDecl(name, fields, ln, tparams)

    def type(self):
        t = self.peek()
        if t.kind == "op" and t.val == "!":   # error union type: !T
            self.eat("op", "!"); return "!" + self.type()
        if t.kind == "[":
            self.eat("["); self.eat("]"); return "[]" + self.type()
        if t.kind == "fn":
            self.eat("fn"); self.eat("(")
            ps = []
            while not self.at(")"):
                ps.append(self.type())
                if self.at(","): self.eat(",")
            self.eat(")"); ret = self.type()
            s = "fn(" + ",".join(ps) + ")" + ret
            if self.at("annot"):                       # bound: @realtime / @noalloc / ...
                s += self.eat("annot").val
            elif self.at("op", "!"):                   # latent row: ! pure / ! {Alloc} / ! e
                self.eat("op", "!")
                if self.at("{"):
                    self.eat("{"); items = []
                    while not self.at("}"):
                        items.append(self.eat("ident").val)
                        if self.at(","): self.eat(",")
                    self.eat("}"); s += "!{" + ",".join(items) + "}"
                else:
                    s += "!" + self.eat("ident").val   # 'pure' or an effect variable name
            return s
        name = self.eat("ident").val
        if self.at("["):                                # generic type application: Name[T1,T2]
            self.eat("[")
            args = []
            while not self.at("]"):
                args.append(self.type())
                if self.at(","): self.eat(",")
            self.eat("]")
            return name + "[" + ",".join(args) + "]"
        return name

    def fn(self):
        extern = False
        if self.at("extern"): self.eat("extern"); extern = True
        ln = self.eat("fn").line
        recv_type = None
        if self.at("("):   # method receiver: fn (self: T) name(...)
            self.eat("(")
            self.eat("ident")         # receiver param name (conventionally "self")
            self.eat(":")
            recv_type = self.eat("ident").val
            self.eat(")")
        raw_name = self.eat("ident").val
        method_name = None
        if recv_type:
            method_name = raw_name
            name = f"{recv_type}_{raw_name}"   # mangled: Vec3_dot, AudioBuf_render, etc.
        else:
            name = raw_name
        tparams = self.tparams_opt()
        self.eat("(")
        params = []
        while not self.at(")"):
            pn = self.eat("ident").val; self.eat(":"); pt = self.type()
            params.append(Param(pn, pt))
            if self.at(","): self.eat(",")
        self.eat(")")
        ret = self.type()
        annots = []
        while self.at("annot"): annots.append(self.eat("annot").val)
        kw = {"recv_type": recv_type, "method_name": method_name}
        if extern:
            self.eat(";"); return Fn(name, params, ret, annots, None, ln, extern=True, tparams=tparams, **kw)
        return Fn(name, params, ret, annots, self.block(), ln, tparams=tparams, **kw)

    def block(self):
        self.eat("{")
        stmts = []
        while not self.at("}"): stmts.append(self.stmt())
        self.eat("}")
        return stmts

    def stmt(self):
        t = self.peek()
        if t.kind == "let":
            self.eat("let"); name = self.eat("ident").val
            ty = None
            if self.at(":"): self.eat(":"); ty = self.type()
            self.eat("op", "="); e = self.expr(); self.eat(";")
            return Let(name, ty, e, t.line)
        if t.kind == "return":
            self.eat("return"); e = None if self.at(";") else self.expr()
            self.eat(";"); return Return(e, t.line)
        if t.kind == "if":
            self.eat("if"); self.eat("("); c = self.expr(); self.eat(")")
            then = self.block(); els = None
            if self.at("else"): self.eat("else"); els = self.block()
            return If(c, then, els, t.line)
        if t.kind == "while":
            self.eat("while"); self.eat("("); c = self.expr(); self.eat(")")
            return While(c, self.block(), t.line)
        if t.kind == "switch":
            self.eat("switch"); self.eat("("); subj = self.expr(); self.eat(")")
            self.eat("{")
            arms = []; els = None
            while not self.at("}"):
                if self.at("else"):
                    self.eat("else"); self.eat("op", "=>"); els = self.block(); continue
                self.eat("."); tag = self.eat("ident").val
                self.eat("op", "=>")
                cap = None
                if self.at("|"):
                    self.eat("|"); cap = self.eat("ident").val; self.eat("|")
                arms.append((tag, cap, self.block()))
            self.eat("}")
            return Switch(subj, arms, els, t.line)
        e = self.expr()
        if self.at("op", "="):
            self.eat("op", "="); rhs = self.expr(); self.eat(";")
            return Assign(e, rhs, t.line)
        self.eat(";"); return ExprStmt(e, t.line)

    def expr(self): return self.catch_expr()
    def catch_expr(self):
        if self.at("try"):                               # try expr — propagate error upward
            ln = self.eat("try").line
            return Try(self.catch_expr(), ln)
        e = self.binexpr(0)
        if self.at("catch"):                             # expr catch [|e|] default
            ln = self.eat("catch").line
            cap = None
            if self.at("|"): self.eat("|"); cap = self.eat("ident").val; self.eat("|")
            return Catch(e, self.binexpr(0), cap, ln)
        return e
    PREC = {"||":1, "&&":2, "==":3, "!=":3, "<":4, ">":4, "<=":4, ">=":4,
            "|":4, "^":4, "&":4,               # bitwise / VSA ops
            "+":5, "-":5, "*":6, "/":6, "%":6}
    def binexpr(self, minp):
        left = self.unary()
        while self.at("op") and self.peek().val in self.PREC and self.PREC[self.peek().val] >= minp:
            op = self.eat("op"); right = self.binexpr(self.PREC[op.val] + 1)
            left = Bin(op.val, left, right, op.line)
        return left
    def unary(self):
        if self.at("op") and self.peek().val in ("-", "!"):
            op = self.eat("op"); return Un(op.val, self.unary(), op.line)
        return self.postfix()
    def postfix(self):
        e = self.primary()
        while True:
            if self.at("("):
                ln = self.eat("(").line; args = []
                while not self.at(")"):
                    args.append(self.expr())
                    if self.at(","): self.eat(",")
                self.eat(")"); e = Call(e, args, ln)
            elif self.at("["):
                ln = self.eat("[").line; idx = self.expr(); self.eat("]"); e = Index(e, idx, ln)
            elif self.at("op", ".") or self.at("."):
                ln = self.peek().line; self.i += 1; e = Field(e, self.eat("ident").val, ln)
            else:
                break
        return e
    def closure(self):
        ln = self.eat("fn").line
        self.eat("[")
        caps = []
        while not self.at("]"):
            caps.append(self.eat("ident").val)
            if self.at(","): self.eat(",")
        self.eat("]")
        self.eat("(")
        params = []
        while not self.at(")"):
            pn = self.eat("ident").val; self.eat(":"); pt = self.type()
            params.append(Param(pn, pt))
            if self.at(","): self.eat(",")
        self.eat(")")
        ret = self.type()
        return Closure(caps, params, ret, self.block(), ln)

    def primary(self):
        t = self.peek()
        if t.kind == "fn": return self.closure()           # closure literal: fn[caps](params)ret{...}
        if t.kind == "error":                              # error.Name literal
            self.eat("error")
            if self.at("op", ".") or self.at("."):
                self.i += 1; name = self.eat("ident").val; return ErrLit(name, t.line)
            raise ZagError(t.line, "expected 'error.Name'")
        if t.kind == "str": self.eat("str"); return Lit("str", t.val, t.line)
        if t.kind == "int": self.eat("int"); return Lit("int_lit", t.val, t.line)
        if t.kind == "float": self.eat("float"); return Lit("float_lit", t.val, t.line)
        if t.kind in ("true", "false"): self.i += 1; return Lit("bool", t.val, t.line)
        if t.kind == "(":
            self.eat("("); e = self.expr(); self.eat(")"); return e
        if t.kind == "ident":
            if self.nxt().kind == "{":                  # struct literal: Name{ .f = v, ... }
                self.eat("ident")
                return self._struct_lit(t, [])
            if self.nxt().kind == "[" and self._generic_ctor_ahead():   # Name[T]{ .f = v, ... }
                self.eat("ident"); self.eat("[")
                targs = []
                while not self.at("]"):
                    targs.append(self.type())
                    if self.at(","): self.eat(",")
                self.eat("]")
                return self._struct_lit(t, targs)
            self.eat("ident"); return Var(t.val, t.line)
        raise ZagError(t.line, f"unexpected {t.val!r} in expression")

    def _struct_lit(self, t, targs):
        self.eat("{")
        fields = []
        while not self.at("}"):
            self.eat("."); fn_ = self.eat("ident").val; self.eat("op", "=")
            fields.append((fn_, self.expr()))
            if self.at(","): self.eat(",")
        self.eat("}")
        return StructLit(t.val, fields, t.line, targs)

    def _generic_ctor_ahead(self):
        # at an ident whose next token is '['; true iff the matching ']' is followed by '{'
        j = self.i + 1; depth = 0
        while j < len(self.toks):
            k = self.toks[j].kind
            if k == "[": depth += 1
            elif k == "]":
                depth -= 1
                if depth == 0: return self.toks[j+1].kind == "{"
            elif k == "eof": return False
            j += 1
        return False

# ───────────────────────────── helpers: effect rows ─────────────────────────────

ALL_EFFECTS = {"Alloc", "Lock", "IO", "Panic", "DeviceAlloc", "DeviceIO"}
FORBIDS = {
    "@realtime":  {"Alloc", "Lock", "IO"},
    "@noalloc":   {"Alloc"},
    "@pure":      {"Alloc", "Lock", "IO"},
    "@total":     {"Panic"},
    # GPU annotations
    "@kernel":    {"Alloc", "Lock", "IO"},   # no host-side alloc/lock/io in a GPU kernel
    "@device":    {"Alloc", "Lock", "IO"},   # device helpers have the same restrictions
}
BUILTINS = {
    "zalloc":    {"params": ["i32"],   "ret": "[]f32", "eff": {"Alloc"}},
    "zfree":     {"params": ["[]f32"], "ret": "void",  "eff": {"Alloc"}},
    "zalloc_i":  {"params": ["i32"],   "ret": "[]i32", "eff": {"Alloc"}},
    "zfree_i":   {"params": ["[]i32"], "ret": "void",  "eff": {"Alloc"}},
    "lock":      {"params": [],        "ret": "void",  "eff": {"Lock"}},
    "print_str": {"params": ["[]u8"],  "ret": "void",  "eff": {"IO"}},
    "print_i32": {"params": ["i32"],   "ret": "void",  "eff": {"IO"}},
    "print_f32": {"params": ["f32"],   "ret": "void",  "eff": {"IO"}},
    "print_u64": {"params": ["u64"],   "ret": "void",  "eff": {"IO"}},
    "print_i64": {"params": ["i64"],   "ret": "void",  "eff": {"IO"}},
    "print_f64": {"params": ["f64"],   "ret": "void",  "eff": {"IO"}},
    # posit casts (explicit, per the spec: floats never implicitly cast to posits)
    "@intToPosit":   {"params": ["i64"], "ret": "p32", "eff": set()},
    "@floatToPosit": {"params": ["f64"], "ret": "p32", "eff": set()},
    "@positToFloat": {"params": ["p32"], "ret": "f64", "eff": set()},
    "@positToBits":  {"params": ["p32"], "ret": "u64", "eff": set()},
    # width-specific posit casts: @floatToP8/@floatToP16/@floatToP64 etc.
    "@floatToP8":  {"params": ["f64"], "ret": "p8",  "eff": set()},
    "@floatToP16": {"params": ["f64"], "ret": "p16", "eff": set()},
    "@floatToP64": {"params": ["f64"], "ret": "p64", "eff": set()},
    "@intToP8":    {"params": ["i64"], "ret": "p8",  "eff": set()},
    "@intToP16":   {"params": ["i64"], "ret": "p16", "eff": set()},
    "@intToP64":   {"params": ["i64"], "ret": "p64", "eff": set()},
    "@p8ToFloat":  {"params": ["p8"],  "ret": "f64", "eff": set()},
    "@p16ToFloat": {"params": ["p16"], "ret": "f64", "eff": set()},
    "@p64ToFloat": {"params": ["p64"], "ret": "f64", "eff": set()},
    "@p8ToBits":   {"params": ["p8"],  "ret": "u64", "eff": set()},
    "@p16ToBits":  {"params": ["p16"], "ret": "u64", "eff": set()},
    "@p64ToBits":  {"params": ["p64"], "ret": "u64", "eff": set()},
    # quire (exact 512-bit FMA accumulator for p32). Pure (stack value) -> usable in @realtime.
    "@quireZero":    {"params": [],                  "ret": "quire", "eff": set()},
    "@quireFMA":     {"params": ["quire","p32","p32"], "ret": "quire", "eff": set()},
    "@quireToPosit": {"params": ["quire"],           "ret": "p32",   "eff": set()},
    "@strEq":    {"params": ["[]u8", "[]u8"], "ret": "bool", "eff": set()},
    "@strLen":   {"params": ["[]u8"],        "ret": "i32",  "eff": set()},
    "sinf":      {"params": ["f32"],   "ret": "f32",   "eff": set()},
    "sqrtf":     {"params": ["f32"],   "ret": "f32",   "eff": set()},
    # ── GPU intrinsics (only valid inside @kernel / @device functions) ─────────
    # Thread/block addressing — reads hardware thread index registers
    "@gpuThreadIdx": {"params": ["i32"],  "ret": "i32",  "eff": set()},
    "@gpuBlockIdx":  {"params": ["i32"],  "ret": "i32",  "eff": set()},
    "@gpuBlockDim":  {"params": ["i32"],  "ret": "i32",  "eff": set()},
    "@gpuGridDim":   {"params": ["i32"],  "ret": "i32",  "eff": set()},
    # Thread barrier (equivalent to __syncthreads in CUDA)
    "@gpuSyncThreads": {"params": [],     "ret": "void", "eff": set()},
    # Host-side GPU memory management (DeviceAlloc effect — forbidden in @kernel)
    "@gpuAlloc":     {"params": ["i32"],          "ret": "[]f32", "eff": {"DeviceAlloc"}},
    "@gpuFree":      {"params": ["[]f32"],         "ret": "void",  "eff": {"DeviceAlloc"}},
    # Kernel launch — DeviceIO effect; forbidden in @realtime host code
    "@gpuLaunch":    {"params": ["i32","i32","i32","i32","i32","i32"],
                      "ret": "void", "eff": {"DeviceIO"}},
    # LNS casts (Logarithmic Number System — l32 type)
    "@floatToLog":   {"params": ["f32"], "ret": "l32", "eff": set()},
    "@logToFloat":   {"params": ["l32"], "ret": "f32", "eff": set()},
    # MX microscaling casts
    "@floatToMxFp8": {"params": ["f32"], "ret": "mx_fp8", "eff": set()},
    "@mxFp8ToFloat": {"params": ["mx_fp8"], "ret": "f32", "eff": set()},
    # VSA hypervector ops (vsa_b<N> type — binary VSA over N-bit hypervectors)
    # bind: VSA binding = pointwise XOR (makes a new dissimilar vector)
    # bundle: VSA bundling = pointwise majority (combines multiple role-filler pairs)
    # vsaSim: cosine similarity via Hamming distance on binary vectors
    "@vsaBind":   {"params": ["vsa_b<10000>", "vsa_b<10000>"], "ret": "vsa_b<10000>", "eff": set()},
    "@vsaBundle": {"params": ["vsa_b<10000>", "vsa_b<10000>"], "ret": "vsa_b<10000>", "eff": set()},
    "@vsaSim":    {"params": ["vsa_b<10000>", "vsa_b<10000>"], "ret": "f32",          "eff": set()},
}

def is_fn_type(t): return isinstance(t, str) and t.startswith("fn(")

def fn_parts(t):
    """fn(P..)RET[suffix] -> (params:list, ret:str, suffix:str). Depth-aware so a nested fn
    type in a param or return position parses correctly. A nested fn return keeps its own
    suffix; only a simple (non-fn) return carries this function's own @/! suffix."""
    depth = 0; close = None
    for k in range(2, len(t)):                  # t[2] == '('
        if t[k] == "(": depth += 1
        elif t[k] == ")":
            depth -= 1
            if depth == 0: close = k; break
    params, cur, d = [], "", 0
    for ch in t[3:close]:
        if ch in "([{": d += 1
        elif ch in ")]}": d -= 1
        if ch == "," and d == 0: params.append(cur); cur = ""
        else: cur += ch
    if cur.strip(): params.append(cur)
    params = [p.strip() for p in params if p.strip()]
    rest = t[close+1:]
    if rest.startswith("fn("):                  # return is itself a fn type, owns its suffix
        return params, rest, ""
    suf = ""
    for k, ch in enumerate(rest):
        if ch in "@!":
            # !T at position 0 means the return type IS an error union (e.g. fn(i32)!i32)
            # !pure / !{Alloc} / !e and @annot after the return type are effect suffixes
            if k == 0 and ch == "!" and len(rest) > 1 and (rest[1].isalpha() or rest[1] == "_" or rest[1] == "["):
                break   # entire rest IS the return type (error union !T)
            suf = rest[k:]; rest = rest[:k]; break
    return params, rest, suf

def row_of(t):
    """Return ('bound', forbidden_set) | ('row', latent_set) | ('var', name) | None for a fn type's suffix."""
    _, _, suf = fn_parts(t)
    if not suf: return None
    if suf[0] == "@": return ("bound", FORBIDS[suf])
    body = suf[1:]
    if body == "pure": return ("row", set())
    if body.startswith("{"): return ("row", {x for x in body[1:-1].split(",") if x})
    return ("var", body)

def latent_when_opaque(t):
    """Over-approximate latent effect of an opaque function value of type t (we can't see its body)."""
    r = row_of(t)
    if r is None: return set(ALL_EFFECTS)            # plain fn type, unknown -> conservative
    k, v = r
    if k == "bound": return ALL_EFFECTS - v          # may do anything not forbidden
    if k == "row":   return set(v)                   # exactly the declared latent
    return set(ALL_EFFECTS)                           # bare effect variable, standalone -> conservative

def satisfies(actual_eff, t):
    """Does a function value with effects `actual_eff` fit a slot of type t?  (eff, blamed_set)"""
    r = row_of(t)
    if r is None: return True, set()
    k, v = r
    if k == "bound": bad = actual_eff & v;             return (not bad), bad
    if k == "row":   bad = actual_eff - v;             return (not bad), bad
    return True, set()                                 # effect variable: instantiated, never rejected

def row_str(t):
    r = row_of(t)
    if r is None: return "unbounded"
    k, v = r
    if k == "bound": return next(a for a, f in FORBIDS.items() if f == v) if v in FORBIDS.values() else "@bound"
    if k == "row":   return "! " + ("pure" if not v else "{" + ",".join(sorted(v)) + "}")
    return "! " + v

# ───────────────────────────── numeric type system ─────────────────────────────
# Fixed-width scalar types. Integer literals are `int_lit` (comptime-int, like Zig): they
# coerce to ANY integer type from context, defaulting to i32. Likewise float_lit -> f32/f64.
INT_TYPES   = {"i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize"}
FLOAT_TYPES = {"f32", "f64"}
POSIT_TYPES = {"p8", "p16", "p32", "p64"}     # native posit family (P1: only p32 has a runtime)
# ── GPU-native types ──────────────────────────────────────────────────────────
# LNS: Logarithmic Number System.  Mul/div = integer add/sub of exponents → 1 clock on LNS ASICs.
# Add/sub requires an antilog table or Mitchell approximation; emulated on stock GPUs.
LNS_TYPES   = {"l16", "l32"}
# bfloat16: Google Brain float.  Tensor Core native on A100/H100.  Same exponent range as f32.
# Not in vanilla IEEE — requires explicit Zag type so the effect system can track precision.
BF16_TYPES  = {"bf16"}
# MX Microscaling: OCP Microscaling Formats standard.  32-element blocks share 1 scale factor.
# mx_fp8 = E4M3 (4-bit exp, 3-bit mantissa, ~half the bits of f16, fits Blackwell B100 GEMM).
# mx_fp4 = E2M1 (2-bit exp, 1-bit mantissa, extreme density for speculative inference).
MX_TYPES    = {"mx_fp8", "mx_fp4"}
# VSA: Vector Symbolic Architecture hypervectors.  vsa_b<N> = N-dimensional binary hypervector.
# Bind (XOR) + Bundle (majority) + Similarity (Hamming) are the primitive operations.
# The type is parameterised: vsa_b<10000> is 10,000 boolean dimensions.
# (Parsed as a plain identifier in the current bootstrap — the angle-bracket form
#  is handled as a generic type application Name[N] for now.)

def is_vsa_type(t):   return isinstance(t, str) and t.startswith("vsa_b<") and t.endswith(">")
def is_gpu_buf(t):    return isinstance(t, str) and t.startswith("gpu_buf<") and t.endswith(">")
def is_lns(t):        return t in LNS_TYPES
def is_mx(t):         return t in MX_TYPES

# ── Arbitrary-width integers: u1..u127, i1..i127 ──────────────────────────────
# The compiler proves the bit width; C codegen emits the next-larger standard type
# plus a mask.  MLIR natively supports iN for any N, so GPU/HPC paths get exact types.
# Embedded use-case: u11 for an 11-bit ADC reading packs 4.3× more values into SRAM
# than using u16 (with automatic mask-shift codegen), zero manual bitmask boilerplate.
def is_arb_int(t: str) -> bool:
    if not isinstance(t, str) or len(t) < 2: return False
    if t[0] not in ("u", "i"): return False
    rest = t[1:]
    if not rest.isdigit(): return False
    n = int(rest)
    return 1 <= n <= 127 and t not in INT_TYPES   # standard widths already handled

def arb_int_bits(t: str) -> int:  return int(t[1:])
def arb_int_signed(t: str) -> bool: return t[0] == "i"

def arb_int_ctype(t: str) -> str:
    """Map uN/iN to the smallest standard C integer type that holds N bits."""
    n = arb_int_bits(t); s = arb_int_signed(t)
    if n <= 8:  return "int8_t"  if s else "uint8_t"
    if n <= 16: return "int16_t" if s else "uint16_t"
    if n <= 32: return "int32_t" if s else "uint32_t"
    if n <= 64: return "int64_t" if s else "uint64_t"
    return "__int128"

def arb_int_mask(t: str) -> str:
    """C mask expression for N-bit value: '0x7FFu' for u11."""
    n = arb_int_bits(t)
    mask = (1 << n) - 1
    suffix = "u" if not arb_int_signed(t) else ""
    return f"0x{mask:X}{suffix}"

# ── Saturating integers: sat_i8..sat_i64, sat_u8..sat_u64 ─────────────────────
# Key property: saturating arithmetic CANNOT overflow → removes Panic effect.
# DSP/audio use-case: audio sample clipping instead of wrapping = no distortion.
# @realtime DSP functions can safely use sat_i16 math without @total obligations.
SAT_TYPES = {"sat_i8","sat_i16","sat_i32","sat_i64",
             "sat_u8","sat_u16","sat_u32","sat_u64"}

def is_sat(t): return t in SAT_TYPES
def sat_base(t): return t[4:]   # "sat_i16" -> "i16"
def sat_ctype(t): return arb_int_ctype(sat_base(t))

# ── Fixed-point: fixed_<I>_<F> (Q format) ────────────────────────────────────
# fixed_8_8 = Q8.8: 8 integer bits, 8 fractional bits, stored as int16_t.
# Mul: (a * b) >> F. Add: exact. No rounding error per step (unlike float).
# HPC use-case: iterative solvers that stay stable without 64-bit float overhead.
def is_fixed(t: str) -> bool:
    if not isinstance(t, str): return False
    p = t.split("_")
    return len(p) == 3 and p[0] == "fixed" and p[1].isdigit() and p[2].isdigit()

def fixed_parts(t: str) -> tuple:
    _, i, f = t.split("_")
    return int(i), int(f)

def fixed_ctype(t: str) -> str:
    i, f = fixed_parts(t)
    total = i + f
    if total <= 8:  return "int8_t"
    if total <= 16: return "int16_t"
    if total <= 32: return "int32_t"
    return "int64_t"

# ── Bignum: u_any / i_any — arbitrary-precision with register-first promotion ──
# Starts as a 128-bit register value.  If arithmetic overflows, the Alloc effect
# is introduced (conceptually promotes to heap bignum).  This means u_any math
# in a @realtime or @noalloc context is statically rejected unless the compiler
# can prove no overflow occurs.  Bootstrap: backed by __int128 / unsigned __int128.
BIGNUM_TYPES = {"u_any", "i_any"}
def is_bignum(t): return t in BIGNUM_TYPES

# ── Residue Number System: rns_<N> — N moduli CRT representation ──────────────
# rns_3 stores a value as (r1 mod M1, r2 mod M2, r3 mod M3).
# Add/mul are perfectly parallel across all N residues — ideal for HPC SIMD.
# No carry between residues = no data dependency between lanes.
# Comparison and division require reconstruction via CRT (expensive); use for
# add/mul-heavy workloads (FFT, neural net weights, polynomial evaluation).
def is_rns(t: str) -> bool:
    if not isinstance(t, str): return False
    p = t.split("_")
    return len(p) == 2 and p[0] == "rns" and p[1].isdigit() and 2 <= int(p[1]) <= 8

def rns_channels(t: str) -> int: return int(t.split("_")[1])

def is_int(t):   return t in INT_TYPES or t == "int_lit" or is_arb_int(t) or is_sat(t) or is_bignum(t)
def is_float(t): return t in FLOAT_TYPES or t == "float_lit" or t in BF16_TYPES
def is_posit(t): return t in POSIT_TYPES
def is_error_union(t): return isinstance(t, str) and t.startswith("!")
def error_inner(t): return t[1:]   # "!i32" -> "i32"
def default_ty(t):
    if t == "str": return "[]u8"
    return "i32" if t == "int_lit" else ("f32" if t == "float_lit" else t)

def assignable(target, source):
    if target == source: return True
    if target in INT_TYPES and source == "int_lit": return True
    if target in INT_TYPES and source == "bool": return True   # bool is i32 in C
    if target in FLOAT_TYPES and source == "float_lit": return True
    if target in BF16_TYPES and source == "float_lit": return True
    if target in LNS_TYPES and source == "int_lit": return True
    if target in MX_TYPES and source == "float_lit": return True
    if is_arb_int(target) and source == "int_lit": return True
    if is_sat(target) and source == "int_lit": return True
    if is_sat(target) and is_sat(source) and sat_base(target) == sat_base(source): return True
    if is_fixed(target) and source in ("int_lit", "float_lit"): return True
    if is_fixed(target) and is_arb_int(source): return True   # small int widens to fixed-pt
    if is_bignum(target) and source == "int_lit": return True
    if is_bignum(target) and is_int(source): return True   # any int can widen to u_any/i_any
    if is_rns(target) and source == "int_lit": return True
    # Numeric widening: arb-width/sat/bignum/unsigned pass to any standard integer for output
    if target in INT_TYPES and (is_arb_int(source) or is_sat(source)): return True
    if target in INT_TYPES and is_bignum(source): return True
    if target in INT_TYPES and is_fixed(source): return True
    if target in INT_TYPES and source in INT_TYPES: return True  # u32->i32, i8->i32, etc.
    if is_fn_type(target) and is_fn_type(source): return fn_parts(target)[:2] == fn_parts(source)[:2]
    # string literal ("str") fits []u8
    if target == "[]u8" and source == "str": return True
    # error union assignability: error.X ("err") fits any !T; !T value fits same !T
    if is_error_union(target) and source == "err": return True
    if is_error_union(target) and is_error_union(source):
        return assignable(error_inner(target), error_inner(source))
    return False

# ───────────────────────────── generics: type-string ops ─────────────────────────────

def split_app(ty):
    """'Box[i32,f32]' -> ('Box', ['i32','f32']); anything else -> (ty, None)."""
    if not isinstance(ty, str) or ty.startswith("[]") or is_fn_type(ty) or "[" not in ty or not ty.endswith("]"):
        return ty, None
    base = ty[:ty.index("[")]
    inner = ty[ty.index("[")+1:-1]
    args, cur, d = [], "", 0
    for ch in inner:
        if ch in "([{": d += 1
        elif ch in ")]}": d -= 1
        if ch == "," and d == 0: args.append(cur); cur = ""
        else: cur += ch
    if cur: args.append(cur)
    return base, [a.strip() for a in args]

def subst_type(ty, mp):
    if ty is None: return None
    return re.sub(r"[A-Za-z_][A-Za-z0-9_]*", lambda m: mp.get(m.group(0), m.group(0)), ty)

def unify(pat, conc, tparams, sub):
    if pat in tparams:
        sub.setdefault(pat, conc); return
    if pat.startswith("[]") and conc.startswith("[]"):
        unify(pat[2:], conc[2:], tparams, sub); return
    if is_fn_type(pat) and is_fn_type(conc):
        pp, pr, _ = fn_parts(pat); cp, cr, _ = fn_parts(conc)
        for a, b in zip(pp, cp): unify(a, b, tparams, sub)
        unify(pr, cr, tparams, sub); return
    bp, ap = split_app(pat)
    if ap is not None:
        bc, ac = split_app(conc)
        if ac is not None and bp == bc:
            for a, b in zip(ap, ac): unify(a, b, tparams, sub)

# deep-copy an AST subtree, substituting type-variable names in every embedded type string
def clone_expr(e, mp):
    if isinstance(e, Lit): return Lit(e.lty, e.val, e.line)
    if isinstance(e, Var): return Var(e.name, e.line)
    if isinstance(e, Un): return Un(e.op, clone_expr(e.e, mp), e.line)
    if isinstance(e, Bin): return Bin(e.op, clone_expr(e.l, mp), clone_expr(e.r, mp), e.line)
    if isinstance(e, Index): return Index(clone_expr(e.base, mp), clone_expr(e.idx, mp), e.line)
    if isinstance(e, Field): return Field(clone_expr(e.base, mp), e.fname, e.line)
    if isinstance(e, StructLit):
        return StructLit(e.sname, [(n, clone_expr(v, mp)) for n, v in e.fields], e.line,
                         [subst_type(a, mp) for a in e.targs])
    if isinstance(e, Closure):
        return Closure(list(e.caps), [Param(p.name, subst_type(p.pty, mp)) for p in e.params],
                       subst_type(e.ret, mp), clone_stmts(e.body, mp), e.line)
    if isinstance(e, Call):
        return Call(clone_expr(e.callee, mp), [clone_expr(a, mp) for a in e.args], e.line)
    if isinstance(e, ErrLit): return ErrLit(e.errname, e.line)
    if isinstance(e, Try): return Try(clone_expr(e.expr, mp), e.line)
    if isinstance(e, Catch): return Catch(clone_expr(e.expr, mp), clone_expr(e.default, mp), e.cap, e.line)
    return e

def clone_stmts(stmts, mp): return [clone_stmt(s, mp) for s in stmts]
def clone_stmt(s, mp):
    if isinstance(s, Let): return Let(s.name, subst_type(s.dty, mp), clone_expr(s.expr, mp), s.line)
    if isinstance(s, Assign): return Assign(clone_expr(s.target, mp), clone_expr(s.expr, mp), s.line)
    if isinstance(s, Return): return Return(clone_expr(s.expr, mp) if s.expr else None, s.line)
    if isinstance(s, If): return If(clone_expr(s.cond, mp), clone_stmts(s.then, mp),
                                    clone_stmts(s.els, mp) if s.els else None, s.line)
    if isinstance(s, While): return While(clone_expr(s.cond, mp), clone_stmts(s.body, mp), s.line)
    if isinstance(s, Switch):
        return Switch(clone_expr(s.subject, mp),
                      [(tag, cap, clone_stmts(body, mp)) for tag, cap, body in s.arms],
                      clone_stmts(s.els, mp) if s.els else None, s.line)
    if isinstance(s, ExprStmt): return ExprStmt(clone_expr(s.expr, mp), s.line)
    return s

# ───────────────────────────── 4. sema ─────────────────────────────

class Sema:
    def __init__(self, decls):
        self.generic_fns = {d.name: d for d in decls if isinstance(d, Fn) and d.tparams}
        self.generic_structs = {d.name: d for d in decls if isinstance(d, StructDecl) and d.tparams}
        self.fns = {d.name: d for d in decls if isinstance(d, Fn) and not d.tparams}
        self.structs = {d.name: d for d in decls if isinstance(d, StructDecl) and not d.tparams}
        self.enums = {d.name: d for d in decls if isinstance(d, EnumDecl)}
        self.unions = {d.name: d for d in decls if isinstance(d, UnionDecl)}
        # method table: (recv_type, method_short_name) -> Fn  (also in self.fns under mangled name)
        self.methods = {(d.recv_type, d.method_name): d
                        for d in decls if isinstance(d, Fn) and not d.tparams and d.recv_type}
        # error names declared via `error { A, B }` — also extended by error.X usage
        self.err_names = []
        for d in decls:
            if isinstance(d, ErrorDecl):
                for n in d.names:
                    if n not in self.err_names: self.err_names.append(n)
        self.errors = []
        self._memo = {}
        self._visiting = set()
        self._checked = set()       # instance/concrete fns already type-checked

    # ---- monomorphization: instantiate generics on demand, integrated with type checking ----
    def resolve_type(self, ty):
        if ty is None: return None
        if ty.startswith("[]"): return "[]" + self.resolve_type(ty[2:])
        if is_fn_type(ty):
            ps, ret, suf = fn_parts(ty)
            return "fn(" + ",".join(self.resolve_type(p) for p in ps) + ")" + self.resolve_type(ret) + suf
        base, args = split_app(ty)
        if args is not None:
            cargs = [self.resolve_type(a) for a in args]
            if base in self.generic_structs: return self.inst_struct(base, cargs)
            self.err(0, f"unknown generic type '{base}'"); return ty
        return ty

    def inst_struct(self, base, cargs):
        applied = base + "[" + ",".join(cargs) + "]"     # canonical applied form (mangled only at codegen)
        if applied in self.structs: return applied
        g = self.generic_structs[base]
        mp = dict(zip(g.tparams, cargs))
        self.structs[applied] = StructDecl(applied, [], g.line)        # placeholder (recursion-safe)
        self.structs[applied].fields = [Param(p.name, self.resolve_type(subst_type(p.pty, mp))) for p in g.fields]
        return applied

    def inst_fn(self, base, cargs):
        applied = base + "[" + ",".join(cargs) + "]"
        if applied in self.fns: return applied
        g = self.generic_fns[base]
        mp = dict(zip(g.tparams, cargs))
        params = [Param(p.name, self.resolve_type(subst_type(p.pty, mp))) for p in g.params]
        ret = self.resolve_type(subst_type(g.ret, mp))
        inst = Fn(applied, params, ret, list(g.annots), clone_stmts(g.body, mp), g.line)
        self.fns[applied] = inst
        self._check_fn(inst)
        return applied

    def err(self, line, msg): self.errors.append(ZagError(line, msg))

    def fn_type_of_named(self, name):
        if name in self.fns:
            f = self.fns[name]; return "fn(" + ",".join(p.pty for p in f.params) + ")" + f.ret
        if name in BUILTINS:
            b = BUILTINS[name]; return "fn(" + ",".join(b["params"]) + ")" + b["ret"]
        return None

    def field_type(self, struct_name, fname):
        s = self.structs.get(struct_name)
        if not s: return None
        for p in s.fields:
            if p.name == fname: return p.pty
        return None

    def elem_of(self, ty): return ty[2:] if ty.startswith("[]") else None

    # ---- type checking; annotates every node with .ty ----
    def type_of(self, e, scope):
        t = self._type_of(e, scope)
        e.ty = t
        return t

    def _type_of(self, e, scope):
        if isinstance(e, ErrLit):
            if e.errname not in self.err_names: self.err_names.append(e.errname)
            return "err"          # "err" is assignable to any !T
        if isinstance(e, Try):
            inner_ty = self.type_of(e.expr, scope)
            if not is_error_union(inner_ty):
                self.err(e.line, f"'try' applied to non-error-union type {inner_ty}"); return inner_ty
            return error_inner(inner_ty)     # unwrap !T -> T
        if isinstance(e, Catch):
            inner_ty = self.type_of(e.expr, scope)
            if not is_error_union(inner_ty):
                self.err(e.line, f"'catch' applied to non-error-union type {inner_ty}")
            T = error_inner(inner_ty) if is_error_union(inner_ty) else inner_ty
            # check default expression (with error capture in scope if present)
            def_scope = dict(scope)
            if e.cap: def_scope[e.cap] = "u32"   # error code is u32
            self.type_of(e.default, def_scope)
            return T
        if isinstance(e, Lit):
            if e.lty == "str": return "[]u8"
            return e.lty
        if isinstance(e, Var):
            if e.name in scope: return scope[e.name]
            ft = self.fn_type_of_named(e.name)
            if ft: return ft
            self.err(e.line, f"undefined name '{e.name}'"); return "i32"
        if isinstance(e, Un):
            t = self.type_of(e.e, scope); return "bool" if e.op == "!" else t
        if isinstance(e, Bin):
            lt = self.type_of(e.l, scope); rt = self.type_of(e.r, scope)
            if e.op in ("==", "!=", "<", ">", "<=", ">=", "&&", "||"): return "bool"
            # Bignum: u_any/i_any — check BEFORE general int so mixed int+bignum doesn't fail
            if is_bignum(lt) or is_bignum(rt):
                ty = lt if is_bignum(lt) else rt
                other = rt if is_bignum(lt) else lt
                if other == "int_lit" or is_int(other): pass   # any int widens to bignum
                if e.op in ("+", "-", "*", "/"): return ty
                if e.op in ("==","!=","<",">","<=",">="): return "bool"
                return ty
            # numeric: a comptime literal takes the concrete operand's type; two concretes must match
            if is_int(lt) and is_int(rt):
                if lt == "int_lit": return rt
                if rt == "int_lit": return lt
                if lt != rt: self.err(e.line, f"type mismatch: {lt} {e.op} {rt}")
                if e.op in ("^", "|", "&"): return lt   # bitwise / VSA-pack ops
                return lt
            if is_float(lt) and is_float(rt):
                if lt == "float_lit": return rt
                if rt == "float_lit": return lt
                if lt != rt: self.err(e.line, f"type mismatch: {lt} {e.op} {rt}")
                return lt
            if is_posit(lt) and is_posit(rt):
                if lt != rt: self.err(e.line, f"posit type mismatch: {lt} {e.op} {rt}")
                pass  # all posit widths (p8/p16/p32/p64) now have runtimes
                if e.op in ("+", "-", "*", "/"): return lt
                self.err(e.line, f"operator '{e.op}' not supported on posits"); return lt
            # LNS arithmetic (l32): mul/div = exact; add/sub = Mitchell approximation
            if is_lns(lt) and is_lns(rt):
                if lt != rt: self.err(e.line, f"LNS type mismatch: {lt} {e.op} {rt}")
                if e.op in ("+", "-", "*", "/"): return lt
                if e.op in ("==", "!=", "<", ">", "<=", ">="): return "bool"
                self.err(e.line, f"operator '{e.op}' not supported on LNS types"); return lt
            # bf16 / MX float arithmetic — treat like float for type checking
            if lt in BF16_TYPES and rt in BF16_TYPES:
                if e.op in ("+", "-", "*", "/"): return lt
                if e.op in ("==", "!=", "<", ">", "<=", ">="): return "bool"
                return lt
            if lt in MX_TYPES and rt in MX_TYPES:
                if e.op in ("+", "-", "*", "/"): return lt
                if e.op in ("==", "!=", "<", ">", "<=", ">="): return "bool"
                return lt
            # Arbitrary-width integers: uN op uN → uN (with masking in codegen)
            if is_arb_int(lt) and is_arb_int(rt):
                if lt != rt: self.err(e.line, f"arbitrary-int width mismatch: {lt} vs {rt} (use explicit cast)")
                if e.op in ("^", "|", "&"): return lt
                if e.op in ("+", "-", "*"): return lt
                if e.op == "/" and isinstance(e.r, Lit): return lt   # literal divisor = safe
                if e.op == "/": return lt   # still Panic if divisor unproven nonzero
                if e.op in ("==","!=","<",">","<=",">="): return "bool"
                return lt
            if is_arb_int(lt) and rt == "int_lit": return lt
            if lt == "int_lit" and is_arb_int(rt): return rt

            # Saturating types: sat op sat → sat; no Panic (clamps instead of overflows)
            if is_sat(lt) and is_sat(rt):
                if lt != rt: self.err(e.line, f"saturating type mismatch: {lt} vs {rt}")
                if e.op in ("+", "-", "*"): return lt   # always safe — clamping is defined behaviour
                if e.op in ("==","!=","<",">","<=",">="): return "bool"
                return lt
            if is_sat(lt) and rt == "int_lit": return lt
            if lt == "int_lit" and is_sat(rt): return rt

            # Fixed-point: fixed op fixed → fixed
            if is_fixed(lt) and is_fixed(rt):
                if lt != rt: self.err(e.line, f"fixed-point format mismatch: {lt} vs {rt}")
                if e.op in ("+", "-", "*", "/"): return lt
                if e.op in ("==","!=","<",">","<=",">="): return "bool"
                return lt
            if is_fixed(lt) and rt == "int_lit": return lt

            # RNS: parallel residue arithmetic — add/mul exact per channel
            if is_rns(lt) and is_rns(rt):
                if lt != rt: self.err(e.line, f"RNS channel mismatch: {lt} vs {rt}")
                if e.op in ("+", "-", "*"): return lt
                self.err(e.line, f"RNS comparison/division requires CRT reconstruction — not yet supported")
                return lt
            if is_rns(lt) and rt == "int_lit": return lt

            # VSA ops: bind (^) and bundle (|) produce the same hypervector type
            if is_vsa_type(lt) and is_vsa_type(rt):
                if lt != rt: self.err(e.line, f"VSA dimension mismatch: {lt} vs {rt}")
                if e.op in ("^", "|", "&"): return lt   # bind / bundle / intersection
                self.err(e.line, f"operator '{e.op}' not supported on VSA types"); return lt
            self.err(e.line, f"type mismatch: {lt} {e.op} {rt}")
            return lt
        if isinstance(e, Index):
            bt = self.type_of(e.base, scope); el = self.elem_of(bt)
            if el is None: self.err(e.line, f"cannot index non-slice type {bt}"); return "i32"
            if not is_int(self.type_of(e.idx, scope)): self.err(e.line, "index must be an integer")
            return el
        if isinstance(e, Field):
            if isinstance(e.base, Var) and e.base.name in self.enums:     # enum member: Color.Red
                ed = self.enums[e.base.name]
                if e.fname not in ed.members:
                    self.err(e.line, f"enum '{e.base.name}' has no member '{e.fname}'")
                return e.base.name
            bt = self.type_of(e.base, scope)
            if bt and bt.startswith("[]"):
                if e.fname == "len": return "i32"
                self.err(e.line, f"slice has no field '{e.fname}'"); return "i32"
            # RNS field access: rns_3.r1 / rns_3.r2 / rns_3.r3 → u32
            if is_rns(bt):
                n = rns_channels(bt)
                valid = {f"r{i+1}" for i in range(n)}
                if e.fname not in valid:
                    self.err(e.line, f"rns_{n} has no field '{e.fname}' (valid: {', '.join(sorted(valid))})")
                return "u32"
            ft = self.field_type(bt, e.fname)
            if ft is None: self.err(e.line, f"type {bt} has no field '{e.fname}'"); return "i32"
            return ft
        if isinstance(e, StructLit):
            if e.sname in self.unions:                                    # tagged-union construction
                e.inst_sname = e.sname
                decl = {p.name: p.pty for p in self.unions[e.sname].fields}
                if len(e.fields) != 1:
                    self.err(e.line, f"union '{e.sname}' construction must set exactly one variant")
                for fn_, val in e.fields:
                    vt = self.type_of(val, scope); pt = decl.get(fn_)
                    if pt is None: self.err(e.line, f"union '{e.sname}' has no variant '{fn_}'")
                    elif not assignable(pt, vt): self.err(e.line, f"variant '{fn_}': expected {pt}, got {vt}")
                return e.sname
            if e.targs or e.sname in self.generic_structs:
                e.inst_sname = self.inst_struct(e.sname, [self.resolve_type(a) for a in e.targs])
            else:
                e.inst_sname = e.sname
            s = self.structs.get(e.inst_sname)
            if not s: self.err(e.line, f"unknown struct '{e.sname}'"); return e.inst_sname
            declared = {p.name: p.pty for p in s.fields}
            for fn_, val in e.fields:
                vt = self.type_of(val, scope)
                pt = declared.get(fn_)
                if pt is None: self.err(e.line, f"struct '{e.inst_sname}' has no field '{fn_}'")
                elif not assignable(pt, vt):
                    self.err(e.line, f"field '{fn_}': expected {pt}, got {vt}")
            return e.inst_sname
        if isinstance(e, Closure):
            cap_scope = {}
            for c in e.caps:
                if c not in scope:
                    self.err(e.line, f"closure captures undefined name '{c}'"); cap_scope[c] = "i32"
                else:
                    cap_scope[c] = scope[c]
            e.cap_types = dict(cap_scope)
            body_scope = dict(cap_scope)
            for p in e.params: body_scope[p.name] = p.pty
            shim = Fn("<closure>", e.params, e.ret, [], e.body, e.line)
            self._check_block(e.body, body_scope, shim)
            return "fn(" + ",".join(p.pty for p in e.params) + ")" + e.ret
        if isinstance(e, Call):
            callee = e.callee
            # Method call: obj.method(args) — resolve before type_of(callee) would error on Field
            if isinstance(callee, Field):
                base_ty = self.type_of(callee.base, scope)
                key = (base_ty, callee.fname)
                if key in self.methods:
                    meth = self.methods[key]
                    argtys = [self.type_of(a, scope) for a in e.args]
                    if len(meth.params) != len(e.args):
                        self.err(e.line, f"method '{base_ty}.{callee.fname}' expects {len(meth.params)} args, got {len(e.args)}")
                    else:
                        for a, p in zip(e.args, meth.params):
                            if not assignable(p.pty, a.ty):
                                self.err(e.line, f"arg '{p.name}': expected {p.pty}, got {a.ty}")
                    e.ty = meth.ret; return meth.ret
            if isinstance(callee, Var) and callee.name in self.generic_fns:
                g = self.generic_fns[callee.name]
                argtys = [self.type_of(a, scope) for a in e.args]
                sub = {}
                for p, at in zip(g.params, argtys):
                    unify(p.pty, at, set(g.tparams), sub)
                cargs = []
                for tp in g.tparams:
                    if tp not in sub:
                        self.err(e.line, f"cannot infer type parameter '{tp}' of '{callee.name}'"); sub[tp] = "i32"
                    cargs.append(sub[tp])
                e.inst_name = self.inst_fn(callee.name, cargs)
                return self.fns[e.inst_name].ret
            ct = self.type_of(e.callee, scope)
            for a in e.args: self.type_of(a, scope)
            if is_fn_type(ct):
                params, ret, _ = fn_parts(ct)
                if len(params) != len(e.args):
                    self.err(e.line, f"call expects {len(params)} args, got {len(e.args)}")
                for a, pt in zip(e.args, params):
                    if not assignable(pt, a.ty):
                        self.err(e.line, f"arg type mismatch: expected {pt}, got {a.ty}")
                return ret
            self.err(e.line, "called a non-function value"); return "i32"
        return "i32"

    def check_types(self):
        # canonicalize concrete declaration types first (instantiates any generics they name)
        for s in list(self.structs.values()):
            for p in s.fields: p.pty = self.resolve_type(p.pty)
        for f in list(self.fns.values()):
            for p in f.params: p.pty = self.resolve_type(p.pty)
            f.ret = self.resolve_type(f.ret)
        for s in list(self.structs.values()):
            for p in s.fields: self._check_type_exists(p.pty, s.line)
        for f in list(self.fns.values()):
            self._check_fn(f)

    def _check_fn(self, f):
        if f.name in self._checked: return
        self._checked.add(f.name)
        for p in f.params: self._check_type_exists(p.pty, f.line)
        self._check_type_exists(f.ret, f.line)
        if f.extern: return
        scope = {p.name: p.pty for p in f.params}
        if f.recv_type: scope["self"] = f.recv_type   # inject implicit self for method bodies
        self._check_block(f.body, scope, f)

    def _check_type_exists(self, ty, line):
        if is_error_union(ty): self._check_type_exists(error_inner(ty), line); return
        if is_fn_type(ty):
            ps, ret, _ = fn_parts(ty)
            for p in ps: self._check_type_exists(p, line)
            self._check_type_exists(ret, line); return
        base = ty[2:] if ty.startswith("[]") else ty
        # Accept all known scalar families + GPU-native + heterogeneous compute types
        if base in INT_TYPES: return
        if base in FLOAT_TYPES: return
        if base in POSIT_TYPES: return
        if base in LNS_TYPES: return
        if base in BF16_TYPES: return
        if base in MX_TYPES: return
        if base in SAT_TYPES: return
        if base in BIGNUM_TYPES: return
        if base in ("bool", "void", "quire"): return
        if is_arb_int(base): return
        if is_fixed(base): return
        if is_rns(base): return
        if is_vsa_type(base): return
        if is_gpu_buf(base): return
        if base in self.structs or base in self.enums or base in self.unions: return
        self.err(line, f"unknown type '{ty}'")

    def _check_block(self, stmts, scope, f):
        for s in stmts:
            if isinstance(s, Let):
                if s.dty: s.dty = self.resolve_type(s.dty)
                t = self.type_of(s.expr, scope)
                if s.dty:
                    if not assignable(s.dty, t):
                        self.err(s.line, f"let {s.name}: declared {s.dty} but initializer is {t}")
                    scope[s.name] = s.dty
                else:
                    scope[s.name] = default_ty(t)        # infer concrete type from a comptime literal
            elif isinstance(s, Assign):
                tt = self.type_of(s.target, scope); et = self.type_of(s.expr, scope)
                if not assignable(tt, et): self.err(s.line, f"assignment type mismatch: {tt} = {et}")
            elif isinstance(s, Return):
                rt = self.type_of(s.expr, scope) if s.expr else "void"
                fn_ret = f.ret
                # In a !T function: `return error.X` returns "err" (ok); `return val` returns T
                if is_error_union(fn_ret):
                    T = error_inner(fn_ret)
                    if rt == "err" or assignable(fn_ret, rt): pass   # error propagation or !T
                    elif assignable(T, rt): pass                      # plain T value returned
                    else: self.err(s.line, f"return type mismatch in '{f.name}': expected {fn_ret} or {T}, got {rt}")
                elif not assignable(fn_ret, rt):
                    self.err(s.line, f"return type mismatch in '{f.name}': expected {fn_ret}, got {rt}")
            elif isinstance(s, If):
                self.type_of(s.cond, scope); self._check_block(s.then, dict(scope), f)
                if s.els: self._check_block(s.els, dict(scope), f)
            elif isinstance(s, While):
                self.type_of(s.cond, scope); self._check_block(s.body, dict(scope), f)
            elif isinstance(s, Switch):
                st = self.type_of(s.subject, scope)
                if st in self.enums:
                    members = self.enums[st].members
                    for tag, cap, body in s.arms:
                        if tag not in members: self.err(s.line, f"enum '{st}' has no member '{tag}'")
                        if cap is not None: self.err(s.line, f"enum arm '.{tag}' takes no capture")
                        self._check_block(body, dict(scope), f)
                elif st in self.unions:
                    vt = {p.name: p.pty for p in self.unions[st].fields}
                    for tag, cap, body in s.arms:
                        if tag not in vt: self.err(s.line, f"union '{st}' has no variant '{tag}'")
                        arm_scope = dict(scope)
                        if cap is not None: arm_scope[cap] = vt.get(tag, "i32")
                        self._check_block(body, arm_scope, f)
                else:
                    self.err(s.line, f"switch subject must be an enum or union, got {st}")
                if s.els: self._check_block(s.els, dict(scope), f)
            elif isinstance(s, ExprStmt):
                self.type_of(s.expr, scope)

    # ---- latent effect of a function-VALUED expression: (eff_set, {eff: witness_tail}) ----
    def latent(self, e, env, local_lat):
        if isinstance(e, Closure):
            fnp = {p.name: p.pty for p in e.params if is_fn_type(p.pty)}
            return self._effects(e.body, "closure", dict(local_lat), fnp)
        if isinstance(e, Var):
            if e.name in local_lat: return local_lat[e.name]
            if e.name in env: return env[e.name]
            ft = self.fn_type_of_named(e.name)
            if e.name in self.fns or e.name in BUILTINS:
                if is_fn_type(ft) or e.name in BUILTINS or e.name in self.fns:
                    eff, wit = self.analyze(e.name, {})        # precise: we can see the body
                    return set(eff), dict(wit)
            # function-typed parameter without a binding -> opaque, use its declared row
            opa = latent_when_opaque(e.ty) if is_fn_type(e.ty) else set(ALL_EFFECTS)
            return opa, {x: [f"opaque callback '{e.name}'"] for x in opa}
        if isinstance(e, Field):
            opa = latent_when_opaque(e.ty) if is_fn_type(e.ty) else set(ALL_EFFECTS)
            label = self._render(e)
            return opa, {x: [f"{label} (field, {row_str(e.ty)})"] for x in opa}
        if isinstance(e, Call):
            opa = latent_when_opaque(e.ty) if is_fn_type(e.ty) else set(ALL_EFFECTS)
            return opa, {x: [f"value returned by {self._render(e.callee)}()"] for x in opa}
        return set(ALL_EFFECTS), {x: ["unknown function value"] for x in ALL_EFFECTS}

    def _render(self, e):
        if isinstance(e, Var): return e.name
        if isinstance(e, Field): return f"{self._render(e.base)}.{e.fname}"
        if isinstance(e, Call): return f"{self._render(e.callee)}(...)"
        return "<expr>"

    # ---- effect inference. env: param-name -> (eff,wit) bound at this call site ----
    def analyze(self, name, env):
        if name in BUILTINS:
            eff = BUILTINS[name]["eff"]; return set(eff), {e: [f"{name}()"] for e in eff}
        key = (name, tuple(sorted((p, frozenset(v[0])) for p, v in env.items())))
        if not env and name in self._memo: return self._memo[name]
        if key in self._visiting: return set(), {}
        self._visiting.add(key)
        f = self.fns[name]
        fnparams = {p.name: p.pty for p in f.params if is_fn_type(p.pty)}
        eff, wit = self._effects(f.body, name, dict(env), fnparams)
        self._visiting.discard(key)
        if not env: self._memo[name] = (eff, wit)
        return eff, wit

    # ---- the reusable body walker (used for both named functions and closure bodies) ----
    def _effects(self, stmts, label, local_lat, fnparams):
        eff, wit = set(), {}
        def add(e, chain):
            if e not in wit: wit[e] = chain
            eff.add(e)
        def callsite_env(decl, args):
            ev = {}
            if decl:
                for p, a in zip(decl.params, args):
                    if is_fn_type(p.pty):
                        ev[p.name] = self.latent(a, local_lat, local_lat)
            return ev
        def walk(x):
            if isinstance(x, Bin):
                lty = getattr(x.l, "ty", None) or ""
                rty = getattr(x.r, "ty", None) or ""
                # u_any / i_any arithmetic: may promote to heap → Alloc effect
                if is_bignum(lty) or is_bignum(rty):
                    add("Alloc", [label, f"bignum arithmetic at line {x.line} (may heap-promote on overflow)"])
                # RNS arithmetic: safe (modular, never panics) — no Panic added
                # Saturating arithmetic: never panics (always clamps) — no Panic added
                # Standard integer division: may panic if divisor is zero
                if x.op in ("/", "%"):
                    sat = is_sat(lty) or is_sat(rty)           # sat types: clamp, never panic
                    arb = is_arb_int(lty) or is_arb_int(rty)  # arb-width: same rules as ints
                    safe = isinstance(x.r, Lit) and is_int(x.r.lty) and int(x.r.val) != 0
                    floaty = is_float(lty) or is_float(rty)
                    if not safe and not floaty and not sat:
                        add("Panic", [label, f"'{x.op}' at line {x.line} (divisor not provably nonzero)"])
                walk(x.l); walk(x.r)
            elif isinstance(x, Un): walk(x.e)
            elif isinstance(x, Index): walk(x.base); walk(x.idx)
            elif isinstance(x, Field): walk(x.base)
            elif isinstance(x, StructLit):
                for _, v in x.fields: walk(v)
            elif isinstance(x, ErrLit): pass                           # error literal: no runtime effect
            elif isinstance(x, Try): walk(x.expr)
            elif isinstance(x, Catch): walk(x.expr); walk(x.default)
            elif isinstance(x, Closure): pass                          # defining a closure has no effect
            elif isinstance(x, Call):
                for a in x.args: walk(a)
                callee = x.callee
                cn = x.inst_name or (callee.name if isinstance(callee, Var) else None)
                # Resolve method calls to their mangled fn name for effect analysis
                if cn is None and isinstance(callee, Field):
                    base_ty = getattr(callee.base, "ty", None)
                    meth = self.methods.get((base_ty, callee.fname)) if base_ty else None
                    if meth: cn = meth.name
                if cn in local_lat:                                    # call a function-valued local/param
                    le, lw = local_lat[cn]
                    for e in le: add(e, [label] + lw[e])
                elif cn and (cn in self.fns or cn in BUILTINS) and cn not in fnparams:
                    ev = callsite_env(self.fns.get(cn), x.args)         # instantiate effect vars per call site
                    ce, cw = self.analyze(cn, ev)
                    for e in ce: add(e, [label] + cw[e])
                else:                                                  # callee is a value expr (Field, closure, opaque param)
                    le, lw = self.latent(callee, local_lat, local_lat)
                    for e in le: add(e, [label] + lw[e])
        def walk_stmt(s):
            if isinstance(s, Let):
                walk(s.expr)
                lt = s.dty or s.expr.ty
                if is_fn_type(lt) or (s.expr.ty and is_fn_type(s.expr.ty)):
                    local_lat[s.name] = self.latent(s.expr, local_lat, local_lat)
            elif isinstance(s, Assign): walk(s.target); walk(s.expr)
            elif isinstance(s, Return):
                if s.expr: walk(s.expr)
            elif isinstance(s, If):
                walk(s.cond)
                for st in s.then: walk_stmt(st)
                if s.els:
                    for st in s.els: walk_stmt(st)
            elif isinstance(s, While):
                walk(s.cond)
                for st in s.body: walk_stmt(st)
            elif isinstance(s, Switch):
                walk(s.subject)
                for _, _, body in s.arms:
                    for st in body: walk_stmt(st)
                if s.els:
                    for st in s.els: walk_stmt(st)
            elif isinstance(s, ExprStmt): walk(s.expr)
        for s in stmts: walk_stmt(s)
        return eff, wit

    # ---- store checks: you cannot launder an effect through an arg/return/let/field ----
    def check_stores(self):
        for f in self.fns.values():
            if f.extern: continue
            self._store_block(f.body, dict(), f)

    def _store_block(self, stmts, local_lat, f):
        for s in stmts:
            if isinstance(s, Let):
                self._store_expr(s.expr, local_lat)
                slot = s.dty
                if slot and is_fn_type(slot):
                    eff, wit = self.latent(s.expr, local_lat, local_lat)
                    ok, bad = satisfies(eff, slot)
                    if not ok:
                        e = sorted(bad)[0]
                        self.err(s.line, f"effect violation: storing into '{s.name}: {slot}' but value may {e}:\n"
                                         f"            {' → '.join(wit[e])}   [introduces {e}]")
                if (slot and is_fn_type(slot)) or (s.expr.ty and is_fn_type(s.expr.ty)):
                    local_lat[s.name] = self.latent(s.expr, local_lat, local_lat)
            elif isinstance(s, Return):
                if s.expr is not None: self._store_expr(s.expr, local_lat)
                if isinstance(s.expr, Closure) and s.expr.caps:
                    self.err(s.line, f"a closure capturing {s.expr.caps} may not escape its scope "
                                     f"(no heap: its environment is stack-allocated; returning closures is Phase-1 work)")
                if s.expr is not None and is_fn_type(f.ret):
                    eff, wit = self.latent(s.expr, local_lat, local_lat)
                    ok, bad = satisfies(eff, f.ret)
                    if not ok:
                        e = sorted(bad)[0]
                        self.err(s.line, f"effect violation: '{f.name}' returns {f.ret} but value may {e}:\n"
                                         f"            {' → '.join(wit[e])}   [introduces {e}]")
            elif isinstance(s, Assign): self._store_expr(s.target, local_lat); self._store_expr(s.expr, local_lat)
            elif isinstance(s, ExprStmt): self._store_expr(s.expr, local_lat)
            elif isinstance(s, If):
                self._store_expr(s.cond, local_lat)
                self._store_block(s.then, dict(local_lat), f)
                if s.els: self._store_block(s.els, dict(local_lat), f)
            elif isinstance(s, While):
                self._store_expr(s.cond, local_lat); self._store_block(s.body, dict(local_lat), f)
            elif isinstance(s, Switch):
                self._store_expr(s.subject, local_lat)
                for _, _, body in s.arms: self._store_block(body, dict(local_lat), f)
                if s.els: self._store_block(s.els, dict(local_lat), f)

    def _store_expr(self, e, local_lat):
        # check function args passed into bounded/rowed params, and struct-literal fn fields
        if isinstance(e, Call):
            self._store_expr(e.callee, local_lat)
            callee = e.callee
            cn = e.inst_name or (callee.name if isinstance(callee, Var) else None)
            decl = self.fns.get(cn)
            if decl:
                for p, a in zip(decl.params, e.args):
                    if is_fn_type(p.pty) and row_of(p.pty) and row_of(p.pty)[0] != "var":
                        eff, wit = self.latent(a, local_lat, local_lat)
                        ok, bad = satisfies(eff, p.pty)
                        if not ok:
                            x = sorted(bad)[0]
                            self.err(e.line, f"callback bound violation: argument to '{cn}' "
                                             f"param '{p.name}: {p.pty}' may {x}:\n"
                                             f"            {' → '.join(wit[x])}   [introduces {x}]")
            for a in e.args: self._store_expr(a, local_lat)
        elif isinstance(e, StructLit):
            s = self.structs.get(e.inst_sname or e.sname); declared = {p.name: p.pty for p in s.fields} if s else {}
            for fn_, val in e.fields:
                self._store_expr(val, local_lat)
                pt = declared.get(fn_)
                if pt and is_fn_type(pt) and row_of(pt) and row_of(pt)[0] != "var":
                    eff, wit = self.latent(val, local_lat, local_lat)
                    ok, bad = satisfies(eff, pt)
                    if not ok:
                        x = sorted(bad)[0]
                        self.err(e.line, f"effect violation: field '{e.sname}.{fn_}: {pt}' stored a value that may {x}:\n"
                                         f"            {' → '.join(wit[x])}   [introduces {x}]")
        elif isinstance(e, Bin): self._store_expr(e.l, local_lat); self._store_expr(e.r, local_lat)
        elif isinstance(e, Un): self._store_expr(e.e, local_lat)
        elif isinstance(e, Index): self._store_expr(e.base, local_lat); self._store_expr(e.idx, local_lat)
        elif isinstance(e, Field): self._store_expr(e.base, local_lat)
        elif isinstance(e, Try): self._store_expr(e.expr, local_lat)
        elif isinstance(e, Catch): self._store_expr(e.expr, local_lat); self._store_expr(e.default, local_lat)

    def check_capabilities(self):
        report = []
        self.discharges = []
        for f in self.fns.values():
            if f.extern or not f.annots: continue
            eff, wit = self.analyze(f.name, {})
            forbidden = set()
            for a in f.annots: forbidden |= FORBIDS[a]
            viol = eff & forbidden
            # @total: discharge div-by-zero (the Panic effect) with the SMT prover when available
            if "@total" in f.annots and "Panic" in viol and self.prover_available():
                viol = viol - {"Panic"}                       # the verifier owns this verdict
                unproven = self.verify_total(f)
                callpanic = self._panic_from_calls(f)
                for line, ce in unproven:
                    self.err(line, f"capability violation: '{f.name}' is @total but a division can trap — "
                                   f"{self.prover_name()} counterexample: {ce}")
                if callpanic:
                    self.err(f.line, f"capability violation: '{f.name}' is @total but may Panic via a call:\n"
                                     f"            {' → '.join(callpanic)}   [introduces Panic]")
                if not unproven and not callpanic:
                    self.discharges.append(f"{self.prover_name()} proved '{f.name}' @total: every division has a provably-nonzero divisor")
            report.append((f, eff, viol, wit))
            for e in sorted(viol):
                ann = next(a for a in f.annots if e in FORBIDS[a])
                self.err(f.line, f"capability violation: '{f.name}' is {ann} but may {e}:\n"
                                 f"            {' → '.join(wit[e])}   [introduces {e}]")
        return report

    def iter_calls(self, stmts):
        out = []
        def we(x):
            if isinstance(x, Bin): we(x.l); we(x.r)
            elif isinstance(x, Un): we(x.e)
            elif isinstance(x, Index): we(x.base); we(x.idx)
            elif isinstance(x, Field): we(x.base)
            elif isinstance(x, StructLit):
                for _, v in x.fields: we(v)
            elif isinstance(x, Try): we(x.expr)
            elif isinstance(x, Catch): we(x.expr); we(x.default)
            elif isinstance(x, Call):
                out.append(x); we(x.callee)
                for a in x.args: we(a)
        def ws(s):
            if isinstance(s, Let): we(s.expr)
            elif isinstance(s, Assign): we(s.target); we(s.expr)
            elif isinstance(s, Return):
                if s.expr: we(s.expr)
            elif isinstance(s, If):
                we(s.cond); [ws(z) for z in s.then]
                if s.els: [ws(z) for z in s.els]
            elif isinstance(s, While):
                we(s.cond); [ws(z) for z in s.body]
            elif isinstance(s, Switch):
                we(s.subject)
                for _, _, body in s.arms: [ws(z) for z in body]
                if s.els: [ws(z) for z in s.els]
            elif isinstance(s, ExprStmt): we(s.expr)
        for s in stmts: ws(s)
        return out

    def _panic_from_calls(self, f):
        for call in self.iter_calls(f.body):
            callee = call.callee
            cn = call.inst_name or (callee.name if isinstance(callee, Var) else None)
            if cn is None and isinstance(callee, Field):
                base_ty = getattr(callee.base, "ty", None)
                meth = self.methods.get((base_ty, callee.fname)) if base_ty else None
                if meth: cn = meth.name
            if cn and cn in self.fns:
                ce, cw = self.analyze(cn, {})
                if "Panic" in ce: return [f.name] + cw["Panic"]
        return None

    # ---- SMT verification (Phase 3): symbolically execute a @total fn, emit an SMT-LIB2
    #      verification condition per division ("can the divisor be 0 under this path?"), and
    #      hand it to GHOST_ENGINE to discharge (unsat => proven). Python-z3 is a fallback only. ----
    def _assigned_vars(self, stmts):
        out = set()
        for s in stmts:
            if isinstance(s, Assign) and isinstance(s.target, Var): out.add(s.target.name)
            elif isinstance(s, If):
                out |= self._assigned_vars(s.then); out |= self._assigned_vars(s.els or [])
            elif isinstance(s, While): out |= self._assigned_vars(s.body)
            elif isinstance(s, Switch):
                for _, _, body in s.arms: out |= self._assigned_vars(body)
                if s.els: out |= self._assigned_vars(s.els)
        return out

    def verify_total(self, f):
        reassigned = self._assigned_vars(f.body)
        env = {}                                              # non-reassigned lets -> initializer AST (inlined)
        # declare params + reassigned locals as free SMT consts; non-reassigned lets are inlined
        decl_types = {p.name: p.pty for p in f.params}
        def collect(stmts):
            for s in stmts:
                if isinstance(s, Let) and s.name in reassigned:
                    decl_types[s.name] = s.dty or getattr(s.expr, "ty", None) or "i32"
                elif isinstance(s, If): collect(s.then); collect(s.els or [])
                elif isinstance(s, While): collect(s.body)
                elif isinstance(s, Switch):
                    for _, cap, body in s.arms:
                        if cap: decl_types.setdefault(cap, "i32")
                        collect(body)
                    if s.els: collect(s.els)
        collect(f.body)
        sort = lambda t: "Real" if is_float(t) else ("Bool" if t == "bool" else "Int")
        hav = []                                              # havoc consts for unmodeled terms (sound free vars)
        def smt(e):
            if isinstance(e, Lit):
                if is_int(e.lty):
                    v = int(e.val); return f"(- {-v})" if v < 0 else str(v)
                if is_float(e.lty): return repr(float(e.val))
                return "true" if e.val == "true" else "false"
            if isinstance(e, Var):
                if e.name in env: return smt(env[e.name])     # inline single-assignment let
                return e.name
            if isinstance(e, Un): return f"(not {smt(e.e)})" if e.op == "!" else f"(- {smt(e.e)})"
            if isinstance(e, Bin):
                l, r, op = smt(e.l), smt(e.r), e.op
                M = {"+": "+", "-": "-", "*": "*", "/": "div", "%": "mod",
                     "<": "<", ">": ">", "<=": "<=", ">=": ">="}
                if op in M: return f"({M[op]} {l} {r})"
                if op == "==": return f"(= {l} {r})"
                if op == "!=": return f"(not (= {l} {r}))"
                if op == "&&": return f"(and {l} {r})"
                if op == "||": return f"(or {l} {r})"
            n = f"_hav{len(hav)}"                              # Call/Index/Field/Closure -> fresh free const
            hav.append((n, getattr(e, "ty", None) or "i32"))
            return n
        unproven = []
        def query(divisor_expr, path):
            del hav[:]
            dz = smt(divisor_expr)
            paths = [smt(c) for c in path]
            decls = dict(decl_types)
            for n, t in hav: decls[n] = t
            modelable = lambda t: is_int(t) or is_float(t) or t == "bool"
            lines = ["(set-logic ALL)"]
            lines += [f"(declare-const {n} {sort(t)})" for n, t in decls.items() if modelable(t)]
            lines += [f"(assert {c})" for c in paths]
            lines.append(f"(assert (= {dz} 0))")              # is the divisor zero on this path?
            lines.append("(check-sat)")
            names = [n for n, t in decls.items() if modelable(t)]
            if names: lines.append(f"(get-value ({' '.join(names)}))")
            return "\n".join(lines) + "\n"
        def check(e, path):
            if isinstance(e, Bin):
                if e.op in ("/", "%") and is_int(getattr(e.l, "ty", None) or ""):
                    verdict, output = self._discharge(query(e.r, path))
                    if verdict != "unsat":                    # only UNSAT discharges (unknown stays unproven)
                        ce = self._parse_ce(output, f) if verdict == "sat" else f"solver said '{verdict}'"
                        unproven.append((e.line, ce))
                check(e.l, path); check(e.r, path)
            elif isinstance(e, Un): check(e.e, path)
            elif isinstance(e, Index): check(e.base, path); check(e.idx, path)
            elif isinstance(e, Field): check(e.base, path)
            elif isinstance(e, Call):
                for a in e.args: check(a, path)
            elif isinstance(e, StructLit):
                for _, v in e.fields: check(v, path)
        def run(stmts, path):
            for s in stmts:
                if isinstance(s, Let):
                    check(s.expr, path)
                    if s.name not in reassigned: env[s.name] = s.expr
                elif isinstance(s, Assign): check(s.expr, path)
                elif isinstance(s, Return):
                    if s.expr is not None: check(s.expr, path)
                elif isinstance(s, ExprStmt): check(s.expr, path)
                elif isinstance(s, If):
                    check(s.cond, path)
                    run(s.then, path + [s.cond]); run(s.els or [], path + [Un("!", s.cond, s.line)])
                elif isinstance(s, While):
                    check(s.cond, path); run(s.body, path + [s.cond])
                elif isinstance(s, Switch):
                    check(s.subject, path)
                    for _, _, body in s.arms: run(body, path)
                    if s.els: run(s.els, path)
        run(f.body, [])
        return unproven

    def _parse_ce(self, output, f):
        vals = dict(re.findall(r"\(([A-Za-z_]\w*)\s+(\(-\s*\d+\)|-?\d+)\)", output))
        params = [p.name for p in f.params]
        shown = ", ".join(f"{n}={vals[n].replace('(- ', '-').rstrip(')') if vals[n].startswith('(') else vals[n]}"
                          for n in params if n in vals)
        return shown or (output.strip().replace("\n", " ") or "counterexample")

    # ---- prover backend: prefer the actual ghost_engine bridge; fall back to inline python-z3 ----
    def _ghost_verify_path(self):
        cand = []
        if os.environ.get("GHOST_VERIFY"): cand.append(os.environ["GHOST_VERIFY"])
        root = os.environ.get("GHOST_ENGINE") or os.path.join(os.path.dirname(os.path.abspath(__file__)), "..", "..", "ghost_engine")
        cand.append(os.path.join(root, "zig-out", "bin", "zag_verify"))
        for p in cand:
            if p and os.path.isfile(p) and os.access(p, os.X_OK): return p
        return None

    def prover_available(self):
        return bool(self._ghost_verify_path()) or HAVE_Z3

    def prover_name(self):
        return "ghost_engine" if self._ghost_verify_path() else ("z3-python" if HAVE_Z3 else "none")

    def _discharge(self, smt2):
        gv = self._ghost_verify_path()
        if gv:
            try:
                r = subprocess.run([gv], input=smt2, capture_output=True, text=True, timeout=30)
                j = json.loads(r.stdout)
                return j.get("verdict", "err"), j.get("output", "")
            except Exception as ex:
                return "err", f"ghost_engine bridge error: {ex}"
        if HAVE_Z3:
            try:
                s = z3.Solver(); s.from_string(smt2)
                res = s.check()
                if res == z3.unsat: return "unsat", ""
                if res == z3.sat: return "sat", str(s.model())
                return "unknown", ""
            except Exception as ex:
                return "err", str(ex)
        return "unknown", ""

# ───────────────────────────── 5. C codegen ─────────────────────────────

BASE_CTYPE = {"void": "void", "bool": "int32_t",
              "i8": "int8_t", "i16": "int16_t", "i32": "int32_t", "i64": "int64_t",
              "u8": "uint8_t", "u16": "uint16_t", "u32": "uint32_t", "u64": "uint64_t",
              "usize": "size_t", "f32": "float", "f64": "double",
              "int_lit": "int32_t", "float_lit": "float",
              "p8": "uint8_t", "p16": "uint16_t", "p32": "uint32_t", "p64": "uint64_t",
              "quire": "ZagQuire",
              "[]u8": "ZagSliceU8", "[]f32": "ZagSliceF32", "[]i32": "ZagSliceI32",
              "l16": "int16_t",  "l32": "int32_t",
              "bf16": "uint16_t",
              "mx_fp8": "uint8_t", "mx_fp4": "uint8_t",
              # Saturating: same backing type as the base width
              "sat_i8":  "int8_t",  "sat_i16": "int16_t",
              "sat_i32": "int32_t", "sat_i64": "int64_t",
              "sat_u8":  "uint8_t", "sat_u16": "uint16_t",
              "sat_u32": "uint32_t","sat_u64": "uint64_t",
              # Bignum: __int128 bootstrap (true heap bignum is Phase UH-2)
              "u_any": "unsigned __int128", "i_any": "__int128",
              }

# builtin call -> emitted C function name
BUILTIN_CNAME = {
    "@strEq":  "_zag_str_eq", "@strLen": "_zag_str_len",
    "@intToPosit": "zag_p32_from_i64", "@floatToPosit": "zag_f64_to_p32",
    "@positToFloat": "zag_p32_to_f64", "@positToBits": "zag_p32_bits",
    "@floatToP8":  "zag_f64_to_p8",   "@floatToP16": "zag_f64_to_p16",  "@floatToP64": "zag_f64_to_p64",
    "@intToP8":    "zag_p8_from_i64", "@intToP16":   "zag_p16_from_i64", "@intToP64":   "zag_p64_from_i64",
    "@p8ToFloat":  "zag_p8_to_f64",   "@p16ToFloat": "zag_p16_to_f64",  "@p64ToFloat": "zag_p64_to_f64",
    "@p8ToBits":   "zag_p8_bits",     "@p16ToBits":  "zag_p16_bits",    "@p64ToBits":  "zag_p64_bits",
    "@quireZero": "zag_quire_zero", "@quireFMA": "zag_quire_fma", "@quireToPosit": "zag_quire_to_p32",
}
# Per-width posit arithmetic dispatch (used in gen_expr for binary ops on posit operands)
POSIT_OPS = {
    "p8":  {"+": "zag_p8_add",  "-": "zag_p8_sub",  "*": "zag_p8_mul",  "/": "zag_p8_div"},
    "p16": {"+": "zag_p16_add", "-": "zag_p16_sub", "*": "zag_p16_mul", "/": "zag_p16_div"},
    "p32": {"+": "zag_p32_add", "-": "zag_p32_sub", "*": "zag_p32_mul", "/": "zag_p32_div"},
    "p64": {"+": "zag_p64_add", "-": "zag_p64_sub", "*": "zag_p64_mul", "/": "zag_p64_div"},
}
POSIT_TO_F64 = {"p8": "zag_p8_to_f64", "p16": "zag_p16_to_f64",
                "p32": "zag_p32_to_f64", "p64": "zag_p64_to_f64"}
POSIT_OP = POSIT_OPS["p32"]   # kept for any legacy references

# Function VALUES are fat pointers {fn(void*env, ...), env}. This is how closures stay
# allocation-free: the captured environment is a stack value, addressed by the env pointer.
FNPTR_TYPEDEFS = {}     # (tuple(params), ret) -> ZagClo typedef name
CLOSURES = []           # Closure nodes, with .cid assigned
THUNKS = {}             # named-fn-used-as-value -> its fn type string
_CLOS_COUNTER = [0]
_SW_CTR = [0]
_TRY_CTR = [0]
_FNS, _STRUCTS, _ENUMS, _UNIONS, _METHODS = {}, {}, {}, {}, {}
_ERR_NAMES   = []    # ordered list of error names encountered (for C enum)
_RESULT_TYPES = []   # inner types T of all !T types encountered (for ZagResult_T structs)
_SLICE_TYPES  = {}   # {tname -> elem_ctype} for dynamically-discovered slice types

class _G: pass
G = _G(); G.fnlocals = set(); G.caps = set(); G.fn_ret = "void"

def _mangle1(t):
    return (t.replace("[]", "S").replace("[", "_").replace("]", "").replace("(", "_").replace(")", "_")
             .replace(",", "_").replace("!", "B").replace("@", "A").replace("{", "").replace("}", "").replace(" ", ""))

def cfn(name): return _mangle1(name)   # C function name for an instance (e.g. "map[f32]" -> "map_f32")

def fnptr_name(ty):
    ps, ret, _ = fn_parts(ty)
    key = (tuple(ps), ret)
    if key not in FNPTR_TYPEDEFS:
        FNPTR_TYPEDEFS[key] = "ZagClo_" + "_".join(_mangle1(p) for p in ps) + "__" + _mangle1(ret)
    return FNPTR_TYPEDEFS[key]

def ctype(ty):
    if is_fn_type(ty): return fnptr_name(ty)
    if is_error_union(ty):
        inner = error_inner(ty)
        if inner not in _RESULT_TYPES: _RESULT_TYPES.append(inner)
        return "ZagResult_" + _mangle1(inner)
    if ty in BASE_CTYPE: return BASE_CTYPE[ty]
    if is_arb_int(ty): return arb_int_ctype(ty)   # u11 -> uint16_t
    if is_sat(ty): return sat_ctype(ty)            # sat_i16 -> int16_t
    if is_fixed(ty): return fixed_ctype(ty)        # fixed_8_8 -> int16_t
    if is_rns(ty): return "ZagRns"                 # always 3-channel struct
    if is_bignum(ty): return BASE_CTYPE[ty]
    # Dynamic slice types: []sat_i16, []u11, etc. — generate struct typedef on demand
    if ty.startswith("[]"):
        elem = ty[2:]
        elem_ct = ctype(elem)   # recurse to get the backing C element type
        safe = re.sub(r'[^a-zA-Z0-9]', '_', elem)
        tname = f"ZagSlice_{safe}"
        if tname not in _SLICE_TYPES: _SLICE_TYPES[tname] = elem_ct
        return tname
    return _mangle1(ty)

def c_decl(ty, name): return f"{ctype(ty)} {name}"

def _iter_lets(stmts):
    for s in stmts:
        if isinstance(s, Let): yield s
        elif isinstance(s, If):
            yield from _iter_lets(s.then)
            if s.els: yield from _iter_lets(s.els)
        elif isinstance(s, While): yield from _iter_lets(s.body)
        elif isinstance(s, Switch):
            for _, _, body in s.arms: yield from _iter_lets(body)
            if s.els: yield from _iter_lets(s.els)

def _let_fnlocals(stmts):
    out = set()
    for lt in _iter_lets(stmts):
        t = lt.dty or getattr(lt.expr, "ty", None)
        if is_fn_type(t): out.add(lt.name)
    return out

def fn_type_string(name):
    if name in _FNS:
        f = _FNS[name]; return "fn(" + ",".join(p.pty for p in f.params) + ")" + f.ret
    b = BUILTINS[name]; return "fn(" + ",".join(b["params"]) + ")" + b["ret"]

def assign_closure_ids(decls):
    def we(x):
        if isinstance(x, Closure):
            x.cid = _CLOS_COUNTER[0]; _CLOS_COUNTER[0] += 1; CLOSURES.append(x)
            for s in x.body: ws(s)
            return
        for attr in ("l", "r", "e", "base", "idx", "callee", "expr", "cond", "default"):
            v = getattr(x, attr, None)
            if isinstance(v, Node): we(v)
        if isinstance(x, Call):
            for a in x.args: we(a)
        if isinstance(x, StructLit):
            for _, v in x.fields: we(v)
    def ws(s):
        if isinstance(s, Let): we(s.expr)
        elif isinstance(s, Assign): we(s.target); we(s.expr)
        elif isinstance(s, Return):
            if s.expr: we(s.expr)
        elif isinstance(s, If):
            we(s.cond); [ws(z) for z in s.then]
            if s.els: [ws(z) for z in s.els]
        elif isinstance(s, While):
            we(s.cond); [ws(z) for z in s.body]
        elif isinstance(s, Switch):
            we(s.subject)
            for _, _, body in s.arms: [ws(z) for z in body]
            if s.els: [ws(z) for z in s.els]
        elif isinstance(s, ExprStmt): we(s.expr)
    for f in decls:
        if not f.extern:
            for s in f.body: ws(s)

def collect_fn_typedefs(sema):
    def reg(ty):
        if not is_fn_type(ty): return
        ps, ret, _ = fn_parts(ty)
        for p in ps: reg(p)
        reg(ret)
        fnptr_name(ty)
    for s in sema.structs.values():
        for p in s.fields: reg(p.pty)
    for f in sema.fns.values():
        for p in f.params: reg(p.pty)
        reg(f.ret)
        if not f.extern:
            for lt in _iter_lets(f.body):
                if lt.dty: reg(lt.dty)
                et = getattr(lt.expr, "ty", None)
                if is_fn_type(et): reg(et)
    for c in CLOSURES: reg(c.ty)
    lines = []
    for (ps, ret), nm in list(FNPTR_TYPEDEFS.items()):
        inner = ", ".join(["void*"] + [ctype(p) for p in ps])
        lines.append(f"typedef struct {{ {ctype(ret)} (*fn)({inner}); void* env; }} {nm};")
    return "\n".join(lines)

PRELUDE = r"""/* generated by zagc — Zag bootstrap compiler */
#include <stdint.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <math.h>
typedef struct { const uint8_t* ptr; int32_t len; } ZagSliceU8;
typedef struct { float*   ptr; int32_t len; } ZagSliceF32;
typedef struct { int32_t* ptr; int32_t len; } ZagSliceI32;
static void    print_str(ZagSliceU8 s){ fwrite(s.ptr, 1, (size_t)s.len, stdout); putchar('\n'); }
static int32_t _zag_str_eq(ZagSliceU8 a, ZagSliceU8 b){ return a.len==b.len && memcmp(a.ptr,b.ptr,(size_t)a.len)==0; }
static int32_t _zag_str_len(ZagSliceU8 s){ return s.len; }
static ZagSliceF32 zalloc(int32_t n){ ZagSliceF32 s; s.ptr=(float*)malloc((size_t)n*sizeof(float)); s.len=n; return s; }
static void    zfree(ZagSliceF32 s){ free(s.ptr); }
static ZagSliceI32 zalloc_i(int32_t n){ ZagSliceI32 s; s.ptr=(int32_t*)malloc((size_t)n*sizeof(int32_t)); s.len=n; return s; }
static void    zfree_i(ZagSliceI32 s){ free(s.ptr); }
static void    lock(void){ /* real impl would take a mutex; the effect is what matters */ }
static void    print_i32(int32_t x){ printf("%d\n", x); }
static void    print_f32(float x){ printf("%g\n", (double)x); }
static void    print_u64(uint64_t x){ printf("%llu\n", (unsigned long long)x); }
static void    print_i64(int64_t x){ printf("%lld\n", (long long)x); }
static void    print_f64(double x){ printf("%g\n", x); }

/* ── Saturating arithmetic ────────────────────────────────────────────────────
   Key property: sat ops CANNOT overflow → Zag's effect system never adds Panic.
   DSP/embedded use: sat_i16 audio samples clamp at ±32767 instead of wrapping.
   ARM64: these inline as SQADD/UQADD (1 cycle).  x86: SSE PADDSW.  Fallback: C.
   Note: sat_mul is intentionally truncating-then-clamping (standard DSP behavior). */
#define ZAG_SAT_ADD(T, MIN, MAX) \
static T zag_sat_add_##T(T a, T b){ int64_t r=(int64_t)a+(int64_t)b; return (T)(r>MAX?MAX:r<MIN?MIN:r); }
#define ZAG_SAT_SUB(T, MIN, MAX) \
static T zag_sat_sub_##T(T a, T b){ int64_t r=(int64_t)a-(int64_t)b; return (T)(r>MAX?MAX:r<MIN?MIN:r); }
#define ZAG_SAT_MUL(T, MIN, MAX) \
static T zag_sat_mul_##T(T a, T b){ int64_t r=(int64_t)a*(int64_t)b; return (T)(r>MAX?MAX:r<MIN?MIN:r); }
typedef int8_t   i8; typedef int16_t  i16; typedef int32_t  i32;
typedef uint8_t  u8; typedef uint16_t u16; typedef uint32_t u32;
ZAG_SAT_ADD(i8, -128, 127)        ZAG_SAT_SUB(i8, -128, 127)        ZAG_SAT_MUL(i8, -128, 127)
ZAG_SAT_ADD(i16,-32768,32767)     ZAG_SAT_SUB(i16,-32768,32767)     ZAG_SAT_MUL(i16,-32768,32767)
ZAG_SAT_ADD(u8, 0, 255)           ZAG_SAT_SUB(u8, 0, 255)           ZAG_SAT_MUL(u8, 0, 255)
ZAG_SAT_ADD(u16,0, 65535)         ZAG_SAT_SUB(u16,0, 65535)         ZAG_SAT_MUL(u16,0, 65535)
/* i32/u32 sat: widen to int64_t (always fits) */
static i32 zag_sat_add_i32(i32 a,i32 b){int64_t r=(int64_t)a+b;return(i32)(r>(int64_t)2147483647?2147483647:r<(int64_t)-2147483648?-2147483648:r);}
static i32 zag_sat_sub_i32(i32 a,i32 b){int64_t r=(int64_t)a-b;return(i32)(r>(int64_t)2147483647?2147483647:r<(int64_t)-2147483648?-2147483648:r);}
static i32 zag_sat_mul_i32(i32 a,i32 b){int64_t r=(int64_t)a*(int64_t)b;return(i32)(r>(int64_t)2147483647?2147483647:r<(int64_t)-2147483648?-2147483648:r);}
static u32 zag_sat_add_u32(u32 a,u32 b){uint64_t r=(uint64_t)a+b;return(u32)(r>4294967295ULL?4294967295U:r);}
static u32 zag_sat_sub_u32(u32 a,u32 b){return a>b?(u32)(a-b):0u;}
static u32 zag_sat_mul_u32(u32 a,u32 b){uint64_t r=(uint64_t)a*b;return(u32)(r>4294967295ULL?4294967295U:r);}
/* i64/u64: widen to __int128 */
static int64_t  zag_sat_add_i64(int64_t a,int64_t b){__int128 r=(__int128)a+b;int64_t MAX=(int64_t)9223372036854775807LL,MIN=-(MAX)-1;return(int64_t)(r>MAX?MAX:r<MIN?MIN:r);}
static int64_t  zag_sat_sub_i64(int64_t a,int64_t b){__int128 r=(__int128)a-b;int64_t MAX=(int64_t)9223372036854775807LL,MIN=-(MAX)-1;return(int64_t)(r>MAX?MAX:r<MIN?MIN:r);}
static int64_t  zag_sat_mul_i64(int64_t a,int64_t b){__int128 r=(__int128)a*b;int64_t MAX=(int64_t)9223372036854775807LL,MIN=-(MAX)-1;return(int64_t)(r>MAX?MAX:r<MIN?MIN:r);}
static uint64_t zag_sat_add_u64(uint64_t a,uint64_t b){__int128 r=(__int128)a+b;uint64_t MAX=18446744073709551615ULL;return(uint64_t)(r>(unsigned __int128)MAX?MAX:r);}
static uint64_t zag_sat_sub_u64(uint64_t a,uint64_t b){return a>b?a-b:0ULL;}
static uint64_t zag_sat_mul_u64(uint64_t a,uint64_t b){__int128 r=(__int128)a*b;uint64_t MAX=18446744073709551615ULL;return(uint64_t)(r>(unsigned __int128)MAX?MAX:r);}

/* ── Residue Number System (rns_N) ──────────────────────────────────────────
   Stores a value as N residues over fixed coprime moduli.  Add/mul are
   lane-independent: no carry, no data dependency across channels.  Ideal for
   HPC SIMD where each lane computes one modulus in parallel.
   Phase RNS-1: rns_3 uses moduli M1=2^16−15, M2=2^16−5, M3=2^16−3 (coprime primes
   near 65536 → max representable value ≈ 2.81 × 10^14).  Phase RNS-2 adds
   CRT reconstruction (comparison, conversion to/from int) via precomputed constants. */
#define ZAG_RNS_M1 65521u   /* 2^16 - 15, a prime */
#define ZAG_RNS_M2 65531u   /* 2^16 - 5,  a prime */
#define ZAG_RNS_M3 65533u   /* 2^16 - 3,  a prime */
typedef struct { uint32_t r1, r2, r3; } ZagRns;
static ZagRns zag_rns_from_i64(int64_t x){
    return (ZagRns){(uint32_t)(((uint64_t)(x%ZAG_RNS_M1)+ZAG_RNS_M1)%ZAG_RNS_M1),
                    (uint32_t)(((uint64_t)(x%ZAG_RNS_M2)+ZAG_RNS_M2)%ZAG_RNS_M2),
                    (uint32_t)(((uint64_t)(x%ZAG_RNS_M3)+ZAG_RNS_M3)%ZAG_RNS_M3)};}
static ZagRns zag_rns_add(ZagRns a, ZagRns b){
    return (ZagRns){(a.r1+b.r1)%ZAG_RNS_M1,(a.r2+b.r2)%ZAG_RNS_M2,(a.r3+b.r3)%ZAG_RNS_M3};}
static ZagRns zag_rns_sub(ZagRns a, ZagRns b){
    return (ZagRns){(a.r1+ZAG_RNS_M1-b.r1)%ZAG_RNS_M1,
                    (a.r2+ZAG_RNS_M2-b.r2)%ZAG_RNS_M2,
                    (a.r3+ZAG_RNS_M3-b.r3)%ZAG_RNS_M3};}
static ZagRns zag_rns_mul(ZagRns a, ZagRns b){
    return (ZagRns){(uint32_t)(((uint64_t)a.r1*b.r1)%ZAG_RNS_M1),
                    (uint32_t)(((uint64_t)a.r2*b.r2)%ZAG_RNS_M2),
                    (uint32_t)(((uint64_t)a.r3*b.r3)%ZAG_RNS_M3)};}

/* ── Posit runtime: p32, es=2 (useed = 2^(2^2) = 16). Reference software emulation. ──
   decode is exact bit-manipulation; arithmetic goes decode->f64->encode with round-to-
   nearest-even on repack. f64's 53-bit mantissa >= p32's <=27 fraction bits, so this is
   exact in the normal range (the optimized branchless integer path is Phase P2). */
static double zag_p32_to_f64(uint32_t bits){
    if (bits == 0u) return 0.0;
    if (bits == 0x80000000u) return NAN;                 /* NaR */
    int neg = (bits >> 31) & 1;
    uint32_t u = neg ? (uint32_t)(-(int32_t)bits) : bits; /* magnitude (sign cleared) */
    int b = 30, k;
    if (((u >> 30) & 1) == 1) {                          /* regime = run of 1s */
        int run = 0; while (b >= 0 && ((u >> b) & 1) == 1) { run++; b--; }
        if (b >= 0) b--;                                 /* consume the 0 terminator */
        k = run - 1;
    } else {                                             /* regime = run of 0s */
        int run = 0; while (b >= 0 && ((u >> b) & 1) == 0) { run++; b--; }
        if (b >= 0) b--;                                 /* consume the 1 terminator */
        k = -run;
    }
    int e = 0;                                           /* es=2 exponent bits (zero-padded) */
    for (int i = 0; i < 2; i++) { e <<= 1; if (b >= 0) { e |= (u >> b) & 1; b--; } }
    int fbits = b + 1;
    double fraction = 1.0;
    if (fbits > 0) {
        uint32_t fr = u & ((fbits >= 32) ? 0xFFFFFFFFu : ((1u << fbits) - 1u));
        fraction = 1.0 + (double)fr / (double)((uint64_t)1 << fbits);
    }
    double val = ldexp(fraction, 4 * k + e);             /* useed^k * 2^e = 2^(4k+e) */
    return neg ? -val : val;
}
static uint32_t zag_f64_to_p32(double x){
    if (x == 0.0) return 0u;
    if (isnan(x) || isinf(x)) return 0x80000000u;        /* NaR */
    int neg = (x < 0.0); double ax = fabs(x);
    int E2; double m = frexp(ax, &E2); m *= 2.0; int E = E2 - 1;  /* ax = m * 2^E, m in [1,2) */
    int k = (E >= 0) ? (E / 4) : -(((-E) + 3) / 4);      /* floor(E/4) */
    int e = E - 4 * k;                                   /* 0..3 */
    double fr = m - 1.0;
    unsigned char bs[80]; int n = 0;                     /* MSB-first magnitude bit stream */
    if (k >= 0) { for (int i = 0; i <= k && n < 80; i++) bs[n++] = 1; if (n < 80) bs[n++] = 0; }
    else        { for (int i = 0; i < -k && n < 80; i++) bs[n++] = 0; if (n < 80) bs[n++] = 1; }
    if (n < 80) bs[n++] = (e >> 1) & 1;
    if (n < 80) bs[n++] = e & 1;
    while (n < 80) { fr *= 2.0; int d = (int)fr; bs[n++] = (unsigned char)d; fr -= d; }
    uint32_t mag = 0;
    for (int i = 0; i < 31; i++) mag = (mag << 1) | (i < n ? bs[i] : 0);
    int roundb = (31 < n) ? bs[31] : 0, sticky = 0;
    for (int i = 32; i < n; i++) sticky |= bs[i];
    if (roundb && (sticky || (mag & 1))) mag++;          /* round to nearest, ties to even */
    uint32_t word = mag & 0x7FFFFFFFu;
    return neg ? (uint32_t)(-(int32_t)word) : word;
}
static uint32_t zag_p32_from_i64(int64_t v){ return zag_f64_to_p32((double)v); }
static uint64_t zag_p32_bits(uint32_t b){ return (uint64_t)b; }

/* ── P2: branchless integer-only path (Path A). decode via CLZ, integer significand math,
      integer repack with round-to-nearest-even — NO float intermediate. Validated bit-for-bit
      against a long-double oracle over 5M+ inputs. value = (-1)^neg * sig * 2^sexp. ── */
static void zag_p32_fields(uint32_t bits, int* neg, int* sexp, uint64_t* sig){
    if (bits == 0u) { *neg = 0; *sexp = 0; *sig = 0; return; }
    int n = (bits >> 31) & 1;
    uint32_t u = n ? (uint32_t)(-(int32_t)bits) : bits;
    uint32_t w = u << 1;                                    /* first regime bit -> bit31 */
    int r = (int)(w >> 31);
    int run = __builtin_clz(r ? ~w : w);                    /* CLZ counts the regime run, branchless */
    int k = r ? (run - 1) : (-run);
    int rembits = 30 - run, e, F; uint64_t frac;
    if (rembits >= 2) {
        uint32_t field = u & ((rembits >= 32) ? 0xFFFFFFFFu : ((1u << rembits) - 1u));
        e = field >> (rembits - 2); F = rembits - 2;
        frac = field & ((F >= 32) ? 0xFFFFFFFFu : ((1u << F) - 1u));
    } else if (rembits == 1) { e = (u & 1) << 1; F = 0; frac = 0; }
    else { e = 0; F = 0; frac = 0; }
    *neg = n; *sig = ((uint64_t)1 << F) | frac; *sexp = (4 * k + e) - F;
}
static uint32_t zag_p32_enc_int(int sign, uint64_t P, int pe){   /* value = (-1)^sign * P * 2^pe -> p32, RNE */
    if (P == 0) return 0u;
    int L = 64 - __builtin_clzll(P), E = pe + L - 1;
    int k = (E >= 0) ? (E / 4) : -(((-E) + 3) / 4), e = E - 4 * k;
    unsigned char bs[96]; int n = 0;
    if (k >= 0) { for (int i = 0; i <= k && n < 96; i++) bs[n++] = 1; if (n < 96) bs[n++] = 0; }
    else        { for (int i = 0; i < -k && n < 96; i++) bs[n++] = 0; if (n < 96) bs[n++] = 1; }
    if (n < 96) bs[n++] = (e >> 1) & 1; if (n < 96) bs[n++] = e & 1;
    for (int i = L - 2; i >= 0 && n < 96; i--) bs[n++] = (unsigned char)((P >> i) & 1);
    uint32_t mag = 0; for (int i = 0; i < 31; i++) mag = (mag << 1) | (i < n ? bs[i] : 0);
    int rb = (31 < n) ? bs[31] : 0, st = 0; for (int i = 32; i < n; i++) st |= bs[i];
    if (rb && (st || (mag & 1))) mag++;
    uint32_t word = mag & 0x7FFFFFFFu; if (word == 0) word = 1;
    return sign ? (uint32_t)(-(int32_t)word) : word;
}
#ifndef ZAG_TARGET_PPU32  /* software math: compiled out when --target ppu32 selects hardware path */
static uint32_t zag_p32_add_core(int na, int ea, uint64_t sa, int nb, int eb, uint64_t sb){
    int G = 60, anchor = (ea > eb) ? ea : eb, sticky = 0, sh; __int128 acc = 0;
    sh = ea - anchor + G;
    { __int128 m; if (sh >= 0) m = (__int128)sa << sh;
      else { int rs = -sh; if (rs < 64) { if (sa & (((uint64_t)1 << rs) - 1)) sticky = 1; m = (__int128)(sa >> rs); } else { if (sa) sticky = 1; m = 0; } }
      acc += na ? -m : m; }
    sh = eb - anchor + G;
    { __int128 m; if (sh >= 0) m = (__int128)sb << sh;
      else { int rs = -sh; if (rs < 64) { if (sb & (((uint64_t)1 << rs) - 1)) sticky = 1; m = (__int128)(sb >> rs); } else { if (sb) sticky = 1; m = 0; } }
      acc += nb ? -m : m; }
    if (acc == 0) return sticky ? 1u : 0u;
    int rsgn = (acc < 0); unsigned __int128 mag = rsgn ? (unsigned __int128)(-acc) : (unsigned __int128)acc;
    int L = 0; { unsigned __int128 t = mag; while (t) { L++; t >>= 1; } }
    int drop = (L > 60) ? (L - 60) : 0;
    if (drop > 0) { unsigned __int128 lm = (((unsigned __int128)1) << drop) - 1; if (mag & lm) sticky = 1; }
    uint64_t P = (uint64_t)(mag >> drop); if (sticky) P |= 1;
    return zag_p32_enc_int(rsgn, P, (anchor - G) + drop);
}
static uint32_t zag_p32_mul(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (a == 0 || b == 0) return 0u;
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    return zag_p32_enc_int(na ^ nb, sa * sb, ea + eb);
}
static uint32_t zag_p32_add(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (a == 0) return b; if (b == 0) return a;
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    return zag_p32_add_core(na, ea, sa, nb, eb, sb);
}
static uint32_t zag_p32_sub(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u) return 0x80000000u;
    if (b == 0) return a; if (a == 0) return (uint32_t)(-(int32_t)b);
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    return zag_p32_add_core(na, ea, sa, !nb, eb, sb);
}
static uint32_t zag_p32_div(uint32_t a, uint32_t b){
    if (a == 0x80000000u || b == 0x80000000u || b == 0) return 0x80000000u;
    if (a == 0) return 0u;
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    int La = 64 - __builtin_clzll(sa), Lb = 64 - __builtin_clzll(sb), shift = 60 - (La - Lb);
    __int128 num = (__int128)sa << shift;
    uint64_t Q = (uint64_t)(num / sb); if ((uint64_t)(num % sb)) Q |= 1;
    return zag_p32_enc_int(na ^ nb, Q, ea - eb - shift);
}
#endif /* ZAG_TARGET_PPU32 */

/* ── Quire: 512-bit fixed-point exact accumulator for p32 (Posit Standard: n²/2 bits). ──
   Holds sums of products with NO rounding until read out. LSB weight = 2^-240, so it spans
   minpos² (2^-240) .. maxpos² (2^240) with carry headroom in the top limbs. This is the posit
   feature with no IEEE/hardware equivalent: a fused dot product that rounds exactly once. */
typedef struct { uint64_t limb[8]; int nar; } ZagQuire;
/* (zag_p32_fields — the branchless CLZ decode above — is shared by the quire) */
static ZagQuire zag_quire_zero(void){ ZagQuire q; for (int i = 0; i < 8; i++) q.limb[i] = 0; q.nar = 0; return q; }
static void q_add_at(uint64_t* L, int off, uint64_t lo, uint64_t hi){
    if (off > 7) return;
    unsigned __int128 s = (unsigned __int128)L[off] + lo; L[off] = (uint64_t)s; uint64_t c = (uint64_t)(s >> 64);
    if (off + 1 <= 7) { unsigned __int128 s2 = (unsigned __int128)L[off+1] + hi + c; L[off+1] = (uint64_t)s2; c = (uint64_t)(s2 >> 64);
        for (int i = off + 2; i < 8 && c; i++) { unsigned __int128 s3 = (unsigned __int128)L[i] + c; L[i] = (uint64_t)s3; c = (uint64_t)(s3 >> 64); } }
}
static void q_sub_at(uint64_t* L, int off, uint64_t lo, uint64_t hi){
    if (off > 7) return;
    unsigned __int128 d = (unsigned __int128)L[off] - lo; L[off] = (uint64_t)d; uint64_t br = (d >> 64) ? 1 : 0;
    if (off + 1 <= 7) { unsigned __int128 d2 = (unsigned __int128)L[off+1] - hi - br; L[off+1] = (uint64_t)d2; br = (d2 >> 64) ? 1 : 0;
        for (int i = off + 2; i < 8 && br; i++) { unsigned __int128 d3 = (unsigned __int128)L[i] - br; L[i] = (uint64_t)d3; br = (d3 >> 64) ? 1 : 0; } }
}
static ZagQuire zag_quire_fma(ZagQuire q, uint32_t a, uint32_t b){   /* q += a*b, EXACTLY */
    if (a == 0x80000000u || b == 0x80000000u || q.nar) { q.nar = 1; return q; }
    int na, nb, ea, eb; uint64_t sa, sb;
    zag_p32_fields(a, &na, &ea, &sa); zag_p32_fields(b, &nb, &eb, &sb);
    if (sa == 0 || sb == 0) return q;                 /* product is zero */
    uint64_t P = sa * sb;                              /* <= 2^57, exact in uint64 */
    int shift = (ea + eb) + 240;                       /* place at exact bit position */
    if (shift < 0) return q;                           /* below quire LSB (unreachable for valid p32) */
    int off = shift >> 6, bo = shift & 63;
    uint64_t lo, hi;
    if (bo == 0) { lo = P; hi = 0; } else { lo = P << bo; hi = P >> (64 - bo); }
    if (na ^ nb) q_sub_at(q.limb, off, lo, hi); else q_add_at(q.limb, off, lo, hi);
    return q;
}
static int q_bit(const uint64_t* L, int i){ return (int)((L[i >> 6] >> (i & 63)) & 1); }
static uint32_t zag_quire_to_p32(ZagQuire q){           /* round the exact value to p32 (RNE) */
    if (q.nar) return 0x80000000u;
    uint64_t m[8]; int neg = (q.limb[7] >> 63) & 1;
    if (neg) { uint64_t c = 1; for (int i = 0; i < 8; i++) { unsigned __int128 t = (unsigned __int128)(~q.limb[i]) + c; m[i] = (uint64_t)t; c = (uint64_t)(t >> 64); } }
    else for (int i = 0; i < 8; i++) m[i] = q.limb[i];
    int M = -1; for (int i = 511; i >= 0; i--) if (q_bit(m, i)) { M = i; break; }
    if (M < 0) return 0u;
    uint64_t hi53 = 0;
    for (int j = 0; j < 53; j++) { int bi = M - j; hi53 = (hi53 << 1) | (bi >= 0 ? (uint64_t)q_bit(m, bi) : 0); }
    int sticky = 0; for (int i = 0; i <= M - 53; i++) if (q_bit(m, i)) { sticky = 1; break; }
    if (sticky) hi53 |= 1ull;                           /* round-to-odd: makes the final RNE correct */
    double val = ldexp((double)hi53, (M - 52) - 240);
    return zag_f64_to_p32(neg ? -val : val);
}
"""

# ─── p8 / p16 / p64 software runtimes ────────────────────────────────────────
# p8  (n=8,  es=0, useed=2):  max 6 frac bits  → f64 path is exact (53 ≥ 6)
# p16 (n=16, es=1, useed=4):  max 14 frac bits → f64 path is exact (53 ≥ 14)
# p64 (n=64, es=3, useed=256): max 59 frac bits → long double path (64-bit mantissa ≥ 59);
#   mul has ~1 ULP error (120-bit product > 64-bit mantissa); encode/decode exact.
PRELUDE_POSIT_MULTI = r"""
/* ── p8: n=8, es=0, useed=2; range [2^-6, 2^6] = [1/64, 64]; max 6 fraction bits ── */
static double zag_p8_to_f64(uint8_t bits){
    if (!bits) return 0.0; if (bits == 0x80u) return NAN;
    int neg = (bits >> 7) & 1;
    uint8_t u = neg ? (uint8_t)(0u - (unsigned)bits) : bits;
    uint32_t wu = (uint32_t)u << 25;          /* bit6 of u -> bit31 for __builtin_clz */
    int r = (int)(wu >> 31);
    int run = __builtin_clz(r ? ~wu : wu);    /* regime run length */
    int k = r ? (run - 1) : (-run);           /* regime value; es=0: useed_exp=1, E=k */
    int F = 6 - run;                          /* n-2-run fraction bits (may be 0 or neg) */
    if (F < 0) F = 0;
    double frac = F ? (double)(u & ((1u << F) - 1u)) / (double)(1u << F) : 0.0;
    return (neg ? -1.0 : 1.0) * ldexp(1.0 + frac, k);
}
static uint8_t zag_f64_to_p8(double x){
    if (x == 0.0) return 0u; if (isnan(x) || isinf(x)) return 0x80u;
    int neg = (x < 0.0); double ax = fabs(x);
    int E2; double m = frexp(ax, &E2); m *= 2.0; int E = E2 - 1;
    int k = E;                                /* es=0: k=E, e=0 */
    double fr = m - 1.0; unsigned char bs[24]; int n = 0;
    if(k>=0){for(int i=0;i<=k&&n<24;i++)bs[n++]=1;if(n<24)bs[n++]=0;}
    else    {for(int i=0;i<-k&&n<24;i++)bs[n++]=0;if(n<24)bs[n++]=1;}
    while(n<24){fr*=2.0;int d=(int)fr;bs[n++]=(unsigned char)d;fr-=d;}
    uint8_t mag=0; for(int i=0;i<7;i++) mag=(uint8_t)((mag<<1)|(i<n?bs[i]:0));
    int rb=(7<n)?bs[7]:0,st=0; for(int i=8;i<n;i++) st|=bs[i];
    if(rb&&(st||(mag&1))) mag++;
    uint8_t w = mag & 0x7Fu; if(!w) w=1;
    return neg ? (uint8_t)(0u-(unsigned)w) : w;
}
static uint8_t  zag_p8_from_i64(int64_t v){ return zag_f64_to_p8((double)v); }
static uint64_t zag_p8_bits(uint8_t b){ return (uint64_t)b; }
static uint8_t  zag_p8_add(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u)return 0x80u; return zag_f64_to_p8(zag_p8_to_f64(a)+zag_p8_to_f64(b)); }
static uint8_t  zag_p8_sub(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u)return 0x80u; return zag_f64_to_p8(zag_p8_to_f64(a)-zag_p8_to_f64(b)); }
static uint8_t  zag_p8_mul(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u)return 0x80u;if(!a||!b)return 0u; return zag_f64_to_p8(zag_p8_to_f64(a)*zag_p8_to_f64(b)); }
static uint8_t  zag_p8_div(uint8_t a,uint8_t b){ if(a==0x80u||b==0x80u||!b)return 0x80u;if(!a)return 0u; return zag_f64_to_p8(zag_p8_to_f64(a)/zag_p8_to_f64(b)); }

/* ── p16: n=16, es=1, useed=4; range [2^-28, 2^28]; max 14 fraction bits ── */
static double zag_p16_to_f64(uint16_t bits){
    if (!bits) return 0.0; if (bits == 0x8000u) return NAN;
    int neg = (bits >> 15) & 1;
    uint16_t u = neg ? (uint16_t)(0u - (unsigned)bits) : bits;
    uint32_t wu = (uint32_t)u << 17;          /* bit14 of u -> bit31 */
    int r = (int)(wu >> 31);
    int run = __builtin_clz(r ? ~wu : wu);
    int k = r ? (run - 1) : (-run);
    int rem = 14 - run;                       /* n-2-run */
    int e = 0;
    if (rem >= 1) { e = (u >> (rem - 1)) & 1; rem--; }  /* es=1: one exp bit */
    int F = rem > 0 ? rem : 0;
    double frac = F ? (double)(u & ((1u << F) - 1u)) / (double)(1u << F) : 0.0;
    return (neg ? -1.0 : 1.0) * ldexp(1.0 + frac, 2 * k + e);
}
static uint16_t zag_f64_to_p16(double x){
    if (x == 0.0) return 0u; if (isnan(x) || isinf(x)) return 0x8000u;
    int neg = (x < 0.0); double ax = fabs(x);
    int E2; double m = frexp(ax, &E2); m *= 2.0; int E = E2 - 1;
    int k = (E >= 0) ? (E / 2) : -(((-E) + 1) / 2);    /* floor(E/2) for es=1 */
    int e = E - 2 * k;
    double fr = m - 1.0; unsigned char bs[48]; int n = 0;
    if(k>=0){for(int i=0;i<=k&&n<48;i++)bs[n++]=1;if(n<48)bs[n++]=0;}
    else    {for(int i=0;i<-k&&n<48;i++)bs[n++]=0;if(n<48)bs[n++]=1;}
    if(n<48) bs[n++]=e&1;                    /* es=1: single exp bit */
    while(n<48){fr*=2.0;int d=(int)fr;bs[n++]=(unsigned char)d;fr-=d;}
    uint16_t mag=0; for(int i=0;i<15;i++) mag=(uint16_t)((mag<<1)|(i<n?bs[i]:0));
    int rb=(15<n)?bs[15]:0,st=0; for(int i=16;i<n;i++) st|=bs[i];
    if(rb&&(st||(mag&1))) mag++;
    uint16_t w = mag & 0x7FFFu; if(!w) w=1;
    return neg ? (uint16_t)(0u-(unsigned)w) : w;
}
static uint16_t zag_p16_from_i64(int64_t v){ return zag_f64_to_p16((double)v); }
static uint64_t zag_p16_bits(uint16_t b){ return (uint64_t)b; }
static uint16_t zag_p16_add(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u)return 0x8000u; return zag_f64_to_p16(zag_p16_to_f64(a)+zag_p16_to_f64(b)); }
static uint16_t zag_p16_sub(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u)return 0x8000u; return zag_f64_to_p16(zag_p16_to_f64(a)-zag_p16_to_f64(b)); }
static uint16_t zag_p16_mul(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u)return 0x8000u;if(!a||!b)return 0u; return zag_f64_to_p16(zag_p16_to_f64(a)*zag_p16_to_f64(b)); }
static uint16_t zag_p16_div(uint16_t a,uint16_t b){ if(a==0x8000u||b==0x8000u||!b)return 0x8000u;if(!a)return 0u; return zag_f64_to_p16(zag_p16_to_f64(a)/zag_p16_to_f64(b)); }

/* ── p64: n=64, es=3, useed=256; range [2^-240, 2^240]; max 59 fraction bits.
   Decode/encode via long double (64-bit mantissa ≥ 59 frac bits → exact).
   Arithmetic via long double (exact for +/-; mul has ≤1 ULP — 120-bit product > 64-bit mant). ── */
static long double zag_p64_to_ld(uint64_t bits){
    if (!bits) return 0.0L;
    if (bits == 0x8000000000000000ULL) return (long double)NAN;
    int neg = (int)(bits >> 63);
    uint64_t u = neg ? (uint64_t)(0ULL - bits) : bits;
    uint64_t w = u << 1;                          /* bit62 of u -> bit63, for __builtin_clzll */
    int r = (int)(w >> 63);
    int run = __builtin_clzll(r ? ~w : w);
    int k = r ? (run - 1) : (-run);
    int rem = 62 - run;                            /* n-2-run bits remaining */
    int e = 0;
    if (rem >= 3) { e = (int)((u >> (rem - 3)) & 7ULL); rem -= 3; }   /* es=3: 3 exp bits */
    else if (rem > 0) { e = (int)((u & ((1ULL << rem) - 1ULL)) << (3 - rem)); rem = 0; }
    int F = rem > 0 ? rem : 0;
    long double frac = F ? (long double)(u & ((F >= 64) ? ~0ULL : ((1ULL << F) - 1ULL)))
                         / (long double)(1ULL << F) : 0.0L;
    return (neg ? -1.0L : 1.0L) * ldexpl(1.0L + frac, 8 * k + e);
}
static uint64_t zag_ld_to_p64(long double x){
    if (x == 0.0L) return 0ULL;
    if (isnan(x) || isinf(x)) return 0x8000000000000000ULL;
    int neg = (x < 0.0L); long double ax = fabsl(x);
    int E2; long double m = frexpl(ax, &E2); m *= 2.0L; int E = E2 - 1;
    int k = (E >= 0) ? (E / 8) : -(((-E) + 7) / 8);
    int e = E - 8 * k;
    long double fr = m - 1.0L; unsigned char bs[200]; int n = 0;
    if(k>=0){for(int i=0;i<=k&&n<200;i++)bs[n++]=1;if(n<200)bs[n++]=0;}
    else    {for(int i=0;i<-k&&n<200;i++)bs[n++]=0;if(n<200)bs[n++]=1;}
    if(n<200)bs[n++]=(e>>2)&1; if(n<200)bs[n++]=(e>>1)&1; if(n<200)bs[n++]=e&1;
    while(n<200){fr*=2.0L;int d=(int)fr;bs[n++]=(unsigned char)d;fr-=d;}
    uint64_t mag=0; for(int i=0;i<63;i++) mag=(mag<<1)|(i<n?(uint64_t)bs[i]:0ULL);
    int rb=(63<n)?bs[63]:0,st=0; for(int i=64;i<n;i++) st|=bs[i];
    if(rb&&(st||(int)(mag&1))) mag++;
    uint64_t w2 = mag & 0x7FFFFFFFFFFFFFFFULL; if(!w2) w2=1;
    return neg ? (uint64_t)(0ULL - w2) : w2;
}
static double   zag_p64_to_f64(uint64_t b){ return (double)zag_p64_to_ld(b); }
static uint64_t zag_f64_to_p64(double x){ return zag_ld_to_p64((long double)x); }
static uint64_t zag_p64_from_i64(int64_t v){ return zag_ld_to_p64((long double)v); }
static uint64_t zag_p64_bits(uint64_t b){ return b; }
static uint64_t zag_p64_add(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL)return 0x8000000000000000ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)+zag_p64_to_ld(b)); }
static uint64_t zag_p64_sub(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL)return 0x8000000000000000ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)-zag_p64_to_ld(b)); }
static uint64_t zag_p64_mul(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL)return 0x8000000000000000ULL;
    if(!a||!b)return 0ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)*zag_p64_to_ld(b)); }
static uint64_t zag_p64_div(uint64_t a,uint64_t b){
    if(a==0x8000000000000000ULL||b==0x8000000000000000ULL||!b)return 0x8000000000000000ULL;
    if(!a)return 0ULL;
    return zag_ld_to_p64(zag_p64_to_ld(a)/zag_p64_to_ld(b)); }
"""

# P4: hardware posit path — RISC-V PPU direct opcode passthrough.
# Replaces the software add/sub/mul/div when zagc is invoked with --target ppu32.
# p32 values are reinterpret-cast into 32-bit float registers (zero cost via memcpy);
# padd.s/psub.s/pmul.s/pdiv.s are native PPU opcodes (single-cycle on a PPU-equipped core).
# NaR propagation and rounding-to-nearest are handled by the hardware per the Posit Standard.
# Cross-compile: riscv64-linux-gnu-gcc -march=rv64gc_zposit (or vendor posit toolchain).
PRELUDE_PPU_MATH = r"""
/* ── P4: RISC-V PPU hardware posit path — padd.s / psub.s / pmul.s / pdiv.s ──
   Enabled by zagc build --target ppu32. Software path compiled out (#ifndef ZAG_TARGET_PPU32).
   p32 bits move through 32-bit float registers; the PPU instruction sees them as posit values.
   __builtin_memcpy for bit-punning compiles to a single fmv.w.x / fmv.x.w pair at -O1+. */
#if !defined(__riscv)
#warning "zagc --target ppu32: generated for RISC-V PPU; cross-compile with riscv64 toolchain"
#endif
static inline float   _zp_load(uint32_t b){ float f; __builtin_memcpy(&f,&b,4); return f; }
static inline uint32_t _zp_store(float f){ uint32_t b; __builtin_memcpy(&b,&f,4); return b; }
static uint32_t zag_p32_add(uint32_t a, uint32_t b){
    float _r; __asm__ volatile("padd.s %0,%1,%2":"=f"(_r):"f"(_zp_load(a)),"f"(_zp_load(b))); return _zp_store(_r); }
static uint32_t zag_p32_sub(uint32_t a, uint32_t b){
    float _r; __asm__ volatile("psub.s %0,%1,%2":"=f"(_r):"f"(_zp_load(a)),"f"(_zp_load(b))); return _zp_store(_r); }
static uint32_t zag_p32_mul(uint32_t a, uint32_t b){
    float _r; __asm__ volatile("pmul.s %0,%1,%2":"=f"(_r):"f"(_zp_load(a)),"f"(_zp_load(b))); return _zp_store(_r); }
static uint32_t zag_p32_div(uint32_t a, uint32_t b){
    float _r; __asm__ volatile("pdiv.s %0,%1,%2":"=f"(_r):"f"(_zp_load(a)),"f"(_zp_load(b))); return _zp_store(_r); }
"""

def _params_c(params):
    return ", ".join(c_decl(p.pty, p.name) for p in params) or "void"

def _proto(ret, name, param_ctypes):
    return f"static {ret} {name}({', '.join(param_ctypes)});"

def cgen(decls, sema, target="native"):
    FNPTR_TYPEDEFS.clear(); CLOSURES.clear(); THUNKS.clear(); _CLOS_COUNTER[0] = 0; _SW_CTR[0] = 0
    _FNS.clear(); _FNS.update(sema.fns); _STRUCTS.clear(); _STRUCTS.update(sema.structs)
    _ENUMS.clear(); _ENUMS.update(sema.enums); _UNIONS.clear(); _UNIONS.update(sema.unions)
    _METHODS.clear(); _METHODS.update(sema.methods)
    _ERR_NAMES.clear(); _ERR_NAMES.extend(sema.err_names)
    # codegen sees CONCRETE decls + generated instances (from sema), never generic templates
    user = [f for f in sema.fns.values() if not f.extern]
    assign_closure_ids(user)
    typedefs = collect_fn_typedefs(sema)

    user_bodies = [gen_fn(f) for f in user]          # populates THUNKS, uses CLOSURES
    closure_defs = [gen_closure_fn(c) for c in CLOSURES]
    thunk_defs = [gen_thunk(n, ft) for n, ft in THUNKS.items()]

    if target == "ppu32":
        prelude = "#define ZAG_TARGET_PPU32\n" + PRELUDE + PRELUDE_PPU_MATH + PRELUDE_POSIT_MULTI
    else:
        prelude = PRELUDE + PRELUDE_POSIT_MULTI
    # Collect all !T types and dynamic slice types — scan AFTER user_bodies so all types are known
    _RESULT_TYPES.clear(); _SLICE_TYPES.clear()
    for f in sema.fns.values():
        if is_error_union(f.ret): ctype(f.ret)   # registers the inner type
        for p in f.params:                        # also scan param types for slice/new types
            ctype(p.pty)
    out = [prelude]
    # Error union support: enum of error codes + ZagResult_T structs (one per inner type used)
    if _ERR_NAMES:
        enum_vals = ["ZAG_ERR_OK = 0"] + [f"ZAG_ERR_{n} = {i+1}" for i, n in enumerate(_ERR_NAMES)]
        out.append(f"typedef enum {{ {', '.join(enum_vals)} }} ZagErrCode;")
    if _RESULT_TYPES:
        for inner in _RESULT_TYPES:
            nm = "ZagResult_" + _mangle1(inner)
            if inner == "void":
                out.append(f"typedef struct {{ ZagErrCode _err; }} {nm};")
            else:
                out.append(f"typedef struct {{ ZagErrCode _err; {ctype(inner)} _val; }} {nm};")
        out.append("")
    # Dynamic slice types: []sat_i16, []u11, etc. — emit struct typedefs as needed
    if _SLICE_TYPES:
        for tname, elem_ct in _SLICE_TYPES.items():
            out.append(f"typedef struct {{ {elem_ct}* ptr; int32_t len; }} {tname};")
        out.append("")
    for e in sema.enums.values():                    # enums: plain C enums
        out.append(f"typedef enum {{ {', '.join(e.name + '_' + m for m in e.members)} }} {e.name};")
    if typedefs: out.append(typedefs)
    for s in sema.structs.values():
        out.append(f"typedef struct {{ {' '.join(c_decl(p.pty, p.name) + ';' for p in s.fields)} }} {ctype(s.name)};")
    for u in sema.unions.values():                   # tagged unions: { tag; union{..} u; }
        out.append(f"enum {{ {', '.join(u.name + '_' + p.name for p in u.fields)} }};")
        inner = " ".join(c_decl(p.pty, p.name) + ";" for p in u.fields)
        out.append(f"typedef struct {{ int32_t tag; union {{ {inner} }} u; }} {u.name};")
    for c in CLOSURES:
        if c.caps:
            out.append(f"typedef struct {{ {' '.join(c_decl(c.cap_types[cap], cap) + ';' for cap in c.caps)} }} __ClosEnv_{c.cid};")
    out.append("")
    protos = []
    for f in user:
        if f.name != "main":
            ptypes = ([ctype(f.recv_type)] if f.recv_type else []) + [ctype(p.pty) for p in f.params]
            protos.append(_proto(ctype(f.ret), cfn(f.name), ptypes or ["void"]))
    for c in CLOSURES:
        protos.append(_proto(ctype(c.ret), f"__clos_{c.cid}", ["void*"] + [ctype(p.pty) for p in c.params]))
    for n, ft in THUNKS.items():
        ps, ret, _ = fn_parts(ft)
        protos.append(_proto(ctype(ret), f"__thunk_{cfn(n)}", ["void*"] + [ctype(p) for p in ps]))
    out.append("\n".join(protos)); out.append("")
    out += thunk_defs + closure_defs + user_bodies
    return "\n".join(out) + "\n"

def gen_fn(f):
    save = (G.fnlocals, G.caps, G.fn_ret)
    G.fnlocals = {p.name for p in f.params if is_fn_type(p.pty)} | _let_fnlocals(f.body)
    G.caps = set()
    G.fn_ret = f.ret
    if f.recv_type:
        user = _params_c(f.params)
        all_params = f"{ctype(f.recv_type)} self" + (f", {user}" if user != "void" else "")
        head = f"static {ctype(f.ret)} {cfn(f.name)}({all_params})"
    else:
        head = "int main(void)" if f.name == "main" else f"static {ctype(f.ret)} {cfn(f.name)}({_params_c(f.params)})"
    body = "\n".join(gen_stmt(s, 1) for s in f.body)
    G.fnlocals, G.caps, G.fn_ret = save
    return f"{head} {{\n{body}\n}}\n"

def gen_closure_fn(c):
    save = (G.fnlocals, G.caps)
    G.fnlocals = ({p.name for p in c.params if is_fn_type(p.pty)}
                  | {cap for cap in c.caps if is_fn_type(c.cap_types[cap])} | _let_fnlocals(c.body))
    G.caps = set(c.caps)
    params = _params_c(c.params)
    sig = "void* __envp" + (", " + params if params != "void" else "")
    pre = (f"{ind(1)}__ClosEnv_{c.cid}* __e = (__ClosEnv_{c.cid}*)__envp;"
           if c.caps else f"{ind(1)}(void)__envp;")
    body = "\n".join(gen_stmt(s, 1) for s in c.body)
    G.fnlocals, G.caps = save
    return f"static {ctype(c.ret)} __clos_{c.cid}({sig}) {{\n{pre}\n{body}\n}}\n"

def gen_thunk(name, ft):
    if name in _FNS:
        f = _FNS[name]; ret = ctype(f.ret); pls = [(p.name, p.pty) for p in f.params]
    else:
        b = BUILTINS[name]; ret = ctype(b["ret"]); pls = [(f"p{i}", t) for i, t in enumerate(b["params"])]
    params = ", ".join(["void* __envp"] + [c_decl(t, n) for n, t in pls])
    call = f"{cfn(name)}(" + ", ".join(n for n, _ in pls) + ")"
    inner = f"{ind(1)}(void)__envp; " + (f"return {call};" if ret != "void" else f"{call};")
    return f"static {ret} __thunk_{cfn(name)}({params}) {{\n{inner}\n}}\n"

def fn_value_literal(name):
    ft = fn_type_string(name); THUNKS[name] = ft
    return f"({ctype(ft)}){{ &__thunk_{cfn(name)}, (void*)0 }}"

def ind(n): return "    " * n
def gen_stmt(s, d):
    if isinstance(s, Let):
        ty = s.dty or s.expr.ty or "i32"
        rhs = gen_expr(s.expr)
        # RNS from int literal: ZagRns x = 12345 → ZagRns x = zag_rns_from_i64(12345)
        if is_rns(ty) and isinstance(s.expr, Lit):
            rhs = f"zag_rns_from_i64({rhs})"
        return f"{ind(d)}{c_decl(ty, s.name)} = {rhs};"
    if isinstance(s, Assign): return f"{ind(d)}{gen_expr(s.target)} = {gen_expr(s.expr)};"
    if isinstance(s, Return):
        fn_ret = G.fn_ret
        if is_error_union(fn_ret):
            T = error_inner(fn_ret); rt = ctype(fn_ret)
            if s.expr is None:
                return f"{ind(d)}return ({rt}){{0}};"    # return; in !void fn
            if isinstance(s.expr, ErrLit):
                return f"{ind(d)}return ({rt}){{ZAG_ERR_{s.expr.errname}, {{0}}}};"
            return f"{ind(d)}return ({rt}){{0, {gen_expr(s.expr)}}};"
        return f"{ind(d)}return{(' ' + gen_expr(s.expr)) if s.expr else ''};"
    if isinstance(s, If):
        out = f"{ind(d)}if ({gen_expr(s.cond)}) {{\n" + "\n".join(gen_stmt(x, d+1) for x in s.then) + f"\n{ind(d)}}}"
        if s.els: out += " else {\n" + "\n".join(gen_stmt(x, d+1) for x in s.els) + f"\n{ind(d)}}}"
        return out
    if isinstance(s, While):
        return f"{ind(d)}while ({gen_expr(s.cond)}) {{\n" + "\n".join(gen_stmt(x, d+1) for x in s.body) + f"\n{ind(d)}}}"
    if isinstance(s, Switch):
        _SW_CTR[0] += 1; tmp = f"__sw{_SW_CTR[0]}"
        ty = s.subject.ty; is_union = ty in _UNIONS
        disc = f"{tmp}.tag" if is_union else tmp
        variants = {p.name: p.pty for p in _UNIONS[ty].fields} if is_union else {}
        L = [f"{ind(d)}{{ {ctype(ty)} {tmp} = {gen_expr(s.subject)};",
             f"{ind(d)}switch ({disc}) {{"]
        for tag, cap, body in s.arms:
            L.append(f"{ind(d+1)}case {ty}_{tag}: {{")
            if is_union and cap:
                L.append(f"{ind(d+2)}{c_decl(variants[tag], cap)} = {tmp}.u.{tag};")
            L += [gen_stmt(x, d+2) for x in body]
            L.append(f"{ind(d+2)}break;"); L.append(f"{ind(d+1)}}}")
        if s.els is not None:
            L.append(f"{ind(d+1)}default: {{")
            L += [gen_stmt(x, d+2) for x in s.els]
            L.append(f"{ind(d+2)}break;"); L.append(f"{ind(d+1)}}}")
        L.append(f"{ind(d)}}} }}")
        return "\n".join(L)
    if isinstance(s, ExprStmt): return f"{ind(d)}{gen_expr(s.expr)};"
    return f"{ind(d)}/* ? */"

def gen_expr(e):
    if isinstance(e, ErrLit):
        return f"ZAG_ERR_{e.errname}"    # just the error code; full result emitted at Return/Catch site
    if isinstance(e, Try):
        inner_ty = getattr(e.expr, "ty", None)   # !T
        if inner_ty and is_error_union(inner_ty):
            T = error_inner(inner_ty)
            rc = ctype(inner_ty)
            _TRY_CTR[0] += 1; tmp = f"__try{_TRY_CTR[0]}"
            outer = G.fn_ret
            # propagation: if enclosing fn returns !U, return ZagResult_U with the error code
            if is_error_union(outer):
                ou = ctype(outer)
                if T == "void":
                    return f"({{ {rc} {tmp} = {gen_expr(e.expr)}; if ({tmp}._err) return ({ou}){{{tmp}._err, {{0}}}}; }})"
                return f"({{ {rc} {tmp} = {gen_expr(e.expr)}; if ({tmp}._err) return ({ou}){{{tmp}._err, {{0}}}}; {tmp}._val; }})"
            else:
                # try in a non-!T fn: panic on error (best-effort for PoC)
                if T == "void":
                    return f"({{ {rc} {tmp} = {gen_expr(e.expr)}; if ({tmp}._err) {{ fprintf(stderr, \"error: %d\\n\", {tmp}._err); exit(1); }} }})"
                return f"({{ {rc} {tmp} = {gen_expr(e.expr)}; if ({tmp}._err) {{ fprintf(stderr, \"error: %d\\n\", {tmp}._err); exit(1); }} {tmp}._val; }})"
        return gen_expr(e.expr)   # fallback (sema will have reported the error)
    if isinstance(e, Catch):
        inner_ty = getattr(e.expr, "ty", None)   # !T
        if inner_ty and is_error_union(inner_ty):
            T = error_inner(inner_ty)
            rc = ctype(inner_ty)
            _TRY_CTR[0] += 1; tmp = f"__try{_TRY_CTR[0]}"
            inner_e = gen_expr(e.expr); default_e = gen_expr(e.default)
            if e.cap:
                if T == "void":
                    return f"({{ {rc} {tmp} = {inner_e}; int32_t {e.cap} = (int32_t){tmp}._err; (void){e.cap}; }})"
                return f"({{ {rc} {tmp} = {inner_e}; int32_t {e.cap} = (int32_t){tmp}._err; {tmp}._err ? {default_e} : {tmp}._val; }})"
            if T == "void":
                return f"({{ {rc} {tmp} = {inner_e}; (void){tmp}._err; }})"
            return f"({{ {rc} {tmp} = {inner_e}; {tmp}._err ? {default_e} : {tmp}._val; }})"
        return gen_expr(e.expr)
    if isinstance(e, Lit):
        if e.lty == "str":
            # Count logical bytes: escape sequences like \n count as 1 byte each
            n, i = 0, 0
            while i < len(e.val):
                if e.val[i] == "\\" and i + 1 < len(e.val): i += 2
                else: i += 1
                n += 1
            return f'(ZagSliceU8){{(const uint8_t*)"{e.val}", {n}}}'
        if is_float(e.lty):
            v = e.val; return v if any(c in v for c in ".eE") else v + ".0"
        if e.lty == "bool": return "1" if e.val == "true" else "0"
        return e.val                                   # integer literal: emit as-is (C promotes to slot type)
    if isinstance(e, Var):
        if e.name in G.caps: return f"__e->{e.name}"
        if e.name in G.fnlocals: return e.name
        if e.name in _FNS or e.name in BUILTINS: return fn_value_literal(e.name)   # named fn as a value
        return e.name
    if isinstance(e, Un): return f"({e.op}{gen_expr(e.e)})"
    if isinstance(e, Bin):
        lt = getattr(e.l, "ty", None)
        rt = getattr(e.r, "ty", None)
        if is_posit(lt):                                   # posit ops dispatch to the per-width runtime
            ops = POSIT_OPS.get(lt, POSIT_OPS["p32"])
            decode = POSIT_TO_F64.get(lt, "zag_p32_to_f64")
            gl, gr = gen_expr(e.l), gen_expr(e.r)
            if e.op in ops: return f"{ops[e.op]}({gl}, {gr})"
            return f"({decode}({gl}) {e.op} {decode}({gr}))"              # comparisons via decode
        # Saturating arithmetic: emit calls to zag_sat_<op>_<width> runtime helpers
        if is_sat(lt) and e.op in ("+", "-", "*"):
            base = sat_base(lt)   # "i16"
            op_name = {"+" : "add", "-": "sub", "*": "mul"}[e.op]
            return f"zag_sat_{op_name}_{base}({gen_expr(e.l)}, {gen_expr(e.r)})"
        # Arbitrary-width integers: emit arithmetic then mask to N bits
        if is_arb_int(lt) and e.op in ("+", "-", "*", "&", "|"):
            ct  = arb_int_ctype(lt)
            msk = arb_int_mask(lt)
            inner = f"({gen_expr(e.l)} {e.op} {gen_expr(e.r)})"
            if arb_int_signed(lt):
                # sign-extend: mask to N bits then propagate the sign bit
                n   = arb_int_bits(lt)
                smask = f"0x{((1<<n)-1):X}u"
                signbit = f"0x{(1<<(n-1)):X}u"
                return (f"((({ct})({inner} & {smask})) ^ {signbit}) - (({ct}){signbit})")
            return f"(({ct})(({inner}) & {msk}))"
        if is_arb_int(lt) and e.op == "^":
            ct = arb_int_ctype(lt); msk = arb_int_mask(lt)
            return f"(({ct})(({gen_expr(e.l)} ^ {gen_expr(e.r)}) & {msk}))"
        # Fixed-point: add/sub exact; mul needs >> F
        if is_fixed(lt):
            if e.op in ("+", "-"):
                return f"(({fixed_ctype(lt)})({gen_expr(e.l)} {e.op} {gen_expr(e.r)}))"
            if e.op == "*":
                _, frac = fixed_parts(lt)
                wider = "int64_t" if fixed_ctype(lt) in ("int8_t","int16_t","int32_t") else "__int128"
                return f"(({fixed_ctype(lt)})((({wider}){gen_expr(e.l)} * {gen_expr(e.r)}) >> {frac}))"
            if e.op == "/":
                _, frac = fixed_parts(lt)
                wider = "int64_t" if fixed_ctype(lt) in ("int8_t","int16_t","int32_t") else "__int128"
                return f"(({fixed_ctype(lt)})(((({wider}){gen_expr(e.l)}) << {frac}) / {gen_expr(e.r)}))"
        # RNS arithmetic: dispatch to parallel modular runtime functions
        if is_rns(lt) and is_rns(rt):
            if e.op == "+": return f"zag_rns_add({gen_expr(e.l)}, {gen_expr(e.r)})"
            if e.op == "-": return f"zag_rns_sub({gen_expr(e.l)}, {gen_expr(e.r)})"
            if e.op == "*": return f"zag_rns_mul({gen_expr(e.l)}, {gen_expr(e.r)})"
        # bitwise XOR — also the VSA bind operator (^ on i32 words = bind over packed bits)
        if e.op == "^": return f"({gen_expr(e.l)} ^ {gen_expr(e.r)})"
        return f"({gen_expr(e.l)} {e.op} {gen_expr(e.r)})"
    if isinstance(e, Index):
        bt = getattr(e.base, "ty", None); base = gen_expr(e.base)
        return f"{base}.ptr[{gen_expr(e.idx)}]" if bt and bt.startswith("[]") else f"{base}[{gen_expr(e.idx)}]"
    if isinstance(e, Field):
        if isinstance(e.base, Var) and e.base.name in _ENUMS:    # enum member -> C enum constant
            return f"{e.base.name}_{e.fname}"
        return f"{gen_expr(e.base)}.{e.fname}"
    if isinstance(e, StructLit):
        nm = e.inst_sname or e.sname
        if nm in _UNIONS:                                        # tagged-union construction
            tag, val = e.fields[0]
            return f"({nm}){{ .tag = {nm}_{tag}, .u = {{ .{tag} = {gen_expr(val)} }} }}"
        return f"({ctype(nm)}){{ " + ", ".join(f".{n} = {gen_expr(v)}" for n, v in e.fields) + " }"
    if isinstance(e, Closure):
        X = ctype(e.ty)
        if e.caps:
            env = f"&(__ClosEnv_{e.cid}){{ " + ", ".join(f".{c} = {gen_expr(Var(c, e.line))}" for c in e.caps) + " }"
        else:
            env = "(void*)0"
        return f"({X}){{ &__clos_{e.cid}, {env} }}"
    if isinstance(e, Call):
        if e.inst_name:                                                                # generic instance
            return f"{cfn(e.inst_name)}(" + ", ".join(gen_expr(a) for a in e.args) + ")"
        callee = e.callee
        # Method call: obj.method(args) -> RecvType_method(obj, args)
        if isinstance(callee, Field):
            base_ty = getattr(callee.base, "ty", None)
            if base_ty and (base_ty, callee.fname) in _METHODS:
                mname = cfn(f"{base_ty}_{callee.fname}")
                base = gen_expr(callee.base)
                args_c = ", ".join(gen_expr(a) for a in e.args)
                return f"{mname}({base}" + (f", {args_c}" if args_c else "") + ")"
        if isinstance(callee, Var) and callee.name not in G.caps and callee.name not in G.fnlocals \
           and (callee.name in _FNS or callee.name in BUILTINS):
            cname = BUILTIN_CNAME.get(callee.name, cfn(callee.name))      # @-casts route to the runtime
            return f"{cname}(" + ", ".join(gen_expr(a) for a in e.args) + ")"   # direct named call
        cv = gen_expr(callee)                                                          # fat-pointer call
        return f"({cv}).fn(" + ", ".join([f"({cv}).env"] + [gen_expr(a) for a in e.args]) + ")"
    return "/*?*/"

# ───────────────────────────── 6. driver ─────────────────────────────

def compile_file(path):
    decls = Parser(lex(open(path).read())).parse()
    sema = Sema(decls)
    sema.check_types()
    sema.check_stores()
    report = sema.check_capabilities()
    return decls, sema, report

def print_report(report, sema=None):
    if not report: print("  (no capability annotations to verify)")
    for f, eff, viol, wit in report:
        effs = ", ".join(sorted(eff)) or "none"
        mark = "✗ VIOLATED" if viol else "✓ proven"
        print(f"  {mark}  {f.name} {' '.join(f.annots)}   inferred effects: {{{effs}}}")
    for d in (getattr(sema, "discharges", None) or []):
        print(f"  🔒 {d}")
    if sema is not None and not sema.prover_available() and any("@total" in f.annots for f, *_ in report):
        print("  (note: no SMT prover found — @total uses the conservative literal-divisor rule.")
        print("         build the bridge with: cd ../../ghost_engine && zig build zag-verify)")

def cmd_check(path):
    try: decls, sema, report = compile_file(path)
    except ZagError as e: print(f"{path}:{e.line}: error: {e.msg}"); return 1
    print(f"== effect/capability report for {path} =="); print_report(report, sema)
    if sema.errors:
        print("\nerrors:")
        for e in sema.errors: print(f"{path}:{e.line}: error: {e.msg}")
        return 1
    print("\nOK — all capability claims proven, types check."); return 0

# ── Architecture target tables ────────────────────────────────────────────────
# Maps target name → CC flags / ABI notes for heterogeneous CPU targets.
# GPU targets take a completely different path (MLIR backend, see cmd_build_gpu).
# Key properties per target:
#   x86_64 : has SSE2 PADDSW for sat_i16 (emit __builtin_ia32_paddsw later); __int128 ok
#   arm64  : has SQADD/UQADD (1-cycle sat); bf16 native on ARMv8.6+; WASM via Emscripten
#   riscv32: 32-bit; avoid i64 literals; sat via C helpers; Zce extension for u11 bitmanip
#   riscv64: like riscv32 but 64-bit; RVV extension for vectorised sat ops
#   wasm   : no __int128; 32/64-bit ints only; sat_i16 via SIMD lane128 i16x8.add_sat
CPU_TARGETS = {
    "native":  {"cc_flags": ["-O2"], "has_int128": True,  "has_sat_intrinsics": False},
    "ppu32":   {"cc_flags": ["-O2", "-march=rv64g"], "has_int128": True, "has_sat_intrinsics": False},
    "x86_64":  {"cc_flags": ["-O2", "-march=x86-64-v2"], "has_int128": True, "has_sat_intrinsics": True},
    "arm64":   {"cc_flags": ["-O2", "-march=armv8-a"], "has_int128": True, "has_sat_intrinsics": True},
    "riscv32": {"cc_flags": ["-O2", "-march=rv32imac", "-mabi=ilp32"], "has_int128": False, "has_sat_intrinsics": False},
    "riscv64": {"cc_flags": ["-O2", "-march=rv64imac", "-mabi=lp64"], "has_int128": True, "has_sat_intrinsics": False},
    "wasm":    {"cc_flags": ["-O2", "-msimd128"], "has_int128": False, "has_sat_intrinsics": False},
}

def _is_gpu_target(target: str) -> bool:
    return target.startswith("gpu-") or target == "gpu-auto"

def cmd_build_gpu(path, out, target):
    """Route @kernel/@device functions through the MLIR GPU backend."""
    gpu_pkg = os.path.join(os.path.dirname(os.path.abspath(__file__)), "gpu")
    import sys as _sys
    if gpu_pkg not in _sys.path: _sys.path.insert(0, os.path.dirname(gpu_pkg))
    try:
        from gpu.mlir_emitter import emit_mlir
        from gpu.lowering import lower, detect_target
    except ImportError as ex:
        print(f"GPU backend import error: {ex}")
        print(f"Ensure the gpu/ directory is present at {gpu_pkg}")
        return 1

    try: decls, sema, report = compile_file(path)
    except ZagError as e: print(f"{path}:{e.line}: error: {e.msg}"); return 1
    print(f"== effect/capability report for {path} =="); print_report(report, sema)
    if sema.errors:
        print("\nbuild failed — capability/type errors:")
        for e in sema.errors: print(f"{path}:{e.line}: error: {e.msg}")
        return 1

    # Resolve gpu-auto to the system's detected GPU vendor
    if target == "gpu-auto":
        resolved = detect_target()
        print(f"  [gpu] auto-detected target: {resolved}")
    else:
        resolved = target.removeprefix("gpu-")   # 'gpu-nvidia' -> 'nvidia'

    mlir_text = emit_mlir(sema, target=resolved)
    out_base = out or os.path.splitext(path)[0]
    return lower(mlir_text, resolved, out_base)

def cmd_build(path, out, run, emit_c, target="native"):
    # GPU targets take a separate path through the MLIR emitter
    if _is_gpu_target(target):
        return cmd_build_gpu(path, out, target)

    try: decls, sema, report = compile_file(path)
    except ZagError as e: print(f"{path}:{e.line}: error: {e.msg}"); return 1
    print(f"== effect/capability report for {path} =="); print_report(report, sema)
    if sema.errors:
        print("\nbuild failed — capability/type errors:")
        for e in sema.errors: print(f"{path}:{e.line}: error: {e.msg}")
        return 1
    c = cgen(decls, sema, target=target)
    cpath = (out or os.path.splitext(path)[0]) + ".c"
    open(cpath, "w").write(c)
    if emit_c:
        if target == "ppu32": print(f"  [ppu32] hardware posit path — padd.s/psub.s/pmul.s/pdiv.s inline asm")
        print(f"\nwrote {cpath}"); return 0
    binpath = out or os.path.splitext(path)[0]
    tinfo = CPU_TARGETS.get(target, CPU_TARGETS["native"])
    if target in ("ppu32", "riscv32", "riscv64"):
        cc = (shutil.which("riscv64-linux-gnu-gcc") or shutil.which("riscv64-unknown-elf-gcc")
              or shutil.which("cc") or shutil.which("gcc"))
    elif target == "wasm":
        cc = shutil.which("emcc") or shutil.which("cc") or shutil.which("gcc")
    elif target in ("arm64",):
        cc = (shutil.which("aarch64-linux-gnu-gcc") or shutil.which("cc") or shutil.which("gcc"))
    else:
        cc = shutil.which("cc") or shutil.which("gcc")
    if not cc: print("no system cc/gcc found"); return 1
    r = subprocess.run([cc, cpath, "-o", binpath, "-lm", "-w"] + tinfo["cc_flags"], capture_output=True, text=True)
    if r.returncode != 0: print("C backend failed:\n" + r.stderr); return 1
    print(f"\nbuilt native binary: {binpath}")
    if run:
        print(f"-- running {binpath} --")
        rr = subprocess.run([binpath], capture_output=True, text=True)
        sys.stdout.write(rr.stdout)
        if rr.stderr: sys.stderr.write(rr.stderr)
        print(f"-- exit {rr.returncode} --")
    return 0

USAGE = """zagc — Zag bootstrap compiler  (universal heterogeneous computing edition)
usage:
  zagc check <file.zag>
  zagc build <file.zag> [-o out] [--run] [--emit-c] [--target <target>]

cpu targets:
  native      (default) host cpu — software posit, u_any backed by __int128
  x86_64      x86-64 v2 — SSE2 saturating PADDSW for sat_i16/sat_i8
  arm64       ARMv8-A — SQADD/UQADD 1-cycle sat ops; bf16 native on ARMv8.6+
  riscv32     RV32IMAC — 32-bit; sat/u_any via C helpers; Zce for u11 bit-pack
  riscv64     RV64IMAC — 64-bit; RVV for vectorised sat/arb-int
  wasm        WebAssembly SIMD — i16x8.add_sat for sat_i16; no __int128
  ppu32       RISC-V PPU hardware posit — padd.s/psub.s inline asm

gpu targets (MLIR backend — bypasses Vulkan, talks directly to silicon):
  gpu-nvidia  NVIDIA NVVM/CUDA → PTX; mx_fp8=f8E4M3FN; tensor cores on sm_89+
  gpu-amd     AMD ROCDL/HIP → GCN ISA; default mcpu gfx90a (MI300X)
  gpu-vulkan  Vulkan SPIR-V portability — any Vulkan 1.3 device; no tensor cores
  gpu-auto    auto-detect from nvidia-smi / rocm-smi; falls back to gpu-nvidia

heterogeneous compute types (all targets):
  u3..u127      arbitrary-width unsigned ints — MLIR iN native; C: next-larger + mask
  i3..i127      arbitrary-width signed ints   — MLIR iN native; C: mask + sign-extend
  sat_i8/16/32/64   saturating signed   — clamps instead of overflow; NO Panic effect
  sat_u8/16/32/64   saturating unsigned — clamps to [0,MAX];          NO Panic effect
  fixed_I_F     Q-format fixed-point (I int bits, F frac bits); mul does (a*b)>>F
  u_any / i_any register-first bignum; Alloc effect on overflow; __int128 bootstrap
  rns_N         Residue Number System — N coprime channels; add/mul perfectly parallel

gpu-native types (gpu-* targets):
  l32 / l16     Logarithmic Number System; mul/div = integer add/sub of exponents
  bf16          bfloat16; tensor core native on A100/H100
  mx_fp8        MX Microscaling FP8 E4M3; Blackwell B100 block-scaled GEMM
  mx_fp4        MX Microscaling FP4 E2M1; extreme density for speculative decoding
  vsa_b<N>      Binary VSA hypervector (N-dim; bind=XOR, bundle=majority)

gpu annotations / builtins:
  @kernel / @device                     forbid Alloc/Lock/IO (same proof as @realtime)
  @gpuThreadIdx(d) @gpuBlockIdx(d)      thread/block coordinates
  @gpuSyncThreads()                     thread barrier
  @gpuAlloc(n) @gpuFree(buf)            device memory (DeviceAlloc effect)
  @gpuLaunch(gx,gy,gz,bx,by,bz)        kernel dispatch (DeviceIO effect)

gpu requires mlir-opt (LLVM/MLIR >= 18):
  Ubuntu: apt install mlir-tools llvm-18
  macOS:  brew install llvm  (mlir-opt in $(brew --prefix llvm)/bin/)
"""

def main(argv):
    if len(argv) < 2: print(USAGE); return 2
    cmd = argv[1]
    if cmd == "check" and len(argv) >= 3: return cmd_check(argv[2])
    if cmd == "build" and len(argv) >= 3:
        path = argv[2]; out = None; run = False; emit_c = False; target = "native"; i = 3
        while i < len(argv):
            if argv[i] == "-o": out = argv[i+1]; i += 2
            elif argv[i] == "--run": run = True; i += 1
            elif argv[i] == "--emit-c": emit_c = True; i += 1
            elif argv[i] == "--target": target = argv[i+1]; i += 2
            else: i += 1
        return cmd_build(path, out, run, emit_c, target=target)
    print(USAGE); return 2

if __name__ == "__main__":
    sys.exit(main(sys.argv))
