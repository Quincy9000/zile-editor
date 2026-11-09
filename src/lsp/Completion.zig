//! The completion popup's state: the server's items and the ones matching
//! what has been typed since `word_start`, fuzzy-ranked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fuzzy = @import("../picker/fuzzy.zig");
const Lsp = @import("Lsp.zig");

const Completion = @This();

pub const Item = struct {
    label: []const u8,
    /// What typed text is matched against (`filterText`, else the label).
    filter: []const u8,
    /// Text to insert in place of the typed word.
    insert: []const u8,
    detail: []const u8,
    /// `insert` is a snippet (`${1:arg}` placeholders).
    snippet: bool = false,
    /// A function, method or constructor (CompletionItemKind 2, 3, 4):
    /// accepting it makes a call, which <Tab> can end with `;`.
    call: bool = false,
};

arena: std.heap.ArenaAllocator,
items: []Item,
/// Where the word being completed starts; it is replaced on accept.
word_start: usize,
/// Indices into `items` that match, best first.
shown: std.ArrayList(u32) = .empty,
selected: usize = 0,

pub const max_shown = 100;

/// Builds the popup from a `textDocument/completion` result.
pub fn fromJson(gpa: Allocator, result: std.json.Value, word_start: usize) !Completion {
    var c: Completion = .{ .arena = .init(gpa), .items = &.{}, .word_start = word_start };
    errdefer c.arena.deinit();
    const a = c.arena.allocator();
    const list = switch (result) {
        .array => result,
        .object => Lsp.field(result, "items") orelse .null,
        else => .null,
    };
    if (list != .array) return c;
    var items: std.ArrayList(Item) = .empty;
    for (list.array.items) |it| {
        // clangd prefixes labels with a space or "•" (header insertion).
        const raw_label = Lsp.str(Lsp.field(it, "label")) orelse continue;
        const label = std.mem.trimStart(u8, std.mem.trimStart(u8, raw_label, " "), "\u{2022}");
        const insert = Lsp.str(Lsp.field(Lsp.field(it, "textEdit"), "newText")) orelse
            Lsp.str(Lsp.field(it, "insertText")) orelse label;
        try items.append(a, .{
            .label = try a.dupe(u8, label),
            .filter = try a.dupe(u8, Lsp.str(Lsp.field(it, "filterText")) orelse label),
            .insert = try a.dupe(u8, insert),
            .detail = try a.dupe(u8, Lsp.str(Lsp.field(it, "detail")) orelse ""),
            .snippet = if (Lsp.field(it, "insertTextFormat")) |f| f == .integer and f.integer == 2 else false,
            .call = if (Lsp.field(it, "kind")) |k| k == .integer and k.integer >= 2 and k.integer <= 4 else false,
        });
    }
    c.items = try items.toOwnedSlice(a);
    return c;
}

pub fn deinit(c: *Completion, gpa: Allocator) void {
    c.shown.deinit(gpa);
    c.arena.deinit();
}

/// Re-ranks the items against `typed` (the text since `word_start`).
pub fn filter(c: *Completion, gpa: Allocator, typed: []const u8) !void {
    c.shown.clearRetainingCapacity();
    c.selected = 0;
    const q = fuzzy.Query.init(typed);
    var scratch: fuzzy.Scratch = .{};
    var scored: std.ArrayList(struct { index: u32, score: i32 }) = .empty;
    defer scored.deinit(gpa);
    for (c.items, 0..) |item, i| {
        const s = fuzzy.score(q, item.filter, &scratch) orelse continue;
        try scored.append(gpa, .{ .index = @intCast(i), .score = s });
    }
    // Stable: equal scores keep the server's order.
    std.mem.sort(@TypeOf(scored.items[0]), scored.items, {}, struct {
        fn lessThan(_: void, a: @TypeOf(scored.items[0]), b: @TypeOf(scored.items[0])) bool {
            return if (a.score != b.score) a.score > b.score else a.index < b.index;
        }
    }.lessThan);
    for (scored.items[0..@min(scored.items.len, max_shown)]) |s| try c.shown.append(gpa, s.index);
}

pub fn current(c: *const Completion) ?*const Item {
    if (c.shown.items.len == 0) return null;
    return &c.items[c.shown.items[c.selected]];
}

pub fn move(c: *Completion, delta: isize) void {
    const n: isize = @intCast(c.shown.items.len);
    if (n == 0) return;
    c.selected = @intCast(@mod(@as(isize, @intCast(c.selected)) + delta, n));
}

test "filtering ranks prefix matches first" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"deinit"},{"label":"append","detail":"fn"},{"label":"appendSlice"},{"label":"items"}]}
    , .{});
    defer parsed.deinit();
    var c = try fromJson(gpa, parsed.value, 0);
    defer c.deinit(gpa);
    try c.filter(gpa, "app");
    try std.testing.expectEqual(2, c.shown.items.len);
    try std.testing.expectEqualStrings("append", c.current().?.label);
    try c.filter(gpa, "");
    try std.testing.expectEqual(4, c.shown.items.len);
}
