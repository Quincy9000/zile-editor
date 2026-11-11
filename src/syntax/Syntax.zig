//! Tree-sitter state for one buffer: the parser, the syntax tree, and the
//! highlight styles of the visible region.
//!
//! Edits are reported (`noteInsert`/`noteDelete`) before they are applied, so
//! the tree can be adjusted with `ts_tree_edit`; `update` then reparses
//! incrementally, at most once per frame.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("tree_sitter");
const Text = @import("../core/Text.zig");
const languages = @import("languages.zig");

pub const Style = languages.Style;

const Syntax = @This();

lang: *languages.Language,
parser: *c.TSParser,
cursor: *c.TSQueryCursor,
tree: ?*c.TSTree = null,
/// Edited since the last parse.
dirty: bool = true,
/// Bumped on every parse.
version: u64 = 0,

/// Styles for bytes `[hl_start, hl_start + styles.len)`, valid for `hl_version`.
styles: std.ArrayList(Style) = .empty,
hl_start: usize = 0,
hl_version: u64 = std.math.maxInt(u64),

pub fn forPath(path: []const u8) ?Syntax {
    const lang = languages.forPath(path) orelse return null;
    return init(lang);
}

/// By the file's name, else by its `#!` line.
pub fn forFile(path: []const u8, text: []const u8) ?Syntax {
    if (forPath(path)) |s| return s;
    const first = text[0 .. std.mem.indexOfScalar(u8, text, '\n') orelse text.len];
    return init(languages.forShebang(first) orelse return null);
}

pub fn init(lang: *languages.Language) ?Syntax {
    const parser = c.ts_parser_new() orelse return null;
    if (!c.ts_parser_set_language(parser, lang.ts())) {
        c.ts_parser_delete(parser);
        return null;
    }
    const cursor = c.ts_query_cursor_new() orelse {
        c.ts_parser_delete(parser);
        return null;
    };
    return .{ .lang = lang, .parser = parser, .cursor = cursor };
}

pub fn deinit(s: *Syntax, gpa: Allocator) void {
    if (s.tree) |t| c.ts_tree_delete(t);
    c.ts_query_cursor_delete(s.cursor);
    c.ts_parser_delete(s.parser);
    s.styles.deinit(gpa);
    s.* = undefined;
}

fn point(t: *const Text, pos: usize) c.TSPoint {
    const line = t.lineOf(pos);
    return .{ .row = @intCast(line), .column = @intCast(pos - t.lineStart(line)) };
}

/// Call before inserting `bytes` at `pos`.
pub fn noteInsert(s: *Syntax, t: *const Text, pos: usize, bytes: []const u8) void {
    s.dirty = true;
    const tree = s.tree orelse return;
    const start = point(t, pos);
    var end = start;
    if (std.mem.lastIndexOfScalar(u8, bytes, '\n')) |last_nl| {
        end.row += @intCast(std.mem.count(u8, bytes, "\n"));
        end.column = @intCast(bytes.len - last_nl - 1);
    } else end.column += @intCast(bytes.len);
    const edit: c.TSInputEdit = .{
        .start_byte = @intCast(pos),
        .old_end_byte = @intCast(pos),
        .new_end_byte = @intCast(pos + bytes.len),
        .start_point = start,
        .old_end_point = start,
        .new_end_point = end,
    };
    c.ts_tree_edit(tree, &edit);
}

/// Call before deleting `[start, end)`.
pub fn noteDelete(s: *Syntax, t: *const Text, start: usize, end: usize) void {
    s.dirty = true;
    const tree = s.tree orelse return;
    const sp = point(t, start);
    const edit: c.TSInputEdit = .{
        .start_byte = @intCast(start),
        .old_end_byte = @intCast(end),
        .new_end_byte = @intCast(start),
        .start_point = sp,
        .old_end_point = point(t, end),
        .new_end_point = sp,
    };
    c.ts_tree_edit(tree, &edit);
}

