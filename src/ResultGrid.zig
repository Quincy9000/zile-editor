//! The results of a SQL statement as a grid you move in with vim's keys:
//! a cell cursor (`hjkl`, `w` / `b` the next / previous cell, `0` `$` `gg`
//! `G`, counts), `v` a block of cells, `V` whole rows, `y` yanks, `/`
//! searches (`n` / `N`).
//!
//! Only the state and the keys are here; `ui/picker_view.zig` draws it and
//! the editor owns it (`Editor.grid`) and the rows it looks at.

const std = @import("std");
const Allocator = std.mem.Allocator;
const keys = @import("input/keys.zig");
const KeyEvent = keys.KeyEvent;

const Grid = @This();

gpa: Allocator,
/// Borrowed: the editor keeps the results while the grid is open.
columns: []const []const u8,
rows: []const []const []const u8,
/// Each column's width on screen, in cells.
widths: []usize,
row: usize = 0,
col: usize = 0,
/// First row and column shown (the view keeps the cursor in sight).
top: usize = 0,
left: usize = 0,
visual: Visual = .none,
anchor_row: usize = 0,
anchor_col: usize = 0,
/// A count being typed (`5j`); 0: none.
count: usize = 0,
/// `g` was typed: `gg` goes to the top.
pending_g: bool = false,
/// `/` is being typed into `input`.
typing: bool = false,
input: std.ArrayList(u8) = .empty,
/// The last search, for `n` / `N` and for the view to mark.
search: std.ArrayList(u8) = .empty,
/// Rows the view shows (it says; half of it is Ctrl-d's step).
page: usize = 10,

pub const Visual = enum { none, cells, rows };

/// A column is at most this wide on screen (the value line below the grid
/// shows the cell under the cursor in full).
pub const max_width = 40;

/// What a key asks of the editor.
pub const Outcome = union(enum) {
    /// Used (or ignored): nothing more to do.
    stay,
    close,
    /// Text for the yank register (owned by the caller from here), and what
    /// to say about it.
    yank: struct { text: []u8, what: []const u8, n: usize },
    /// `o`: the results as a table in a buffer.
    table,
    /// The search found nothing.
    not_found,
};

pub fn init(gpa: Allocator, columns: []const []const u8, rows: []const []const []const u8) !Grid {
    const widths = try gpa.alloc(usize, columns.len);
    for (columns, widths) |name, *w| w.* = @max(cellsOf(name), 1);
    // Enough rows to size the columns by; a million would take a moment.
    for (rows[0..@min(rows.len, 5000)]) |r| for (r, 0..) |value, c| {
        if (c < widths.len) widths[c] = @max(widths[c], @min(cellsOf(value), max_width));
    };
    return .{ .gpa = gpa, .columns = columns, .rows = rows, .widths = widths };
}

pub fn deinit(g: *Grid) void {
    g.gpa.free(g.widths);
    g.input.deinit(g.gpa);
    g.search.deinit(g.gpa);
}

fn cellsOf(value: []const u8) usize {
    return std.unicode.utf8CountCodepoints(value) catch value.len;
}

/// The value at `r`, `c` ("" where a row is short).
pub fn cell(g: *const Grid, r: usize, c: usize) []const u8 {
    if (r >= g.rows.len or c >= g.rows[r].len) return "";
    return g.rows[r][c];
}

pub const Range = struct { r0: usize, r1: usize, c0: usize, c1: usize };

/// What is selected: the cursor's cell, the block from the anchor to it,
/// or its rows.
pub fn selection(g: *const Grid) Range {
    const last_col = g.columns.len -| 1;
    return switch (g.visual) {
        .none => .{ .r0 = g.row, .r1 = g.row, .c0 = g.col, .c1 = g.col },
        .cells => .{ .r0 = @min(g.row, g.anchor_row), .r1 = @max(g.row, g.anchor_row), .c0 = @min(g.col, g.anchor_col), .c1 = @max(g.col, g.anchor_col) },
        .rows => .{ .r0 = @min(g.row, g.anchor_row), .r1 = @max(g.row, g.anchor_row), .c0 = 0, .c1 = last_col },
    };
}

pub fn selected(g: *const Grid, r: usize, c: usize) bool {
    if (g.visual == .none) return false;
    const s = g.selection();
    return r >= s.r0 and r <= s.r1 and c >= s.c0 and c <= s.c1;
}

