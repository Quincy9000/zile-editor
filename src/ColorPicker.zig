//! The colour wheel (`SPC l c`): edits the colour literal at the cursor with
//! vim keys. Hue goes around the wheel, saturation from its centre to its rim,
//! and a bar beside it is the brightness.
//!
//!   h / l    hue (around)            H / L    hue, in big steps
//!   k / j    more / less saturated   K / J    lighter / darker (also + / -)
//!   a / A    less / more opaque (literals with alpha)
//!   [count]  before any of them: that many steps
//!   r reset   y copy   Enter write it to the file   Esc / q cancel
//!
//! Pure state and maths; the editor opens it, applies it and draws it.

const std = @import("std");
const Buffer = @import("core/Buffer.zig");

const ColorPicker = @This();

pub const Rgba = struct { r: u8, g: u8, b: u8, a: u8 = 255 };

/// Hue in degrees [0, 360), saturation and value in [0, 1].
pub const Hsv = struct { h: f32, s: f32, v: f32 };

/// How the literal is written, kept when it is written back.
pub const Form = enum {
    /// `#rgb` (written back as `#rrggbb`: three digits can't hold most colours).
    hash3,
    hash6,
    hash8,
    /// `0xRRGGBB`.
    hex6,
};

/// The literal being edited: its buffer and byte range, and the buffer's
/// version then (an edit elsewhere closes the wheel).
buffer: *Buffer,
start: usize,
end: usize,
version: u64,
form: Form,
/// The literal used upper-case hex digits.
upper: bool,
original: Rgba,
/// Kept as HSV, so the hue survives passing through grey or black.
hsv: Hsv,
alpha: f32,
/// A count typed before a key.
count: usize = 0,

pub const hue_step = 2.0;
pub const hue_big_step = 15.0;
pub const step = 0.02;

pub fn toHsv(c: Rgba) Hsv {
    const r = @as(f32, @floatFromInt(c.r)) / 255;
    const g = @as(f32, @floatFromInt(c.g)) / 255;
    const b = @as(f32, @floatFromInt(c.b)) / 255;
    const max = @max(r, g, b);
    const min = @min(r, g, b);
    const d = max - min;
    var h: f32 = 0;
    if (d > 0) {
        h = if (max == r) 60 * @mod((g - b) / d, 6) else if (max == g) 60 * ((b - r) / d + 2) else 60 * ((r - g) / d + 4);
    }
    return .{ .h = @mod(h, 360), .s = if (max > 0) d / max else 0, .v = max };
}

pub fn toRgb(c: Hsv) Rgba {
    const h = @mod(c.h, 360) / 60;
    const chroma = c.v * c.s;
    const x = chroma * (1 - @abs(@mod(h, 2) - 1));
    const m = c.v - chroma;
    const rgb: [3]f32 = switch (@as(u8, @intFromFloat(@floor(h)))) {
        0 => .{ chroma, x, 0 },
        1 => .{ x, chroma, 0 },
        2 => .{ 0, chroma, x },
        3 => .{ 0, x, chroma },
        4 => .{ x, 0, chroma },
        else => .{ chroma, 0, x },
    };
    const byte = struct {
        fn of(f: f32) u8 {
            return @intFromFloat(@round(std.math.clamp(f, 0, 1) * 255));
        }
    }.of;
    return .{ .r = byte(rgb[0] + m), .g = byte(rgb[1] + m), .b = byte(rgb[2] + m) };
}

pub const Parsed = struct { color: Rgba, form: Form, upper: bool };

/// Reads a colour literal: `#rgb`, `#rrggbb`, `#rrggbbaa` or `0xRRGGBB`.
pub fn parse(text: []const u8) ?Parsed {
    var digits: []const u8 = undefined;
    var form: Form = undefined;
    if (std.mem.startsWith(u8, text, "#")) {
        digits = text[1..];
        form = switch (digits.len) {
            3 => .hash3,
            6 => .hash6,
            8 => .hash8,
            else => return null,
        };
    } else if (text.len == 8 and text[0] == '0' and (text[1] == 'x' or text[1] == 'X')) {
        digits = text[2..];
        form = .hex6;
    } else return null;
    var n: [8]u8 = undefined;
    var upper = false;
    for (digits, 0..) |d, i| {
        n[i] = std.fmt.charToDigit(d, 16) catch return null;
        upper = upper or (d >= 'A' and d <= 'F');
    }
    const rgba: Rgba = if (form == .hash3)
        .{ .r = n[0] * 17, .g = n[1] * 17, .b = n[2] * 17 }
    else
        .{ .r = n[0] * 16 + n[1], .g = n[2] * 16 + n[3], .b = n[4] * 16 + n[5], .a = if (form == .hash8) n[6] * 16 + n[7] else 255 };
    return .{ .color = rgba, .form = form, .upper = upper };
}

pub fn init(buffer: *Buffer, start: usize, end: usize, p: Parsed) ColorPicker {
    return .{
        .buffer = buffer,
        .start = start,
        .end = end,
        .version = buffer.edit_version,
        .form = p.form,
        .upper = p.upper,
        .original = p.color,
        .hsv = toHsv(p.color),
        .alpha = @as(f32, @floatFromInt(p.color.a)) / 255,
    };
}

pub fn hasAlpha(p: *const ColorPicker) bool {
    return p.form == .hash8;
}

/// The colour as it is now.
pub fn color(p: *const ColorPicker) Rgba {
    var c = toRgb(p.hsv);
    c.a = if (p.hasAlpha()) @intFromFloat(@round(p.alpha * 255)) else 255;
    return c;
}

