//! The completion popup's state: the server's items and the ones matching
//! what has been typed since `word_start`, fuzzy-ranked.

const std = @import("std");
const Allocator = std.mem.Allocator;
const fuzzy = @import("../picker/fuzzy.zig");
const Lsp = @import("Lsp.zig");
const emmet = @import("../emmet.zig");
const snippets = @import("../snippets.zig");

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
    /// A class, struct, enum, interface or type parameter (kinds 7, 8, 13,
    /// 22, 25).
    is_type: bool = false,
    /// A word of the file, not the server's.
    from_buffer: bool = false,
    /// An element for between tags (`<div>`), ours.
    markup: bool = false,
    /// One of our snippets (`snippets.zig`): first when its trigger is typed
    /// in full, otherwise after the server's items.
    user_snippet: bool = false,
};

arena: std.heap.ArenaAllocator,
items: []Item,
/// Where the word being completed starts; it is replaced on accept.
word_start: usize,
/// Indices into `items` that match, best first.
shown: std.ArrayList(u32) = .empty,
selected: usize = 0,
/// Where on the line the server says the replaced text starts (byte column
/// of the items' `textEdit` range), when it says. It knows better than a
/// guess from the text: zls completes `@import` from after the `@`.
edit_col: ?usize = null,
/// The server cut the list short (`isIncomplete`): it has to be asked again
/// as the text changes, since what was left out might be what matches.
incomplete: bool = false,
/// What `shown` was last ranked against (a hash of the typed text).
ranked_for: ?u64 = null,

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
    if (result == .object) if (Lsp.field(result, "isIncomplete")) |inc| {
        c.incomplete = inc == .bool and inc.bool;
    };
    if (list != .array) return c;
    var items: std.ArrayList(Item) = .empty;
    for (list.array.items) |it| {
        // clangd prefixes labels with a space or "•" (header insertion).
        const raw_label = Lsp.str(Lsp.field(it, "label")) orelse continue;
        const label = std.mem.trimStart(u8, std.mem.trimStart(u8, raw_label, " "), "\u{2022}");
        if (c.edit_col == null) {
            const edit = Lsp.field(it, "textEdit");
            // A plain TextEdit has `range`; an InsertReplaceEdit `insert`.
            const range = Lsp.field(edit, "range") orelse Lsp.field(edit, "insert");
            if (Lsp.field(Lsp.field(range, "start"), "character")) |col| if (col == .integer and col.integer >= 0) {
                c.edit_col = @intCast(col.integer);
            };
        }
        const insert = Lsp.str(Lsp.field(Lsp.field(it, "textEdit"), "newText")) orelse
            Lsp.str(Lsp.field(it, "insertText")) orelse label;
        try items.append(a, .{
            .label = try a.dupe(u8, label),
            .filter = try a.dupe(u8, Lsp.str(Lsp.field(it, "filterText")) orelse label),
            .insert = try a.dupe(u8, insert),
            .detail = try a.dupe(u8, Lsp.str(Lsp.field(it, "detail")) orelse ""),
            .snippet = if (Lsp.field(it, "insertTextFormat")) |f| f == .integer and f.integer == 2 else false,
            .is_type = if (Lsp.field(it, "kind")) |k| k == .integer and switch (k.integer) {
                7, 8, 13, 22, 25 => true,
                else => false,
            } else false,
            .call = if (Lsp.field(it, "kind")) |k| k == .integer and k.integer >= 2 and k.integer <= 4 else false,
        });
    }
    c.items = try items.toOwnedSlice(a);
    return c;
}

/// Adds the words of the file itself that the server did not offer, after
/// its items: a server that can't parse the file (a syntax error somewhere)
/// answers with little or nothing, and typing should still get suggestions.
/// The word at `word_start` is the one being typed (it would only suggest
/// itself).
pub fn addWords(c: *Completion, text: []const u8, word_start: usize) !void {
    // After a `.` only names used that way elsewhere (fields, methods).
    const member = word_start > 0 and text[word_start - 1] == '.';
    const a = c.arena.allocator();
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    for (c.items) |it| try seen.put(a, it.label, {});
    var extra: std.ArrayList(Item) = .empty;
    var i: usize = 0;
    while (i < text.len and extra.items.len < 2000) {
        if (!isWordByte(text[i])) {
            i += 1;
            continue;
        }
        const start = i;
        while (i < text.len and isWordByte(text[i])) i += 1;
        const w = text[start..i];
        if (w.len < 3 or w.len > 64 or start == word_start or std.ascii.isDigit(w[0])) continue;
        if (member and (start == 0 or text[start - 1] != '.')) continue;
        if (seen.contains(w)) continue;
        const owned = try a.dupe(u8, w);
        try seen.put(a, owned, {});
        try extra.append(a, .{ .label = owned, .filter = owned, .insert = owned, .detail = "buffer", .from_buffer = true });
    }
    if (extra.items.len == 0) return;
    const merged = try a.alloc(Item, c.items.len + extra.items.len);
    @memcpy(merged[0..c.items.len], c.items);
    @memcpy(merged[c.items.len..], extra.items);
    c.items = merged;
    c.ranked_for = null;
}

