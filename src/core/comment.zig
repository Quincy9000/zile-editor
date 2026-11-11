//! Line comments (mini.comment): each language's comment prefix, and which
//! lines are comments. Pure; the edits are in `textops.zig`.

const std = @import("std");
const Text = @import("Text.zig");

/// Comment prefix by file extension (without the dot). Files with no entry
/// use `#` (shell, config files).
const by_extension = std.StaticStringMap([]const u8).initComptime(.{
    .{ "zig", "//" },   .{ "zon", "//" },  .{ "c", "//" },    .{ "h", "//" },     .{ "cpp", "//" },  .{ "hpp", "//" },
    .{ "cc", "//" },    .{ "rs", "//" },   .{ "go", "//" },   .{ "js", "//" },    .{ "ts", "//" },   .{ "jsx", "//" },
    .{ "tsx", "//" },   .{ "java", "//" }, .{ "kt", "//" },   .{ "swift", "//" }, .{ "cs", "//" },   .{ "json", "//" },
    .{ "jsonc", "//" }, .{ "json5", "//" }, .{ "glsl", "//" }, .{ "scss", "//" }, .{ "php", "//" },   .{ "dart", "//" }, .{ "odin", "//" },
    .{ "lua", "--" },   .{ "sql", "--" },  .{ "hs", "--" },   .{ "elm", "--" },   .{ "ada", "--" },  .{ "vim", "\"" },
    .{ "el", ";;" },    .{ "lisp", ";;" }, .{ "clj", ";;" },  .{ "scm", ";;" },   .{ "ini", ";" },   .{ "asm", ";" },
    .{ "tex", "%" },    .{ "erl", "%" },   .{ "m", "%" },     .{ "bat", "REM" },
});

/// How a line is commented: `open` before it, and `close` after it for
/// languages without line comments (`<!-- x -->`, `/* x */`).
pub const Style = struct {
    open: []const u8,
    close: []const u8 = "",

    pub const html: Style = .{ .open = "<!--", .close = "-->" };
    pub const block: Style = .{ .open = "/*", .close = "*/" };
    /// A line among JSX children: `{/* x */}`.
    pub const jsx: Style = .{ .open = "{/*", .close = "*/}" };
};

/// Comment styles of languages without line comments, by extension.
const block_by_extension = std.StaticStringMap(Style).initComptime(.{
    .{ "html", Style.html }, .{ "htm", Style.html }, .{ "xml", Style.html },   .{ "svg", Style.html },
    .{ "vue", Style.html },  .{ "md", Style.html },  .{ "css", Style.block }, .{ "less", Style.block },
});

/// The comment style for `path` (a null path gets `#`).
pub fn styleFor(path: ?[]const u8) Style {
    const p = path orelse return .{ .open = "#" };
    const base = std.fs.path.basename(p);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return .{ .open = "#" };
    const ext = base[dot + 1 ..];
    if (block_by_extension.get(ext)) |st| return st;
    return .{ .open = by_extension.get(ext) orelse "#" };
}

/// The line-comment prefix for `path` (a null path gets `#`).
pub fn prefixFor(path: ?[]const u8) []const u8 {
    return styleFor(path).open;
}

/// Whether a line's text (after its indentation) is a comment in `style`.
pub fn isComment(line: []const u8, style: Style) bool {
    const text = std.mem.trim(u8, line, " \t");
    if (!std.mem.startsWith(u8, text, style.open)) return false;
    return style.close.len == 0 or (text.len >= style.open.len + style.close.len and std.mem.endsWith(u8, text, style.close));
}

/// The block of comment lines around `line` (inclusive), if it is one.
pub fn block(t: *const Text, line: usize, style: Style) ?[2]usize {
    if (!isComment(t.lineSlice(line), style)) return null;
    var first = line;
    var last = line;
    while (first > 0 and isComment(t.lineSlice(first - 1), style)) first -= 1;
    while (last + 1 < t.lineCount() and isComment(t.lineSlice(last + 1), style)) last += 1;
    return .{ first, last };
}

/// The first line of the next (or previous) comment block from `line`.
pub fn nextBlock(t: *const Text, line: usize, style: Style, forward: bool) ?usize {
    const n = t.lineCount();
    if (forward) {
        var l = line + 1;
        while (l < n) : (l += 1) {
            if (isComment(t.lineSlice(l), style) and !isComment(t.lineSlice(l - 1), style)) return l;
        }
        return null;
    }
    // Backward: the start of the block before the one the cursor is in.
    var l = if (block(t, line, style)) |b| b[0] else line;
    while (l > 0) {
        l -= 1;
        if (isComment(t.lineSlice(l), style)) return block(t, l, style).?[0];
    }
    return null;
}

const testing = std.testing;

test "prefixes and blocks" {
    try testing.expectEqualStrings("//", prefixFor("src/main.zig"));
    try testing.expectEqualStrings("#", prefixFor("run.py"));
    try testing.expectEqualStrings("--", prefixFor("init.lua"));
    try testing.expectEqualStrings("#", prefixFor(null));
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "a\n// one\n  // two\nb\n// three");
    defer t.deinit(gpa);
    const sl: Style = .{ .open = "//" };
    try testing.expectEqual([2]usize{ 1, 2 }, block(&t, 2, sl).?);
    try testing.expectEqual(null, block(&t, 0, sl));
    try testing.expectEqual(4, nextBlock(&t, 1, sl, true).?);
    try testing.expectEqual(1, nextBlock(&t, 4, sl, false).?);
    try testing.expectEqualStrings("-->", styleFor("index.html").close);
    try testing.expect(isComment("  <!-- x -->", Style.html));
    try testing.expect(!isComment("  <!-- x", Style.html));
}
