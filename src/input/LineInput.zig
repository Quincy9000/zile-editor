//! A one-line text input (the picker query, the search prompt).

const std = @import("std");
const Allocator = std.mem.Allocator;

const LineInput = @This();

text: std.ArrayList(u8) = .empty,

pub fn deinit(li: *LineInput, gpa: Allocator) void {
    li.text.deinit(gpa);
}

pub fn items(li: *const LineInput) []const u8 {
    return li.text.items;
}

pub fn set(li: *LineInput, gpa: Allocator, s: []const u8) Allocator.Error!void {
    li.text.clearRetainingCapacity();
    try li.text.appendSlice(gpa, s);
}

pub fn insert(li: *LineInput, gpa: Allocator, cp: u21) !void {
    var buf: [4]u8 = undefined;
    const n = try std.unicode.utf8Encode(cp, &buf);
    try li.text.appendSlice(gpa, buf[0..n]);
}

pub fn deleteChar(li: *LineInput) void {
    const t = &li.text;
    if (t.items.len == 0) return;
    var n = t.items.len - 1;
    while (n > 0 and t.items[n] & 0xC0 == 0x80) n -= 1;
    t.shrinkRetainingCapacity(n);
}

/// Deletes back to the previous separator, like <C-w> in a shell.
pub fn deleteWord(li: *LineInput) void {
    const t = &li.text;
    var n = t.items.len;
    while (n > 0 and isSeparator(t.items[n - 1])) n -= 1;
    while (n > 0 and !isSeparator(t.items[n - 1])) n -= 1;
    t.shrinkRetainingCapacity(n);
}

pub fn clear(li: *LineInput) void {
    li.text.clearRetainingCapacity();
}

fn isSeparator(b: u8) bool {
    return switch (b) {
        ' ', '/', '_', '-', '.', ':' => true,
        else => false,
    };
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