fn isWordByte(b: u8) bool {
    return b == '_' or std.ascii.isAlphanumeric(b) or b >= 0x80;
}

/// Elements to complete between tags: HTML's, and in JSX the components
/// named in the file (capitalized words), each inserting its tags.
pub fn addMarkup(c: *Completion, text: []const u8, word_start: usize, jsx: bool, unit: []const u8) !void {
    const a = c.arena.allocator();
    var names: std.ArrayList([]const u8) = .empty;
    var seen: std.StringHashMapUnmanaged(void) = .empty;
    defer seen.deinit(a);
    if (jsx) {
        // As the nvim config's `jsx_tags`: the common React Native
        // components, names imported, and components defined here.
        for (snippets.rn_components) |n| if (!(try seen.getOrPut(a, n)).found_existing) try names.append(a, n);
        var lines = std.mem.splitScalar(u8, text, '\n');
        while (lines.next()) |line| {
            const trimmed = std.mem.trimStart(u8, line, " \t");
            if (std.mem.startsWith(u8, trimmed, "import ")) {
                var i: usize = 0;
                while (i < trimmed.len) {
                    if (!std.ascii.isUpper(trimmed[i]) or (i > 0 and isWordByte(trimmed[i - 1]))) {
                        i += 1;
                        continue;
                    }
                    const start = i;
                    while (i < trimmed.len and isWordByte(trimmed[i])) i += 1;
                    const w = trimmed[start..i];
                    if (!(try seen.getOrPut(a, w)).found_existing) try names.append(a, w);
                }
                continue;
            }
            for ([_][]const u8{ "function ", "const " }) |kw| {
                const at = std.mem.indexOf(u8, line, kw) orelse continue;
                const rest = line[at + kw.len ..];
                if (rest.len == 0 or !std.ascii.isUpper(rest[0])) continue;
                var e: usize = 0;
                while (e < rest.len and isWordByte(rest[e])) e += 1;
                const after = std.mem.trimStart(u8, rest[e..], " ");
                const ok = if (std.mem.eql(u8, kw, "function ")) std.mem.startsWith(u8, after, "(") else after.len > 0 and (after[0] == '=' or after[0] == ':');
                if (ok and !(try seen.getOrPut(a, rest[0..e])).found_existing) try names.append(a, rest[0..e]);
            }
        }
    }
    _ = word_start;
    for (emmet.elements) |e| try names.append(a, e);
    const items = try a.alloc(Item, c.items.len + names.items.len);
    @memcpy(items[0..c.items.len], c.items);
    for (names.items, c.items.len..) |n, k| {
        const snippet = (try emmet.expand(a, n, .{ .jsx = jsx, .unit = unit })) orelse n;
        items[k] = .{
            .label = n,
            .filter = n,
            .insert = snippet,
            .detail = try std.fmt.allocPrint(a, "<{s}>", .{n}),
            .snippet = true,
            .markup = true,
        };
    }
    c.items = items;
    c.ranked_for = null;
}

/// Our snippets for this file type (`snippets.zig`), written for a line
/// indented by `indent`.
pub fn addSnippets(c: *Completion, lists: [3][]const snippets.Snippet, indent: []const u8, unit: []const u8) !void {
    const a = c.arena.allocator();
    var n: usize = 0;
    for (lists) |l| n += l.len;
    if (n == 0) return;
    const items = try a.alloc(Item, c.items.len + n);
    @memcpy(items[0..c.items.len], c.items);
    var k = c.items.len;
    for (lists) |l| for (l) |sn| {
        items[k] = .{
            .label = sn.prefix,
            .filter = sn.prefix,
            .insert = try snippets.render(a, sn.body, indent, unit),
            .detail = sn.desc,
            .snippet = true,
            .user_snippet = true,
        };
        k += 1;
    };
    c.items = items;
    c.ranked_for = null;
}

pub fn deinit(c: *Completion, gpa: Allocator) void {
    c.shown.deinit(gpa);
    c.arena.deinit();
}

