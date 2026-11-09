//! Line diff between a base version (git HEAD) and the buffer: Myers'
//! algorithm on the lines between the common prefix and suffix, which keeps
//! typical edits instant. Produces hunks; equal lines are implied between them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Text = @import("../core/Text.zig");

pub const Hunk = struct {
    /// First old (base) line and how many old lines it replaces.
    old_start: u32,
    old_count: u32,
    /// First new (buffer) line and how many new lines it has.
    new_start: u32,
    new_count: u32,

    pub fn kind(h: Hunk) enum { added, deleted, changed } {
        if (h.old_count == 0) return .added;
        if (h.new_count == 0) return .deleted;
        return .changed;
    }
};

/// Beyond this many edits the middle is reported as one changed hunk instead
/// (bounded time and memory on wholesale rewrites).
const max_edits = 1500;

/// Diffs `old` against `new` (line slices), appending hunks to `out`.
pub fn diffLines(gpa: Allocator, old: []const []const u8, new: []const []const u8, out: *std.ArrayList(Hunk)) !void {
    // Trim the common prefix and suffix.
    var pre: usize = 0;
    while (pre < old.len and pre < new.len and std.mem.eql(u8, old[pre], new[pre])) pre += 1;
    var suf: usize = 0;
    while (suf < old.len - pre and suf < new.len - pre and
        std.mem.eql(u8, old[old.len - 1 - suf], new[new.len - 1 - suf])) suf += 1;
    const a = old[pre .. old.len - suf];
    const b = new[pre .. new.len - suf];
    if (a.len == 0 and b.len == 0) return;

    const deleted = try gpa.alloc(bool, a.len);
    defer gpa.free(deleted);
    const inserted = try gpa.alloc(bool, b.len);
    defer gpa.free(inserted);
    if (!try myers(gpa, a, b, deleted, inserted)) {
        @memset(deleted, true);
        @memset(inserted, true);
    }

    // Walk both sides together; runs of changes become hunks.
    var i: usize = 0;
    var j: usize = 0;
    while (i < a.len or j < b.len) {
        if (i < a.len and j < b.len and !deleted[i] and !inserted[j]) {
            i += 1;
            j += 1;
            continue;
        }
        const si = i;
        const sj = j;
        while (true) {
            const before = i + j;
            while (i < a.len and deleted[i]) i += 1;
            while (j < b.len and inserted[j]) j += 1;
            if (i + j == before) break;
        }
        try out.append(gpa, .{
            .old_start = @intCast(pre + si),
            .old_count = @intCast(i - si),
            .new_start = @intCast(pre + sj),
            .new_count = @intCast(j - sj),
        });
    }
}

/// Marks deleted lines of `a` and inserted lines of `b`. False if the
/// difference exceeds `max_edits`.
fn myers(gpa: Allocator, a: []const []const u8, b: []const []const u8, deleted: []bool, inserted: []bool) !bool {
    @memset(deleted, false);
    @memset(inserted, false);
    const n: isize = @intCast(a.len);
    const m: isize = @intCast(b.len);
    const max_d: isize = @min(n + m, max_edits);
    const offset: isize = max_d + 1;
    const width: usize = @intCast(2 * max_d + 3);
    var v = try gpa.alloc(isize, width);
    defer gpa.free(v);
    @memset(v, 0);
    // V at the start of each round, for backtracking.
    var trace: std.ArrayList([]isize) = .empty;
    defer {
        for (trace.items) |t| gpa.free(t);
        trace.deinit(gpa);
    }

    var d: isize = 0;
    const found = search: while (d <= max_d) : (d += 1) {
        try trace.append(gpa, try gpa.dupe(isize, v));
        var k: isize = -d;
        while (k <= d) : (k += 2) {
            const ki: usize = @intCast(k + offset);
            var x: isize = if (k == -d or (k != d and v[ki - 1] < v[ki + 1])) v[ki + 1] else v[ki - 1] + 1;
            var y = x - k;
            while (x < n and y < m and std.mem.eql(u8, a[@intCast(x)], b[@intCast(y)])) {
                x += 1;
                y += 1;
            }
            v[ki] = x;
            if (x >= n and y >= m) break :search true;
        }
    } else false;
    if (!found) return false;

    // Backtrack from the end, marking each edit.
    var x = n;
    var y = m;
    var dd = d;
    while (dd > 0) : (dd -= 1) {
        const vd = trace.items[@intCast(dd)];
        const k = x - y;
        const ki: usize = @intCast(k + offset);
        const prev_k = if (k == -dd or (k != dd and vd[ki - 1] < vd[ki + 1])) k + 1 else k - 1;
        const prev_x = vd[@intCast(prev_k + offset)];
        const prev_y = prev_x - prev_k;
        while (x > prev_x and y > prev_y) {
            x -= 1;
            y -= 1;
        }
        if (x == prev_x) inserted[@intCast(prev_y)] = true else deleted[@intCast(prev_x)] = true;
        x = prev_x;
        y = prev_y;
    }
    return true;
}

