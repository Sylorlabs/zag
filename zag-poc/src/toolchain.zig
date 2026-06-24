// toolchain.zig — Immutable lockfile toolchains (`zag.mod`).
//
// Complaint #4 ("the no-indicator versioning trap"): a project written for an
// older compiler silently fails to build, and nothing in the project records
// *which* compiler it was written for.  Zag's answer is a NON-OPTIONAL project
// manifest, `zag.mod`, that pins:
//
//   * the compiler version range the project is known to build under,
//   * the language *edition* (the syntax/semantics contract), and
//   * the set of compiler features the project relies on.
//
// The compiler discovers `zag.mod` by walking up from the source file, parses
// it, and ENFORCES it before a single token is lowered.  A version/edition
// mismatch is a hard error with an actionable message — never a mysterious
// parse failure 2000 lines deep.
//
// Format (a tiny, deterministic INI-with-arrays — intentionally trivial to
// parse so the lockfile itself can never drift across editions):
//
//   name = "myproject"
//   [toolchain]
//   zag     = "^0.1.0"      # version constraint: ^  >=  >  <=  <  =  (or bare = exact)
//   edition = "phase0"      # must equal the compiler's edition
//   commit  = "poc-phase0"  # optional: pin to an exact build tag
//   [features]
//   require = ["effects", "interfaces", "hotreload"]

const std = @import("std");
const version = @import("version.zig");

pub const MANIFEST_NAME = "zag.mod";

pub const Manifest = struct {
    path: []const u8, // absolute path the manifest was loaded from
    name: []const u8 = "(unnamed)",
    zag_constraint: ?[]const u8 = null,
    edition: ?[]const u8 = null,
    commit: ?[]const u8 = null,
    require_features: [][]const u8 = &.{},
};

pub const Outcome = struct {
    /// true when the build may proceed.
    ok: bool,
    /// null when no zag.mod was found.
    manifest: ?Manifest,
    /// human-readable problems (empty when ok).
    problems: []const []const u8,
    /// true when a manifest was located and parsed.
    found: bool,
};

// ── Discovery ──────────────────────────────────────────────────────────────

/// Walk up from `start_dir` (absolute) to the filesystem root, returning the
/// absolute path of the first `zag.mod` found, or null.
pub fn discover(alloc: std.mem.Allocator, start_dir: []const u8) ?[]const u8 {
    var dir: []const u8 = start_dir;
    while (true) {
        const candidate = std.fs.path.join(alloc, &.{ dir, MANIFEST_NAME }) catch return null;
        if (std.fs.cwd().access(candidate, .{})) |_| {
            return candidate;
        } else |_| {}
        const parent = std.fs.path.dirname(dir) orelse return null;
        if (std.mem.eql(u8, parent, dir)) return null; // reached root
        dir = parent;
    }
}

// ── Parsing ────────────────────────────────────────────────────────────────

/// Strip a trailing/leading comment introduced by '#' that is not inside a
/// double-quoted string.  Returns the un-commented slice.
fn stripComment(line: []const u8) []const u8 {
    var in_str = false;
    for (line, 0..) |c, i| {
        if (c == '"') in_str = !in_str;
        if (c == '#' and !in_str) return line[0..i];
    }
    return line;
}

/// Remove surrounding double quotes if present.
fn unquote(v: []const u8) []const u8 {
    const t = std.mem.trim(u8, v, " \t");
    if (t.len >= 2 and t[0] == '"' and t[t.len - 1] == '"') return t[1 .. t.len - 1];
    return t;
}

/// Parse a `["a", "b"]` array literal into owned slices.
fn parseArray(alloc: std.mem.Allocator, v: []const u8) ![][]const u8 {
    var out = std.ArrayList([]const u8).init(alloc);
    const t = std.mem.trim(u8, v, " \t");
    if (t.len < 2 or t[0] != '[' or t[t.len - 1] != ']') return out.toOwnedSlice();
    const inner = t[1 .. t.len - 1];
    var it = std.mem.splitScalar(u8, inner, ',');
    while (it.next()) |raw| {
        const item = unquote(raw);
        if (item.len > 0) try out.append(try alloc.dupe(u8, item));
    }
    return out.toOwnedSlice();
}

