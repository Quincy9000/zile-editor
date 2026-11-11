//! Projects: the folder a file belongs to. The nearest folder above it with
//! `.git` (a directory, or a file for worktrees and submodules); without
//! git, the nearest with a build file; else none (the editor falls back to
//! where it was started). Pickers, the runner, git and language servers all
//! work in the current window's project.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Project = @This();

/// Absolute, no trailing slash. Owned by the editor's project list, which
/// outlives buffers, so buffers can keep a plain pointer.
root: []u8,
/// It is a git repository (the git menu and ghost lines work here).
git: bool,

pub fn name(p: *const Project) []const u8 {
    return std.fs.path.basename(p.root);
}

/// Build files that mark a project root when there is no git.
pub const markers = [_][]const u8{ "build.zig", "Cargo.toml", "go.mod", "package.json", "pyproject.toml", "CMakeLists.txt", "Makefile" };

pub const Found = struct { root: []const u8, git: bool };

/// The project folder containing `dir` (absolute), or null. Returns a slice
/// of `dir`.
pub fn detect(io: Io, dir: []const u8) ?Found {
    return detectIn(io, dir, has);
}

/// `detect` with the "does `dir/entry` exist" check passed in, so the walk
/// can be tested without touching the disk.
fn detectIn(ctx: anytype, dir: []const u8, comptime exists: fn (@TypeOf(ctx), []const u8, []const u8) bool) ?Found {
    // Git wins over build files further down (a monorepo is one project).
    var d: ?[]const u8 = dir;
    while (d) |p| : (d = std.fs.path.dirname(p)) {
        if (exists(ctx, p, ".git")) return .{ .root = p, .git = true };
    }
    d = dir;
    while (d) |p| : (d = std.fs.path.dirname(p)) {
        for (markers) |m| if (exists(ctx, p, m)) return .{ .root = p, .git = false };
    }
    return null;
}

fn has(io: Io, dir: []const u8, entry: []const u8) bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, entry }) catch return false;
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

/// A pretend filesystem for tests: the paths that exist.
const FakeFs = struct {
    paths: []const []const u8,
    fn has(fs: FakeFs, dir: []const u8, entry: []const u8) bool {
        for (fs.paths) |p| {
            if (p.len == dir.len + 1 + entry.len and std.mem.startsWith(u8, p, dir) and
                p[dir.len] == '/' and std.mem.endsWith(u8, p, entry)) return true;
        }
        return false;
    }
};

test "detects git roots before build files, walking up" {
    const fs: FakeFs = .{ .paths = &.{ "/w/repo/.git", "/w/repo/sub/crate/Cargo.toml", "/w/plain/pkg/build.zig" } };

    const in_repo = detectIn(fs, "/w/repo/sub/crate/src", FakeFs.has).?;
    try std.testing.expect(in_repo.git);
    try std.testing.expectEqualStrings("/w/repo", in_repo.root);

    const plain = detectIn(fs, "/w/plain/pkg/src", FakeFs.has).?;
    try std.testing.expect(!plain.git);
    try std.testing.expectEqualStrings("/w/plain/pkg", plain.root);

    try std.testing.expectEqual(null, detectIn(fs, "/elsewhere/dir", FakeFs.has));
}
