//! A terminal: a program on a PTY, emulated by libghostty-vt.
//!
//! Threads: a reader thread waits for output and feeds it to the emulator
//! under `mutex`, then wakes the UI. The UI thread locks only to snapshot the
//! screen (`begin_update`), send keys, scroll and resize; it walks the
//! snapshot outside the lock. Replies the emulator owes the program (cursor
//! position reports etc.) are written straight to the PTY from the reader.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const c = @import("vt");
const Pty = @import("Pty.zig");
const keys = @import("../input/keys.zig");

const Terminal = @This();

pub const Rgb = struct { r: u8, g: u8, b: u8 };

pub const Options = struct {
    argv: []const []const u8,
    cwd: []const u8,
    cols: u16,
    rows: u16,
    cell_w: u16 = 0,
    cell_h: u16 = 0,
    /// Default colors, to match the editor theme.
    fg: ?Rgb = null,
    bg: ?Rgb = null,
    wake: *const fn () void,
};

gpa: Allocator,
io: Io,
pty: Pty,
vt: c.GhosttyTerminal,
mutex: Io.Mutex = .init,
reader: std.Thread = undefined,
wake: *const fn () void,
stopping: std.atomic.Value(bool) = .init(false),
/// Set (with `exit_code`) by the reader once the program is gone.
exited: std.atomic.Value(bool) = .init(false),
exit_code: u8 = 0,
cols: u16,
rows: u16,

// UI-thread state for drawing and keys.
render: c.GhosttyRenderState = null,
row_it: c.GhosttyRenderStateRowIterator = null,
cells: c.GhosttyRenderStateRowCells = null,
encoder: c.GhosttyKeyEncoder = null,
key_event: c.GhosttyKeyEvent = null,

const scrollback_bytes: usize = 16 << 20;

pub fn create(gpa: Allocator, io: Io, opts: Options) !*Terminal {
    const t = try gpa.create(Terminal);
    errdefer gpa.destroy(t);
    t.* = .{ .gpa = gpa, .io = io, .pty = undefined, .vt = null, .wake = opts.wake, .cols = opts.cols, .rows = opts.rows };

    if (c.ghostty_terminal_new(null, &t.vt, opts.cols, opts.rows) != c.GHOSTTY_SUCCESS) return error.TerminalInit;
    errdefer c.ghostty_terminal_free(t.vt);
    var sb = scrollback_bytes;
    _ = c.ghostty_terminal_set(t.vt, c.GHOSTTY_TERMINAL_OPT_SCROLLBACK_MAX_BYTES, &sb);
    _ = c.ghostty_terminal_set(t.vt, c.GHOSTTY_TERMINAL_OPT_USERDATA, t);
    _ = c.ghostty_terminal_set(t.vt, c.GHOSTTY_TERMINAL_OPT_WRITE_PTY, @ptrCast(&onWritePty));
    if (opts.fg) |fg| {
        const v: c.GhosttyColorRgb = .{ .r = fg.r, .g = fg.g, .b = fg.b };
        _ = c.ghostty_terminal_set(t.vt, c.GHOSTTY_TERMINAL_OPT_COLOR_FOREGROUND, &v);
    }
    if (opts.bg) |bg| {
        const v: c.GhosttyColorRgb = .{ .r = bg.r, .g = bg.g, .b = bg.b };
        _ = c.ghostty_terminal_set(t.vt, c.GHOSTTY_TERMINAL_OPT_COLOR_BACKGROUND, &v);
    }
    _ = c.ghostty_terminal_resize(t.vt, opts.cols, opts.rows, opts.cell_w, opts.cell_h);

    if (c.ghostty_render_state_new(null, &t.render) != c.GHOSTTY_SUCCESS) return error.TerminalInit;
    errdefer c.ghostty_render_state_free(t.render);
    if (c.ghostty_render_state_row_iterator_new(null, &t.row_it) != c.GHOSTTY_SUCCESS) return error.TerminalInit;
    errdefer c.ghostty_render_state_row_iterator_free(t.row_it);
    if (c.ghostty_render_state_row_cells_new(null, &t.cells) != c.GHOSTTY_SUCCESS) return error.TerminalInit;
    errdefer c.ghostty_render_state_row_cells_free(t.cells);
    if (c.ghostty_key_encoder_new(null, &t.encoder) != c.GHOSTTY_SUCCESS) return error.TerminalInit;
    errdefer c.ghostty_key_encoder_free(t.encoder);
    if (c.ghostty_key_event_new(null, &t.key_event) != c.GHOSTTY_SUCCESS) return error.TerminalInit;
    errdefer c.ghostty_key_event_free(t.key_event);

    t.pty = try Pty.spawn(gpa, opts.argv, opts.cwd, .{ .cols = opts.cols, .rows = opts.rows, .cell_w = opts.cell_w, .cell_h = opts.cell_h });
    errdefer {
        t.pty.hangup();
        _ = t.pty.wait();
        t.pty.close();
    }
    t.reader = try std.Thread.spawn(.{}, readLoop, .{t});
    return t;
}

