//! A TOML reader for the config files, on the built-in tree-sitter TOML
//! grammar: the parse tree becomes tables, arrays, strings, integers,
//! floats and booleans (dates are kept as strings). Values live in the
//! arena given to `parse`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const c = @import("tree_sitter");
const languages = @import("../syntax/languages.zig");

pub const Value = union(enum) {
    string: []const u8,
    int: i64,
    float: f64,
    boolean: bool,
    array: []Value,
    table: *Table,
};

pub const Table = struct {
    keys: std.ArrayList([]const u8) = .empty,
    values: std.ArrayList(Value) = .empty,

    pub fn get(t: *const Table, key: []const u8) ?Value {
        for (t.keys.items, t.values.items) |k, v| if (std.mem.eql(u8, k, key)) return v;
        return null;
    }

    pub fn string(t: *const Table, key: []const u8) ?[]const u8 {
        const v = t.get(key) orelse return null;
        return if (v == .string) v.string else null;
    }

    pub fn int(t: *const Table, key: []const u8) ?i64 {
        const v = t.get(key) orelse return null;
        return if (v == .int) v.int else null;
    }

    pub fn boolean(t: *const Table, key: []const u8) ?bool {
        const v = t.get(key) orelse return null;
        return if (v == .boolean) v.boolean else null;
    }

    /// An array of strings (null if it isn't one).
    pub fn strings(t: *const Table, a: Allocator, key: []const u8) !?[]const []const u8 {
        const v = t.get(key) orelse return null;
        if (v != .array) return null;
        const out = try a.alloc([]const u8, v.array.len);
        for (v.array, out) |item, *o| {
            if (item != .string) return null;
            o.* = item.string;
        }
        return out;
    }

    pub fn table(t: *const Table, key: []const u8) ?*Table {
        const v = t.get(key) orelse return null;
        return if (v == .table) v.table else null;
    }

    /// The tables of an array of tables (`[[name]]`).
    pub fn tables(t: *const Table, key: []const u8) []Value {
        const v = t.get(key) orelse return &.{};
        return if (v == .array) v.array else &.{};
    }

    fn put(t: *Table, a: Allocator, key: []const u8, v: Value) !void {
        for (t.keys.items, 0..) |k, i| if (std.mem.eql(u8, k, key)) {
            t.values.items[i] = v;
            return;
        };
        try t.keys.append(a, key);
        try t.values.append(a, v);
    }

    /// The table at `key`, made if missing.
    fn child(t: *Table, a: Allocator, key: []const u8) !*Table {
        if (t.table(key)) |sub| return sub;
        const sub = try a.create(Table);
        sub.* = .{};
        try t.put(a, key, .{ .table = sub });
        return sub;
    }
};

pub const Error = error{ OutOfMemory, NoTomlGrammar, Syntax };

/// Where parsing stopped, for messages.
pub const Diagnostic = struct { line: usize = 0, message: []const u8 = "" };

pub fn parse(a: Allocator, src: []const u8, diag: *Diagnostic) Error!*Table {
    const lang = languages.byName("toml") orelse return error.NoTomlGrammar;
    const parser = c.ts_parser_new() orelse return error.OutOfMemory;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, lang.ts())) return error.NoTomlGrammar;
    const tree = c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse return error.OutOfMemory;
    defer c.ts_tree_delete(tree);
    const root_node = c.ts_tree_root_node(tree);
    if (c.ts_node_has_error(root_node)) {
        diag.* = .{ .line = firstErrorLine(root_node, src), .message = "not valid TOML" };
        return error.Syntax;
    }
    var r: Reader = .{ .a = a, .src = src, .diag = diag };
    const root = try a.create(Table);
    root.* = .{};
    var i: u32 = 0;
    while (i < c.ts_node_named_child_count(root_node)) : (i += 1) {
        const n = c.ts_node_named_child(root_node, i);
        const ty = typeOf(n);
        if (std.mem.eql(u8, ty, "pair")) {
            try r.pair(root, n);
        } else if (std.mem.eql(u8, ty, "table")) {
            const t = try r.headerTable(root, n, false);
            try r.pairsOf(t, n);
        } else if (std.mem.eql(u8, ty, "table_array_element")) {
            const t = try r.headerTable(root, n, true);
            try r.pairsOf(t, n);
        }
    }
    return root;
}

fn typeOf(n: c.TSNode) []const u8 {
    return std.mem.span(c.ts_node_type(n));
}

