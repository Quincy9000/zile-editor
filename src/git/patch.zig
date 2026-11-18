//! A unified diff (`git diff`, `git show`) read as its changes: one for each
//! `@@` hunk, with the file it is in and where its first changed line is.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Change = struct {
    /// The file, from the repository's top (a slice of the diff).
    path: []const u8,
    /// The first changed line, as the file is now (1-based).
    line: u32,
    added: u32 = 0,
    removed: u32 = 0,
    /// The lines of the file as it is now that the hunk is of (1-based,
    /// from its `@@` line).
    new_start: u32 = 0,
    new_len: u32 = 0,
    /// The hunk in the diff: from its `@@` line to its last line.
    start: usize,
    end: usize,
    /// The file is gone (there is nothing to go to).
    deleted_file: bool = false,
};

/// The path of a `--- a/x` / `+++ b/x` line (after the marker), or null for
/// `/dev/null`.
fn pathOf(rest: []const u8) ?[]const u8 {
    const p = std.mem.trimEnd(u8, rest, "\t\r");
    if (std.mem.eql(u8, p, "/dev/null")) return null;
    return if (p.len > 2 and (p[0] == 'a' or p[0] == 'b') and p[1] == '/') p[2..] else p;
}

/// The changes of `text`, appended to `out` (their paths are slices of it).
pub fn changes(gpa: Allocator, text: []const u8, out: *std.ArrayList(Change)) !void {
    var old_path: ?[]const u8 = null;
    var path: ?[]const u8 = null;
    var deleted = false;
    var open: ?usize = null; // the index in `out` of the hunk being read
    var new_line: u32 = 0;
    var seen_change = false;
    var at: usize = 0;
    while (at < text.len) {
        const eol = std.mem.indexOfScalarPos(u8, text, at, '\n') orelse text.len;
        const line = text[at..eol];
        defer at = eol + 1;
        const in_hunk = open != null;
        if (std.mem.startsWith(u8, line, "diff --git ")) {
            open = null;
            old_path = null;
            path = null;
            deleted = false;
        } else if (!in_hunk and std.mem.startsWith(u8, line, "--- ")) {
            old_path = pathOf(line[4..]);
        } else if (!in_hunk and std.mem.startsWith(u8, line, "+++ ")) {
            path = pathOf(line[4..]);
            deleted = path == null;
            if (deleted) path = old_path;
        } else if (std.mem.startsWith(u8, line, "@@ ")) {
            open = null;
            const p = path orelse continue;
            // "@@ -a,b +c,d @@"
            const plus = std.mem.indexOfScalarPos(u8, line, 3, '+') orelse continue;
            var e = plus + 1;
            while (e < line.len and std.ascii.isDigit(line[e])) e += 1;
            new_line = std.fmt.parseInt(u32, line[plus + 1 .. e], 10) catch continue;
            // (No count: one line.)
            var len: u32 = 1;
            if (e < line.len and line[e] == ',') {
                var e2 = e + 1;
                while (e2 < line.len and std.ascii.isDigit(line[e2])) e2 += 1;
                len = std.fmt.parseInt(u32, line[e + 1 .. e2], 10) catch 1;
            }
            seen_change = false;
            try out.append(gpa, .{ .path = p, .line = @max(new_line, 1), .new_start = new_line, .new_len = len, .start = at, .end = eol, .deleted_file = deleted });
            open = out.items.len - 1;
        } else if (open) |i| {
            const c = &out.items[i];
            if (line.len == 0 or line[0] == ' ') {
                new_line += 1;
            } else if (line[0] == '+' or line[0] == '-') {
                if (!seen_change) c.line = @max(new_line, 1);
                seen_change = true;
                if (line[0] == '+') {
                    c.added += 1;
                    new_line += 1;
                } else c.removed += 1;
            } else if (line[0] != '\\') {
                // Not a diff line: the hunk is over.
                open = null;
                continue;
            }
            c.end = eol;
        }
    }
}

test "a diff's changes: the file, the first changed line, how much" {
    const gpa = std.testing.allocator;
    const text =
        \\diff --git a/src/a.zig b/src/a.zig
        \\index 111..222 100644
        \\--- a/src/a.zig
        \\+++ b/src/a.zig
        \\@@ -10,7 +10,8 @@ fn main() void {
        \\ one
        \\ two
        \\ three
        \\-old
        \\+new
        \\+more
        \\ four
        \\@@ -40,3 +41,2 @@
        \\ x
        \\-gone
        \\ y
        \\diff --git a/old.txt b/old.txt
        \\deleted file mode 100644
        \\--- a/old.txt
        \\+++ /dev/null
        \\@@ -1,2 +0,0 @@
        \\-a
        \\-b
        \\
    ;
    var list: std.ArrayList(Change) = .empty;
    defer list.deinit(gpa);
    try changes(gpa, text, &list);
    try std.testing.expectEqual(3, list.items.len);
    try std.testing.expectEqualStrings("src/a.zig", list.items[0].path);
    try std.testing.expectEqual(13, list.items[0].line);
    try std.testing.expectEqual(2, list.items[0].added);
    try std.testing.expectEqual(1, list.items[0].removed);
    try std.testing.expect(std.mem.startsWith(u8, text[list.items[0].start..list.items[0].end], "@@ -10,7"));
    try std.testing.expect(std.mem.endsWith(u8, text[list.items[0].start..list.items[0].end], " four"));
    try std.testing.expectEqual(42, list.items[1].line);
    try std.testing.expectEqual(1, list.items[1].removed);
    try std.testing.expectEqualStrings("old.txt", list.items[2].path);
    try std.testing.expect(list.items[2].deleted_file);
    try std.testing.expectEqual(2, list.items[2].removed);
}
