//! Files visited before, across sessions (mini.visits): how often and how
//! recently each was opened. Ranks the recent-files picker (`SPC f r`) and
//! puts the files you use first in the file picker.
//!
//! Kept in `$XDG_STATE_HOME/zile/visits` as "count\tlast\tline\tcol\tpath"
//! lines (older "count\tlast\tpath" ones still read). The line and column
//! are where the cursor was: the file reopens there.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Visits = @This();

pub const Entry = struct {
    /// Absolute; owned.
    path: []u8,
    count: u32,
    /// Unix seconds of the last visit.
    last: i64,
    /// The order of visits within this run (0: not visited in it), to tell
    /// apart two in the same second.
    seq: u64 = 0,
    /// Where the cursor was when the file was last left (0-based).
    line: u32 = 0,
    col: u32 = 0,
};

/// More than this and the lowest-ranked entries are dropped.
const max_entries = 500;

entries: std.ArrayList(Entry) = .empty,
loaded: bool = false,
/// Visits recorded since the last save.
unsaved: usize = 0,
visit_count: u64 = 0,

pub fn deinit(v: *Visits, gpa: Allocator) void {
    for (v.entries.items) |e| gpa.free(e.path);
    v.entries.deinit(gpa);
}

/// Frequency weighted by recency: a file opened today outranks one opened
/// more often last month.
pub fn score(e: Entry, now: i64) f64 {
    const age = now - e.last;
    const hour = 3600;
    const weight: f64 = if (age < hour) 4 else if (age < 24 * hour) 2 else if (age < 7 * 24 * hour) 1 else if (age < 30 * 24 * hour) 0.5 else 0.25;
    return @as(f64, @floatFromInt(e.count)) * weight;
}

pub fn record(v: *Visits, gpa: Allocator, path: []const u8, now: i64) Allocator.Error!void {
    v.unsaved += 1;
    v.visit_count += 1;
    for (v.entries.items) |*e| if (std.mem.eql(u8, e.path, path)) {
        e.count +|= 1;
        e.last = now;
        e.seq = v.visit_count;
        return;
    };
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try v.entries.append(gpa, .{ .path = owned, .count = 1, .last = now, .seq = v.visit_count });
}

/// Where the cursor was left in `path` (a file not visited yet is skipped).
pub fn setPosition(v: *Visits, path: []const u8, line: usize, col: usize) void {
    for (v.entries.items) |*e| if (std.mem.eql(u8, e.path, path)) {
        const l: u32 = @intCast(@min(line, std.math.maxInt(u32)));
        const c: u32 = @intCast(@min(col, std.math.maxInt(u32)));
        if (e.line != l or e.col != c) v.unsaved += 1;
        e.line = l;
        e.col = c;
        return;
    };
}

pub fn get(v: *const Visits, path: []const u8) ?Entry {
    for (v.entries.items) |e| if (std.mem.eql(u8, e.path, path)) return e;
    return null;
}

/// Renames an entry (the file moved); a no-op if it isn't known.
pub fn rename(v: *Visits, gpa: Allocator, old: []const u8, new: []const u8) void {
    for (v.entries.items) |*e| if (std.mem.eql(u8, e.path, old)) {
        const owned = gpa.dupe(u8, new) catch return;
        gpa.free(e.path);
        e.path = owned;
        return;
    };
}

/// Sorts the entries best first.
pub fn rank(v: *Visits, now: i64) void {
    std.mem.sort(Entry, v.entries.items, now, struct {
        fn better(n: i64, a: Entry, b: Entry) bool {
            const sa = score(a, n);
            const sb = score(b, n);
            return if (sa != sb) sa > sb else a.last > b.last;
        }
    }.better);
}

/// Sorts the entries by when they were last opened, newest first (the
/// recent-files list: the file just opened is at the top).
pub fn rankRecent(v: *Visits) void {
    std.mem.sort(Entry, v.entries.items, {}, struct {
        fn newer(_: void, a: Entry, b: Entry) bool {
            return if (a.last != b.last) a.last > b.last else a.seq > b.seq;
        }
    }.newer);
}

pub fn load(v: *Visits, gpa: Allocator, io: Io, path: []const u8) void {
    v.loaded = true;
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, '\t');
        const count = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        const last = std.fmt.parseInt(i64, it.next() orelse continue, 10) catch continue;
        // The position, when the line has one (older files don't).
        var p = it.rest();
        var at_line: u32 = 0;
        var at_col: u32 = 0;
        var probe = std.mem.splitScalar(u8, p, '\t');
        const f1 = probe.next() orelse "";
        const f2 = probe.next() orelse "";
        const l = std.fmt.parseInt(u32, f1, 10) catch null;
        const c_ = std.fmt.parseInt(u32, f2, 10) catch null;
        if (l != null and c_ != null) {
            at_line = l.?;
            at_col = c_.?;
            p = probe.rest();
        }
        if (p.len == 0) continue;
        const owned = gpa.dupe(u8, p) catch return;
        v.entries.append(gpa, .{ .path = owned, .count = count, .last = last, .line = at_line, .col = at_col }) catch return gpa.free(owned);
    }
}

pub fn save(v: *Visits, gpa: Allocator, io: Io, path: []const u8, now: i64) void {
    v.rank(now);
    while (v.entries.items.len > max_entries) gpa.free(v.entries.pop().?.path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (v.entries.items) |e| out.print(gpa, "{d}\t{d}\t{d}\t{d}\t{s}\n", .{ e.count, e.last, e.line, e.col, e.path }) catch return;
    if (std.fs.path.dirname(path)) |dir| Io.Dir.cwd().createDirPath(io, dir) catch return;
    Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = out.items }) catch return;
    v.unsaved = 0;
}

test "recent beats frequent-but-old; counts add up" {
    const gpa = std.testing.allocator;
    var v: Visits = .{};
    defer v.deinit(gpa);
    const day = 24 * 3600;
    const now: i64 = 100 * day;
    for (0..3) |_| try v.record(gpa, "/old", now - 40 * day);
    try v.record(gpa, "/new", now - 60);
    try v.record(gpa, "/mid", now - 2 * day);
    try v.record(gpa, "/mid", now - 2 * day);
    v.rank(now);
    try std.testing.expectEqualStrings("/new", v.entries.items[0].path);
    try std.testing.expectEqualStrings("/mid", v.entries.items[1].path);
    try std.testing.expectEqual(2, v.entries.items[1].count);
    try std.testing.expectEqualStrings("/old", v.entries.items[2].path);
    // By recency alone: the one just opened is first, whatever its count.
    try v.record(gpa, "/old", now);
    try v.record(gpa, "/mid", now); // the same second: the later visit wins
    v.rankRecent();
    try std.testing.expectEqualStrings("/mid", v.entries.items[0].path);
    try std.testing.expectEqualStrings("/old", v.entries.items[1].path);
    try std.testing.expectEqualStrings("/new", v.entries.items[2].path);
}

test "positions are kept, and old files still read" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "visits", .data = "3\t100\t/old/file\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "visits" });
    defer gpa.free(path);
    var v: Visits = .{};
    defer v.deinit(gpa);
    v.load(gpa, std.testing.io, path);
    try std.testing.expectEqualStrings("/old/file", v.entries.items[0].path);
    v.setPosition("/old/file", 41, 7);
    v.save(gpa, std.testing.io, path, 200);
    var w: Visits = .{};
    defer w.deinit(gpa);
    w.load(gpa, std.testing.io, path);
    try std.testing.expectEqual(41, w.get("/old/file").?.line);
    try std.testing.expectEqual(7, w.get("/old/file").?.col);
}
