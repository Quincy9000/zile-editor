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
const markers = [_][]const u8{ "build.zig", "Cargo.toml", "go.mod", "package.json", "pyproject.toml", "CMakeLists.txt", "Makefile" };

pub const Found = struct { root: []const u8, git: bool };

/// The project folder containing `dir` (absolute), or null. Returns a slice
/// of `dir`.
pub fn detect(io: Io, dir: []const u8) ?Found {
    // Git wins over build files further down (a monorepo is one project).
    var d: ?[]const u8 = dir;
    while (d) |p| : (d = std.fs.path.dirname(p)) {
        if (has(io, p, ".git")) return .{ .root = p, .git = true };
    }
    d = dir;
    while (d) |p| : (d = std.fs.path.dirname(p)) {
        for (markers) |m| if (has(io, p, m)) return .{ .root = p, .git = false };
    }
    return null;
}

fn has(io: Io, dir: []const u8, entry: []const u8) bool {
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const path = std.fmt.bufPrint(&buf, "{s}/{s}", .{ if (std.mem.eql(u8, dir, "/")) "" else dir, entry }) catch return false;
    Io.Dir.cwd().access(io, path, .{}) catch return false;
    return true;
}

test "detects git roots before build files, walking up" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.createDirPath(io, "repo/.git");
    try tmp.dir.createDirPath(io, "repo/sub/crate/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "repo/sub/crate/Cargo.toml", .data = "" });
    try tmp.dir.createDirPath(io, "plain/pkg/src");
    try tmp.dir.writeFile(io, .{ .sub_path = "plain/pkg/build.zig", .data = "" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    var p: [Io.Dir.max_path_bytes]u8 = undefined;

    const in_repo = detect(io, try std.fmt.bufPrint(&p, "{s}/repo/sub/crate/src", .{base})).?;
    try std.testing.expect(in_repo.git);
    try std.testing.expect(std.mem.endsWith(u8, in_repo.root, "/repo"));

    const plain = detect(io, try std.fmt.bufPrint(&p, "{s}/plain/pkg/src", .{base})).?;
    try std.testing.expect(!plain.git);
    try std.testing.expect(std.mem.endsWith(u8, plain.root, "/plain/pkg"));
}