/// Stops the program (hangup, then kill) and frees everything.
pub fn destroy(t: *Terminal) void {
    t.stopping.store(true, .release);
    t.reader.join();
    if (!t.exited.load(.acquire)) {
        t.pty.hangup();
        t.pty.kill();
        t.exit_code = t.pty.wait();
    }
    t.pty.close();
    c.ghostty_key_event_free(t.key_event);
    c.ghostty_key_encoder_free(t.encoder);
    c.ghostty_render_state_row_cells_free(t.cells);
    c.ghostty_render_state_row_iterator_free(t.row_it);
    c.ghostty_render_state_free(t.render);
    c.ghostty_terminal_free(t.vt);
    t.gpa.destroy(t);
}

fn readLoop(t: *Terminal) void {
    var buf: [64 * 1024]u8 = undefined;
    while (!t.stopping.load(.acquire)) {
        // Wake up now and then to notice `stopping`.
        if (!t.pty.waitReadable(100)) continue;
        const n = t.pty.read(&buf);
        if (n == 0) {
            t.exit_code = t.pty.wait();
            t.exited.store(true, .release);
            t.wake();
            return;
        }
        t.mutex.lockUncancelable(t.io);
        c.ghostty_terminal_vt_write(t.vt, &buf, n);
        t.mutex.unlock(t.io);
        t.wake();
    }
}

/// The emulator answering the program (on the reader thread, under the lock).
fn onWritePty(_: c.GhosttyTerminal, userdata: ?*anyopaque, data: [*c]const u8, len: usize) callconv(.c) void {
    const t: *Terminal = @ptrCast(@alignCast(userdata.?));
    t.pty.write(data[0..len]);
}

pub fn isRunning(t: *const Terminal) bool {
    return !t.exited.load(.acquire);
}

/// Shows `bytes` as if the program printed them (e.g. "[exited 0]").
pub fn print(t: *Terminal, bytes: []const u8) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    c.ghostty_terminal_vt_write(t.vt, bytes.ptr, bytes.len);
}

pub fn resize(t: *Terminal, cols: u16, rows: u16, cell_w: u16, cell_h: u16) void {
    if (cols == t.cols and rows == t.rows) return;
    t.cols = cols;
    t.rows = rows;
    t.mutex.lockUncancelable(t.io);
    _ = c.ghostty_terminal_resize(t.vt, cols, rows, cell_w, cell_h);
    t.mutex.unlock(t.io);
    t.pty.resize(.{ .cols = cols, .rows = rows, .cell_w = cell_w, .cell_h = cell_h });
}

/// Scrolls the view through the scrollback (negative: up, back in time).
pub fn scroll(t: *Terminal, delta: isize) void {
    t.mutex.lockUncancelable(t.io);
    defer t.mutex.unlock(t.io);
    _ = c.ghostty_terminal_scroll_viewport(t.vt, .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_DELTA, .value = .{ .delta = delta } });
}

// ---------------------------------------------------------------------------
// Input

