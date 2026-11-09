//! Append-only picker items, safe for one producer thread and any number of
//! concurrent readers without locks.
//!
//! Items live in fixed-size chunks that never move, and their strings live in
//! an arena that never moves existing data. The producer publishes each item by
//! bumping `len` with release ordering; readers load it with acquire ordering
//! and may read any item below it.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Items = @This();

pub const Item = struct {
    /// Matched against the query and displayed.
    text: []const u8,
    /// Shown dimmed after the text; not matched.
    detail: []const u8 = "",
    /// Source-specific payload (buffer index, command index, ...).
    id: u32 = 0,
};

const chunk_bits = 12;
const chunk_len = 1 << chunk_bits;
const max_chunks = 1024;
pub const capacity = chunk_len * max_chunks;

gpa: Allocator,
arena: std.heap.ArenaAllocator,
chunks: [max_chunks]?*[chunk_len]Item = @splat(null),
len: std.atomic.Value(usize) = .init(0),

pub fn init(gpa: Allocator) Items {
    return .{ .gpa = gpa, .arena = .init(gpa) };
}

/// Only call once no other thread can read the items.
pub fn deinit(items: *Items) void {
    for (items.chunks) |c| if (c) |chunk| items.gpa.destroy(chunk);
    items.arena.deinit();
    items.* = undefined;
}

pub const AppendError = Allocator.Error || error{TooManyItems};

/// Producer thread only.
pub fn append(items: *Items, item: Item) AppendError!void {
    const i = items.len.load(.monotonic);
    if (i == capacity) return error.TooManyItems;
    const c = i >> chunk_bits;
    if (items.chunks[c] == null) items.chunks[c] = try items.gpa.create([chunk_len]Item);
    const a = items.arena.allocator();
    items.chunks[c].?[i & (chunk_len - 1)] = .{
        .text = try a.dupe(u8, item.text),
        .detail = try a.dupe(u8, item.detail),
        .id = item.id,
    };
    items.len.store(i + 1, .release);
}

pub fn count(items: *const Items) usize {
    return items.len.load(.acquire);
}

/// `i` must be below a value previously returned by `count`.
pub fn get(items: *const Items, i: usize) *const Item {
    return &items.chunks[i >> chunk_bits].?[i & (chunk_len - 1)];
}

test "append and read across chunk boundaries" {
    var items: Items = .init(std.testing.allocator);
    defer items.deinit();
    var buf: [16]u8 = undefined;
    for (0..chunk_len + 10) |i| {
        try items.append(.{ .text = try std.fmt.bufPrint(&buf, "item {d}", .{i}), .id = @intCast(i) });
    }
    try std.testing.expectEqual(chunk_len + 10, items.count());
    try std.testing.expectEqualStrings("item 4100", items.get(4100).text);
    try std.testing.expectEqual(4100, items.get(4100).id);
}
