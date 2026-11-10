//! Indent scopes (mini.indentscope): the run of lines around a line that are
//! indented at least as much as it, with the less-indented lines above and
//! below as its borders. Pure.

const std = @import("std");
const Text = @import("Text.zig");
const motions = @import("motions.zig");

pub const Scope = struct {
    /// The scope's lines (inclusive).
    first: usize,
    last: usize,
    /// The scope's own indentation, in display columns.
    indent: usize,
    /// Where the guide is drawn: the indentation of the deeper border.
    guide_col: usize,
    /// The less-indented lines just outside, if any.
    top: ?usize,
    bottom: ?usize,
};

/// A line's indentation in display columns, or null for a blank line.
pub fn lineIndent(t: *const Text, line: usize, tab_width: usize) ?usize {
    const bytes = t.lineSlice(line);
    const first = std.mem.indexOfNone(u8, bytes, " \t") orelse return null;
    return motions.displayCol(bytes, first, tab_width);
}

fn nearestIndent(t: *const Text, line: usize, tab_width: usize, comptime dir: isize) ?usize {
    var l = line;
    while (true) {
        if (dir < 0) {
            if (l == 0) return null;
            l -= 1;
        } else {
            l += 1;
            if (l >= t.lineCount()) return null;
        }
        if (lineIndent(t, l, tab_width)) |i| return i;
    }
}

/// The scope of `line`. With `as_border`, a line that opens a deeper block
/// (`fn f() {`) gives that block's scope. Null when there is no indentation.
pub fn scope(t: *const Text, line: usize, tab_width: usize, as_border: bool) ?Scope {
    const n = t.lineCount();
    if (line >= n) return null;
    var at = line;
    var ind: usize = lineIndent(t, line, tab_width) orelse
        @max(nearestIndent(t, line, tab_width, -1) orelse 0, nearestIndent(t, line, tab_width, 1) orelse 0);
    // On a border: the block it opens.
    if (as_border and lineIndent(t, line, tab_width) != null) {
        if (nearestIndent(t, line, tab_width, 1)) |below| if (below > ind and line + 1 < n) {
            ind = below;
            at = line + 1;
            while (at + 1 < n and lineIndent(t, at, tab_width) == null) at += 1;
        };
    }
    if (ind == 0) return null;

    var first = at;
    while (first > 0) {
        const i = lineIndent(t, first - 1, tab_width);
        if (i != null and i.? < ind) break;
        first -= 1;
    }
    var last = at;
    while (last + 1 < n) {
        const i = lineIndent(t, last + 1, tab_width);
        if (i != null and i.? < ind) break;
        last += 1;
    }
    const top: ?usize = if (first > 0) first - 1 else null;
    const bottom: ?usize = if (last + 1 < n) last + 1 else null;
    // Blank lines at the edges belong to nobody.
    while (first < at and lineIndent(t, first, tab_width) == null) first += 1;
    while (last > at and lineIndent(t, last, tab_width) == null) last -= 1;
    const top_ind = if (top) |l| lineIndent(t, l, tab_width) orelse 0 else 0;
    const bottom_ind = if (bottom) |l| lineIndent(t, l, tab_width) orelse 0 else 0;
    return .{
        .first = first,
        .last = last,
        .indent = ind,
        .guide_col = @max(top_ind, bottom_ind),
        .top = top,
        .bottom = bottom,
    };
}

const testing = std.testing;

test "scope of an indented block, from inside and from its border" {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, "fn f() {\n    a;\n\n    if (x) {\n        b;\n    }\n}\nlast");
    defer t.deinit(gpa);
    const s = scope(&t, 1, 4, true).?;
    try testing.expectEqual(1, s.first);
    try testing.expectEqual(5, s.last);
    try testing.expectEqual(0, s.guide_col);
    try testing.expectEqual(0, s.top.?);
    try testing.expectEqual(6, s.bottom.?);
    // The `if` line opens the inner block.
    const inner = scope(&t, 3, 4, true).?;
    try testing.expectEqual(4, inner.first);
    try testing.expectEqual(4, inner.last);
    try testing.expectEqual(4, inner.guide_col);
    // The function's first line opens its body.
    try testing.expectEqual(1, scope(&t, 0, 4, true).?.first);
    try testing.expectEqual(1, scope(&t, 3, 4, false).?.first);
    try testing.expectEqual(null, scope(&t, 0, 4, false));
    try testing.expectEqual(null, scope(&t, 7, 4, true));
}