fn firstErrorLine(n: c.TSNode, src: []const u8) usize {
    var node = n;
    while (true) {
        if (c.ts_node_is_error(node) or c.ts_node_is_missing(node)) break;
        var next: ?c.TSNode = null;
        var i: u32 = 0;
        while (i < c.ts_node_child_count(node)) : (i += 1) {
            const ch = c.ts_node_child(node, i);
            if (c.ts_node_has_error(ch)) {
                next = ch;
                break;
            }
        }
        node = next orelse break;
    }
    const at = @min(c.ts_node_start_byte(node), src.len);
    return std.mem.count(u8, src[0..at], "\n") + 1;
}

const Reader = struct {
    a: Allocator,
    src: []const u8,
    diag: *Diagnostic,

    fn text(r: *Reader, n: c.TSNode) []const u8 {
        return r.src[c.ts_node_start_byte(n)..c.ts_node_end_byte(n)];
    }

    fn fail(r: *Reader, n: c.TSNode, message: []const u8) Error {
        r.diag.* = .{ .line = std.mem.count(u8, r.src[0..c.ts_node_start_byte(n)], "\n") + 1, .message = message };
        return error.Syntax;
    }

    /// A key's parts (`a.b."c d"` -> a, b, c d).
    fn keyParts(r: *Reader, n: c.TSNode, out: *std.ArrayList([]const u8)) Error!void {
        const ty = typeOf(n);
        if (std.mem.eql(u8, ty, "dotted_key")) {
            var i: u32 = 0;
            while (i < c.ts_node_named_child_count(n)) : (i += 1) try r.keyParts(c.ts_node_named_child(n, i), out);
        } else if (std.mem.eql(u8, ty, "quoted_key")) {
            try out.append(r.a, try r.decodeString(n));
        } else {
            try out.append(r.a, r.text(n));
        }
    }

    /// The table a `[a.b]` / `[[a.b]]` header names (for `[[...]]`, a new
    /// table appended to the array there).
    fn headerTable(r: *Reader, root: *Table, n: c.TSNode, array: bool) Error!*Table {
        const key = c.ts_node_named_child(n, 0);
        var parts: std.ArrayList([]const u8) = .empty;
        try r.keyParts(key, &parts);
        if (parts.items.len == 0) return r.fail(n, "a table needs a name");
        var t = root;
        for (parts.items[0 .. parts.items.len - 1]) |p| t = try r.walk(t, n, p);
        const last = parts.items[parts.items.len - 1];
        if (!array) return t.child(r.a, last);
        const item = try r.a.create(Table);
        item.* = .{};
        const old: []Value = if (t.get(last)) |v| (if (v == .array) v.array else return r.fail(n, "already defined as a value")) else &.{};
        const grown = try r.a.alloc(Value, old.len + 1);
        @memcpy(grown[0..old.len], old);
        grown[old.len] = .{ .table = item };
        try t.put(r.a, last, .{ .array = grown });
        return item;
    }

    /// Into `t[part]`: a table, or the last table of an array of tables.
    fn walk(r: *Reader, t: *Table, n: c.TSNode, part: []const u8) Error!*Table {
        if (t.get(part)) |v| switch (v) {
            .table => |sub| return sub,
            .array => |arr| if (arr.len > 0 and arr[arr.len - 1] == .table) return arr[arr.len - 1].table,
            else => {},
        };
        if (t.get(part) != null) return r.fail(n, "already defined as a value");
        return t.child(r.a, part);
    }

    fn pairsOf(r: *Reader, t: *Table, n: c.TSNode) Error!void {
        var i: u32 = 0;
        while (i < c.ts_node_named_child_count(n)) : (i += 1) {
            const ch = c.ts_node_named_child(n, i);
            if (std.mem.eql(u8, typeOf(ch), "pair")) try r.pair(t, ch);
        }
    }

    fn pair(r: *Reader, t: *Table, n: c.TSNode) Error!void {
        const key = c.ts_node_named_child(n, 0);
        const val = c.ts_node_named_child(n, 1);
        if (c.ts_node_is_null(val)) return r.fail(n, "a key needs a value");
        var parts: std.ArrayList([]const u8) = .empty;
        try r.keyParts(key, &parts);
        var into = t;
        for (parts.items[0 .. parts.items.len - 1]) |p| into = try r.walk(into, n, p);
        try into.put(r.a, parts.items[parts.items.len - 1], try r.value(val));
    }

    fn value(r: *Reader, n: c.TSNode) Error!Value {
        const ty = typeOf(n);
        const t = r.text(n);
        if (std.mem.eql(u8, ty, "string")) return .{ .string = try r.decodeString(n) };
        if (std.mem.eql(u8, ty, "boolean")) return .{ .boolean = std.mem.eql(u8, t, "true") };
        if (std.mem.eql(u8, ty, "integer")) {
            var buf: [64]u8 = undefined;
            var len: usize = 0;
            for (t) |b| if (b != '_' and len < buf.len) {
                buf[len] = b;
                len += 1;
            };
            return .{ .int = std.fmt.parseInt(i64, buf[0..len], 0) catch return r.fail(n, "bad integer") };
        }
        if (std.mem.eql(u8, ty, "float")) return .{ .float = std.fmt.parseFloat(f64, t) catch return r.fail(n, "bad number") };
        if (std.mem.eql(u8, ty, "array")) {
            var items: std.ArrayList(Value) = .empty;
            var i: u32 = 0;
            while (i < c.ts_node_named_child_count(n)) : (i += 1) {
                const ch = c.ts_node_named_child(n, i);
                if (std.mem.eql(u8, typeOf(ch), "comment")) continue;
                try items.append(r.a, try r.value(ch));
            }
            return .{ .array = try items.toOwnedSlice(r.a) };
        }
        if (std.mem.eql(u8, ty, "inline_table")) {
            const sub = try r.a.create(Table);
            sub.* = .{};
            try r.pairsOf(sub, n);
            return .{ .table = sub };
        }
        // Dates and times: their text.
        return .{ .string = t };
    }

    /// A string's value: quotes off, escapes decoded (basic strings only),
    /// a multi-line string's first newline dropped.
    fn decodeString(r: *Reader, n: c.TSNode) Error![]const u8 {
        const t = r.text(n);
        const multi = std.mem.startsWith(u8, t, "\"\"\"") or std.mem.startsWith(u8, t, "'''");
        const q: usize = if (multi) 3 else 1;
        if (t.len < 2 * q) return r.fail(n, "bad string");
        var body = t[q .. t.len - q];
        if (multi) {
            if (std.mem.startsWith(u8, body, "\r\n")) body = body[2..] else if (std.mem.startsWith(u8, body, "\n")) body = body[1..];
        }
        if (t[0] == '\'') return body;
        var out: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        while (i < body.len) : (i += 1) {
            if (body[i] != '\\' or i + 1 >= body.len) {
                try out.append(r.a, body[i]);
                continue;
            }
            i += 1;
            switch (body[i]) {
                'n' => try out.append(r.a, '\n'),
                't' => try out.append(r.a, '\t'),
                'r' => try out.append(r.a, '\r'),
                '"' => try out.append(r.a, '"'),
                '\\' => try out.append(r.a, '\\'),
                'u', 'U' => {
                    const len: usize = if (body[i] == 'u') 4 else 8;
                    if (i + 1 + len > body.len) return r.fail(n, "bad escape");
                    const cp = std.fmt.parseInt(u21, body[i + 1 .. i + 1 + len], 16) catch return r.fail(n, "bad escape");
                    var buf: [4]u8 = undefined;
                    const m = std.unicode.utf8Encode(cp, &buf) catch return r.fail(n, "bad escape");
                    try out.appendSlice(r.a, buf[0..m]);
                    i += len;
                },
                '\n' => {
                    // A line ending backslash: the newline and the next
                    // line's indentation go.
                    while (i + 1 < body.len and std.ascii.isWhitespace(body[i + 1])) i += 1;
                },
                else => try out.append(r.a, body[i]),
            }
        }
        return out.toOwnedSlice(r.a);
    }
};