/// Sends a key press, encoded for the program's current modes.
pub fn sendKey(t: *Terminal, ev: keys.KeyEvent) void {
    var text_buf: [4]u8 = undefined;
    var text: []const u8 = "";
    var key: c.GhosttyKey = c.GHOSTTY_KEY_UNIDENTIFIED;
    switch (ev.key) {
        .codepoint => |cp| {
            text = text_buf[0 .. std.unicode.utf8Encode(cp, &text_buf) catch return];
            key = codepointKey(cp);
        },
        .special => |s| key = specialKey(s),
    }
    var mods: c.GhosttyMods = 0;
    if (ev.mods.shift) mods |= c.GHOSTTY_MODS_SHIFT;
    if (ev.mods.ctrl) mods |= c.GHOSTTY_MODS_CTRL;
    if (ev.mods.alt) mods |= c.GHOSTTY_MODS_ALT;
    if (ev.mods.super) mods |= c.GHOSTTY_MODS_SUPER;

    t.mutex.lockUncancelable(t.io);
    _ = c.ghostty_key_encoder_set_from_terminal(t.encoder, t.vt);
    // Typing returns to the live screen.
    _ = c.ghostty_terminal_scroll_viewport(t.vt, .{ .tag = c.GHOSTTY_TERMINAL_SCROLL_VIEWPORT_BOTTOM, .value = .{ .delta = 0 } });
    t.mutex.unlock(t.io);

    _ = c.ghostty_key_event_set_action(t.key_event, c.GHOSTTY_KEY_ACTION_PRESS);
    _ = c.ghostty_key_event_set_key(t.key_event, key);
    _ = c.ghostty_key_event_set_mods(t.key_event, mods);
    _ = c.ghostty_key_event_set_utf8(t.key_event, .{ .ptr = text.ptr, .len = text.len });
    var out: [128]u8 = undefined;
    var n: usize = 0;
    if (c.ghostty_key_encoder_encode(t.encoder, t.key_event, &out, out.len, &n) != c.GHOSTTY_SUCCESS) return;
    t.pty.write(out[0..n]);
}

/// Pastes text (bracketed when the program asked for it).
pub fn paste(t: *Terminal, text: []const u8) void {
    var mode: c.GhosttyTerminalModeConfig = .{ .mode = c.GHOSTTY_MODE_BRACKETED_PASTE, .value = false };
    t.mutex.lockUncancelable(t.io);
    _ = c.ghostty_terminal_get(t.vt, c.GHOSTTY_TERMINAL_DATA_MODE, &mode);
    t.mutex.unlock(t.io);
    const data = t.gpa.dupe(u8, text) catch return;
    defer t.gpa.free(data);
    const out = t.gpa.alloc(u8, text.len + 16) catch return;
    defer t.gpa.free(out);
    var n: usize = 0;
    if (c.ghostty_paste_encode(data.ptr, data.len, mode.value, out.ptr, out.len, &n) != c.GHOSTTY_SUCCESS) return;
    t.pty.write(out[0..n]);
}

fn codepointKey(cp: u21) c.GhosttyKey {
    return switch (cp) {
        'a'...'z' => @intCast(c.GHOSTTY_KEY_A + (cp - 'a')),
        'A'...'Z' => @intCast(c.GHOSTTY_KEY_A + (cp - 'A')),
        '0'...'9' => @intCast(c.GHOSTTY_KEY_DIGIT_0 + (cp - '0')),
        ' ' => c.GHOSTTY_KEY_SPACE,
        else => c.GHOSTTY_KEY_UNIDENTIFIED,
    };
}

fn specialKey(s: keys.Special) c.GhosttyKey {
    return switch (s) {
        .escape => c.GHOSTTY_KEY_ESCAPE,
        .enter => c.GHOSTTY_KEY_ENTER,
        .tab => c.GHOSTTY_KEY_TAB,
        .backspace => c.GHOSTTY_KEY_BACKSPACE,
        .delete => c.GHOSTTY_KEY_DELETE,
        .insert => c.GHOSTTY_KEY_INSERT,
        .up => c.GHOSTTY_KEY_ARROW_UP,
        .down => c.GHOSTTY_KEY_ARROW_DOWN,
        .left => c.GHOSTTY_KEY_ARROW_LEFT,
        .right => c.GHOSTTY_KEY_ARROW_RIGHT,
        .home => c.GHOSTTY_KEY_HOME,
        .end => c.GHOSTTY_KEY_END,
        .page_up => c.GHOSTTY_KEY_PAGE_UP,
        .page_down => c.GHOSTTY_KEY_PAGE_DOWN,
        inline .f1, .f2, .f3, .f4, .f5, .f6, .f7, .f8, .f9, .f10, .f11, .f12 => |f| @intCast(c.GHOSTTY_KEY_F1 + (@intFromEnum(f) - @intFromEnum(keys.Special.f1))),
    };
}