pub fn parse(alloc: std.mem.Allocator, path: []const u8) !Manifest {
    const text = try std.fs.cwd().readFileAlloc(alloc, path, 1 * 1024 * 1024);
    var m = Manifest{ .path = try alloc.dupe(u8, path) };

    var section: []const u8 = "";
    var line_it = std.mem.splitScalar(u8, text, '\n');
    while (line_it.next()) |raw_line| {
        const line = std.mem.trim(u8, stripComment(raw_line), " \t\r");
        if (line.len == 0) continue;

        if (line[0] == '[' and line[line.len - 1] == ']') {
            section = std.mem.trim(u8, line[1 .. line.len - 1], " \t");
            continue;
        }

        const eq = std.mem.indexOfScalar(u8, line, '=') orelse continue;
        const key = std.mem.trim(u8, line[0..eq], " \t");
        const val = std.mem.trim(u8, line[eq + 1 ..], " \t");

        if (std.mem.eql(u8, section, "") and std.mem.eql(u8, key, "name")) {
            m.name = try alloc.dupe(u8, unquote(val));
        } else if (std.mem.eql(u8, section, "toolchain")) {
            if (std.mem.eql(u8, key, "zag")) {
                m.zag_constraint = try alloc.dupe(u8, unquote(val));
            } else if (std.mem.eql(u8, key, "edition")) {
                m.edition = try alloc.dupe(u8, unquote(val));
            } else if (std.mem.eql(u8, key, "commit")) {
                m.commit = try alloc.dupe(u8, unquote(val));
            }
        } else if (std.mem.eql(u8, section, "features")) {
            if (std.mem.eql(u8, key, "require")) {
                m.require_features = try parseArray(alloc, val);
            }
        }
    }
    return m;
}

// ── Version constraint satisfaction ─────────────────────────────────────────

/// Does the compiler's version satisfy `constraint`?  Supports a single
/// comparator clause: `^`, `>=`, `>`, `<=`, `<`, `=`, or a bare version (exact).
pub fn satisfies(constraint: []const u8, have: version.SemVer) bool {
    const c = std.mem.trim(u8, constraint, " \t");
    if (c.len == 0) return true;

    if (std.mem.startsWith(u8, c, "^")) {
        const want = version.SemVer.parse(c[1..]) orelse return false;
        // Caret: >= want, and within the same "breaking" band.
        // For 0.x, the minor is the breaking axis (0.1.z compatible, 0.2 not).
        // For >=1, the major is the breaking axis.
        if (have.order(want) < 0) return false;
        if (want.major == 0) return have.major == 0 and have.minor == want.minor;
        return have.major == want.major;
    }
    if (std.mem.startsWith(u8, c, ">=")) {
        const want = version.SemVer.parse(c[2..]) orelse return false;
        return have.order(want) >= 0;
    }
    if (std.mem.startsWith(u8, c, "<=")) {
        const want = version.SemVer.parse(c[2..]) orelse return false;
        return have.order(want) <= 0;
    }
    if (std.mem.startsWith(u8, c, ">")) {
        const want = version.SemVer.parse(c[1..]) orelse return false;
        return have.order(want) > 0;
    }
    if (std.mem.startsWith(u8, c, "<")) {
        const want = version.SemVer.parse(c[1..]) orelse return false;
        return have.order(want) < 0;
    }
    if (std.mem.startsWith(u8, c, "=")) {
        const want = version.SemVer.parse(c[1..]) orelse return false;
        return have.order(want) == 0;
    }
    // bare version → exact
    const want = version.SemVer.parse(c) orelse return false;
    return have.order(want) == 0;
}

// ── Enforcement ──────────────────────────────────────────────────────────────