test "tables, arrays of tables, inline tables, strings" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var d: Diagnostic = .{};
    const root = try parse(a,
        \\top = 1
        \\[[language]]
        \\name = "lua"
        \\extensions = ["lua", 'luau']
        \\comment = ["--[[", "]]"]
        \\indent = 2
        \\grammar = { url = "https://x/y", rev = "v1" }
        \\
        \\[[language]]
        \\name = "it\"sA"
        \\server.command = ["a", "b"]
        \\
        \\[editor]
        \\on = true
    , &d);
    try std.testing.expectEqual(1, root.int("top").?);
    const langs = root.tables("language");
    try std.testing.expectEqual(2, langs.len);
    const lua = langs[0].table;
    try std.testing.expectEqualStrings("lua", lua.string("name").?);
    try std.testing.expectEqualStrings("luau", (try lua.strings(a, "extensions")).?[1]);
    try std.testing.expectEqual(2, lua.int("indent").?);
    try std.testing.expectEqualStrings("v1", lua.table("grammar").?.string("rev").?);
    try std.testing.expectEqualStrings("it\"sA", langs[1].table.string("name").?);
    try std.testing.expectEqualStrings("b", (try langs[1].table.table("server").?.strings(a, "command")).?[1]);
    try std.testing.expect(root.table("editor").?.boolean("on").?);

    try std.testing.expectError(error.Syntax, parse(a, "a = \n[x", &d));
    try std.testing.expectEqual(1, d.line);
}
