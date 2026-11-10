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
    .{ "jsonc", "//" }, .{ "glsl", "//" }, .{ "scss", "//" }, .{ "php", "//" },   .{ "dart", "//" }, .{ "odin", "//" },
    .{ "lua", "--" },   .{ "sql", "--" },  .{ "hs", "--" },   .{ "elm", "--" },   .{ "ada", "--" },  .{ "vim", "\"" },
    .{ "el", ";;" },    .{ "lisp", ";;" }, .{ "clj", ";;" },  .{ "scm", ";;" },   .{ "ini", ";" },   .{ "asm", ";" },
    .{ "tex", "%" },    .{ "erl", "%" },   .{ "m", "%" },     .{ "bat", "REM" },
});

/// The line-comment prefix for `path` (a null path gets `#`).
pub fn prefixFor(path: ?[]const u8) []const u8 {
    const p = path orelse return "#";
    const base = std.fs.path.basename(p);
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return "#";
    return by_extension.get(base[dot + 1 ..]) orelse "#";
}

/// Whether a line's text (after its indentation) starts with `prefix`.
pub fn isComment(line: []const u8, prefix: []const u8) bool {
    const text = std.mem.trimStart(u8, line, " \t");
    return std.mem.startsWith(u8, text, prefix);
}

/// The block of comment lines around `line` (inclusive), if it is one.
pub fn block(t: *const Text, line: usize, prefix: []const u8) ?[2]usize {
    if (!isComment(t.lineSlice(line), prefix)) return null;
    var first = line;
    var last = line;
    while (first > 0 and isComment(t.lineSlice(first - 1), prefix)) first -= 1;
    while (last + 1 < t.lineCount() and isComment(t.lineSlice(last + 1), prefix)) last += 1;
    return .{ first, last };
}

/// The first line of the next (or previous) comment block from `line`.
pub fn nextBlock(t: *const Text, line: usize, prefix: []const u8, forward: bool) ?usize {
    const n = t.lineCount();
    if (forward) {
        var l = line + 1;
        while (l < n) : (l += 1) {
            if (isComment(t.lineSlice(l), prefix) and !isComment(t.lineSlice(l - 1), prefix)) return l;
        }
        return null;
    }
    // Backward: the start of the block before the one the cursor is in.
    var l = if (block(t, line, prefix)) |b| b[0] else line;
    while (l > 0) {
        l -= 1;
        if (isComment(t.lineSlice(l), prefix)) return block(t, l, prefix).?[0];
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
    try testing.expectEqual([2]usize{ 1, 2 }, block(&t, 2, "//").?);
    try testing.expectEqual(null, block(&t, 0, "//"));
    try testing.expectEqual(4, nextBlock(&t, 1, "//", true).?);
    try testing.expectEqual(1, nextBlock(&t, 4, "//", false).?);
}