/// The literal for the colour as it is now, in the form it was written in.
pub fn write(p: *const ColorPicker, buf: []u8) []const u8 {
    const c = p.color();
    const prefix = if (p.form == .hex6) "0x" else "#";
    const out = (if (p.hasAlpha())
        std.fmt.bufPrint(buf, "{s}{x:0>2}{x:0>2}{x:0>2}{x:0>2}", .{ prefix, c.r, c.g, c.b, c.a })
    else
        std.fmt.bufPrint(buf, "{s}{x:0>2}{x:0>2}{x:0>2}", .{ prefix, c.r, c.g, c.b })) catch return "";
    if (p.upper) for (buf[prefix.len..out.len]) |*b| {
        b.* = std.ascii.toUpper(b.*);
    };
    return out;
}

pub const Action = enum { none, apply, cancel, yank };

/// Handles a typed character. Enter and Esc are the editor's to map onto
/// `apply` and `cancel`.
pub fn key(p: *ColorPicker, cp: u21) Action {
    if (cp >= '1' and cp <= '9' or (cp == '0' and p.count > 0)) {
        p.count = p.count *| 10 +| (cp - '0');
        return .none;
    }
    const n: f32 = @floatFromInt(@max(p.count, 1));
    p.count = 0;
    const unit = struct {
        fn clamp(f: f32) f32 {
            return std.math.clamp(f, 0, 1);
        }
    }.clamp;
    switch (cp) {
        'h' => p.hsv.h = @mod(p.hsv.h - hue_step * n, 360),
        'l' => p.hsv.h = @mod(p.hsv.h + hue_step * n, 360),
        'H' => p.hsv.h = @mod(p.hsv.h - hue_big_step * n, 360),
        'L' => p.hsv.h = @mod(p.hsv.h + hue_big_step * n, 360),
        'k' => p.hsv.s = unit(p.hsv.s + step * n),
        'j' => p.hsv.s = unit(p.hsv.s - step * n),
        'K', '+', '=' => p.hsv.v = unit(p.hsv.v + step * n),
        'J', '-' => p.hsv.v = unit(p.hsv.v - step * n),
        'a' => if (p.hasAlpha()) {
            p.alpha = unit(p.alpha - step * n);
        },
        'A' => if (p.hasAlpha()) {
            p.alpha = unit(p.alpha + step * n);
        },
        'r' => {
            p.hsv = toHsv(p.original);
            p.alpha = @as(f32, @floatFromInt(p.original.a)) / 255;
        },
        'y' => return .yank,
        'q' => return .cancel,
        else => {},
    }
    return .none;
}

const testing = std.testing;

test "hsv and back, for every corner and a few in between" {
    for ([_]Rgba{
        .{ .r = 0, .g = 0, .b = 0 },       .{ .r = 255, .g = 255, .b = 255 }, .{ .r = 255, .g = 0, .b = 0 },
        .{ .r = 0, .g = 255, .b = 0 },     .{ .r = 0, .g = 0, .b = 255 },     .{ .r = 230, .g = 195, .b = 132 },
        .{ .r = 122, .g = 168, .b = 214 }, .{ .r = 1, .g = 22, .b = 39 },     .{ .r = 128, .g = 128, .b = 128 },
    }) |c| {
        const back = toRgb(toHsv(c));
        try testing.expectEqual(c.r, back.r);
        try testing.expectEqual(c.g, back.g);
        try testing.expectEqual(c.b, back.b);
    }
    try testing.expectEqual(0, toHsv(.{ .r = 255, .g = 0, .b = 0 }).h);
    try testing.expectEqual(120, toHsv(.{ .r = 0, .g = 255, .b = 0 }).h);
    try testing.expectEqual(240, toHsv(.{ .r = 0, .g = 0, .b = 255 }).h);
}

test "literals keep their form; keys turn the wheel" {
    var buffer: Buffer = undefined;
    buffer.edit_version = 0;
    var buf: [16]u8 = undefined;

    var p = init(&buffer, 0, 7, parse("#FF0000").?);
    try testing.expectEqualStrings("#FF0000", p.write(&buf)); // untouched: unchanged
    _ = p.key('6');
    _ = p.key('0');
    _ = p.key('l'); // 60 steps of 2 degrees: red to green
    try testing.expectEqualStrings("#00FF00", p.write(&buf));
    _ = p.key('H'); // back 15 degrees
    try testing.expectEqual(105, p.hsv.h);
    for (0..60) |_| _ = p.key('j'); // no saturation: white, and the hue is kept
    try testing.expectEqualStrings("#FFFFFF", p.write(&buf));
    try testing.expectEqual(105, p.hsv.h);
    _ = p.key('5');
    _ = p.key('0');
    _ = p.key('J'); // all the way dark
    try testing.expectEqualStrings("#000000", p.write(&buf));
    _ = p.key('r');
    try testing.expectEqualStrings("#FF0000", p.write(&buf));
    try testing.expectEqual(Action.yank, p.key('y'));
    try testing.expectEqual(Action.cancel, p.key('q'));

    var q = init(&buffer, 0, 9, parse("#10203080").?);
    _ = q.key('A');
    try testing.expectEqualStrings("#10203085", q.write(&buf));
    var z = init(&buffer, 0, 8, parse("0x7aa8d6").?);
    try testing.expectEqualStrings("0x7aa8d6", z.write(&buf));
    var s = init(&buffer, 0, 4, parse("#f80").?);
    try testing.expectEqualStrings("#ff8800", s.write(&buf));
    try testing.expectEqual(null, parse("#12345"));
    try testing.expectEqual(null, parse("0x12"));
}