/// Diff state of one buffer against its git HEAD version.
pub const State = struct {
    base: Text,
    hunks: std.ArrayList(Hunk) = .empty,
    /// `Buffer.edit_version` the hunks were computed for.
    version: u64 = std.math.maxInt(u64),

    pub fn deinit(s: *State, gpa: Allocator) void {
        s.base.deinit(gpa);
        s.hunks.deinit(gpa);
    }

    /// Recomputes the hunks if the buffer changed.
    pub fn update(s: *State, gpa: Allocator, current: *const Text, version: u64) !void {
        if (s.version == version) return;
        const old = try lines(gpa, &s.base);
        defer gpa.free(old);
        const new = try lines(gpa, current);
        defer gpa.free(new);
        s.hunks.clearRetainingCapacity();
        try diffLines(gpa, old, new, &s.hunks);
        s.version = version;
    }

    fn lines(gpa: Allocator, t: *const Text) ![][]const u8 {
        // An empty text has no lines (so a new file is all additions).
        const n = if (t.len() == 0) 0 else t.lineCount();
        const out = try gpa.alloc([]const u8, n);
        for (out, 0..) |*l, i| l.* = t.lineSlice(i);
        return out;
    }

    pub fn baseLine(s: *const State, i: usize) []const u8 {
        return s.base.lineSlice(i);
    }
};

const testing = std.testing;

fn testDiff(old: []const []const u8, new: []const []const u8) ![]Hunk {
    var out: std.ArrayList(Hunk) = .empty;
    try diffLines(testing.allocator, old, new, &out);
    return out.toOwnedSlice(testing.allocator);
}

test "added, deleted and changed hunks" {
    const h = try testDiff(&.{ "a", "b", "c", "d" }, &.{ "a", "B", "c", "x", "d", "e" });
    defer testing.allocator.free(h);
    try testing.expectEqual(3, h.len);
    try testing.expectEqual(Hunk{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 1 }, h[0]); // b -> B
    try testing.expectEqual(Hunk{ .old_start = 3, .old_count = 0, .new_start = 3, .new_count = 1 }, h[1]); // + x
    try testing.expectEqual(Hunk{ .old_start = 4, .old_count = 0, .new_start = 5, .new_count = 1 }, h[2]); // + e

    const del = try testDiff(&.{ "a", "b", "c" }, &.{ "a", "c" });
    defer testing.allocator.free(del);
    try testing.expectEqual(1, del.len);
    try testing.expectEqual(Hunk{ .old_start = 1, .old_count = 1, .new_start = 1, .new_count = 0 }, del[0]);
    try testing.expectEqual(.deleted, del[0].kind());

    const same = try testDiff(&.{ "a", "b" }, &.{ "a", "b" });
    defer testing.allocator.free(same);
    try testing.expectEqual(0, same.len);
}

test "moves and interleaved edits stay consistent" {
    const old = [_][]const u8{ "1", "2", "3", "4", "5", "6" };
    const new = [_][]const u8{ "2", "3", "x", "5", "6", "1" };
    const h = try testDiff(&old, &new);
    defer testing.allocator.free(h);
    // Every old line is either kept or in a hunk, likewise every new line.
    var old_cov: usize = 0;
    var new_cov: usize = 0;
    for (h) |x| {
        old_cov += x.old_count;
        new_cov += x.new_count;
    }
    try testing.expectEqual(old.len - old_cov, new.len - new_cov); // equal kept lines
}