/// Discover and enforce the manifest governing `start_dir`.
/// `locked` makes a *missing* manifest a hard error (CI / reproducible-build mode).
pub fn enforce(alloc: std.mem.Allocator, start_dir: []const u8, locked: bool) Outcome {
    var problems = std.ArrayList([]const u8).init(alloc);

    const path = discover(alloc, start_dir) orelse {
        if (locked) {
            problems.append(
                "no zag.mod found (and --locked was given): every Zag project must pin its toolchain. Run `zagc init`.",
            ) catch {};
            return .{ .ok = false, .manifest = null, .problems = problems.toOwnedSlice() catch &.{}, .found = false };
        }
        return .{ .ok = true, .manifest = null, .problems = &.{}, .found = false };
    };

    const m = parse(alloc, path) catch {
        problems.append(std.fmt.allocPrint(alloc, "zag.mod at '{s}' could not be parsed", .{path}) catch "zag.mod parse error") catch {};
        return .{ .ok = false, .manifest = null, .problems = problems.toOwnedSlice() catch &.{}, .found = true };
    };

    const have = version.current();

    // 1. Version constraint.
    if (m.zag_constraint) |constraint| {
        if (!satisfies(constraint, have)) {
            problems.append(std.fmt.allocPrint(alloc,
                "this project pins zag = \"{s}\", but this compiler is {s} (edition {s}). " ++
                    "Install a matching zagc, or update the [toolchain] constraint in zag.mod.",
                .{ constraint, version.ZAG_VERSION, version.ZAG_EDITION },
            ) catch "version mismatch") catch {};
        }
    }

    // 2. Edition contract.  A mismatched edition means the parser rules this
    //    compiler implements are not the ones the source was authored against.
    if (m.edition) |ed| {
        if (!std.mem.eql(u8, ed, version.ZAG_EDITION)) {
            problems.append(std.fmt.allocPrint(alloc,
                "this project targets language edition '{s}', but this compiler implements edition '{s}'. " ++
                    "Editions are a hard compatibility boundary — use a zagc that speaks '{s}'.",
                .{ ed, version.ZAG_EDITION, ed },
            ) catch "edition mismatch") catch {};
        }
    }

    // 3. Feature forward-compat guard.
    for (m.require_features) |feat| {
        if (!version.hasFeature(feat)) {
            problems.append(std.fmt.allocPrint(alloc,
                "this project requires compiler feature '{s}', which this zagc does not implement.",
                .{feat},
            ) catch "missing feature") catch {};
        }
    }

    const probs = problems.toOwnedSlice() catch &.{};
    return .{ .ok = probs.len == 0, .manifest = m, .problems = probs, .found = true };
}

// ── `zagc init` template ─────────────────────────────────────────────────────

/// Render a fresh zag.mod pinned to *this* compiler.  Caller owns the result.
pub fn renderInit(alloc: std.mem.Allocator, project_name: []const u8) ![]const u8 {
    const have = version.current();
    return std.fmt.allocPrint(alloc,
        \\# zag.mod — Zag project lockfile (REQUIRED at project root).
        \\# Generated by `zagc init`. Pins the toolchain this project builds under,
        \\# so a future zagc can refuse to silently miscompile legacy sources.
        \\name = "{s}"
        \\
        \\[toolchain]
        \\# Caret constraint: any compatible compiler within the 0.{d} series.
        \\zag     = "^{d}.{d}.{d}"
        \\# Language edition — the syntax/semantics contract. Hard compatibility boundary.
        \\edition = "{s}"
        \\# Exact build this lockfile was generated against (informational pin).
        \\commit  = "{s}"
        \\
        \\[features]
        \\# Compiler capabilities this project relies on. Build fails fast if a
        \\# future/older zagc cannot honor one of these.
        \\require = ["effects", "generics", "interfaces", "hotreload"]
        \\
    , .{
        project_name,
        have.minor,
        have.major, have.minor, have.patch,
        version.ZAG_EDITION,
        version.ZAG_COMMIT,
    });
}
