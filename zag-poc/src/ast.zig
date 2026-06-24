const std = @import("std");

pub const NodeRef = *Node;

// ── Param: a name+type pair used in fn signatures, struct fields, union variants ──
pub const Param = struct {
    name: []const u8,
    pty:  []const u8,   // type string (e.g. "i32", "?bool", "[]u8")
};

// ── FieldInit: one field in a struct literal ──
pub const FieldInit = struct {
    name: []const u8,
    val:  NodeRef,
};

// ── SwitchArm: one arm of a switch statement/expression ──
pub const SwitchArm = struct {
    tags: [][]const u8,  // one or more patterns (ident strings or decimal int strings)
    cap:  ?[]const u8,   // capture variable name, or null
    body: []NodeRef,
};

// ── The main tagged union covering every AST node ──
pub const Node = union(enum) {
    // ── top-level declarations ──
    fn_decl:     FnDecl,
    struct_decl: StructDecl,
    enum_decl:   EnumDecl,
    union_decl:  UnionDecl,
    error_decl:  ErrorDecl,
    mod_alias:   ModAlias,

    // ── statements ──
    let:       Let,
    assign:    Assign,
    return_:   Return,
    if_:       If,
    while_:    While,
    expr_stmt: ExprStmt,
    switch_:   Switch,

    // ── expressions ──
    lit:          Lit,
    var_:         Var,
    bin:          Bin,
    un:           Un,
    call:         Call,
    index:        Index,
    slice:        Slice,
    cast:         Cast,
    field:        Field,
    struct_lit:   StructLit,
    closure:      Closure,
    err_lit:      ErrLit,
    try_:         NodeRef,         // the sub-expression (try <expr>)
    catch_:       Catch,
    null_lit:     NullLit,
    or_else:      OrElse,
    force_unwrap: NodeRef,         // the sub-expression (<expr>.?)

    // ── sema helpers ──

    /// Return the sema-inferred type string for this node, or null if sema
    /// has not yet visited it.  Works by checking for a `ty` field on the
    /// active union payload via comptime reflection.
    pub fn getType(self: *const Node) ?[]const u8 {
        return switch (self.*) {
            // try_ and force_unwrap carry a bare NodeRef — no ty field.
            .try_         => null,
            .force_unwrap => null,
            inline else   => |v| if (@hasField(@TypeOf(v), "ty")) v.ty else null,
        };
    }

    /// Set the sema-inferred type string on this node.  No-ops for the two
    /// variants whose payload is a bare NodeRef (try_ / force_unwrap).
    pub fn setType(self: *Node, ty: []const u8) void {
        switch (self.*) {
            .try_         => {},
            .force_unwrap => {},
            inline else   => |*v| if (@hasField(@TypeOf(v.*), "ty")) {
                v.ty = ty;
            },
        }
    }
};

// ─────────────────────────────────────────────────────────────────────────────
// Top-level declarations
// ─────────────────────────────────────────────────────────────────────────────

pub const FnDecl = struct {
    name:        []const u8,
    params:      []Param,
    ret:         []const u8,        // return type string
    annots:      [][]const u8,      // e.g. ["@realtime", "@pure"]
    body:        ?[]NodeRef,        // null for extern declarations
    line:        u32,
    is_extern:   bool = false,
    tparams:     [][]const u8 = &.{},   // generic type-parameter names
    recv_type:   ?[]const u8 = null,    // method receiver type, or null
    method_name: ?[]const u8 = null,    // short method name (e.g. "render"), or null
    ty:          ?[]const u8 = null,    // sema: resolved fn type string
};

pub const StructDecl = struct {
    name:    []const u8,
    fields:  []Param,
    line:    u32,
    tparams: [][]const u8 = &.{},
    ty:      ?[]const u8 = null,
};

pub const EnumDecl = struct {
    name:    []const u8,
    members: [][]const u8,
    line:    u32,
    ty:      ?[]const u8 = null,
};

pub const UnionDecl = struct {
    name:   []const u8,
    fields: []Param,       // Param.pty = payload type per variant
    line:   u32,
    ty:     ?[]const u8 = null,
};

pub const ErrorDecl = struct {
    names: [][]const u8,
    line:  u32,
    ty:    ?[]const u8 = null,
};

