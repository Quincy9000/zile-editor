//! Files visited before, across sessions (mini.visits): how often and how
//! recently each was opened. Ranks the recent-files picker (`SPC f r`) and
//! puts the files you use first in the file picker.
//!
//! Kept in `$XDG_STATE_HOME/zile/visits` as "count\tlast\tpath" lines.

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
};

/// More than this and the lowest-ranked entries are dropped.
const max_entries = 500;

entries: std.ArrayList(Entry) = .empty,
loaded: bool = false,
/// Visits recorded since the last save.
unsaved: usize = 0,

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
    for (v.entries.items) |*e| if (std.mem.eql(u8, e.path, path)) {
        e.count +|= 1;
        e.last = now;
        return;
    };
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    try v.entries.append(gpa, .{ .path = owned, .count = 1, .last = now });
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

pub fn load(v: *Visits, gpa: Allocator, io: Io, path: []const u8) void {
    v.loaded = true;
    const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(4 << 20)) catch return;
    defer gpa.free(data);
    var lines = std.mem.splitScalar(u8, data, '\n');
    while (lines.next()) |line| {
        var it = std.mem.splitScalar(u8, line, '\t');
        const count = std.fmt.parseInt(u32, it.next() orelse continue, 10) catch continue;
        const last = std.fmt.parseInt(i64, it.next() orelse continue, 10) catch continue;
        const p = it.rest();
        if (p.len == 0) continue;
        const owned = gpa.dupe(u8, p) catch return;
        v.entries.append(gpa, .{ .path = owned, .count = count, .last = last }) catch return gpa.free(owned);
    }
}

pub fn save(v: *Visits, gpa: Allocator, io: Io, path: []const u8, now: i64) void {
    v.rank(now);
    while (v.entries.items.len > max_entries) gpa.free(v.entries.pop().?.path);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);
    for (v.entries.items) |e| out.print(gpa, "{d}\t{d}\t{s}\n", .{ e.count, e.last, e.path }) catch return;
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
}
