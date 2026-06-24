// version.zig — single source of truth for the compiler's identity.
//
// Every part of the toolchain that needs to know "which zagc is this" reads
// from here: the lockfile enforcer (toolchain.zig), the JSON diagnostics
// emitter (jsonout.zig), and the CLI driver (main.zig).

const std = @import("std");

/// Semantic version of this compiler build.  Bump on every release.
pub const ZAG_VERSION = "0.1.0";

/// Language edition — the *syntax/semantics contract* a source file is written
/// against.  A project's zag.mod pins the edition it was authored for; the
/// compiler refuses to build a project whose edition it does not implement,
/// rather than silently miscompiling legacy syntax (complaint #4).
pub const ZAG_EDITION = "phase0";

/// Build commit / channel tag.  Surfaced in JSON output and `zagc version`
/// so tooling can pin to an exact build, not just a semver range.
pub const ZAG_COMMIT = "poc-phase0";

/// Feature capabilities this compiler implements.  A zag.mod may request a
/// `features = [...]` set; we reject the build up front if it asks for a
/// capability this binary cannot honor (forward-compat guard).
pub const ZAG_FEATURES = [_][]const u8{
    "effects", // compiler-proven @realtime/@noalloc/@total/@pure capability system
    "generics", // monomorphized generic fns + structs
    "interfaces", // compile-time structural duck typing (vtable lowering)
    "hotreload", // runtime function-pointer patching
    "json-diagnostics", // structured machine-readable diagnostics
    "mlir-gpu", // MLIR GPU backend
};

/// Parsed semantic version (major.minor.patch). Pre-release/build metadata
/// after a '-' or '+' is ignored for ordering purposes.
pub const SemVer = struct {
    major: u32,
    minor: u32,
    patch: u32,

    pub fn parse(text: []const u8) ?SemVer {
        // Trim a leading 'v' and anything from the first '-'/'+'.
        var t = std.mem.trim(u8, text, " \t");
        if (t.len > 0 and (t[0] == 'v' or t[0] == 'V')) t = t[1..];
        if (std.mem.indexOfAny(u8, t, "-+")) |cut| t = t[0..cut];

        var it = std.mem.splitScalar(u8, t, '.');
        const maj = it.next() orelse return null;
        const major = std.fmt.parseInt(u32, maj, 10) catch return null;
        const minor = blk: {
            const m = it.next() orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, m, 10) catch return null;
        };
        const patch = blk: {
            const p = it.next() orelse break :blk 0;
            break :blk std.fmt.parseInt(u32, p, 10) catch return null;
        };
        return .{ .major = major, .minor = minor, .patch = patch };
    }

    /// -1 if a<b, 0 if equal, 1 if a>b.
    pub fn order(a: SemVer, b: SemVer) i32 {
        if (a.major != b.major) return if (a.major < b.major) -1 else 1;
        if (a.minor != b.minor) return if (a.minor < b.minor) -1 else 1;
        if (a.patch != b.patch) return if (a.patch < b.patch) -1 else 1;
        return 0;
    }
};

/// The compiler's own version, pre-parsed.
pub fn current() SemVer {
    return SemVer.parse(ZAG_VERSION).?;
}

pub fn hasFeature(name: []const u8) bool {
    for (ZAG_FEATURES) |f| {
        if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}
