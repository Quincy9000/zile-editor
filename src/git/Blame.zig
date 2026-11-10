//! `git blame` of a file's HEAD version, run in the background: who last
//! changed each line, when, and the commit's summary. The editor maps buffer
//! lines to HEAD lines through its diff, so the result stays valid while the
//! buffer is edited.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Blame = @This();

pub const Commit = struct {
    sha: [40]u8,
    author: []const u8 = "",
    /// Unix seconds.
    time: i64 = 0,
    summary: []const u8 = "",
};

gpa: Allocator,
io: Io,
/// Owns the strings and the result.
arena: std.heap.ArenaAllocator,
root: []const u8,
/// Relative to `root`.
path: []const u8,
wake: *const fn () void,
thread: std.Thread = undefined,
done: std.atomic.Value(bool) = .init(false),
// Valid once `done`:
commits: []Commit = &.{},
/// For each HEAD line, an index into `commits`.
lines: []u32 = &.{},

pub fn start(gpa: Allocator, io: Io, root: []const u8, path: []const u8, wake: *const fn () void) !*Blame {
    const b = try gpa.create(Blame);
    errdefer gpa.destroy(b);
    b.* = .{ .gpa = gpa, .io = io, .arena = .init(gpa), .root = &.{}, .path = &.{}, .wake = wake };
    errdefer b.arena.deinit();
    const a = b.arena.allocator();
    b.root = try a.dupe(u8, root);
    b.path = try a.dupe(u8, path);
    b.thread = try std.Thread.spawn(.{}, run, .{b});
    return b;
}

pub fn destroy(b: *Blame) void {
    b.thread.join();
    b.arena.deinit();
    b.gpa.destroy(b);
}

/// The commit that last changed HEAD line `line` (0-based), once known.
pub fn at(b: *const Blame, line: usize) ?*const Commit {
    if (!b.done.load(.acquire) or line >= b.lines.len) return null;
    return &b.commits[b.lines[line]];
}

fn run(b: *Blame) void {
    defer {
        b.done.store(true, .release);
        b.wake();
    }
    const r = std.process.run(b.gpa, b.io, .{
        .argv = &.{ "git", "blame", "--porcelain", "HEAD", "--", b.path },
        .cwd = .{ .path = b.root },
    }) catch return;
    defer b.gpa.free(r.stdout);
    defer b.gpa.free(r.stderr);
    if (!r.term.success()) return;
    parse(b.arena.allocator(), r.stdout, &b.commits, &b.lines) catch {};
}

/// Parses `git blame --porcelain` output.
pub fn parse(a: Allocator, out: []const u8, commits_out: *[]Commit, lines_out: *[]u32) !void {
    var commits: std.ArrayList(Commit) = .empty;
    var lines: std.ArrayList(u32) = .empty;
    var current: u32 = 0;
    var it = std.mem.splitScalar(u8, out, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        if (line[0] == '\t') {
            // The line's text: the end of its group.
            try lines.append(a, current);
            continue;
        }
        if (line.len > 41 and line[40] == ' ' and isSha(line[0..40])) {
            current = for (commits.items, 0..) |c, i| {
                if (std.mem.eql(u8, &c.sha, line[0..40])) break @intCast(i);
            } else blk: {
                try commits.append(a, .{ .sha = line[0..40].* });
                break :blk @intCast(commits.items.len - 1);
            };
            continue;
        }
        if (commits.items.len == 0) continue;
        const c = &commits.items[current];
        if (value(line, "author ")) |v| c.author = try a.dupe(u8, v);
        if (value(line, "author-time ")) |v| c.time = std.fmt.parseInt(i64, v, 10) catch 0;
        if (value(line, "summary ")) |v| c.summary = try a.dupe(u8, v);
    }
    commits_out.* = commits.items;
    lines_out.* = lines.items;
}

fn value(line: []const u8, key: []const u8) ?[]const u8 {
    return if (std.mem.startsWith(u8, line, key)) line[key.len..] else null;
}

fn isSha(s: []const u8) bool {
    for (s) |c| if (!std.ascii.isHex(c)) return false;
    return true;
}

/// "3 days ago" for a time `seconds` in the past.
pub fn ago(buf: []u8, seconds: i64) []const u8 {
    const units = [_]struct { i64, []const u8 }{
        .{ 365 * 86400, "year" }, .{ 30 * 86400, "month" }, .{ 7 * 86400, "week" },
        .{ 86400, "day" },        .{ 3600, "hour" },        .{ 60, "minute" },
    };
    for (units) |u| if (seconds >= u[0]) {
        const n = @divTrunc(seconds, u[0]);
        return std.fmt.bufPrint(buf, "{d} {s}{s} ago", .{ n, u[1], if (n == 1) "" else "s" }) catch "";
    };
    return "just now";
}

test "porcelain blame: one commit entry per sha, one index per line" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const sha_a = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa";
    const sha_b = "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb";
    const out = sha_a ++ " 1 1 2\nauthor Ann\nauthor-time 100\nsummary first\nfilename f\n\tone\n" ++
        sha_a ++ " 2 2\n\ttwo\n" ++
        sha_b ++ " 1 3 1\nauthor Bob\nauthor-time 200\nsummary second one\nfilename f\n\tthree\n";
    var commits: []Commit = &.{};
    var lines: []u32 = &.{};
    try parse(arena.allocator(), out, &commits, &lines);
    try std.testing.expectEqual(2, commits.len);
    try std.testing.expectEqualSlices(u32, &.{ 0, 0, 1 }, lines);
    try std.testing.expectEqualStrings("Bob", commits[1].author);
    try std.testing.expectEqualStrings("second one", commits[1].summary);
    var buf: [32]u8 = undefined;
    try std.testing.expectEqualStrings("2 days ago", ago(&buf, 2 * 86400 + 5));
    try std.testing.expectEqualStrings("1 hour ago", ago(&buf, 3700));
}
