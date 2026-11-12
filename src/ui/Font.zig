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
const icons = @import("icons.zig");
const Gsub = @import("Gsub.zig");

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
/// The font has the Nerd Font file icons (a terminal's font is its own
/// business: assumed there).
has_icons: bool = true,
/// Its ligatures (null: it has none; a terminal draws its own).
lig: ?*Ligatures = null,

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
    var out: [n + icons.codepoints.len]c_int = undefined;
    for (icons.codepoints, n..) |cp, at| out[at] = cp;
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
    // Only glyphs the font has are in the atlas.
    const probe = @as(usize, @intCast(rl.GetGlyphIndex(font, icons.folder.cp)));
    return .{
        .lig = Ligatures.load(gpa, io, resolved, size),
        .has_icons = font.glyphs[probe].value == icons.folder.cp,
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
    if (f.lig) |l| l.destroy();
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
    // Whole pixels: the atlas is sampled pixel for pixel, and a glyph drawn
    // between pixels comes out uneven (half rows, e.g. which-key padding).
    rl.DrawTextCodepoint(f.font, cp, .{ .x = @round(x), .y = @round(y + f.glyph_y) }, @floatFromInt(f.font.baseSize), color);
}

/// The ligatures of a line of text (UTF-8 `bytes`): per codepoint, the
/// glyph to draw in its cell instead of its own, or 0 to keep its own. Null
/// when the line has none (or the font, or the line is very long).
pub fn ligatures(f: *const Font, bytes: []const u8) ?[]const u16 {
    const l = f.lig orelse return null;
    return l.line(bytes);
}

