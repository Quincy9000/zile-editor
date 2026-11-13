//! Smooth scrolling (mini.animate): when a view's top moves, the text glides there.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const window_ops = @import("window_ops.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const View = Editor.View;
const Row = Editor.Row;

/// Advances every window's glide by `dt` seconds. Called once per frame by
/// the windowed UI (never in a terminal or in tests).
pub fn animate(ed: *Editor, dt: f32) void {
    const step = @min(dt, 1.0 / 30.0);
    for (ed.window_list.items) |w| animateView(ed, window_ops.windowView(ed, w), window_ops.windowBuffer(ed, w), w == ed.window, step);
    if (ed.cmd_float) |f| {
        window_ops.windowView(ed, f).scroll_offset = 0;
        window_ops.windowView(ed, f).scroll_frac = 0;
    }
}

/// The mouse wheel: scrolls the focused window by `delta` rows, fractions
/// included. Whole lines move `top` (and glide like any scroll); the rest is
/// shown as a partial line, so a touchpad or smooth wheel moves the text
/// continuously instead of a line at a time.
pub fn scrollSmooth(ed: *Editor, delta: f32) void {
    if (delta == 0) return;
    const v = &ed.view;
    if (!ed.options.smooth_scroll) {
        // Whole lines only; fractions add up out of sight.
        if ((delta > 0) != (ed.wheel_rest > 0)) ed.wheel_rest = 0;
        ed.wheel_rest += delta;
        const whole = @trunc(ed.wheel_rest);
        ed.wheel_rest -= whole;
        if (whole != 0) ed.scrollLines(@intFromFloat(whole));
        return;
    }
    v.scroll_idle = 0;
    const top = row_model.topRow(ed);
    const at_edge = if (delta < 0) row_model.prevRow(ed, top).eql(top) else row_model.nextRow(ed, top).eql(top);
    // Turning back, or nowhere left to go: the partial line becomes part of
    // the glide (the text doesn't jump) and eases back into place.
    if (at_edge or (delta > 0) != (v.scroll_frac > 0)) {
        v.scroll_offset -= v.scroll_frac;
        v.scroll_frac = 0;
        if (at_edge) return;
    }
    const frac = v.scroll_frac + delta;
    const whole = @trunc(frac);
    if (whole != 0) ed.scrollLines(@intFromFloat(whole));
    // The text must not move at the moment of input: what the target gained
    // is added to the glide's distance (`animate` adds the whole lines when
    // it sees `top` moved; the partial line is added here).
    v.scroll_offset += (frac - whole) - v.scroll_frac;
    v.scroll_frac = frac - whole;
}

/// The glide's time constant in seconds: about a fifth of a second to settle.
pub const scroll_glide = 0.06;

/// How long the wheel rests before a partial line settles.
pub const wheel_settle = 0.12;

pub fn animateView(ed: *Editor, v: *View, b: *const Buffer, focused: bool, dt: f32) void {
    // A scroll can run this many screens ahead of the drawn text before the
    // text jumps to keep up.
    const max_rows = v.rows * 4;
    const cap: f32 = @floatFromInt(max_rows);
    // The wheel has come to rest between two lines: settle on the nearer.
    v.scroll_idle += dt;
    if (v.scroll_frac != 0 and v.scroll_idle > wheel_settle and v.seen_buffer == b) {
        if (focused and @abs(v.scroll_frac) >= 0.5) ed.scrollLines(if (v.scroll_frac > 0) 1 else -1);
        v.scroll_offset -= v.scroll_frac;
        v.scroll_frac = 0;
    }
    if (!ed.options.smooth_scroll or v.seen_buffer != b) {
        v.scroll_offset = 0;
        v.scroll_frac = 0;
    } else if (v.top != v.seen_top) {
        const old: Row = .{ .line = v.seen_top };
        const new: Row = .{ .line = v.top };
        // Folds and ghost lines count as the rows they take (for the
        // focused window, whose buffer is the current one).
        const rows: f32 = if (focused)
            @floatFromInt(if (old.before(new)) row_model.rowsFrom(ed, old, new, max_rows) else row_model.rowsFrom(ed, new, old, max_rows))
        else
            @min(@as(f32, @floatFromInt(if (v.top > v.seen_top) v.top - v.seen_top else v.seen_top - v.top)), cap);
        v.scroll_offset = std.math.clamp(v.scroll_offset + (if (old.before(new)) rows else -rows), -cap, cap);
    }
    v.seen_top = v.top;
    v.seen_buffer = b;
    // Every frame closes the same share of what is left, also while more
    // scrolling keeps arriving (a held key, a turning wheel): the text
    // then moves at an even speed a little behind, instead of in steps.
    if (v.scroll_offset != 0) {
        v.scroll_offset *= @exp(-dt / scroll_glide);
        if (@abs(v.scroll_offset) < 0.02) v.scroll_offset = 0;
    }
}
