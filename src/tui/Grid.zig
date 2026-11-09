//! A terminal screen as a grid of cells, drawn into by the same UI code as
//! the window. That code works in pixels; here a cell is `cell_w` x `cell_h`
//! "pixels", and each drawing call maps onto cells:
//!   - a rectangle covering cells paints their background (opaque ones also
//!     clear the text under them, as a popup hides the editor);
//!     translucent ones tint (the dim backdrop behind pickers);
//!   - a thin horizontal one near a cell's bottom underlines (diagnostics);
//!   - a thin vertical one draws `│` in empty cells (dividers, git signs);
//!   - text puts one codepoint per cell.
//! The terminal's own cursor shows where the UI asks (`cursor`).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Color = @import("raylib").Color;

const Grid = @This();

pub const cell_w: f32 = 10;
pub const cell_h: f32 = 20;

pub const Cell = struct {
    cp: u21 = ' ',
    fg: Color = .{ .r = 255, .g = 255, .b = 255, .a = 255 },
    bg: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 },
    /// Underline color, if underlined.
    ul: ?Color = null,

    pub fn eql(a: Cell, b: Cell) bool {
        const same_ul = if (a.ul) |x| (if (b.ul) |y| sameColor(x, y) else false) else b.ul == null;
        return a.cp == b.cp and sameColor(a.fg, b.fg) and sameColor(a.bg, b.bg) and same_ul;
    }
};

pub const CursorShape = enum { block, bar, underline };

cols: usize = 0,
rows: usize = 0,
cells: []Cell = &.{},
/// Drawing offset (a window's origin), in pixels; a small stack.
offsets: [8][2]f32 = undefined,
depth: usize = 0,
off: [2]f32 = .{ 0, 0 },
/// Drawing is limited to this rectangle (absolute pixels), if set.
clip: ?[4]f32 = null,
/// Where the terminal cursor goes this frame (null: hidden).
cursor: ?struct { col: usize, row: usize, shape: CursorShape } = null,

pub fn deinit(g: *Grid, gpa: Allocator) void {
    gpa.free(g.cells);
}

pub fn resize(g: *Grid, gpa: Allocator, cols: usize, rows: usize) !void {
    if (cols == g.cols and rows == g.rows) return;
    gpa.free(g.cells);
    g.cells = try gpa.alloc(Cell, cols * rows);
    g.cols = cols;
    g.rows = rows;
}

/// Starts a frame: every cell blank in `bg`.
pub fn clear(g: *Grid, bg: Color) void {
    @memset(g.cells, .{ .bg = bg, .fg = bg });
    g.depth = 0;
    g.off = .{ 0, 0 };
    g.clip = null;
    g.cursor = null;
}

pub fn pushOffset(g: *Grid, x: f32, y: f32) void {
    if (g.depth < g.offsets.len) g.offsets[g.depth] = g.off;
    g.depth += 1;
    g.off = .{ g.off[0] + x, g.off[1] + y };
}

pub fn popOffset(g: *Grid) void {
    if (g.depth == 0) return;
    g.depth -= 1;
    if (g.depth < g.offsets.len) g.off = g.offsets[g.depth];
}

fn sameColor(a: Color, b: Color) bool {
    return a.r == b.r and a.g == b.g and a.b == b.b;
}

/// `top` over `under` by `top`'s alpha.
fn blend(under: Color, top: Color) Color {
    const a: u32 = top.a;
    const mix = struct {
        fn f(u: u8, t: u8, al: u32) u8 {
            return @intCast((@as(u32, t) * al + @as(u32, u) * (255 - al)) / 255);
        }
    }.f;
    return .{ .r = mix(under.r, top.r, a), .g = mix(under.g, top.g, a), .b = mix(under.b, top.b, a), .a = 255 };
}

fn cellIndex(v: f32, size: f32) isize {
    return @intFromFloat(@round(v / size));
}

