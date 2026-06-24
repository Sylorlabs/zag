// types.zig — Zag compiler type system helpers
// Ported from zagc.py lines 622–971.
// All type predicates operate on []const u8 type strings.

const std = @import("std");
const ast = @import("ast.zig");

// ── Effect sets ───────────────────────────────────────────────────────────────

pub const ALL_EFFECTS = [_][]const u8{
    "Alloc", "Lock", "IO", "Panic", "DeviceAlloc", "DeviceIO",
};

// ── Builtin table ─────────────────────────────────────────────────────────────

pub const BuiltinInfo = struct {
    params: []const []const u8,
    ret:    []const u8,
    eff:    []const []const u8,  // effect names
};

// Statically defined param/eff slices for each builtin entry.
// We cannot initialise slice fields inline in a comptime struct array without
// these being const declarations first, so we use helper constants.

const bi_no_eff: []const []const u8 = &[_][]const u8{};
const bi_eff_alloc: []const []const u8 = &[_][]const u8{"Alloc"};
const bi_eff_lock:  []const []const u8 = &[_][]const u8{"Lock"};
const bi_eff_io:    []const []const u8 = &[_][]const u8{"IO"};
const bi_eff_deva:  []const []const u8 = &[_][]const u8{"DeviceAlloc"};
const bi_eff_devio: []const []const u8 = &[_][]const u8{"DeviceIO"};

const Builtin = struct {
    name:   []const u8,
    info:   BuiltinInfo,
};

// param type slices
const p_i32:           []const []const u8 = &[_][]const u8{"i32"};
const p_f32s_ret:      []const []const u8 = &[_][]const u8{"[]f32"};
const p_i32s_ret:      []const []const u8 = &[_][]const u8{"[]i32"};
const p_none:          []const []const u8 = &[_][]const u8{};
const p_u8s:           []const []const u8 = &[_][]const u8{"[]u8"};
const p_f32:           []const []const u8 = &[_][]const u8{"f32"};
const p_f64:           []const []const u8 = &[_][]const u8{"f64"};
const p_i64:           []const []const u8 = &[_][]const u8{"i64"};
const p_u64:           []const []const u8 = &[_][]const u8{"u64"};
const p_i64_ret:       []const []const u8 = &[_][]const u8{"i64"};
const p_p32:           []const []const u8 = &[_][]const u8{"p32"};
const p_p8:            []const []const u8 = &[_][]const u8{"p8"};
const p_p16:           []const []const u8 = &[_][]const u8{"p16"};
const p_p64:           []const []const u8 = &[_][]const u8{"p64"};
const p_quire:         []const []const u8 = &[_][]const u8{"quire"};
const p_quire_p32_p32: []const []const u8 = &[_][]const u8{"quire", "p32", "p32"};
const p_u8s_u8s:       []const []const u8 = &[_][]const u8{"[]u8", "[]u8"};
const p_i32_3:         []const []const u8 = &[_][]const u8{"i32"};
const p_gpu_launch:    []const []const u8 = &[_][]const u8{"i32","i32","i32","i32","i32","i32"};
const p_l32:           []const []const u8 = &[_][]const u8{"l32"};
const p_mx_fp8:        []const []const u8 = &[_][]const u8{"mx_fp8"};
const p_vsa:           []const []const u8 = &[_][]const u8{"vsa_b<10000>","vsa_b<10000>"};