/// Re-ranks the items against `typed` (the text since `word_start`).
/// `types_first`: a type is expected here (after `name: `), so types rank
/// above everything else.
pub fn filter(c: *Completion, gpa: Allocator, typed: []const u8, types_first: bool) !void {
    // The same text as last time (a key that moved the selection, not one
    // that typed): the list and the selection stay as they are.
    const hash = std.hash.Wyhash.hash(@intFromBool(types_first), typed);
    if (c.ranked_for == hash) return;
    c.ranked_for = hash;
    c.shown.clearRetainingCapacity();
    c.selected = 0;
    // Never case-sensitive (pickers are, once the query has a capital):
    // `Arr` should still offer `arrayList`, and `arr` `ArrayList`.
    var q = fuzzy.Query.init(typed);
    q.case_sensitive = false;
    var scratch: fuzzy.Scratch = .{};
    const Scored = struct { index: u32, score: i32, len: usize, exact: bool, same_case: bool, prefix: bool, buffer: bool, type_wanted: bool, snippet_exact: bool };
    var scored: std.ArrayList(Scored) = .empty;
    defer scored.deinit(gpa);
    for (c.items, 0..) |item, i| {
        const s = fuzzy.score(q, item.filter, &scratch) orelse continue;
        try scored.append(gpa, .{
            .index = @intCast(i),
            .score = s,
            .len = item.filter.len,
            .exact = typed.len > 0 and std.ascii.eqlIgnoreCase(typed, item.filter),
            .same_case = std.mem.eql(u8, typed, item.filter),
            .prefix = typed.len > 0 and item.filter.len >= typed.len and std.ascii.eqlIgnoreCase(typed, item.filter[0..typed.len]),
            .buffer = item.from_buffer or item.user_snippet,
            .snippet_exact = item.user_snippet and std.mem.eql(u8, typed, item.filter),
            .type_wanted = types_first and item.is_type,
        });
    }
    // What was typed in full comes first (`drawtext` is `DrawText`, not the
    // `DrawTexture` it is also the start of); then the better match; among
    // equal matches the shorter name (the more specific one: `DrawText`
    // before `DrawTextEx` before `DrawTexture`); then the server's order.
    std.mem.sort(Scored, scored.items, {}, struct {
        fn lessThan(_: void, a: Scored, b: Scored) bool {
            // A snippet's trigger typed in full: that snippet.
            if (a.snippet_exact != b.snippet_exact) return a.snippet_exact;
            if (a.type_wanted != b.type_wanted) return a.type_wanted;
            if (a.exact != b.exact) return a.exact;
            if (a.same_case != b.same_case) return a.same_case;
            // Names that start with what was typed come before ones that
            // only contain it; the server's before the file's own words.
            if (a.prefix != b.prefix) return a.prefix;
            if (a.score != b.score) return a.score > b.score;
            if (a.buffer != b.buffer) return b.buffer;
            if (a.len != b.len) return a.len < b.len;
            return a.index < b.index;
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
    try c.filter(gpa, "app", false);
    try std.testing.expectEqual(2, c.shown.items.len);
    try std.testing.expectEqualStrings("append", c.current().?.label);
    try c.filter(gpa, "", false);
    try std.testing.expectEqual(4, c.shown.items.len);
}

test "locals and a type with the same letters all match" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"Actor"},{"label":"actors"},{"label":"actor"}]}
    , .{});
    defer parsed.deinit();
    var c = try fromJson(gpa, parsed.value, 0);
    defer c.deinit(gpa);
    try c.filter(gpa, "actor", false);
    try std.testing.expectEqual(3, c.shown.items.len);
    try std.testing.expectEqualStrings("actor", c.current().?.label);
}

test "the file's own words fill in when the server has nothing" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "null", .{});
    defer parsed.deinit();
    var c = try fromJson(gpa, parsed.value, 0);
    defer c.deinit(gpa);
    try c.addWords("var actors = 1; actor.x; actors.len; ac", 37);
    try c.filter(gpa, "ac", false);
    try std.testing.expectEqual(2, c.shown.items.len);
    try std.testing.expectEqualStrings("actor", c.current().?.label);
}

test "after a dot only the names used after dots" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa, "null", .{});
    defer parsed.deinit();
    var c = try fromJson(gpa, parsed.value, 0);
    defer c.deinit(gpa);
    const src = "pub fn f() void { a.append(1); pubx.len; a.p";
    try c.addWords(src, src.len - 1);
    try c.filter(gpa, "pub", false);
    try std.testing.expectEqual(0, c.shown.items.len);
    try c.filter(gpa, "", false);
    try std.testing.expectEqual(2, c.shown.items.len); // append, len
}

test "where a type is expected, types come first" {
    const gpa = std.testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, gpa,
        \\{"items":[{"label":"actor","kind":21},{"label":"Actor","kind":22}]}
    , .{});
    defer parsed.deinit();
    var c = try fromJson(gpa, parsed.value, 0);
    defer c.deinit(gpa);
    try c.filter(gpa, "actor", false);
    try std.testing.expectEqualStrings("actor", c.current().?.label);
    try c.filter(gpa, "actor", true);
    try std.testing.expectEqualStrings("Actor", c.current().?.label);
}