/// Whether the cell at `r`, `c` holds the last search.
pub fn matches(g: *const Grid, r: usize, c: usize) bool {
    return g.search.items.len > 0 and containsFold(g.cell(r, c), g.search.items);
}

/// `needle` in `hay`, letter case aside (ASCII).
fn containsFold(hay: []const u8, needle: []const u8) bool {
    if (needle.len > hay.len) return false;
    for (0..hay.len - needle.len + 1) |i| {
        if (std.ascii.eqlIgnoreCase(hay[i .. i + needle.len], needle)) return true;
    }
    return false;
}

/// Rows `r0..r1`, columns `c0..c1`: tabs between values, a line per row
/// (what a sheet takes). One cell is its value as it is.
fn text(g: *const Grid, s: Range) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(g.gpa);
    for (s.r0..s.r1 + 1) |r| {
        if (r > s.r0) try out.append(g.gpa, '\n');
        for (s.c0..s.c1 + 1) |c| {
            if (c > s.c0) try out.append(g.gpa, '\t');
            try out.appendSlice(g.gpa, g.cell(r, c));
        }
    }
    return out.toOwnedSlice(g.gpa);
}

fn moveRow(g: *Grid, delta: isize) void {
    const last: isize = @intCast(g.rows.len -| 1);
    g.row = @intCast(std.math.clamp(@as(isize, @intCast(g.row)) + delta, 0, last));
}

fn moveCol(g: *Grid, delta: isize) void {
    const last: isize = @intCast(g.columns.len -| 1);
    g.col = @intCast(std.math.clamp(@as(isize, @intCast(g.col)) + delta, 0, last));
}

/// `w` / `b`: the next / previous cell, on to the next row from a row's end.
fn moveCell(g: *Grid, forward: bool) void {
    const cols = g.columns.len;
    if (cols == 0 or g.rows.len == 0) return;
    const at = g.row * cols + g.col;
    const last = g.rows.len * cols - 1;
    const to = if (forward) @min(at + 1, last) else at -| 1;
    g.row = to / cols;
    g.col = to % cols;
}

/// The next (or previous) cell holding the search, from the cursor on,
/// around the end. False when no cell has it.
fn find(g: *Grid, forward: bool) bool {
    const cols = g.columns.len;
    const total = g.rows.len * cols;
    if (total == 0 or g.search.items.len == 0) return false;
    const at = g.row * cols + g.col;
    for (1..total + 1) |step| {
        const i = if (forward) (at + step) % total else (at + total - (step % total)) % total;
        if (g.matches(i / cols, i % cols)) {
            g.row = i / cols;
            g.col = i % cols;
            return true;
        }
    }
    return false;
}