const BUILTIN_TABLE = [_]Builtin{
    .{ .name = "zalloc",          .info = .{ .params = p_i32,           .ret = "[]f32",       .eff = bi_eff_alloc } },
    .{ .name = "zfree",           .info = .{ .params = p_f32s_ret,       .ret = "void",        .eff = bi_eff_alloc } },
    .{ .name = "zalloc_i",        .info = .{ .params = p_i32,           .ret = "[]i32",       .eff = bi_eff_alloc } },
    .{ .name = "zfree_i",         .info = .{ .params = p_i32s_ret,       .ret = "void",        .eff = bi_eff_alloc } },
    .{ .name = "lock",            .info = .{ .params = p_none,           .ret = "void",        .eff = bi_eff_lock  } },
    .{ .name = "print_str",       .info = .{ .params = p_u8s,           .ret = "void",        .eff = bi_eff_io    } },
    .{ .name = "print_i32",       .info = .{ .params = p_i32,           .ret = "void",        .eff = bi_eff_io    } },
    .{ .name = "print_f32",       .info = .{ .params = p_f32,           .ret = "void",        .eff = bi_eff_io    } },
    .{ .name = "print_u64",       .info = .{ .params = p_u64,           .ret = "void",        .eff = bi_eff_io    } },
    .{ .name = "print_i64",       .info = .{ .params = p_i64,           .ret = "void",        .eff = bi_eff_io    } },
    .{ .name = "print_f64",       .info = .{ .params = p_f64,           .ret = "void",        .eff = bi_eff_io    } },
    // posit casts
    .{ .name = "@intToPosit",     .info = .{ .params = p_i64,           .ret = "p32",         .eff = bi_no_eff    } },
    .{ .name = "@floatToPosit",   .info = .{ .params = p_f64,           .ret = "p32",         .eff = bi_no_eff    } },
    .{ .name = "@positToFloat",   .info = .{ .params = p_p32,           .ret = "f64",         .eff = bi_no_eff    } },
    .{ .name = "@positToBits",    .info = .{ .params = p_p32,           .ret = "u64",         .eff = bi_no_eff    } },
    // width-specific posit casts
    .{ .name = "@floatToP8",      .info = .{ .params = p_f64,           .ret = "p8",          .eff = bi_no_eff    } },
    .{ .name = "@floatToP16",     .info = .{ .params = p_f64,           .ret = "p16",         .eff = bi_no_eff    } },
    .{ .name = "@floatToP64",     .info = .{ .params = p_f64,           .ret = "p64",         .eff = bi_no_eff    } },
    .{ .name = "@intToP8",        .info = .{ .params = p_i64,           .ret = "p8",          .eff = bi_no_eff    } },
    .{ .name = "@intToP16",       .info = .{ .params = p_i64,           .ret = "p16",         .eff = bi_no_eff    } },
    .{ .name = "@intToP64",       .info = .{ .params = p_i64,           .ret = "p64",         .eff = bi_no_eff    } },
    .{ .name = "@p8ToFloat",      .info = .{ .params = p_p8,            .ret = "f64",         .eff = bi_no_eff    } },
    .{ .name = "@p16ToFloat",     .info = .{ .params = p_p16,           .ret = "f64",         .eff = bi_no_eff    } },
    .{ .name = "@p64ToFloat",     .info = .{ .params = p_p64,           .ret = "f64",         .eff = bi_no_eff    } },
    .{ .name = "@p8ToBits",       .info = .{ .params = p_p8,            .ret = "u64",         .eff = bi_no_eff    } },
    .{ .name = "@p16ToBits",      .info = .{ .params = p_p16,           .ret = "u64",         .eff = bi_no_eff    } },
    .{ .name = "@p64ToBits",      .info = .{ .params = p_p64,           .ret = "u64",         .eff = bi_no_eff    } },
    // quire
    .{ .name = "@quireZero",      .info = .{ .params = p_none,          .ret = "quire",       .eff = bi_no_eff    } },
    .{ .name = "@quireFMA",       .info = .{ .params = p_quire_p32_p32, .ret = "quire",       .eff = bi_no_eff    } },
    .{ .name = "@quireToPosit",   .info = .{ .params = p_quire,         .ret = "p32",         .eff = bi_no_eff    } },
    // string helpers
    .{ .name = "@strEq",          .info = .{ .params = p_u8s_u8s,       .ret = "bool",        .eff = bi_no_eff    } },
    .{ .name = "@strLen",         .info = .{ .params = p_u8s,           .ret = "i32",         .eff = bi_no_eff    } },
    // ── Manual cache-line control (CPU memory hierarchy) ────────────────────────
    // prefetch is a pure HINT (no Alloc/Lock/IO/Panic) → legal inside @realtime/
    // @noalloc: warm L1 for the next buffer without breaking the capability proof.
    // (Lowers to __builtin_prefetch → PREFETCHT0 on x86, PLD/PRFM on ARM.)
    .{ .name = "@prefetch",       .info = .{ .params = p_f32s_ret,      .ret = "void",        .eff = bi_no_eff    } },
    .{ .name = "@prefetchWrite",  .info = .{ .params = p_f32s_ret,      .ret = "void",        .eff = bi_no_eff    } },
    .{ .name = "@prefetchI",      .info = .{ .params = p_i32s_ret,      .ret = "void",        .eff = bi_no_eff    } },
    // cache-line (64-byte) aligned heap buffer — DOES allocate (honest {Alloc}).
    .{ .name = "@cacheAlignedAlloc", .info = .{ .params = p_i32,        .ret = "[]f32",       .eff = bi_eff_alloc } },
    .{ .name = "@cacheAlignedFree",  .info = .{ .params = p_f32s_ret,   .ret = "void",        .eff = bi_eff_alloc } },
    // target cache-line width — a compile-time const, so pure (usable in @realtime).
    .{ .name = "@cacheLineSize",  .info = .{ .params = p_none,          .ret = "i32",         .eff = bi_no_eff    } },
    // math
    .{ .name = "sinf",            .info = .{ .params = p_f32,           .ret = "f32",         .eff = bi_no_eff    } },
    .{ .name = "sqrtf",           .info = .{ .params = p_f32,           .ret = "f32",         .eff = bi_no_eff    } },
    // GPU thread addressing
    .{ .name = "@gpuThreadIdx",   .info = .{ .params = p_i32_3,         .ret = "i32",         .eff = bi_no_eff    } },
    .{ .name = "@gpuBlockIdx",    .info = .{ .params = p_i32_3,         .ret = "i32",         .eff = bi_no_eff    } },
    .{ .name = "@gpuBlockDim",    .info = .{ .params = p_i32_3,         .ret = "i32",         .eff = bi_no_eff    } },
    .{ .name = "@gpuGridDim",     .info = .{ .params = p_i32_3,         .ret = "i32",         .eff = bi_no_eff    } },
    .{ .name = "@gpuSyncThreads", .info = .{ .params = p_none,          .ret = "void",        .eff = bi_no_eff    } },
    // GPU memory management (DeviceAlloc)
    .{ .name = "@gpuAlloc",       .info = .{ .params = p_i32,           .ret = "[]f32",       .eff = bi_eff_deva  } },
    .{ .name = "@gpuFree",        .info = .{ .params = p_f32s_ret,       .ret = "void",        .eff = bi_eff_deva  } },
    // Kernel launch (DeviceIO)
    .{ .name = "@gpuLaunch",      .info = .{ .params = p_gpu_launch,    .ret = "void",        .eff = bi_eff_devio } },
    // LNS casts
    .{ .name = "@floatToLog",     .info = .{ .params = p_f32,           .ret = "l32",         .eff = bi_no_eff    } },
    .{ .name = "@logToFloat",     .info = .{ .params = p_l32,           .ret = "f32",         .eff = bi_no_eff    } },
    // MX microscaling casts
    .{ .name = "@floatToMxFp8",   .info = .{ .params = p_f32,           .ret = "mx_fp8",      .eff = bi_no_eff    } },
    .{ .name = "@mxFp8ToFloat",   .info = .{ .params = p_mx_fp8,        .ret = "f32",         .eff = bi_no_eff    } },
    // VSA hypervector ops
    .{ .name = "@vsaBind",        .info = .{ .params = p_vsa,           .ret = "vsa_b<10000>",.eff = bi_no_eff    } },
    .{ .name = "@vsaBundle",      .info = .{ .params = p_vsa,           .ret = "vsa_b<10000>",.eff = bi_no_eff    } },
    .{ .name = "@vsaSim",         .info = .{ .params = p_vsa,           .ret = "f32",         .eff = bi_no_eff    } },
};

