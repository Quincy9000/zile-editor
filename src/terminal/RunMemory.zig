//! The code runner's memory: the commands run in each project, kept in
//! `$XDG_STATE_HOME/zile/run-commands` (default `~/.local/state/...`) as
//! "<project dir>\t<command>" lines, oldest first, so it survives restarts.
//! A project's last line is its current command; the rest is its history.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

/// The state file's path, or null without $HOME. Caller frees.
pub fn defaultPath(gpa: Allocator) ?[]u8 {
    return statePath(gpa, "run-commands");
}

/// `$XDG_STATE_HOME/zile/<name>` (default `~/.local/state/zile/<name>`).
/// Caller frees.
pub fn statePath(gpa: Allocator, name: []const u8) ?[]u8 {
    if (std.c.getenv("XDG_STATE_HOME")) |s| {
        const dir = std.mem.span(s);
        if (dir.len > 0) return std.fs.path.join(gpa, &.{ dir, "zile", name }) catch null;
    }
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fs.path.join(gpa, &.{ home, ".local", "state", "zile", name }) catch null;
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
    var last: ?[]const u8 = null;
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        // The last line is the newest.
        if (std.mem.eql(u8, line[0..tab], project)) last = line[tab + 1 ..];
    }
    return gpa.dupe(u8, last orelse return null) catch null;
}

/// Commands kept per project; older ones are dropped.
const max_history = 100;
/// Lines in all (every project's): the oldest go beyond it.
const max_lines = 2000;

fn saveTo(gpa: Allocator, io: Io, path: []const u8, project: []const u8, command: []const u8) !void {
    try rewrite(gpa, io, path, project, command, true);
}

/// Drops `command` from `project`'s history (best effort).
pub fn forget(gpa: Allocator, io: Io, path: []const u8, project: []const u8, command: []const u8) void {
    rewrite(gpa, io, path, project, command, false) catch {};
}

/// Writes the file without `project`'s `command`, then (with `add`) with
/// it as that project's newest line.
fn rewrite(gpa: Allocator, io: Io, path: []const u8, project: []const u8, command: []const u8, add: bool) !void {
    // Commands are one line; projects never contain tabs or newlines in practice.
    if (std.mem.indexOfAny(u8, command, "\n") != null) return;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    const old: ?[]u8 = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch null;
    defer if (old) |o| gpa.free(o);
    if (old) |o| {
        // This project's lines beyond the limit go, oldest first.
        var mine: usize = 0;
        var count = std.mem.splitScalar(u8, o, '\n');
        while (count.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, line[0..tab], project) and !std.mem.eql(u8, line[tab + 1 ..], command)) mine += 1;
        }
        var skip = (mine + @intFromBool(add)) -| max_history;
        var lines = std.mem.splitScalar(u8, o, '\n');
        while (lines.next()) |line| {
            const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
            if (std.mem.eql(u8, line[0..tab], project)) {
                if (std.mem.eql(u8, line[tab + 1 ..], command)) continue;
                if (skip > 0) {
                    skip -= 1;
                    continue;
                }
            }
            try out.print(gpa, "{s}\n", .{line});
        }
    }
    if (add) try out.print(gpa, "{s}\t{s}\n", .{ project, command });
    // Oldest first in the file: what's over the limit is at the top.
    var lines_n = std.mem.count(u8, out.items, "\n");
    var start: usize = 0;
    while (lines_n > max_lines) : (lines_n -= 1) start = (std.mem.indexOfScalarPos(u8, out.items, start, '\n') orelse break) + 1;
    if (start > 0) {
        std.mem.copyForwards(u8, out.items, out.items[start..]);
        out.shrinkRetainingCapacity(out.items.len - start);
    }
    if (std.fs.path.dirname(path)) |dir| try Io.Dir.cwd().createDirPath(io, dir);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items });
}

/// Every command remembered for `project`, newest first. The caller frees
/// each one and the slice.
pub fn history(gpa: Allocator, io: Io, path: []const u8, project: []const u8) Allocator.Error![][]u8 {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |c| gpa.free(c);
        out.deinit(gpa);
    }
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return out.toOwnedSlice(gpa);
    defer gpa.free(data);
    var lines = std.mem.splitBackwardsScalar(u8, data, '\n');
    while (lines.next()) |line| {
        const tab = std.mem.indexOfScalar(u8, line, '\t') orelse continue;
        if (!std.mem.eql(u8, line[0..tab], project)) continue;
        const owned = try gpa.dupe(u8, line[tab + 1 ..]);
        errdefer gpa.free(owned);
        try out.append(gpa, owned);
    }
    return out.toOwnedSlice(gpa);
}

test "keeps each project's history, newest first, without repeats" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });
    defer gpa.free(path);
    for ([_][]const u8{ "one", "two", "three", "one" }) |c| try saveTo(gpa, io, path, "/a", c);
    try saveTo(gpa, io, path, "/b", "other");
    forget(gpa, io, path, "/a", "two");
    const h = try history(gpa, io, path, "/a");
    defer {
        for (h) |c| gpa.free(c);
        gpa.free(h);
    }
    try std.testing.expectEqual(2, h.len);
    try std.testing.expectEqualStrings("one", h[0]); // run again: moved to the front
    try std.testing.expectEqualStrings("three", h[1]);
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