/// The cells (half-open ranges) a rectangle covers, clipped.
fn span(g: *const Grid, x: f32, y: f32, w: f32, h: f32) struct { c0: usize, c1: usize, r0: usize, r1: usize } {
    var x0 = x + g.off[0];
    var y0 = y + g.off[1];
    var x1 = x0 + w;
    var y1 = y0 + h;
    if (g.clip) |c| {
        x0 = @max(x0, c[0]);
        y0 = @max(y0, c[1]);
        x1 = @min(x1, c[0] + c[2]);
        y1 = @min(y1, c[1] + c[3]);
    }
    const clamp = struct {
        fn f(v: isize, max: usize) usize {
            return @intCast(std.math.clamp(v, 0, @as(isize, @intCast(max))));
        }
    }.f;
    return .{
        .c0 = clamp(cellIndex(x0, cell_w), g.cols),
        .c1 = clamp(cellIndex(x1, cell_w), g.cols),
        .r0 = clamp(cellIndex(y0, cell_h), g.rows),
        .r1 = clamp(cellIndex(y1, cell_h), g.rows),
    };
}

pub fn rect(g: *Grid, x: f32, y: f32, w: f32, h: f32, color: Color) void {
    if (w <= 0 or h <= 0 or color.a == 0) return;
    const thin_w = w < cell_w / 2;
    const thin_h = h < cell_h / 2;
    if (thin_w and thin_h) return;
    if (thin_h) {
        // A line near a row's bottom underlines that row.
        const ay = y + g.off[1];
        const row_f = @floor(ay / cell_h);
        if (ay - row_f * cell_h < cell_h / 2) return;
        const s = g.span(x, row_f * cell_h - g.off[1], w, cell_h);
        for (s.r0..s.r1) |r| for (s.c0..s.c1) |c| {
            g.cells[r * g.cols + c].ul = color;
        };
        return;
    }
    if (thin_w) {
        // A vertical line: `│` where nothing is drawn yet.
        const ax = x + g.off[0];
        const col_f = @floor(ax / cell_w);
        const s = g.span(col_f * cell_w - g.off[0], y, cell_w, h);
        for (s.r0..s.r1) |r| for (s.c0..s.c1) |c| {
            const cell = &g.cells[r * g.cols + c];
            if (cell.cp == ' ') {
                cell.cp = '│';
                cell.fg = color;
            }
        };
        return;
    }
    const s = g.span(x, y, w, h);
    for (s.r0..s.r1) |r| for (s.c0..s.c1) |c| {
        const cell = &g.cells[r * g.cols + c];
        if (color.a == 255) {
            cell.* = .{ .bg = color, .fg = cell.fg };
        } else {
            cell.bg = blend(cell.bg, color);
            cell.fg = blend(cell.fg, color);
            if (cell.ul) |u| cell.ul = blend(u, color);
        }
    };
}

/// One codepoint in the cell at (x, y).
pub fn put(g: *Grid, cp: u21, x: f32, y: f32, color: Color) void {
    const s = g.span(x, y, cell_w, cell_h);
    if (s.c0 >= s.c1 or s.r0 >= s.r1) return;
    const cell = &g.cells[s.r0 * g.cols + s.c0];
    cell.cp = cp;
    cell.fg = if (color.a == 255) color else blend(cell.bg, color);
}

pub fn setCursor(g: *Grid, x: f32, y: f32, shape: CursorShape) void {
    const s = g.span(x, y, cell_w, cell_h);
    if (s.c0 >= s.c1 or s.r0 >= s.r1) return;
    g.cursor = .{ .col = s.c0, .row = s.r0, .shape = shape };
}

test "rectangles, lines and text map onto cells" {
    var g: Grid = .{};
    defer g.deinit(std.testing.allocator);
    try g.resize(std.testing.allocator, 10, 4);
    const black: Color = .{ .r = 0, .g = 0, .b = 0, .a = 255 };
    const red: Color = .{ .r = 255, .g = 0, .b = 0, .a = 255 };
    g.clear(black);
    g.put('a', 10, 20, red);
    try std.testing.expectEqual('a', g.cells[1 * 10 + 1].cp);
    // An underline 2px high at the bottom of row 1.
    g.rect(10, 20 + 18, 30, 2, red);
    try std.testing.expect(g.cells[1 * 10 + 1].ul != null);
    try std.testing.expect(g.cells[1 * 10 + 4].ul == null);
    // A 1px divider at column 5.
    g.rect(50, 0, 1, 80, red);
    try std.testing.expectEqual('│', g.cells[2 * 10 + 5].cp);
    // An opaque popup over the text clears it; with an offset.
    g.pushOffset(10, 20);
    g.rect(0, 0, 20, 20, red);
    g.popOffset();
    try std.testing.expectEqual(' ', g.cells[1 * 10 + 1].cp);
    try std.testing.expectEqual(255, g.cells[1 * 10 + 2].bg.r);
}