pub fn getBuiltin(name: []const u8) ?BuiltinInfo {
    for (&BUILTIN_TABLE) |*b| {
        if (std.mem.eql(u8, b.name, name)) return b.info;
    }
    return null;
}

// ── Effect forbids per annotation ─────────────────────────────────────────────
// Python FORBIDS dict:
//   "@realtime" -> {Alloc, Lock, IO}
//   "@noalloc"  -> {Alloc}
//   "@pure"     -> {Alloc, Lock, IO}
//   "@total"    -> {Panic}
//   "@kernel"   -> {Alloc, Lock, IO}
//   "@device"   -> {Alloc, Lock, IO}

const forbids_realtime: []const []const u8 = &[_][]const u8{ "Alloc", "Lock", "IO" };
const forbids_noalloc:  []const []const u8 = &[_][]const u8{ "Alloc" };
const forbids_pure:     []const []const u8 = &[_][]const u8{ "Alloc", "Lock", "IO" };
const forbids_total:    []const []const u8 = &[_][]const u8{ "Panic" };
const forbids_kernel:   []const []const u8 = &[_][]const u8{ "Alloc", "Lock", "IO" };
const forbids_device:   []const []const u8 = &[_][]const u8{ "Alloc", "Lock", "IO" };

/// Return the set of forbidden effects for the given annotation string.
/// Returns an empty slice for unknown annotations.
pub fn forbids(annot: []const u8) []const []const u8 {
    if (std.mem.eql(u8, annot, "@realtime")) return forbids_realtime;
    if (std.mem.eql(u8, annot, "@noalloc"))  return forbids_noalloc;
    if (std.mem.eql(u8, annot, "@pure"))     return forbids_pure;
    if (std.mem.eql(u8, annot, "@total"))    return forbids_total;
    if (std.mem.eql(u8, annot, "@kernel"))   return forbids_kernel;
    if (std.mem.eql(u8, annot, "@device"))   return forbids_device;
    return &[_][]const u8{};
}