/// A key while the grid is open.
pub fn key(g: *Grid, ev: KeyEvent) !Outcome {
    if (g.typing) return g.searchKey(ev);
    const ctrl = ev.mods.ctrl and !ev.mods.alt;
    if (ev.key == .special) {
        switch (ev.key.special) {
            .escape => {
                g.count = 0;
                g.pending_g = false;
                if (g.visual != .none) {
                    g.visual = .none;
                    return .stay;
                }
                return .close;
            },
            .left => g.moveCol(-1),
            .right => g.moveCol(1),
            .up => g.moveRow(-1),
            .down, .enter => g.moveRow(1),
            .tab => g.moveCell(!ev.mods.shift),
            .home => g.col = 0,
            .end => g.col = g.columns.len -| 1,
            .page_down => g.moveRow(@intCast(g.page)),
            .page_up => g.moveRow(-@as(isize, @intCast(g.page))),
            else => {},
        }
        return .stay;
    }
    const cp = ev.key.codepoint;
    if (ctrl) {
        const half: isize = @intCast(@max(g.page / 2, 1));
        switch (cp) {
            'd' => g.moveRow(half),
            'u' => g.moveRow(-half),
            'f' => g.moveRow(@intCast(g.page)),
            'b' => g.moveRow(-@as(isize, @intCast(g.page))),
            'v' => g.startVisual(.cells),
            else => {},
        }
        return .stay;
    }
    if (ev.mods.alt) return .stay;
    // A count: digits, a 0 only after another digit (alone it is a motion).
    if (cp >= '1' and cp <= '9' or (cp == '0' and g.count > 0)) {
        g.count = @min(g.count * 10 + (cp - '0'), 1_000_000);
        return .stay;
    }
    const had_count = g.count > 0;
    const n: isize = @intCast(@max(g.count, 1));
    g.count = 0;
    const was_g = g.pending_g;
    g.pending_g = false;
    switch (cp) {
        'h' => g.moveCol(-n),
        'l' => g.moveCol(n),
        'j' => g.moveRow(n),
        'k' => g.moveRow(-n),
        'w', 'e' => for (0..@intCast(n)) |_| g.moveCell(true),
        'b' => for (0..@intCast(n)) |_| g.moveCell(false),
        '0', '^' => g.col = 0,
        '$' => g.col = g.columns.len -| 1,
        'g' => if (was_g) {
            g.row = if (had_count) @min(@as(usize, @intCast(n)) - 1, g.rows.len -| 1) else 0;
        } else {
            g.pending_g = true;
            // The count is `gg`'s.
            if (had_count) g.count = @intCast(n);
        },
        'G' => g.row = if (had_count) @min(@as(usize, @intCast(n)) - 1, g.rows.len -| 1) else g.rows.len -| 1,
        'v' => g.startVisual(.cells),
        'V' => g.startVisual(.rows),
        'y' => {
            const s = g.selection();
            const what: []const u8 = switch (g.visual) {
                .none => "the cell",
                .cells => "cells",
                .rows => "rows",
            };
            const count = switch (g.visual) {
                .none => 1,
                .cells => (s.r1 - s.r0 + 1) * (s.c1 - s.c0 + 1),
                .rows => s.r1 - s.r0 + 1,
            };
            g.visual = .none;
            return .{ .yank = .{ .text = try g.text(s), .what = what, .n = count } };
        },
        // The cursor's row, whole (as `yy` on a line).
        'Y' => {
            const last = g.columns.len -| 1;
            const s: Range = if (g.visual == .none) .{ .r0 = g.row, .r1 = g.row, .c0 = 0, .c1 = last } else .{ .r0 = g.selection().r0, .r1 = g.selection().r1, .c0 = 0, .c1 = last };
            g.visual = .none;
            return .{ .yank = .{ .text = try g.text(s), .what = "rows", .n = s.r1 - s.r0 + 1 } };
        },
        '/' => {
            g.typing = true;
            g.input.clearRetainingCapacity();
        },
        'n' => if (!g.find(true)) return .not_found,
        'N' => if (!g.find(false)) return .not_found,
        'o' => return .table,
        'q' => return .close,
        else => {},
    }
    return .stay;
}

fn startVisual(g: *Grid, kind: Visual) void {
    // The same key again leaves it; the other one switches kind.
    if (g.visual == kind) {
        g.visual = .none;
        return;
    }
    if (g.visual == .none) {
        g.anchor_row = g.row;
        g.anchor_col = g.col;
    }
    g.visual = kind;
}

/// Keys while `/` is being typed.
fn searchKey(g: *Grid, ev: KeyEvent) !Outcome {
    if (ev.key == .special) switch (ev.key.special) {
        .escape => g.typing = false,
        .backspace => {
            // A whole character.
            var len = g.input.items.len;
            if (len == 0) {
                g.typing = false;
                return .stay;
            }
            len -= 1;
            while (len > 0 and g.input.items[len] & 0xC0 == 0x80) len -= 1;
            g.input.shrinkRetainingCapacity(len);
        },
        .enter => {
            g.typing = false;
            g.search.clearRetainingCapacity();
            try g.search.appendSlice(g.gpa, g.input.items);
            if (g.search.items.len == 0) return .stay;
            // The cursor's own cell counts: it may be what you looked for.
            if (g.matches(g.row, g.col)) return .stay;
            if (!g.find(true)) return .not_found;
        },
        else => {},
    } else if (ev.text()) |cp| {
        var buf: [4]u8 = undefined;
        const len = std.unicode.utf8Encode(cp, &buf) catch return .stay;
        try g.input.appendSlice(g.gpa, buf[0..len]);
    }
    return .stay;
}

