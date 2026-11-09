//! Monospace font on a fixed cell grid.
//!
//! raylib bakes a glyph atlas at load time for a fixed codepoint set, with no
//! fallback fonts and no shaping. That is fine for a monospace grid, but the
//! set below is a stopgap: DESIGN.md plans an on-demand glyph cache (needed for
//! CJK, emoji and Nerd Font icons, especially in the terminal).

const std = @import("std");
const Io = std.Io;
const Allocator = std.mem.Allocator;
const rl = @import("raylib");
const gfx = @import("gfx.zig");
const Grid = @import("../tui/Grid.zig");

const Font = @This();

font: rl.Font,
/// Pixel size the atlas was rasterized at.
size: i32,
cell_w: f32,
cell_h: f32,
/// Offset from a cell's top to the glyph box's top, centering it vertically.
glyph_y: f32,
/// Terminal mode: no atlas; glyphs go to the cell grid (the terminal draws
/// them with its own font).
grid_mode: bool = false,

/// The "font" of terminal mode: a cell in the grid's pixel units.
pub fn cells() Font {
    return .{ .font = undefined, .size = 0, .cell_w = Grid.cell_w, .cell_h = Grid.cell_h, .glyph_y = 0, .grid_mode = true };
}

const line_height = 1.3;

/// Codepoint ranges baked into the atlas.
const ranges = [_][2]u21{
    .{ 0x0020, 0x007E }, // ASCII
    .{ 0x00A0, 0x017F }, // Latin-1 supplement, Latin extended-A
    .{ 0x2000, 0x206F }, // general punctuation
    .{ 0x2190, 0x21FF }, // arrows
    .{ 0x2500, 0x259F }, // box drawing, block elements
    .{ 0x25A0, 0x25FF }, // geometric shapes
    .{ 0x2700, 0x27BF }, // dingbats (✓ ✗)
    .{ 0xFFFD, 0xFFFD }, // replacement character
};

const codepoints = blk: {
    @setEvalBranchQuota(10_000);
    var n: usize = 0;
    for (ranges) |r| n += r[1] - r[0] + 1;
    var out: [n]c_int = undefined;
    var i: usize = 0;
    for (ranges) |r| {
        for (r[0]..r[1] + 1) |cp| {
            out[i] = cp;
            i += 1;
        }
    }
    const result = out;
    break :blk result;
};

/// Common monospace font locations, tried in order before asking fontconfig.
const candidates = [_][]const u8{
    "/usr/share/fonts/TTF/JetBrainsMonoNerdFontMono-Regular.ttf",
    "/usr/share/fonts/TTF/JetBrainsMono-Regular.ttf",
    "/usr/share/fonts/truetype/jetbrains-mono/JetBrainsMono-Regular.ttf",
    "/usr/share/fonts/TTF/DejaVuSansMono.ttf",
    "/usr/share/fonts/truetype/dejavu/DejaVuSansMono.ttf",
};

pub const LoadError = error{FontLoadFailed} || Allocator.Error;

/// Loads `path`, or discovers a monospace font when null.
pub fn load(gpa: Allocator, io: Io, path: ?[]const u8, size: i32) LoadError!Font {
    const resolved: [:0]u8 = if (path) |p|
        try gpa.dupeSentinel(u8, p, 0)
    else
        try discover(gpa, io) orelse return error.FontLoadFailed;
    defer gpa.free(resolved);

    const font = rl.LoadFontEx(resolved.ptr, size, &codepoints, codepoints.len);
    if (!rl.IsFontValid(font) or font.glyphCount == 0) {
        std.log.err("could not load font '{s}'", .{resolved});
        return error.FontLoadFailed;
    }
    // Glyphs are rasterized at the exact size and drawn at integer positions.
    rl.SetTextureFilter(font.texture, rl.TEXTURE_FILTER_POINT);

    const m = @as(usize, @intCast(rl.GetGlyphIndex(font, 'M')));
    const advance: f32 = if (font.glyphs[m].advanceX > 0)
        @floatFromInt(font.glyphs[m].advanceX)
    else
        font.recs[m].width;
    const base: f32 = @floatFromInt(font.baseSize);
    const cell_h = @round(base * line_height);
    return .{
        .font = font,
        .size = size,
        // Integer cells keep every glyph pixel-aligned.
        .cell_w = @max(@round(advance), 1),
        .cell_h = cell_h,
        .glyph_y = @floor((cell_h - base) / 2),
    };
}

pub fn deinit(f: *Font) void {
    if (!f.grid_mode) rl.UnloadFont(f.font);
    f.* = undefined;
}

fn discover(gpa: Allocator, io: Io) Allocator.Error!?[:0]u8 {
    for (candidates) |c| {
        if (Io.Dir.accessAbsolute(io, c, .{})) |_| {
            return try gpa.dupeSentinel(u8, c, 0);
        } else |_| {}
    }
    const result = std.process.run(gpa, io, .{
        .argv = &.{ "fc-match", "-f", "%{file}", "monospace" },
    }) catch return null;
    defer gpa.free(result.stdout);
    defer gpa.free(result.stderr);
    const file = std.mem.trim(u8, result.stdout, " \n");
    if (file.len == 0) return null;
    return try gpa.dupeSentinel(u8, file, 0);
}

/// Draws one codepoint with its cell's top-left at (x, y).
pub fn drawCodepoint(f: *const Font, cp: u21, x: f32, y: f32, color: rl.Color) void {
    if (f.grid_mode) return gfx.glyph(cp, x, y, color);
    rl.DrawTextCodepoint(f.font, cp, .{ .x = x, .y = y + f.glyph_y }, @floatFromInt(f.font.baseSize), color);
}

/// Draws UTF-8 `s` one cell per codepoint. Returns the x after the last cell.
pub fn drawText(f: *const Font, s: []const u8, x: f32, y: f32, color: rl.Color) f32 {
    var cx = x;
    var it = Utf8Lossy{ .bytes = s };
    while (it.next()) |cp| {
        if (cp != ' ') f.drawCodepoint(cp, cx, y, color);
        cx += f.cell_w;
    }
    return cx;
}

/// Decodes UTF-8, yielding U+FFFD for each invalid byte instead of failing.
pub const Utf8Lossy = struct {
    bytes: []const u8,
    i: usize = 0,

    pub fn next(it: *Utf8Lossy) ?u21 {
        if (it.i >= it.bytes.len) return null;
        const b = it.bytes[it.i];
        const n = std.unicode.utf8ByteSequenceLength(b) catch {
            it.i += 1;
            return 0xFFFD;
        };
        if (it.i + n > it.bytes.len) {
            it.i += 1;
            return 0xFFFD;
        }
        const cp = std.unicode.utf8Decode(it.bytes[it.i .. it.i + n]) catch {
            it.i += 1;
            return 0xFFFD;
        };
        it.i += n;
        return cp;
    }
};