// ---------------------------------------------------------------------------
// Drawing: a snapshot of the visible screen, walked cell by cell.

pub const Cell = struct {
    x: u16,
    y: u16,
    /// 2 for wide characters (CJK, emoji).
    width: u2,
    /// The grapheme's codepoints (empty for blank cells).
    text: []const u32,
    fg: Rgb,
    bg: Rgb,
    /// The background differs from the default (worth drawing).
    has_bg: bool,
    bold: bool,
    italic: bool,
    underline: bool,
    faint: bool,
};

pub const Cursor = struct {
    x: u16,
    y: u16,
    style: enum { bar, block, underline, hollow },
};

/// Snapshots the screen, then calls `ctx.cell(Cell)` for every cell with
/// text or a background, and returns the cursor (if shown).
pub fn draw(t: *Terminal, ctx: anytype) ?Cursor {
    t.mutex.lockUncancelable(t.io);
    _ = c.ghostty_render_state_begin_update(t.render, t.vt);
    t.mutex.unlock(t.io);
    _ = c.ghostty_render_state_end_update(t.render);

    var colors = std.mem.zeroes(c.GhosttyRenderStateColors);
    colors.size = @sizeOf(c.GhosttyRenderStateColors);
    _ = c.ghostty_render_state_get(t.render, c.GHOSTTY_RENDER_STATE_DATA_COLORS, &colors);
    _ = c.ghostty_render_state_get(t.render, c.GHOSTTY_RENDER_STATE_DATA_ROW_ITERATOR, @ptrCast(&t.row_it));
    var y: u16 = 0;
    while (c.ghostty_render_state_row_iterator_next(t.row_it)) : (y += 1) {
        _ = c.ghostty_render_state_row_get(t.row_it, c.GHOSTTY_RENDER_STATE_ROW_DATA_CELLS, @ptrCast(&t.cells));
        var x: u16 = 0;
        while (c.ghostty_render_state_row_cells_next(t.cells)) : (x += 1) {
            var raw: c.GhosttyCell = 0;
            _ = c.ghostty_render_state_row_cells_get(t.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_RAW, &raw);
            var wide: c.GhosttyCellWide = c.GHOSTTY_CELL_WIDE_NARROW;
            _ = c.ghostty_cell_get(raw, c.GHOSTTY_CELL_DATA_WIDE, &wide);
            if (wide == c.GHOSTTY_CELL_WIDE_SPACER_TAIL or wide == c.GHOSTTY_CELL_WIDE_SPACER_HEAD) continue;

            var style: c.GhosttyStyle = std.mem.zeroes(c.GhosttyStyle);
            _ = c.ghostty_render_state_row_cells_get(t.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_STYLE, &style);
            var fg = colors.foreground;
            var bg = colors.background;
            _ = c.ghostty_render_state_row_cells_get(t.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_FG_COLOR, &fg);
            const has_bg = c.ghostty_render_state_row_cells_get(t.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_BG_COLOR, &bg) == c.GHOSTTY_SUCCESS;
            const flags = style.flags;
            if (flags & c.GHOSTTY_STYLE_FLAG_INVERSE != 0) std.mem.swap(c.GhosttyColorRgb, &fg, &bg);

            var cps: [16]u32 = undefined;
            var gb: c.GhosttyCodepointBuffer = .{ .ptr = &cps, .cap = cps.len, .len = 0 };
            _ = c.ghostty_render_state_row_cells_get(t.cells, c.GHOSTTY_RENDER_STATE_ROW_CELLS_DATA_GRAPHEMES_BUF, &gb);
            const invisible = flags & c.GHOSTTY_STYLE_FLAG_INVISIBLE != 0;
            const inverse = flags & c.GHOSTTY_STYLE_FLAG_INVERSE != 0;
            if (gb.len == 0 and !has_bg and !inverse) continue;
            ctx.cell(.{
                .x = x,
                .y = y,
                .width = if (wide == c.GHOSTTY_CELL_WIDE_WIDE) 2 else 1,
                .text = if (invisible) &.{} else cps[0..@min(gb.len, cps.len)],
                .fg = rgb(fg),
                .bg = rgb(bg),
                .has_bg = has_bg or inverse,
                .bold = flags & c.GHOSTTY_STYLE_FLAG_BOLD != 0,
                .italic = flags & c.GHOSTTY_STYLE_FLAG_ITALIC != 0,
                .underline = (flags >> 8) & 7 != 0,
                .faint = flags & c.GHOSTTY_STYLE_FLAG_FAINT != 0,
            });
        }
    }

    var cur = std.mem.zeroes(c.GhosttyRenderStateCursor);
    cur.size = @sizeOf(c.GhosttyRenderStateCursor);
    _ = c.ghostty_render_state_get(t.render, c.GHOSTTY_RENDER_STATE_DATA_CURSOR, &cur);
    _ = c.ghostty_render_state_clean(t.render);
    if (!cur.visible or !cur.viewport_has_value) return null;
    return .{
        .x = cur.viewport_x,
        .y = cur.viewport_y,
        .style = switch (cur.visual_style) {
            c.GHOSTTY_CURSOR_STYLE_BAR => .bar,
            c.GHOSTTY_CURSOR_STYLE_UNDERLINE => .underline,
            c.GHOSTTY_CURSOR_STYLE_BLOCK_HOLLOW => .hollow,
            else => .block,
        },
    };
}