/// Keeps the cursor in sight for a view of `rows` rows and `cols` cells of
/// columns (each column takes its width and a 3-cell divider).
pub fn scrollTo(g: *Grid, rows: usize, cols: usize) void {
    g.page = @max(rows, 1);
    if (g.row < g.top) g.top = g.row;
    if (g.row >= g.top + g.page) g.top = g.row + 1 - g.page;
    if (g.col < g.left) g.left = g.col;
    // Columns `left..=col` have to fit: drop from the left until they do.
    while (g.left < g.col) {
        var used: usize = 0;
        for (g.left..g.col + 1) |c| used += g.widths[c] + 3;
        if (used <= cols + 3) break;
        g.left += 1;
    }
}

const testing = std.testing;

fn feed(g: *Grid, text_keys: []const u8) !Outcome {
    var last: Outcome = .stay;
    for (text_keys) |b| last = try g.key(.char(b));
    return last;
}

test "moving by cell, counts, the edges" {
    const rows = [_][]const []const u8{ &.{ "1", "ann", "x" }, &.{ "2", "bob", "y" }, &.{ "3", "cy", "z" } };
    var g = try Grid.init(testing.allocator, &.{ "id", "name", "k" }, &rows);
    defer g.deinit();
    _ = try feed(&g, "lj");
    try testing.expectEqualStrings("bob", g.cell(g.row, g.col));
    _ = try feed(&g, "ww"); // past the row's end: the next row's first cell
    try testing.expectEqualStrings("3", g.cell(g.row, g.col));
    _ = try feed(&g, "b");
    try testing.expectEqualStrings("y", g.cell(g.row, g.col));
    _ = try feed(&g, "gg0");
    try testing.expectEqual(0, g.row + g.col);
    _ = try feed(&g, "2j9l"); // clamped at the last row and column
    try testing.expectEqualStrings("z", g.cell(g.row, g.col));
    _ = try feed(&g, "2G0");
    try testing.expectEqualStrings("2", g.cell(g.row, g.col));
    _ = try feed(&g, "G$");
    try testing.expectEqualStrings("z", g.cell(g.row, g.col));
}

test "yanking: a cell, a block, rows" {
    const rows = [_][]const []const u8{ &.{ "1", "ann", "x" }, &.{ "2", "bob", "y" }, &.{ "3", "cy", "z" } };
    var g = try Grid.init(testing.allocator, &.{ "id", "name", "k" }, &rows);
    defer g.deinit();
    var out = try feed(&g, "ly");
    try testing.expectEqualStrings("ann", out.yank.text);
    testing.allocator.free(out.yank.text);
    // A block: two columns of two rows.
    out = try feed(&g, "vjly");
    try testing.expectEqualStrings("ann\tx\nbob\ty", out.yank.text);
    try testing.expectEqual(4, out.yank.n);
    testing.allocator.free(out.yank.text);
    try testing.expect(g.visual == .none);
    // Rows, whole, wherever the cursor's column is.
    out = try feed(&g, "Vky");
    try testing.expectEqualStrings("1\tann\tx\n2\tbob\ty", out.yank.text);
    testing.allocator.free(out.yank.text);
    out = try feed(&g, "GY");
    try testing.expectEqualStrings("3\tcy\tz", out.yank.text);
    testing.allocator.free(out.yank.text);
}

test "searching: / then n and N, around the end; Esc leaves visual, then closes" {
    const rows = [_][]const []const u8{ &.{ "1", "ann", "x" }, &.{ "2", "Bob", "y" }, &.{ "3", "bobby", "z" } };
    var g = try Grid.init(testing.allocator, &.{ "id", "name", "k" }, &rows);
    defer g.deinit();
    _ = try feed(&g, "/bob");
    try testing.expect(g.typing);
    _ = try g.key(.special(.enter));
    try testing.expectEqualStrings("Bob", g.cell(g.row, g.col));
    _ = try feed(&g, "n");
    try testing.expectEqualStrings("bobby", g.cell(g.row, g.col));
    _ = try feed(&g, "n"); // around
    try testing.expectEqualStrings("Bob", g.cell(g.row, g.col));
    _ = try feed(&g, "N");
    try testing.expectEqualStrings("bobby", g.cell(g.row, g.col));
    _ = try feed(&g, "/nope");
    try testing.expect(try g.key(.special(.enter)) == .not_found);
    _ = try feed(&g, "v");
    try testing.expect(try g.key(.special(.escape)) == .stay);
    try testing.expect(try g.key(.special(.escape)) == .close);
}