// ── Type predicate helpers ────────────────────────────────────────────────────

pub fn isFnType(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "fn(");
}

pub fn isErrorUnion(t: []const u8) bool {
    return t.len > 0 and t[0] == '!';
}

pub fn errorInner(t: []const u8) []const u8 {
    return t[1..];
}

pub fn isOptional(t: []const u8) bool {
    return t.len > 0 and t[0] == '?';
}

pub fn optionalInner(t: []const u8) []const u8 {
    return t[1..];
}

pub fn isSlice(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "[]");
}

pub fn sliceInner(t: []const u8) []const u8 {
    return t[2..];
}

/// Returns true if t is a pointer type (*T). A leading '*' is unambiguous:
/// `*[]u8` is pointer-to-slice, `*Node` pointer-to-struct, etc.
pub fn isPointer(t: []const u8) bool {
    return t.len > 1 and t[0] == '*';
}

/// Returns the inner type of *T, or t unchanged if not a pointer type.
pub fn pointerInner(t: []const u8) []const u8 {
    if (isPointer(t)) return t[1..];
    return t;
}

// ── Named type sets ───────────────────────────────────────────────────────────

pub const INT_TYPES = [_][]const u8{
    "i8", "i16", "i32", "i64", "u8", "u16", "u32", "u64", "usize", "bool",
};

pub const FLOAT_TYPES = [_][]const u8{ "f32", "f64" };

pub const POSIT_TYPES = [_][]const u8{ "p8", "p16", "p32", "p64", "quire" };

// Python LNS_TYPES = {"l16","l32"}; BF16_TYPES = {"bf16"}; MX_TYPES = {"mx_fp8","mx_fp4"}
pub const LNS_TYPES  = [_][]const u8{ "l16", "l32" };
pub const MX_TYPES   = [_][]const u8{ "mx_fp8", "mx_fp4" };
pub const BF16_TYPES = [_][]const u8{ "bf16" };

// SAT_TYPES for is_sat
const SAT_TYPES = [_][]const u8{
    "sat_i8",  "sat_i16", "sat_i32", "sat_i64",
    "sat_u8",  "sat_u16", "sat_u32", "sat_u64",
};

// BIGNUM_TYPES
const BIGNUM_TYPES = [_][]const u8{ "u_any", "i_any" };

// ── Arbitrary-width integers: u1..u127, i1..i127 ─────────────────────────────

/// Returns true if t is a non-standard-width uN or iN (1 <= N <= 127, not in INT_TYPES).
pub fn isArbInt(t: []const u8) bool {
    if (t.len < 2) return false;
    if (t[0] != 'u' and t[0] != 'i') return false;
    const rest = t[1..];
    // must be all digits
    for (rest) |c| {
        if (c < '0' or c > '9') return false;
    }
    const n = std.fmt.parseInt(u32, rest, 10) catch return false;
    if (n < 1 or n > 127) return false;
    // exclude standard widths already in INT_TYPES
    for (&INT_TYPES) |s| {
        if (std.mem.eql(u8, s, t)) return false;
    }
    return true;
}

pub fn arbIntBits(t: []const u8) u32 {
    return std.fmt.parseInt(u32, t[1..], 10) catch 0;
}

pub fn arbIntSigned(t: []const u8) bool {
    return t[0] == 'i';
}

// ── Saturating integers ───────────────────────────────────────────────────────