/// Draws glyph `glyph` (a ligature's part) with its cell's top-left at (x, y).
pub fn drawGlyph(f: *const Font, glyph: u16, x: f32, y: f32, color: rl.Color) void {
    const l = f.lig orelse return;
    const g = l.glyph(glyph) orelse return;
    rl.DrawTexture(g.tex, @as(c_int, @intFromFloat(@round(x))) + g.x, @as(c_int, @intFromFloat(@round(y + f.glyph_y))) + g.y, color);
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

// ---------------------------------------------------------------------------
// Ligatures: the font's `calt` rules (Gsub.zig) pick each cell's glyph; the
// glyphs raylib's atlas doesn't have (it is baked per codepoint) are
// rasterized on demand (ttf.c, stb_truetype by glyph id).

extern fn zile_ttf_open(data: [*]const u8, pixel_height: c_int) ?*anyopaque;
extern fn zile_ttf_close(f: *anyopaque) void;
extern fn zile_ttf_glyph(f: *const anyopaque, codepoint: c_int) c_int;
extern fn zile_ttf_bitmap(f: *const anyopaque, glyph: c_int, w: *c_int, h: *c_int, xoff: *c_int, yoff: *c_int) ?[*]u8;
extern fn zile_ttf_free(b: [*]u8) void;

pub const Ligatures = struct {
    gpa: Allocator,
    /// The font file (the shaper and stb_truetype read it in place).
    data: []u8,
    ttf: *anyopaque,
    gsub: Gsub,
    /// Rasterized glyphs by id (null: an empty one, a ligature's spacer).
    glyphs: std.AutoHashMapUnmanaged(u16, ?Glyph) = .empty,
    /// Shaped lines by their text's hash (empty: none in it).
    lines: std.AutoHashMapUnmanaged(u64, []u16) = .empty,

    const Glyph = struct { tex: rl.Texture2D, x: c_int, y: c_int };
    /// Longer lines aren't shaped.
    const max_line = 1024;
    /// Shaped lines kept before the cache starts over.
    const max_lines = 4096;

    /// Null when the font has no ligatures (or can't be read).
    pub fn load(gpa: Allocator, io: Io, path: []const u8, size: i32) ?*Ligatures {
        const data = Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch return null;
        const gsub = (Gsub.init(gpa, data) catch null) orelse {
            gpa.free(data);
            return null;
        };
        const ttf = zile_ttf_open(data.ptr, size) orelse {
            var g = gsub;
            g.deinit(gpa);
            gpa.free(data);
            return null;
        };
        const l = gpa.create(Ligatures) catch {
            zile_ttf_close(ttf);
            var g = gsub;
            g.deinit(gpa);
            gpa.free(data);
            return null;
        };
        l.* = .{ .gpa = gpa, .data = data, .ttf = ttf, .gsub = gsub };
        return l;
    }

    pub fn destroy(l: *Ligatures) void {
        var it = l.glyphs.valueIterator();
        while (it.next()) |g| if (g.*) |gl| rl.UnloadTexture(gl.tex);
        l.glyphs.deinit(l.gpa);
        l.forgetLines();
        l.lines.deinit(l.gpa);
        l.gsub.deinit(l.gpa);
        zile_ttf_close(l.ttf);
        l.gpa.free(l.data);
        l.gpa.destroy(l);
    }

    fn forgetLines(l: *Ligatures) void {
        var it = l.lines.valueIterator();
        while (it.next()) |v| l.gpa.free(v.*);
        l.lines.clearRetainingCapacity();
    }

    fn line(l: *Ligatures, bytes: []const u8) ?[]const u16 {
        if (bytes.len == 0 or bytes.len > max_line) return null;
        const key = std.hash.Wyhash.hash(0, bytes);
        if (l.lines.get(key)) |v| return if (v.len == 0) null else v;
        const shaped = l.shape(bytes) catch return null;
        if (l.lines.count() >= max_lines) l.forgetLines();
        l.lines.put(l.gpa, key, shaped) catch {
            l.gpa.free(shaped);
            return null;
        };
        return if (shaped.len == 0) null else shaped;
    }

    /// Per codepoint the substituted glyph or 0; empty when none changed.
    fn shape(l: *Ligatures, bytes: []const u8) Allocator.Error![]u16 {
        var base: [max_line]u16 = undefined;
        var glyphs: [max_line]u16 = undefined;
        var n: usize = 0;
        var it = Utf8Lossy{ .bytes = bytes };
        while (it.next()) |cp| : (n += 1) {
            base[n] = @intCast(zile_ttf_glyph(l.ttf, cp));
            glyphs[n] = base[n];
        }
        l.gsub.apply(glyphs[0..n]);
        if (std.mem.eql(u16, base[0..n], glyphs[0..n])) return &.{};
        const out = try l.gpa.alloc(u16, n);
        for (out, base[0..n], glyphs[0..n]) |*o, b, g| o.* = if (g == b) 0 else g;
        return out;
    }

    /// Glyph `id`, rasterized the first time it is drawn.
    fn glyph(l: *Ligatures, id: u16) ?Glyph {
        if (l.glyphs.get(id)) |g| return g;
        const g = l.rasterize(id);
        l.glyphs.put(l.gpa, id, g) catch {};
        return g;
    }

    fn rasterize(l: *Ligatures, id: u16) ?Glyph {
        var w: c_int = 0;
        var h: c_int = 0;
        var x: c_int = 0;
        var y: c_int = 0;
        const bitmap = zile_ttf_bitmap(l.ttf, id, &w, &h, &x, &y) orelse return null;
        defer zile_ttf_free(bitmap);
        if (w <= 0 or h <= 0) return null;
        // White with the coverage as alpha, as raylib's own atlas.
        const n: usize = @intCast(w * h);
        const pixels = l.gpa.alloc(u8, 2 * n) catch return null;
        defer l.gpa.free(pixels);
        for (0..n) |i| {
            pixels[2 * i] = 255;
            pixels[2 * i + 1] = bitmap[i];
        }
        const tex = rl.LoadTextureFromImage(.{ .data = pixels.ptr, .width = w, .height = h, .mipmaps = 1, .format = rl.PIXELFORMAT_UNCOMPRESSED_GRAY_ALPHA });
        rl.SetTextureFilter(tex, rl.TEXTURE_FILTER_POINT);
        return .{ .tex = tex, .x = x, .y = y };
    }
};
