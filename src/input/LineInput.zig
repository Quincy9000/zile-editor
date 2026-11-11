//! A one-line text input (the picker query, the search prompt), with a
//! cursor (a byte offset) and vim's word motions for editing it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const LineInput = @This();

text: std.ArrayList(u8) = .empty,
/// Where typing goes: a byte offset, `0..len`.
cursor: usize = 0,

pub fn deinit(li: *LineInput, gpa: Allocator) void {
    li.text.deinit(gpa);
}

pub fn items(li: *const LineInput) []const u8 {
    return li.text.items;
}

/// Replaces the text; the cursor goes to its end.
pub fn set(li: *LineInput, gpa: Allocator, s: []const u8) Allocator.Error!void {
    li.text.clearRetainingCapacity();
    try li.text.appendSlice(gpa, s);
    li.cursor = li.text.items.len;
}

pub fn insert(li: *LineInput, gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try li.insertSlice(gpa, buf[0..n]);
}

pub fn insertSlice(li: *LineInput, gpa: Allocator, s: []const u8) Allocator.Error!void {
    li.cursor = @min(li.cursor, li.text.items.len);
    try li.text.insertSlice(gpa, li.cursor, s);
    li.cursor += s.len;
}

/// `<BS>`: the character before the cursor.
pub fn deleteChar(li: *LineInput) void {
    if (li.cursor == 0) return;
    li.delete(li.prev(li.cursor), li.cursor);
}

/// `<C-w>`: back to the previous separator, like a shell.
pub fn deleteWord(li: *LineInput) void {
    const t = li.text.items;
    var n = @min(li.cursor, t.len);
    while (n > 0 and isSeparator(t[n - 1])) n -= 1;
    while (n > 0 and !isSeparator(t[n - 1])) n -= 1;
    li.delete(n, li.cursor);
}

pub fn clear(li: *LineInput) void {
    li.text.clearRetainingCapacity();
    li.cursor = 0;
}

/// Deletes bytes `[start, end)`; the cursor goes to `start` if it was after.
pub fn delete(li: *LineInput, start: usize, end: usize) void {
    const e = @min(end, li.text.items.len);
    if (start >= e) return;
    li.text.replaceRangeAssumeCapacity(start, e - start, &.{});
    if (li.cursor >= e) li.cursor -= e - start else if (li.cursor > start) li.cursor = start;
}

fn isSeparator(b: u8) bool {
    return switch (b) {
        ' ', '/', '_', '-', '.', ':' => true,
        else => false,
    };
}

// ---------------------------------------------------------------------------
// Positions (byte offsets) for vim's motions, as in a buffer's one line.

/// The start of the character before `pos`.
pub fn prev(li: *const LineInput, pos: usize) usize {
    const t = li.text.items;
    var n = @min(pos, t.len);
    if (n == 0) return 0;
    n -= 1;
    while (n > 0 and t[n] & 0xC0 == 0x80) n -= 1;
    return n;
}

/// The start of the character after the one at `pos`.
pub fn next(li: *const LineInput, pos: usize) usize {
    const t = li.text.items;
    if (pos >= t.len) return t.len;
    var n = pos + 1;
    while (n < t.len and t[n] & 0xC0 == 0x80) n += 1;
    return n;
}

/// The last character's start (where normal mode's cursor stops).
pub fn lastChar(li: *const LineInput) usize {
    return li.prev(li.text.items.len);
}

const Class = enum { space, word, punct };

fn classOf(b: u8, big: bool) Class {
    if (b == ' ' or b == '\t') return .space;
    if (big or std.ascii.isAlphanumeric(b) or b == '_' or b >= 0x80) return .word;
    return .punct;
}

/// `w` / `W`: the next word's start (the end of the text if none).
pub fn wordForward(li: *const LineInput, pos: usize, big: bool) usize {
    const t = li.text.items;
    var i = pos;
    if (i >= t.len) return t.len;
    const c = classOf(t[i], big);
    while (i < t.len and classOf(t[i], big) == c and c != .space) i += 1;
    while (i < t.len and classOf(t[i], big) == .space) i += 1;
    return i;
}

/// `b` / `B`: the start of this word, or of the one before.
pub fn wordBackward(li: *const LineInput, pos: usize, big: bool) usize {
    const t = li.text.items;
    var i = @min(pos, t.len);
    while (i > 0 and classOf(t[i - 1], big) == .space) i -= 1;
    if (i == 0) return 0;
    const c = classOf(t[i - 1], big);
    while (i > 0 and classOf(t[i - 1], big) == c) i -= 1;
    return i;
}

/// `e` / `E`: the last character of this word, or of the next.
pub fn wordEnd(li: *const LineInput, pos: usize, big: bool) usize {
    const t = li.text.items;
    if (t.len == 0) return 0;
    var i = pos + 1;
    while (i < t.len and classOf(t[i], big) == .space) i += 1;
    if (i >= t.len) return li.lastChar();
    const c = classOf(t[i], big);
    while (i + 1 < t.len and classOf(t[i + 1], big) == c) i += 1;
    return i;
}

/// `iw` / `aw` around `pos`: the word (or run of spaces), and with `around`
/// the spaces after it (else before it).
pub fn wordObject(li: *const LineInput, pos: usize, around: bool, big: bool) [2]usize {
    const t = li.text.items;
    if (t.len == 0) return .{ 0, 0 };
    const p = @min(pos, t.len - 1);
    const c = classOf(t[p], big);
    var s = p;
    var e = p + 1;
    while (s > 0 and classOf(t[s - 1], big) == c) s -= 1;
    while (e < t.len and classOf(t[e], big) == c) e += 1;
    if (around and c != .space) {
        const e0 = e;
        while (e < t.len and classOf(t[e], big) == .space) e += 1;
        if (e == e0) while (s > 0 and classOf(t[s - 1], big) == .space) {
            s -= 1;
        };
    }
    return .{ s, e };
}

test "editing" {
    const gpa = std.testing.allocator;
    var li: LineInput = .{};
    defer li.deinit(gpa);
    for ("src/main.zig") |c| try li.insert(gpa, c);
    try li.insert(gpa, 'é');
    li.deleteChar();
    try std.testing.expectEqualStrings("src/main.zig", li.items());
    li.deleteWord();
    try std.testing.expectEqualStrings("src/main.", li.items());
    li.deleteWord();
    try std.testing.expectEqualStrings("src/", li.items());
    li.clear();
    try std.testing.expectEqualStrings("", li.items());
}

test "a cursor in the middle, and word motions" {
    const gpa = std.testing.allocator;
    var li: LineInput = .{};
    defer li.deinit(gpa);
    try li.set(gpa, "foo bar.baz");
    li.cursor = 4;
    try li.insert(gpa, 'X');
    try std.testing.expectEqualStrings("foo Xbar.baz", li.items());
    li.deleteChar();
    try std.testing.expectEqual(4, li.cursor);
    try std.testing.expectEqual(4, li.wordForward(0, false));
    try std.testing.expectEqual(7, li.wordForward(4, false)); // "."
    try std.testing.expectEqual(11, li.wordForward(4, true)); // to the end
    try std.testing.expectEqual(4, li.wordBackward(7, false));
    try std.testing.expectEqual(6, li.wordEnd(4, false));
    try std.testing.expectEqual(10, li.wordEnd(4, true));
    try std.testing.expectEqual([2]usize{ 4, 7 }, li.wordObject(5, false, false));
    try std.testing.expectEqual([2]usize{ 0, 4 }, li.wordObject(1, true, false));
    li.delete(4, 8);
    try std.testing.expectEqualStrings("foo baz", li.items());
}