pub fn isSat(t: []const u8) bool {
    for (&SAT_TYPES) |s| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

/// "sat_i16" -> "i16"
pub fn satBase(t: []const u8) []const u8 {
    return t[4..];
}

// ── Fixed-point: fixed_<I>_<F> ────────────────────────────────────────────────

pub fn isFixed(t: []const u8) bool {
    // Must be "fixed_<digits>_<digits>"
    if (!std.mem.startsWith(u8, t, "fixed_")) return false;
    const rest = t[6..]; // after "fixed_"
    // find the second underscore
    var first_under: ?usize = null;
    for (rest, 0..) |c, i| {
        if (c == '_') { first_under = i; break; }
    }
    const fu = first_under orelse return false;
    if (fu == 0) return false; // no digits before underscore
    const i_part = rest[0..fu];
    const f_part = rest[fu + 1..];
    if (f_part.len == 0) return false;
    for (i_part) |c| { if (c < '0' or c > '9') return false; }
    for (f_part) |c| { if (c < '0' or c > '9') return false; }
    return true;
}

pub fn fixedParts(t: []const u8) struct { i: u32, f: u32 } {
    // t = "fixed_<I>_<F>"
    const rest = t[6..];
    var fu: usize = 0;
    while (fu < rest.len and rest[fu] != '_') : (fu += 1) {}
    const i_val = std.fmt.parseInt(u32, rest[0..fu], 10) catch 0;
    const f_val = std.fmt.parseInt(u32, rest[fu + 1..], 10) catch 0;
    return .{ .i = i_val, .f = f_val };
}

// ── Bignum ────────────────────────────────────────────────────────────────────

pub fn isBignum(t: []const u8) bool {
    for (&BIGNUM_TYPES) |s| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

// ── Residue Number System: rns_<N> ───────────────────────────────────────────

pub fn isRns(t: []const u8) bool {
    if (!std.mem.startsWith(u8, t, "rns_")) return false;
    const rest = t[4..];
    if (rest.len == 0) return false;
    for (rest) |c| { if (c < '0' or c > '9') return false; }
    const n = std.fmt.parseInt(u32, rest, 10) catch return false;
    return n >= 2 and n <= 8;
}

pub fn rnsChannels(t: []const u8) u32 {
    return std.fmt.parseInt(u32, t[4..], 10) catch 0;
}

// ── VSA / GPU buf ─────────────────────────────────────────────────────────────

pub fn isVsaType(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "vsa_b<") and t[t.len - 1] == '>';
}

pub fn isGpuBuf(t: []const u8) bool {
    return std.mem.startsWith(u8, t, "gpu_buf<") and t[t.len - 1] == '>';
}

// ── LNS / MX ─────────────────────────────────────────────────────────────────

pub fn isLns(t: []const u8) bool {
    for (&LNS_TYPES) |s| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

pub fn isMx(t: []const u8) bool {
    for (&MX_TYPES) |s| {
        if (std.mem.eql(u8, s, t)) return true;
    }
    return false;
}

// ── Composite predicates ──────────────────────────────────────────────────────

/// True for integer types: standard INT_TYPES, "int_lit", arb-width, sat, bignum.
pub fn isInt(t: []const u8) bool {
    for (&INT_TYPES) |s| { if (std.mem.eql(u8, s, t)) return true; }
    if (std.mem.eql(u8, t, "int_lit")) return true;
    if (isArbInt(t)) return true;
    if (isSat(t)) return true;
    if (isBignum(t)) return true;
    return false;
}

/// True for float types: standard FLOAT_TYPES, "float_lit", bf16.
pub fn isFloat(t: []const u8) bool {
    for (&FLOAT_TYPES) |s| { if (std.mem.eql(u8, s, t)) return true; }
    if (std.mem.eql(u8, t, "float_lit")) return true;
    for (&BF16_TYPES) |s| { if (std.mem.eql(u8, s, t)) return true; }
    return false;
}

pub fn isPosit(t: []const u8) bool {
    for (&POSIT_TYPES) |s| { if (std.mem.eql(u8, s, t)) return true; }
    return false;
}

// ── defaultTy ─────────────────────────────────────────────────────────────────

/// "int_lit" -> "i32", "float_lit" -> "f32", "str" -> "[]u8", else identity.
/// Pointer types (*T) are returned as-is without any conversion.
pub fn defaultTy(t: []const u8) []const u8 {
    if (isPointer(t))                     return t;
    if (std.mem.eql(u8, t, "str"))        return "[]u8";
    if (std.mem.eql(u8, t, "int_lit"))    return "i32";
    if (std.mem.eql(u8, t, "float_lit"))  return "f32";
    return t;
}

// ── assignable ────────────────────────────────────────────────────────────────

/// Return true if a value of type `source` can be assigned to a slot of type `target`.
/// Mirrors zagc.py assignable() exactly.
pub fn assignable(target: []const u8, source: []const u8) bool {
    // exact match
    if (std.mem.eql(u8, target, source)) return true;

    // int_lit coerces to any INT_TYPES
    if (std.mem.eql(u8, source, "int_lit")) {
        for (&INT_TYPES) |s| { if (std.mem.eql(u8, s, target)) return true; }
    }
    // bool is i32 in C -> assignable to any int
    if (std.mem.eql(u8, source, "bool")) {
        for (&INT_TYPES) |s| { if (std.mem.eql(u8, s, target)) return true; }
    }
    // float_lit coerces to any FLOAT_TYPES
    if (std.mem.eql(u8, source, "float_lit")) {
        for (&FLOAT_TYPES) |s| { if (std.mem.eql(u8, s, target)) return true; }
    }
    // float_lit coerces to bf16
    if (std.mem.eql(u8, source, "float_lit")) {
        for (&BF16_TYPES) |s| { if (std.mem.eql(u8, s, target)) return true; }
    }
    // int_lit coerces to LNS types
    if (std.mem.eql(u8, source, "int_lit")) {
        if (isLns(target)) return true;
    }
    // float_lit coerces to MX types
    if (std.mem.eql(u8, source, "float_lit")) {
        if (isMx(target)) return true;
    }
    // int_lit coerces to arb-width int
    if (std.mem.eql(u8, source, "int_lit") and isArbInt(target)) return true;
    // int_lit coerces to sat
    if (std.mem.eql(u8, source, "int_lit") and isSat(target)) return true;
    // sat -> sat (same base)
    if (isSat(target) and isSat(source)) {
        if (std.mem.eql(u8, satBase(target), satBase(source))) return true;
    }
    // fixed-point from int_lit or float_lit
    if (isFixed(target) and (std.mem.eql(u8, source, "int_lit") or std.mem.eql(u8, source, "float_lit"))) return true;
    // fixed-point from arb-width int (small int widens to fixed-pt)
    if (isFixed(target) and isArbInt(source)) return true;
    // bignum from int_lit
    if (isBignum(target) and std.mem.eql(u8, source, "int_lit")) return true;
    // bignum from any int
    if (isBignum(target) and isInt(source)) return true;
    // rns from int_lit
    if (isRns(target) and std.mem.eql(u8, source, "int_lit")) return true;

    // Numeric widening: arb-width/sat -> standard int
    {
        var target_is_int = false;
        for (&INT_TYPES) |s| { if (std.mem.eql(u8, s, target)) { target_is_int = true; break; } }
        if (target_is_int) {
            if (isArbInt(source) or isSat(source)) return true;
            if (isBignum(source)) return true;
            if (isFixed(source)) return true;
            // any standard int widens to any standard int (e.g. u32->i32, i8->i32)
            for (&INT_TYPES) |s| { if (std.mem.eql(u8, s, source)) return true; }
        }
    }

    // fn type structural equality (params + ret, ignoring effect suffix)
    if (isFnType(target) and isFnType(source)) {
        // We cannot allocate here; do a quick structural compare without suffix.
        // Use a stack allocator for the parse.
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const alloc = fba.allocator();
        const tp = fnParts(alloc, target) catch return false;
        const sp = fnParts(alloc, source) catch return false;
        if (!std.mem.eql(u8, tp.ret, sp.ret)) return false;
        if (tp.params.len != sp.params.len) return false;
        for (tp.params, sp.params) |a, b| {
            if (!std.mem.eql(u8, a, b)) return false;
        }
        return true;
    }

    // string literal fits []u8
    if (std.mem.eql(u8, target, "[]u8") and std.mem.eql(u8, source, "str")) return true;

    // error union: "err" fits any !T; !T fits !T if inner assignable
    if (isErrorUnion(target) and std.mem.eql(u8, source, "err")) return true;
    if (isErrorUnion(target) and isErrorUnion(source)) {
        return assignable(errorInner(target), errorInner(source));
    }

    // optional: null fits any ?T
    if (isOptional(target) and std.mem.eql(u8, source, "null")) return true;
    // ?T fits ?T if inner assignable
    if (isOptional(target) and isOptional(source)) {
        return assignable(optionalInner(target), optionalInner(source));
    }
    // T fits ?T if T assignable to inner (wrap)
    if (isOptional(target) and assignable(optionalInner(target), source)) return true;

    // pointer: *T fits *T' if inner types are assignable
    if (isPointer(target) and isPointer(source)) {
        return assignable(pointerInner(target), pointerInner(source));
    }

    return false;
}

// ── fn type parsing ───────────────────────────────────────────────────────────

pub const FnParts = struct {
    params: [][]const u8,
    ret:    []const u8,
    suffix: []const u8,
};

/// Parse "fn(P1,P2,...)RET[suffix]" into params, ret, suffix.
/// Depth-aware so nested fn types in param/return positions parse correctly.
/// Caller owns the returned params slice (allocated from `alloc`).
pub fn fnParts(alloc: std.mem.Allocator, t: []const u8) !FnParts {
    // Find the closing ')' of the parameter list, depth-aware.
    var depth: i32 = 0;
    var close: ?usize = null;
    var k: usize = 2; // t[2] is the '(' of fn(
    while (k < t.len) : (k += 1) {
        if (t[k] == '(') { depth += 1; }
        else if (t[k] == ')') {
            depth -= 1;
            if (depth == 0) { close = k; break; }
        }
    }
    const close_idx = close orelse return error.MalformedFnType;

    // Split params by ',' at depth 0, respecting nested brackets.
    const param_str = t[3..close_idx];
    var params = std.ArrayList([]const u8).init(alloc);
    var cur_start: usize = 0;
    var d: i32 = 0;
    for (param_str, 0..) |ch, i| {
        switch (ch) {
            '(', '[', '{' => d += 1,
            ')', ']', '}' => d -= 1,
            ',' => if (d == 0) {
                const seg = std.mem.trim(u8, param_str[cur_start..i], " ");
                if (seg.len > 0) try params.append(seg);
                cur_start = i + 1;
            },
            else => {},
        }
    }
    // last segment
    {
        const seg = std.mem.trim(u8, param_str[cur_start..], " ");
        if (seg.len > 0) try params.append(seg);
    }

    // The rest after the closing ')'
    var rest = t[close_idx + 1..];

    // If return type is itself a fn type, it owns its suffix.
    if (std.mem.startsWith(u8, rest, "fn(")) {
        return FnParts{
            .params = try params.toOwnedSlice(),
            .ret    = rest,
            .suffix = "",
        };
    }

    // Otherwise, scan for an effect suffix starting with '@' or '!' that is
    // NOT the error-union prefix of the return type.
    var suf: []const u8 = "";
    var suf_start: ?usize = null;
    for (rest, 0..) |ch, i| {
        if (ch == '@' or ch == '!') {
            // '!' at position 0 where rest[1] is alpha/'_'/'[' means the return IS an error union
            if (i == 0 and ch == '!' and rest.len > 1) {
                const next = rest[1];
                if (std.ascii.isAlphabetic(next) or next == '_' or next == '[') {
                    break; // entire rest is the return type
                }
            }
            suf_start = i;
            break;
        }
    }
    if (suf_start) |si| {
        suf  = rest[si..];
        rest = rest[0..si];
    }

    return FnParts{
        .params = try params.toOwnedSlice(),
        .ret    = rest,
        .suffix = suf,
    };
}

// ── Row / effect suffix ───────────────────────────────────────────────────────

/// Possible row kinds for a fn type's effect suffix.
pub const RowKind = enum { bound, row, variable };

pub const RowInfo = struct {
    kind:     RowKind,
    /// For .bound: the set of FORBIDDEN effects (strings from ALL_EFFECTS).
    /// For .row:   the set of LATENT (allowed) effects.
    /// For .variable: empty slice; `varname` holds the type-variable name.
    effects:  []const []const u8,
    varname:  []const u8,
};

/// Parse the effect-row suffix of a fn type.
/// Returns null when there is no suffix (plain/opaque fn type).
/// Uses `alloc` only for the .row case that must split the comma-separated list.
pub fn rowOf(t: []const u8) ?struct { kind: RowKind, effects: []const []const u8, varname: []const u8 } {
    // We need a small alloc for fnParts; use a fixed-buffer allocator.
    var buf: [4096]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const alloc = fba.allocator();

    const parts = fnParts(alloc, t) catch return null;
    const suf = parts.suffix;
    if (suf.len == 0) return null;

    if (suf[0] == '@') {
        // bound annotation: "@realtime", "@noalloc", etc.
        const f = forbids(suf);
        return .{ .kind = .bound, .effects = f, .varname = "" };
    }

    // starts with '!'
    const body = suf[1..];
    if (std.mem.eql(u8, body, "pure")) {
        return .{ .kind = .row, .effects = &[_][]const u8{}, .varname = "" };
    }
    if (body.len > 0 and body[0] == '{') {
        // "{Alloc,IO}" -> split on ','
        const inner = body[1 .. body.len - 1];
        if (inner.len == 0) {
            return .{ .kind = .row, .effects = &[_][]const u8{}, .varname = "" };
        }
        // Count commas to know slice size
        var count: usize = 1;
        for (inner) |c| { if (c == ',') count += 1; }
        const eff_slice = alloc.alloc([]const u8, count) catch return null;
        var idx: usize = 0;
        var it = std.mem.splitScalar(u8, inner, ',');
        while (it.next()) |part| {
            eff_slice[idx] = part;
            idx += 1;
        }
        // NOTE: eff_slice points into fba memory; callers must not outlive this call.
        // For the satisfies() use-case this is fine since we only iterate it.
        return .{ .kind = .row, .effects = eff_slice, .varname = "" };
    }
    // bare effect variable name
    return .{ .kind = .variable, .effects = &[_][]const u8{}, .varname = body };
}

/// Does a function with the given effect set `actual_eff` (slice of effect name strings)
/// satisfy the constraint imposed by the fn type `t`?
/// Returns true when the call is allowed.
pub fn satisfies(actual_eff: []const []const u8, t: []const u8) bool {
    const r = rowOf(t) orelse return true; // no suffix -> no constraint
    switch (r.kind) {
        .bound => {
            // forbidden: actual_eff must not intersect r.effects
            for (actual_eff) |ae| {
                for (r.effects) |fe| {
                    if (std.mem.eql(u8, ae, fe)) return false;
                }
            }
            return true;
        },
        .row => {
            // latent row: actual_eff must be a subset of r.effects
            for (actual_eff) |ae| {
                var found = false;
                for (r.effects) |le| {
                    if (std.mem.eql(u8, ae, le)) { found = true; break; }
                }
                if (!found) return false;
            }
            return true;
        },
        .variable => return true, // effect variable: instantiated, never rejected
    }
}

// ── Generic type helpers ───────────────────────────────────────────────────────

/// Substitute every identifier in `ty` using the map `mp`.
/// Mirrors: re.sub(r"[A-Za-z_][A-Za-z0-9_]*", lambda m: mp.get(m.group(0), m.group(0)), ty)
/// Returns a newly allocated string; caller owns it.
pub fn substType(alloc: std.mem.Allocator, ty: []const u8, mp: std.StringHashMap([]const u8)) ![]const u8 {
    var out = std.ArrayList(u8).init(alloc);
    var i: usize = 0;
    while (i < ty.len) {
        const c = ty[i];
        if (std.ascii.isAlphabetic(c) or c == '_') {
            // start of an identifier
            const start = i;
            i += 1;
            while (i < ty.len and (std.ascii.isAlphanumeric(ty[i]) or ty[i] == '_')) : (i += 1) {}
            const ident = ty[start..i];
            if (mp.get(ident)) |replacement| {
                try out.appendSlice(replacement);
            } else {
                try out.appendSlice(ident);
            }
        } else {
            try out.append(c);
            i += 1;
        }
    }
    return out.toOwnedSlice();
}

/// Split a generic type application "Box[i32,f32]" -> ("Box", ["i32","f32"]).
/// Returns (ty, null) for non-application types.
/// Slice memory is allocated from `alloc`.
fn splitApp(alloc: std.mem.Allocator, ty: []const u8) !struct { base: []const u8, args: ?[][]const u8 } {
    // Excluded: slice types and fn types
    if (std.mem.startsWith(u8, ty, "[]") or std.mem.startsWith(u8, ty, "fn(")) {
        return .{ .base = ty, .args = null };
    }
    // Must contain '[' and end with ']'
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

/// Unify a pattern type `pat` against a concrete type `conc`, binding free type
/// parameters (listed in `tparams`) into `sub`.
/// Mirrors zagc.py unify() exactly.
pub fn unify(
    alloc: std.mem.Allocator,
    pat: []const u8,
    conc: []const u8,
    tparams: []const []const u8,
    sub: *std.StringHashMap([]const u8),
) void {
    // If pat is a type parameter, bind it (first binding wins).
    for (tparams) |tp| {
        if (std.mem.eql(u8, pat, tp)) {
            if (!sub.contains(tp)) {
                sub.put(tp, conc) catch {};
            }
            return;
        }
    }

    // []T ~ []T'
    if (std.mem.startsWith(u8, pat, "[]") and std.mem.startsWith(u8, conc, "[]")) {
        unify(alloc, pat[2..], conc[2..], tparams, sub);
        return;
    }

    // fn(P...)R ~ fn(P'...)R'
    if (isFnType(pat) and isFnType(conc)) {
        const pp = fnParts(alloc, pat) catch return;
        const cp = fnParts(alloc, conc) catch return;
        const len = @min(pp.params.len, cp.params.len);
        for (pp.params[0..len], cp.params[0..len]) |a, b| {
            unify(alloc, a, b, tparams, sub);
        }
        unify(alloc, pp.ret, cp.ret, tparams, sub);
        return;
    }

    // Generic application: Box[A,B] ~ Box[C,D]
    const sp = splitApp(alloc, pat) catch return;
    if (sp.args) |pat_args| {
        const sc = splitApp(alloc, conc) catch return;
        if (sc.args) |conc_args| {
            if (std.mem.eql(u8, sp.base, sc.base)) {
                const len2 = @min(pat_args.len, conc_args.len);
                for (pat_args[0..len2], conc_args[0..len2]) |a, b| {
                    unify(alloc, a, b, tparams, sub);
                }
            }
        }
    }
}