fn rgb(v: c.GhosttyColorRgb) Rgb {
    return .{ .r = v.r, .g = v.g, .b = v.b };
}

/// The visible screen as text, rows joined by "\n", trailing blanks trimmed
/// (tests, and copying output). Caller frees.
pub fn screenText(t: *Terminal, gpa: Allocator) ![]u8 {
    const Collect = struct {
        rows: [][256]u8,
        lens: []usize,
        pub fn cell(self: @This(), cl: Cell) void {
            if (cl.y >= self.rows.len or cl.text.len == 0) return;
            var buf: [4]u8 = undefined;
            const n = std.unicode.utf8Encode(@intCast(cl.text[0]), &buf) catch return;
            const row = &self.rows[cl.y];
            // Pad to the column first (cells arrive left to right).
            while (self.lens[cl.y] < cl.x and self.lens[cl.y] < row.len) : (self.lens[cl.y] += 1) row[self.lens[cl.y]] = ' ';
            if (self.lens[cl.y] + n > row.len) return;
            @memcpy(row[self.lens[cl.y]..][0..n], buf[0..n]);
            self.lens[cl.y] += n;
        }
    };
    const rows = try gpa.alloc([256]u8, t.rows);
    defer gpa.free(rows);
    const lens = try gpa.alloc(usize, t.rows);
    defer gpa.free(lens);
    @memset(lens, 0);
    _ = t.draw(Collect{ .rows = rows, .lens = lens });
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var last: usize = 0;
    for (lens, 0..) |l, i| if (l > 0) {
        last = i + 1;
    };
    for (0..last) |i| {
        if (i > 0) try out.append(gpa, '\n');
        try out.appendSlice(gpa, rows[i][0..lens[i]]);
    }
    return out.toOwnedSlice(gpa);
}

fn noWake() void {}

/// Waits (in tests) for the program to finish.
fn waitExit(t: *Terminal) void {
    var i: usize = 0;
    while (t.isRunning() and i < 500) : (i += 1) std.Thread.yield() catch {};
    while (t.isRunning()) {}
}

test "runs a program, emulates its output, reports its exit code" {
    const t = try create(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "printf 'hello\\n\\033[31mred\\033[0m\\n'; exit 2" },
        .cwd = "/",
        .cols = 40,
        .rows = 5,
        .wake = noWake,
    });
    defer t.destroy();
    t.waitExit();
    try std.testing.expectEqual(2, t.exit_code);
    const text = try t.screenText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hello\nred", text);
}

test "keys reach the program" {
    const t = try create(std.testing.allocator, std.testing.io, .{
        .argv = &.{ "/bin/sh", "-c", "read line; echo \"got $line\"" },
        .cwd = "/",
        .cols = 40,
        .rows = 5,
        .wake = noWake,
    });
    defer t.destroy();
    for ("hi") |ch| t.sendKey(.{ .key = .{ .codepoint = ch } });
    t.sendKey(.{ .key = .{ .special = .enter } });
    t.waitExit();
    const text = try t.screenText(std.testing.allocator);
    defer std.testing.allocator.free(text);
    try std.testing.expectEqualStrings("hi\ngot hi", text);
}
