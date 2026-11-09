//! Text storage: UTF-8 bytes plus an index of line starts.
//!
//! Milestone-1 implementation: one contiguous ArrayList. The public API is what a
//! persistent rope will implement later (see DESIGN.md). Callers must not rely on
//! `slice`/`lineSlice` being zero-copy beyond the next mutation.
//!
//! Lines are separated by '\n'. The text never stores the file's final newline
//! (Buffer strips it on load and restores it on save), so `lineCount() >= 1`
//! and an empty text is one empty line, matching vim's model.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Text = @This();

bytes: std.ArrayList(u8) = .empty,
/// `line_starts[i]` is the byte offset where line `i` begins. Always non-empty.
line_starts: std.ArrayList(usize) = .empty,

pub fn init(gpa: Allocator, content: []const u8) Allocator.Error!Text {
    var t: Text = .{};
    errdefer t.deinit(gpa);
    try t.bytes.appendSlice(gpa, content);
    try t.line_starts.append(gpa, 0);
    for (content, 0..) |b, i| {
        if (b == '\n') try t.line_starts.append(gpa, i + 1);
    }
    return t;
}

pub fn deinit(t: *Text, gpa: Allocator) void {
    t.bytes.deinit(gpa);
    t.line_starts.deinit(gpa);
    t.* = undefined;
}

pub fn len(t: *const Text) usize {
    return t.bytes.items.len;
}

pub fn lineCount(t: *const Text) usize {
    return t.line_starts.items.len;
}

pub fn lineStart(t: *const Text, line: usize) usize {
    return t.line_starts.items[line];
}

/// Byte offset of the line's terminating '\n', or `len()` for the last line.
pub fn lineEnd(t: *const Text, line: usize) usize {
    if (line + 1 < t.line_starts.items.len) return t.line_starts.items[line + 1] - 1;
    return t.bytes.items.len;
}

/// Line contents without the newline.
pub fn lineSlice(t: *const Text, line: usize) []const u8 {
    return t.bytes.items[t.lineStart(line)..t.lineEnd(line)];
}

pub fn lineLen(t: *const Text, line: usize) usize {
    return t.lineEnd(line) - t.lineStart(line);
}

/// The line containing byte offset `pos` (a '\n' belongs to the line it ends).
pub fn lineOf(t: *const Text, pos: usize) usize {
    std.debug.assert(pos <= t.len());
    const starts = t.line_starts.items;
    // Last start <= pos.
    var lo: usize = 0;
    var hi: usize = starts.len;
    while (hi - lo > 1) {
        const mid = lo + (hi - lo) / 2;
        if (starts[mid] <= pos) lo = mid else hi = mid;
    }
    return lo;
}

pub fn byteAt(t: *const Text, pos: usize) u8 {
    return t.bytes.items[pos];
}

pub fn slice(t: *const Text, start: usize, end: usize) []const u8 {
    return t.bytes.items[start..end];
}

pub fn insert(t: *Text, gpa: Allocator, pos: usize, new: []const u8) Allocator.Error!void {
    std.debug.assert(pos <= t.len());
    if (new.len == 0) return;
    var newlines: usize = 0;
    for (new) |b| newlines += @intFromBool(b == '\n');

    try t.bytes.insertSlice(gpa, pos, new);

    const line = t.lineOf(pos);
    const starts = &t.line_starts;
    // Starts after the insertion point move right.
    for (starts.items[line + 1 ..]) |*s| s.* += new.len;
    if (newlines > 0) {
        try starts.ensureUnusedCapacity(gpa, newlines);
        var at = line + 1;
        for (new, 0..) |b, i| {
            if (b == '\n') {
                starts.insertAssumeCapacity(at, pos + i + 1);
                at += 1;
            }
        }
    }
}

/// Removes bytes `[start, end)`.
pub fn delete(t: *Text, start: usize, end: usize) void {
    std.debug.assert(start <= end and end <= t.len());
    if (start == end) return;
    const removed = end - start;
    const first = t.lineOf(start);
    const last = t.lineOf(end);
    t.bytes.replaceRangeAssumeCapacity(start, removed, &.{});

    const starts = &t.line_starts;
    // Lines first+1 ..= last started inside the deleted range; drop them.
    const drop = last - first;
    if (drop > 0) starts.replaceRangeAssumeCapacity(first + 1, drop, &.{});
    for (starts.items[first + 1 ..]) |*s| s.* -= removed;
}

const testing = std.testing;

fn expectLines(t: *const Text, expected: []const []const u8) !void {
    try testing.expectEqual(expected.len, t.lineCount());
    for (expected, 0..) |line, i| try testing.expectEqualStrings(line, t.lineSlice(i));
}

test "line index" {
    var t = try Text.init(testing.allocator, "ab\ncd\n\nef");
    defer t.deinit(testing.allocator);
    try expectLines(&t, &.{ "ab", "cd", "", "ef" });
    try testing.expectEqual(0, t.lineOf(0));
    try testing.expectEqual(0, t.lineOf(2)); // the '\n'
    try testing.expectEqual(1, t.lineOf(3));
    try testing.expectEqual(2, t.lineOf(6));
    try testing.expectEqual(3, t.lineOf(9)); // end of text
}

test "empty text is one empty line" {
    var t = try Text.init(testing.allocator, "");
    defer t.deinit(testing.allocator);
    try expectLines(&t, &.{""});
}

test "insert and delete keep the index in sync" {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "hello\nworld");
    defer t.deinit(gpa);

    try t.insert(gpa, 5, ",\nthere");
    try expectLines(&t, &.{ "hello,", "there", "world" });

    try t.insert(gpa, 0, "\n");
    try expectLines(&t, &.{ "", "hello,", "there", "world" });

    t.delete(0, 1);
    try expectLines(&t, &.{ "hello,", "there", "world" });

    // Delete across two newlines: "o,\nthere\nw" -> ""
    t.delete(4, 4 + "o,\nthere\nw".len);
    try expectLines(&t, &.{"hellorld"});

    try t.insert(gpa, t.len(), "\n\n");
    try expectLines(&t, &.{ "hellorld", "", "" });
    t.delete(t.lineEnd(0), t.len());
    try expectLines(&t, &.{"hellorld"});
}
