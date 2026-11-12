//! The UI's drawing primitives: raylib in a window, or a character grid in
//! a terminal (`grid` set). The UI draws in pixels either way.

const rl = @import("raylib");
const Grid = @import("../tui/Grid.zig");

pub const Color = rl.Color;
pub const CursorShape = Grid.CursorShape;

/// Set in terminal mode: everything draws into it.
pub var grid: ?*Grid = null;

// rlgl (part of raylib): a transform applied to everything drawn.
extern fn rlPushMatrix() void;
extern fn rlPopMatrix() void;
extern fn rlTranslatef(x: f32, y: f32, z: f32) void;

pub fn clear(c: Color) void {
    if (grid) |g| return g.clear(c);
    rl.ClearBackground(c);
}

pub fn rect(x: f32, y: f32, w: f32, h: f32, c: Color) void {
    if (grid) |g| return g.rect(x, y, w, h, c);
    rl.DrawRectangleRec(.{ .x = x, .y = y, .width = w, .height = h }, c);
}

/// A wavy underline `w` wide whose bottom is at `bottom` (in a terminal, a
/// plain one).
pub fn squiggle(x: f32, bottom: f32, w: f32, c: Color) void {
    if (grid) |g| return g.rect(x, bottom - 2, w, 2, c);
    // A triangle wave a pixel column at a time, from rectangles (raylib's
    // lines can pick up the glyph atlas after text and vanish).
    const heights = [_]f32{ 0, 1, 2, 3, 2, 1 };
    var i: usize = 0;
    var px = @floor(x);
    while (px < x + w) : ({
        px += 1;
        i += 1;
    }) {
        const top = bottom - 4 + heights[i % heights.len];
        rl.DrawRectangleRec(.{ .x = px, .y = top, .width = 1, .height = 1.5 }, c);
    }
}

/// One glyph with its cell's top-left at (x, y) (terminal mode).
pub fn glyph(cp: u21, x: f32, y: f32, c: Color) void {
    if (grid) |g| g.put(cp, x, y, c);
}

/// Limits drawing to a rectangle (absolute pixels) until `endClip`.
pub fn beginClip(x: f32, y: f32, w: f32, h: f32) void {
    if (grid) |g| {
        g.clip = .{ x, y, w, h };
        return;
    }
    rl.BeginScissorMode(@intFromFloat(x), @intFromFloat(y), @intFromFloat(@ceil(w)), @intFromFloat(@ceil(h)));
}

pub fn endClip() void {
    if (grid) |g| {
        g.clip = null;
        return;
    }
    rl.EndScissorMode();
}

/// Draws relative to (x, y) until `popOffset` (a window's origin).
pub fn pushOffset(x: f32, y: f32) void {
    if (grid) |g| return g.pushOffset(x, y);
    rlPushMatrix();
    rlTranslatef(x, y, 0);
}

pub fn popOffset() void {
    if (grid) |g| return g.popOffset();
    rlPopMatrix();
}

/// Where the text cursor is (the terminal shows its own cursor there; a
/// window draws its own and ignores this).
pub fn cursor(x: f32, y: f32, shape: CursorShape) void {
    if (grid) |g| g.setCursor(x, y, shape);
}
