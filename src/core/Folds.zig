//! Closed folds of one buffer.
//!
//! Each fold is a byte range from the start of its first line to the end of
//! its last; edits shift the ranges (`noteInsert`/`noteDelete`), so folds stay
//! on the same text. Nested closed folds are fine: the outermost one decides
//! what is hidden. Folds that edits shrink to one line are dropped lazily.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Text = @import("Text.zig");

const Folds = @This();

pub const Fold = struct { start: usize, end: usize };

pub const Lines = struct { first: usize, last: usize };

list: std.ArrayList(Fold) = .empty,

pub fn deinit(f: *Folds, gpa: Allocator) void {
    f.list.deinit(gpa);
}

pub fn isEmpty(f: *const Folds) bool {
    return f.list.items.len == 0;
}

fn linesOf(t: *const Text, fold: Fold) Lines {
    return .{ .first = t.lineOf(@min(fold.start, t.len())), .last = t.lineOf(@min(fold.end, t.len())) };
}

/// Closes lines `first..last` (ignored unless it spans two lines or more).
pub fn add(f: *Folds, gpa: Allocator, t: *const Text, first: usize, last: usize) Allocator.Error!void {
    if (last <= first or last >= t.lineCount()) return;
    const fold: Fold = .{ .start = t.lineStart(first), .end = t.lineEnd(last) };
    for (f.list.items) |existing| {
        if (existing.start == fold.start and existing.end == fold.end) return;
    }
    try f.list.append(gpa, fold);
}

/// The closed fold whose lines include `line` and that hides the most
/// (outermost), or null when the line is not folded.
pub fn region(f: *const Folds, t: *const Text, line: usize) ?Lines {
    var best: ?Lines = null;
    for (f.list.items) |fold| {
        const ls = linesOf(t, fold);
        if (ls.last <= ls.first or line < ls.first or line > ls.last) continue;
        if (best == null or ls.first < best.?.first or (ls.first == best.?.first and ls.last > best.?.last)) best = ls;
    }
    return best;
}

/// Opens the innermost closed fold containing `line` (or, with `all`, every
/// one). Returns whether anything was opened.
pub fn open(f: *Folds, t: *const Text, line: usize, all: bool) bool {
    var opened = false;
    while (true) {
        var inner: ?usize = null;
        var inner_span: usize = std.math.maxInt(usize);
        for (f.list.items, 0..) |fold, i| {
            const ls = linesOf(t, fold);
            if (line < ls.first or line > ls.last) continue;
            if (ls.last - ls.first < inner_span) {
                inner = i;
                inner_span = ls.last - ls.first;
            }
        }
        const i = inner orelse return opened;
        _ = f.list.swapRemove(i);
        opened = true;
        if (!all) return true;
    }
}

/// Whether lines `first..last` are a closed fold.
pub fn isClosed(f: *const Folds, t: *const Text, first: usize, last: usize) bool {
    for (f.list.items) |fold| {
        const ls = linesOf(t, fold);
        if (ls.first == first and ls.last == last) return true;
    }
    return false;
}

pub fn clear(f: *Folds) void {
    f.list.clearRetainingCapacity();
}

/// Call when `n` bytes are inserted at `pos`.
pub fn noteInsert(f: *Folds, pos: usize, n: usize) void {
    for (f.list.items) |*fold| {
        if (pos < fold.start) fold.start += n;
        if (pos <= fold.end) fold.end += n;
    }
}

/// Call when bytes `[start, end)` are deleted.
pub fn noteDelete(f: *Folds, start: usize, end: usize) void {
    const shift = struct {
        fn map(p: usize, a: usize, b: usize) usize {
            if (p <= a) return p;
            if (p >= b) return p - (b - a);
            return a;
        }
    }.map;
    for (f.list.items) |*fold| {
        fold.start = shift(fold.start, start, end);
        fold.end = shift(fold.end, start, end);
    }
}

const testing = std.testing;

test "folds follow edits and nest" {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "a\nb\nc\nd\ne");
    defer t.deinit(gpa);
    var f: Folds = .{};
    defer f.deinit(gpa);
    try f.add(gpa, &t, 1, 3); // b..d
    try f.add(gpa, &t, 2, 3); // c..d (inner)
    try testing.expectEqual(Lines{ .first = 1, .last = 3 }, f.region(&t, 2).?);
    try testing.expectEqual(null, f.region(&t, 4));

    // Insert a line above: the fold moves down with its text.
    f.noteInsert(0, 2);
    try t.insert(gpa, 0, "z\n");
    try testing.expectEqual(Lines{ .first = 2, .last = 4 }, f.region(&t, 3).?);

    try testing.expect(f.open(&t, 3, false)); // innermost (c..d) first
    try testing.expectEqual(Lines{ .first = 2, .last = 4 }, f.region(&t, 3).?);
    try testing.expect(f.open(&t, 3, false));
    try testing.expectEqual(null, f.region(&t, 3));
}