pub const ModAlias = struct {
    alias:  []const u8,   // the local binding name
    prefix: []const u8,   // the canonical module prefix used by sema
    line:   u32,
    ty:     ?[]const u8 = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Statements
// ─────────────────────────────────────────────────────────────────────────────

pub const Let = struct {
    name: []const u8,
    dty:  ?[]const u8,   // declared type annotation, or null (inferred)
    expr: NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Assign = struct {
    target: NodeRef,
    expr:   NodeRef,
    line:   u32,
    ty:     ?[]const u8 = null,
};

pub const Return = struct {
    expr: ?NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const ExprStmt = struct {
    expr: NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const If = struct {
    cond: NodeRef,
    then: []NodeRef,
    els:  ?[]NodeRef,
    line: u32,
    cap:  ?[]const u8 = null,   // if-let capture variable, e.g. "x" in "if val |x| {"
    ty:   ?[]const u8 = null,
};

pub const While = struct {
    cond: NodeRef,
    body: []NodeRef,
    line: u32,
    cap:  ?[]const u8 = null,   // while-let capture variable
    ty:   ?[]const u8 = null,
};

pub const Switch = struct {
    subject:   NodeRef,
    arms:      []SwitchArm,
    els:       ?[]NodeRef,          // else/default arm body, or null
    line:      u32,
    is_expr:   bool = false,         // true when switch is used as a value
    switch_ty: ?[]const u8 = null,   // sema: result type when is_expr=true
    ty:        ?[]const u8 = null,
};

// ─────────────────────────────────────────────────────────────────────────────
// Expressions
// ─────────────────────────────────────────────────────────────────────────────

pub const LitKind = enum { int_lit, float_lit, str, bool_ };

pub const Lit = struct {
    lty:  LitKind,
    val:  []const u8,   // textual representation of the literal
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Var = struct {
    name: []const u8,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Bin = struct {
    op:   []const u8,   // operator string, e.g. "+", "==", "and"
    l:    NodeRef,
    r:    NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Un = struct {
    op:   []const u8,   // operator string, e.g. "-", "not"
    e:    NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Call = struct {
    callee:    NodeRef,
    args:      []NodeRef,
    line:      u32,
    inst_name: ?[]const u8 = null,   // sema: monomorphized generic fn name
    ty:        ?[]const u8 = null,
    /// sema flag: this call-site argument should be wrapped into ?T at codegen
    opt_wrap:  ?[]const u8 = null,
    /// explicit generic type arguments: foo[T1,T2](args) and @sizeOf[T]()
    targs:     [][]const u8 = &.{},
};

pub const Index = struct {
    base: NodeRef,
    idx:  NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Cast = struct {
    expr:   NodeRef,
    target: []const u8,        // the `as Type` target type
    line:   u32,
    ty:     ?[]const u8 = null,
};

pub const Slice = struct {
    base: NodeRef,
    lo:   NodeRef,
    hi:   NodeRef,
    line: u32,
    ty:   ?[]const u8 = null,
};

pub const Field = struct {
    base:  NodeRef,
    fname: []const u8,
    line:  u32,
    ty:    ?[]const u8 = null,
};

pub const StructLit = struct {
    sname:      []const u8,
    fields:     []FieldInit,
    line:       u32,
    targs:      [][]const u8 = &.{},    // explicit generic type arguments
    inst_sname: ?[]const u8 = null,      // sema: monomorphized struct name
    ty:         ?[]const u8 = null,
};

pub const Closure = struct {
    caps:      [][]const u8,                              // captured variable names
    params:    []Param,
    ret:       []const u8,
    body:      []NodeRef,
    line:      u32,
    cap_types: std.StringHashMapUnmanaged([]const u8) = .{},  // filled by sema
    cid:       ?u32 = null,                               // filled by codegen
    ty:        ?[]const u8 = null,
};

pub const ErrLit = struct {
    errname: []const u8,
    line:    u32,
    ty:      ?[]const u8 = null,
};

pub const Catch = struct {
    expr:    NodeRef,
    default: NodeRef,
    cap:     ?[]const u8,   // capture name for the error value, or null
    line:    u32,
    ty:      ?[]const u8 = null,
};

pub const NullLit = struct {
    line: u32,
    ty:   ?[]const u8 = null,   // sema: set to "?T" of surrounding context
};

pub const OrElse = struct {
    expr:    NodeRef,
    default: NodeRef,
    line:    u32,
    ty:      ?[]const u8 = null,
};

/// ForceUnwrap (.?) — the sub-expression is stored as the NodeRef payload of
/// the `.force_unwrap` union variant rather than as a field here, so this
/// struct only needs to carry the source location for diagnostics.
pub const ForceUnwrap = struct {
    line: u32,
};

// ─────────────────────────────────────────────────────────────────────────────
// Free-standing sema helpers (mirror Node.getType / Node.setType)
// ─────────────────────────────────────────────────────────────────────────────

/// Return the sema-inferred type string for a node, or null.
pub fn nodeType(n: NodeRef) ?[]const u8 {
    return switch (n.*) {
        .try_         => null,
        .force_unwrap => null,
        inline else   => |*v| if (@hasField(@TypeOf(v.*), "ty")) v.ty else null,
    };
}

/// Set the sema-inferred type string on a node.
pub fn setNodeType(n: NodeRef, ty: []const u8) void {
    switch (n.*) {
        .try_         => {},
        .force_unwrap => {},
        inline else   => |*v| if (@hasField(@TypeOf(v.*), "ty")) {
            v.ty = ty;
        },
    }
}
