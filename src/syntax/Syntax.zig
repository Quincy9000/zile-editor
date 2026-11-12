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

/// The languages inside this one (markdown's text and code fences), parsed
/// for `injected_version`: only highlighting needs them.
injected: std.ArrayList(Injected) = .empty,
injected_version: u64 = std.math.maxInt(u64),

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
    freeInjected(gpa, &s.injected);
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
    const text = t.slice(0, t.len());
    try s.styles.resize(gpa, end - start);
    languages.run(q, s.cursor, c.ts_tree_root_node(tree), text, start, end, s.styles.items);
    if (s.lang.injections() != null) {
        if (s.injected_version != s.version) {
            freeInjected(gpa, &s.injected);
            try parseInjected(gpa, s.lang, c.ts_tree_root_node(tree), text, &s.injected);
            s.injected_version = s.version;
        }
        overlayInjected(s.injected.items, s.cursor, text, start, end, s.styles.items);
    }
    s.hl_start = start;
    s.hl_version = s.version;
}

// ---------------------------------------------------------------------------
// Injections: languages inside the text (markdown's inline text in its
// blocks, code fences in their language). Each language found is parsed
// once over all its ranges (`ts_parser_set_included_ranges`), and its
// highlights go over the host's. One level deep.

pub const Injected = struct { lang: *languages.Language, tree: *c.TSTree };

fn freeInjected(gpa: Allocator, list: *std.ArrayList(Injected)) void {
    for (list.items) |inj| c.ts_tree_delete(inj.tree);
    list.clearAndFree(gpa);
}

/// Parses the languages `lang`'s injection query finds under `root`.
fn parseInjected(gpa: Allocator, lang: *languages.Language, root: c.TSNode, text: []const u8, out: *std.ArrayList(Injected)) Allocator.Error!void {
    const q = lang.injections() orelse return;
    const cursor = c.ts_query_cursor_new() orelse return;
    defer c.ts_query_cursor_delete(cursor);
    c.ts_query_cursor_exec(cursor, q.ts, root);

    const Group = struct { lang: *languages.Language, ranges: std.ArrayList(c.TSRange) = .empty };
    var groups: std.ArrayList(Group) = .empty;
    defer {
        for (groups.items) |*g| g.ranges.deinit(gpa);
        groups.deinit(gpa);
    }
    var m: c.TSQueryMatch = undefined;
    while (c.ts_query_cursor_next_match(cursor, &m)) {
        if (!q.matches(m, text)) continue;
        var content: ?c.TSNode = null;
        var name = q.set_language[m.pattern_index];
        for (m.captures[0..m.capture_count]) |cap| {
            if (q.content == cap.index) content = cap.node;
            if (q.language == cap.index) {
                const a = c.ts_node_start_byte(cap.node);
                const b = c.ts_node_end_byte(cap.node);
                if (b <= text.len and a < b) name = text[a..b];
            }
        }
        const node = content orelse continue;
        const inner = languages.forInjection(name orelse continue) orelse continue;
        if (inner == lang or inner.highlights() == null) continue;
        const group = for (groups.items) |*g| {
            if (g.lang == inner) break g;
        } else blk: {
            try groups.append(gpa, .{ .lang = inner });
            break :blk &groups.items[groups.items.len - 1];
        };
        try group.ranges.append(gpa, .{
            .start_point = c.ts_node_start_point(node),
            .end_point = c.ts_node_end_point(node),
            .start_byte = c.ts_node_start_byte(node),
            .end_byte = c.ts_node_end_byte(node),
        });
    }
    for (groups.items) |*g| {
        // In order and not overlapping, as tree-sitter wants them.
        std.mem.sort(c.TSRange, g.ranges.items, {}, struct {
            fn lessThan(_: void, a: c.TSRange, b: c.TSRange) bool {
                return a.start_byte < b.start_byte;
            }
        }.lessThan);
        var kept: usize = 0;
        for (g.ranges.items) |r| {
            if (kept > 0 and r.start_byte < g.ranges.items[kept - 1].end_byte) continue;
            g.ranges.items[kept] = r;
            kept += 1;
        }
        const parser = c.ts_parser_new() orelse continue;
        defer c.ts_parser_delete(parser);
        if (!c.ts_parser_set_language(parser, g.lang.ts())) continue;
        if (!c.ts_parser_set_included_ranges(parser, g.ranges.items.ptr, @intCast(kept))) continue;
        const tree = c.ts_parser_parse_string(parser, null, text.ptr, @intCast(text.len)) orelse continue;
        out.append(gpa, .{ .lang = g.lang, .tree = tree }) catch |err| {
            c.ts_tree_delete(tree);
            return err;
        };
    }
}

