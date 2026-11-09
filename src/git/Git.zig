//! Git access by running the `git` CLI: the repository root and the HEAD
//! version of a file. Everything git-related is off outside a repository.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The top level of the repository containing `dir`, or null if none (or git
/// is not installed). Caller frees.
pub fn repoRoot(gpa: Allocator, io: Io, dir: []const u8) ?[]u8 {
    const out = run(gpa, io, &.{ "git", "-C", dir, "rev-parse", "--show-toplevel" }) orelse return null;
    defer gpa.free(out);
    const root = std.mem.trimEnd(u8, out, "\n");
    if (root.len == 0) return null;
    return gpa.dupe(u8, root) catch null;
}

/// The content of `abs_path` at HEAD, or null if it isn't tracked there (new
/// or untracked file, no commits yet). Caller frees.
pub fn headVersion(gpa: Allocator, io: Io, root: []const u8, abs_path: []const u8) ?[]u8 {
    if (!std.mem.startsWith(u8, abs_path, root) or abs_path.len <= root.len + 1) return null;
    const rel = abs_path[root.len + 1 ..];
    const spec = std.fmt.allocPrint(gpa, "HEAD:{s}", .{rel}) catch return null;
    defer gpa.free(spec);
    return run(gpa, io, &.{ "git", "-C", root, "show", spec });
}

/// Local branch names (current first). Caller frees the list and names.
pub fn branches(gpa: Allocator, io: Io, root: []const u8) ?Branches {
    const out = run(gpa, io, &.{ "git", "-C", root, "branch", "--format=%(HEAD)%(refname:short)" }) orelse return null;
    return .{ .raw = out };
}

pub const Branches = struct {
    raw: []u8,

    pub fn deinit(b: Branches, gpa: Allocator) void {
        gpa.free(b.raw);
    }

    /// Each line: '*' (current) or ' ', then the name.
    pub fn iterator(b: Branches) std.mem.SplitIterator(u8, .scalar) {
        return std.mem.splitScalar(u8, b.raw, '\n');
    }
};

/// `git status --porcelain` output: "XY path" lines. Caller frees.
pub fn status(gpa: Allocator, io: Io, root: []const u8) ?[]u8 {
    return run(gpa, io, &.{ "git", "-C", root, "status", "--porcelain=v1", "--untracked-files=all" });
}

/// A friendly word for a porcelain status code.
pub fn describeStatus(code: []const u8) []const u8 {
    if (std.mem.eql(u8, code, "??")) return "new";
    for (code) |c| switch (c) {
        'M' => return "modified",
        'A' => return "added",
        'D' => return "deleted",
        'R' => return "renamed",
        'U' => return "conflict",
        else => {},
    };
    return "changed";
}

/// The URL of remote `origin`, if set. Caller frees.
pub fn originUrl(gpa: Allocator, io: Io, root: []const u8) ?[]u8 {
    const out = run(gpa, io, &.{ "git", "-C", root, "remote", "get-url", "origin" }) orelse return null;
    defer gpa.free(out);
    return gpa.dupe(u8, std.mem.trimEnd(u8, out, "\n")) catch null;
}

/// stdout of a successful run, else null.
fn run(gpa: Allocator, io: Io, argv: []const []const u8) ?[]u8 {
    const result = std.process.run(gpa, io, .{ .argv = argv, .stdout_limit = .limited(64 * 1024 * 1024) }) catch return null;
    gpa.free(result.stderr);
    if (!result.term.success()) {
        gpa.free(result.stdout);
        return null;
    }
    return result.stdout;
}

/// Normalizes HEAD text the way `Buffer.load` normalizes files: CRLF -> LF
/// and no final newline. Returns a slice of `raw` or an owned copy in `buf`.
pub fn normalize(gpa: Allocator, raw: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, raw.len);
    errdefer out.deinit(gpa);
    var i: usize = 0;
    while (i < raw.len) : (i += 1) {
        if (raw[i] == '\r' and i + 1 < raw.len and raw[i + 1] == '\n') continue;
        out.appendAssumeCapacity(raw[i]);
    }
    if (out.items.len > 0 and out.items[out.items.len - 1] == '\n') out.items.len -= 1;
    return out.toOwnedSlice(gpa);
}

test "normalize" {
    const gpa = std.testing.allocator;
    const n = try normalize(gpa, "a\r\nb\n");
    defer gpa.free(n);
    try std.testing.expectEqualStrings("a\nb", n);
}