/// Reparses if the text changed (incrementally, reusing the edited tree).
pub fn update(s: *Syntax, t: *const Text) void {
    if (!s.dirty) return;
    const bytes = t.slice(0, t.len());
    const new = c.ts_parser_parse_string(s.parser, s.tree, bytes.ptr, @intCast(bytes.len)) orelse return;
    if (s.tree) |old| c.ts_tree_delete(old);
    s.tree = new;
    s.dirty = false;
    s.version += 1;
}

/// Computes styles for `[start, end)` unless already cached.
pub fn highlight(s: *Syntax, gpa: Allocator, t: *const Text, start: usize, end: usize) Allocator.Error!void {
    if (s.hl_version == s.version and s.hl_start == start and s.styles.items.len == end - start) return;
    const tree = s.tree orelse return;
    const q = s.lang.highlights() orelse return;
    try s.styles.resize(gpa, end - start);
    languages.run(q, s.cursor, c.ts_tree_root_node(tree), t.slice(0, t.len()), start, end, s.styles.items);
    s.hl_start = start;
    s.hl_version = s.version;
}

pub fn styleAt(s: *const Syntax, pos: usize) Style {
    if (s.hl_version != s.version or pos < s.hl_start) return .none;
    const i = pos - s.hl_start;
    return if (i < s.styles.items.len) s.styles.items[i] else .none;
}

/// Highlights standalone text (picker previews): parses it from scratch and
/// fills `out` with one style per byte.
pub fn highlightText(gpa: Allocator, lang: *languages.Language, text: []const u8, out: *std.ArrayList(Style)) Allocator.Error!void {
    const q = lang.highlights() orelse return;
    var s = init(lang) orelse return;
    defer s.deinit(gpa);
    const tree = c.ts_parser_parse_string(s.parser, null, text.ptr, @intCast(text.len)) orelse return;
    defer c.ts_tree_delete(tree);
    try out.resize(gpa, text.len);
    languages.run(q, s.cursor, c.ts_tree_root_node(tree), text, 0, text.len, out.items);
}

test "incremental reparse after edits" {
    const gpa = std.testing.allocator;
    var t = try Text.init(gpa, "const x = 1;");
    defer t.deinit(gpa);
    var s = forPath("a.zig").?;
    defer s.deinit(gpa);
    s.update(&t);
    try s.highlight(gpa, &t, 0, t.len());
    try std.testing.expectEqual(.keyword, s.styleAt(0)); // const
    try std.testing.expectEqual(.number, s.styleAt(10)); // 1

    // Insert a string literal, report it, reparse.
    const insert = "\"hi\" ++ ";
    s.noteInsert(&t, 10, insert);
    try t.insert(gpa, 10, insert);
    s.update(&t);
    try s.highlight(gpa, &t, 0, t.len());
    try std.testing.expectEqual(.string, s.styleAt(11));

    s.noteDelete(&t, 0, 6);
    t.delete(0, 6);
    s.update(&t);
    try s.highlight(gpa, &t, 0, t.len());
    try std.testing.expect(s.styleAt(0) != .keyword);
}

test "config files: toml, yaml and json are highlighted" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { path: []const u8, text: []const u8, at: usize, style: Style }{
        .{ .path = "Cargo.toml", .text = "[package]\nname = \"zile\"\n", .at = 18, .style = .string },
        .{ .path = "Cargo.toml", .text = "# note\nx = 1", .at = 0, .style = .comment },
        .{ .path = "ci.yml", .text = "name: build\non: [push]\n", .at = 0, .style = .property },
        .{ .path = "ci.yaml", .text = "# hi\nretries: 3\n", .at = 0, .style = .comment },
        .{ .path = "tsconfig.jsonc", .text = "{\"strict\": true}", .at = 1, .style = .string },
    };
    for (cases) |cs| {
        var out: std.ArrayList(Style) = .empty;
        defer out.deinit(gpa);
        var s = forPath(cs.path) orelse return error.TestUnexpectedResult;
        defer s.deinit(gpa);
        try highlightText(gpa, s.lang, cs.text, &out);
        std.testing.expectEqual(cs.style, out.items[cs.at]) catch |err| {
            std.debug.print("{s}: byte {d}\n", .{ cs.path, cs.at });
            return err;
        };
    }
}