fn overlayInjected(list: []const Injected, cursor: *c.TSQueryCursor, text: []const u8, start: usize, end: usize, out: []Style) void {
    for (list) |inj| {
        const q = inj.lang.highlights() orelse continue;
        languages.overlay(q, cursor, c.ts_tree_root_node(inj.tree), text, start, end, out);
    }
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
    const root = c.ts_tree_root_node(tree);
    languages.run(q, s.cursor, root, text, 0, text.len, out.items);
    var injected: std.ArrayList(Injected) = .empty;
    defer freeInjected(gpa, &injected);
    try parseInjected(gpa, lang, root, text, &injected);
    overlayInjected(injected.items, s.cursor, text, 0, text.len, out.items);
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

test "JSX and HTML: tags, props and brackets have their own colours" {
    const gpa = std.testing.allocator;
    const tsx = "const a = <View style={s}><Text msg=\"hi\" /></View>;";
    const html = "<div class=\"x\"></div>";
    const Case = struct { path: []const u8, text: []const u8, needle: []const u8, style: Style };
    const cases = [_]Case{
        .{ .path = "a.tsx", .text = tsx, .needle = "View style", .style = .tag },
        .{ .path = "a.tsx", .text = tsx, .needle = "style=", .style = .tag_attribute },
        .{ .path = "a.tsx", .text = tsx, .needle = "<View", .style = .tag_delimiter },
        .{ .path = "a.tsx", .text = tsx, .needle = "Text msg", .style = .tag },
        .{ .path = "a.tsx", .text = tsx, .needle = "msg=", .style = .tag_attribute },
        .{ .path = "a.tsx", .text = tsx, .needle = "/>", .style = .tag_delimiter },
        .{ .path = "a.tsx", .text = tsx, .needle = "</View", .style = .tag_delimiter },
        .{ .path = "a.tsx", .text = tsx, .needle = "View>;", .style = .tag },
        .{ .path = "a.tsx", .text = tsx, .needle = "\"hi\"", .style = .string },
        .{ .path = "a.jsx", .text = tsx, .needle = "View style", .style = .tag },
        .{ .path = "a.jsx", .text = tsx, .needle = "msg=", .style = .tag_attribute },
        .{ .path = "a.html", .text = html, .needle = "div class", .style = .tag },
        .{ .path = "a.html", .text = html, .needle = "class=", .style = .tag_attribute },
        .{ .path = "a.html", .text = html, .needle = "<div", .style = .tag_delimiter },
        // The rest of TypeScript still highlights (the queries compile).
        .{ .path = "a.tsx", .text = tsx, .needle = "const", .style = .keyword },
    };
    for (cases) |cs| {
        var out: std.ArrayList(Style) = .empty;
        defer out.deinit(gpa);
        var s = forPath(cs.path) orelse return error.TestUnexpectedResult;
        defer s.deinit(gpa);
        try highlightText(gpa, s.lang, cs.text, &out);
        const at = std.mem.indexOf(u8, cs.text, cs.needle).?;
        std.testing.expectEqual(cs.style, out.items[at]) catch |err| {
            std.debug.print("{s}: \"{s}\" is {s}\n", .{ cs.path, cs.needle, @tagName(out.items[at]) });
            return err;
        };
    }
}

test ".env files: shell highlighting, by name" {
    const gpa = std.testing.allocator;
    const langs = @import("languages.zig");
    for ([_][]const u8{ ".env", "/proj/.env.local", ".env.production", "app.env" }) |p| {
        try std.testing.expect(langs.isEnvFile(p));
        try std.testing.expectEqualStrings("bash", forPath(p).?.lang.name);
    }
    for ([_][]const u8{ ".venv", "env.zig", "environment.ts" }) |p| try std.testing.expect(!langs.isEnvFile(p));
    const text = "# database\nDATABASE_URL=\"postgres://x\"\nexport PORT=3000\n";
    var out: std.ArrayList(Style) = .empty;
    defer out.deinit(gpa);
    var s = forPath(".env.local").?;
    defer s.deinit(gpa);
    try highlightText(gpa, s.lang, text, &out);
    try std.testing.expectEqual(.comment, out.items[0]);
    try std.testing.expectEqual(.string, out.items[std.mem.indexOf(u8, text, "\"postgres").?]);
    try std.testing.expectEqual(.keyword, out.items[std.mem.indexOf(u8, text, "export").?]);
    try std.testing.expect(out.items[std.mem.indexOf(u8, text, "DATABASE_URL").?] != .none);
}

test "lua: highlighted, by name and by #!" {
    const gpa = std.testing.allocator;
    const text = "local function greet(name)\n  -- say it\n  return \"hi \" .. name\nend\n";
    var out: std.ArrayList(Style) = .empty;
    defer out.deinit(gpa);
    var s = forPath("init.lua").?;
    defer s.deinit(gpa);
    try highlightText(gpa, s.lang, text, &out);
    try std.testing.expectEqual(.keyword, out.items[std.mem.indexOf(u8, text, "local").?]);
    try std.testing.expectEqual(.function, out.items[std.mem.indexOf(u8, text, "greet").?]);
    try std.testing.expectEqual(.comment, out.items[std.mem.indexOf(u8, text, "-- say").?]);
    try std.testing.expectEqual(.string, out.items[std.mem.indexOf(u8, text, "\"hi").?]);
    try std.testing.expectEqualStrings("lua", forFile("script", "#!/usr/bin/env lua5.4\nprint(1)").?.lang.name);
}

test "markdown: headings, code spans, links, and code fences in their language" {
    const gpa = std.testing.allocator;
    const src = "# Title\n\nSome `code` and a [link](http://x.y) and *it*.\n\n```zig\nconst x = 1;\n```\n";
    var t = try Text.init(gpa, src);
    defer t.deinit(gpa);
    var s = forPath("README.md").?;
    defer s.deinit(gpa);
    s.update(&t);
    try s.highlight(gpa, &t, 0, t.len());
    const at = struct {
        fn f(needle: []const u8) usize {
            return std.mem.indexOf(u8, src, needle).?;
        }
    }.f;
    try std.testing.expectEqual(.keyword, s.styleAt(at("Title"))); // the heading
    try std.testing.expectEqual(.punctuation, s.styleAt(0)); // its `#`
    try std.testing.expectEqual(.string, s.styleAt(at("code`"))); // a code span (inline)
    try std.testing.expectEqual(.function, s.styleAt(at("link]"))); // a link's text
    try std.testing.expectEqual(.module, s.styleAt(at("http"))); // its url
    try std.testing.expectEqual(.parameter, s.styleAt(at("it*"))); // emphasis
    try std.testing.expectEqual(.keyword, s.styleAt(at("const"))); // zig, in the fence
    try std.testing.expectEqual(.number, s.styleAt(at("1;")));
    try std.testing.expectEqual(.none, s.styleAt(at("Some")));
}
