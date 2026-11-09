//! The code runner's memory: the last command run in each project, kept in
//! `$XDG_STATE_HOME/zile/run-commands` (default `~/.local/state/...`) as
//! "<project dir>\t<command>" lines, so it survives restarts.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The state file's path, or null without $HOME. Caller frees.
pub fn defaultPath(gpa: Allocator) ?[]u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |s| {
        const dir = std.mem.span(s);
        if (dir.len > 0) return std.fs.path.join(gpa, &.{ dir, "zile", "run-commands" }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "zile", "run-commands" }) catch null;
}

/// The command last run in `project`, if any. Caller frees.
pub fn load(gpa: Allocator, io: Io, path: []const u8, project: []const u8) ?[]u8 {
    return loadFrom(gpa, io, path, project);
}

/// Remembers `command` for `project` (best effort).
pub fn save(gpa: Allocator, io: Io, path: []const u8, project: []const u8, command: []const u8) void {
    saveTo(gpa, io, path, project, command) catch {};
}

fn loadFrom(gpa: Allocator, io: Io, path: []const u8, project: []const u8) ?[]u8 {
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return null;
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (std.mem.eql(u8, line[0..tab], project)) return gpa.dupe(u8, line[tab + 1 ..]) catch null;
    }
    return null;
}

fn saveTo(gpa: Allocator, io: Io, path: []const u8, project: []const u8, command: []const u8) !void {
    // Commands are one line; projects never contain tabs or newlines in practice.
    if (std.mem.indexOfAny(u8, command, "\n") != null) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    try out.print(gpa, "{s}\t{s}\n", .{ project, command });
    if (Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(1 << 20))) |old| {
        defer gpa.free(old);
        var lines = std.mem.splitScalar(u8, old, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, line[0..tab], project)) continue;
            try out.print(gpa, "{s}\n", .{line});
        }
    } else |_| {}
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

test "remembers one command per project" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "state", "run-commands" });
    defer gpa.free(path);

    try std.testing.expectEqual(null, loadFrom(gpa, io, path, "/a"));
    try saveTo(gpa, io, path, "/a", "zig build run");
    try saveTo(gpa, io, path, "/b", "cargo test");
    try saveTo(gpa, io, path, "/a", "zig build test");
    const a = loadFrom(gpa, io, path, "/a").?;
    defer gpa.free(a);
    try std.testing.expectEqualStrings("zig build test", a);
    const b = loadFrom(gpa, io, path, "/b").?;
    defer gpa.free(b);
    try std.testing.expectEqualStrings("cargo test", b);
}
