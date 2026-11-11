//! Terminal mode (`zile -t`, or when no window can open, e.g. over SSH):
//! the same editor and UI, drawn into a character grid and written to the
//! terminal; keys read from it.
//!
//! The terminal is put in raw mode on the alternate screen, with the kitty
//! keyboard protocol (so <Esc>, <C-i> vs <Tab> and <C-S-v> stay distinct
//! where supported), bracketed paste and mouse reports. Frames write only
//! the cells that changed, inside synchronized-output markers (no flicker).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Editor = @import("../Editor.zig");
const Font = @import("../ui/Font.zig");
const Theme = @import("../ui/Theme.zig");
const render = @import("../ui/render.zig");
const gfx = @import("../ui/gfx.zig");
const Grid = @import("Grid.zig");
const input = @import("input.zig");
const keys = @import("../input/keys.zig");

pub const Options = struct {
    /// Scripted keys (`<Wait>` separated) and a text snapshot of the screen
    /// to write when they're done (for testing without a terminal).
    test_keys: ?[]const u8 = null,
    test_snapshot: ?[]const u8 = null,
};

const stdin = 0;
const stdout = 1;

/// The self-pipe worker threads write to, waking the loop (`wake`).
var wake_fds: [2]c_int = .{ -1, -1 };

fn wake() void {
    if (wake_fds[1] >= 0) _ = std.c.write(wake_fds[1], "x", 1);
}

extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
const TIOCGWINSZ: c_ulong = 0x5413;
const F_SETFL = 4;
const O_NONBLOCK = 0o4000;

const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };

fn termSize(tty: bool) [2]usize {
    if (tty) {
        var ws: Winsize = undefined;
        if (ioctl(stdout, TIOCGWINSZ, &ws) == 0 and ws.col > 0 and ws.row > 0) return .{ ws.col, ws.row };
    }
    return .{ 120, 40 };
}

pub fn run(gpa: Allocator, io: Io, ed: *Editor, opts: Options) !void {
    const tty = std.c.isatty(stdin) == 1 and std.c.isatty(stdout) == 1;
    if (!tty and opts.test_keys == null) return error.NotATerminal;

    // Raw mode, restored on the way out.
    var saved: std.c.termios = undefined;
    if (tty) {
        if (std.c.tcgetattr(stdin, &saved) != 0) return error.NotATerminal;
        var raw = saved;
        raw.iflag.BRKINT = false;
        raw.iflag.ICRNL = false;
        raw.iflag.INPCK = false;
        raw.iflag.ISTRIP = false;
        raw.iflag.IXON = false;
        raw.oflag.OPOST = false;
        raw.cflag.CSIZE = .CS8;
        raw.lflag.ECHO = false;
        raw.lflag.ICANON = false;
        raw.lflag.IEXTEN = false;
        raw.lflag.ISIG = false;
        raw.cc[@intFromEnum(std.c.V.MIN)] = 1;
        raw.cc[@intFromEnum(std.c.V.TIME)] = 0;
        _ = std.c.tcsetattr(stdin, .FLUSH, &raw);
        // Alternate screen, kitty keys (disambiguate), bracketed paste,
        // mouse clicks, drags and wheel (SGR), focus reports (autosave),
        // cursor hidden while drawing.
        writeAll("\x1b[?1049h\x1b[>1u\x1b[?2004h\x1b[?1002h\x1b[?1006h\x1b[?1004h\x1b[?25l");
    }
    defer if (tty) {
        writeAll("\x1b[?1004l\x1b[?1006l\x1b[?1002l\x1b[?2004l\x1b[<u\x1b[0 q\x1b[?25h\x1b[?1049l");
        _ = std.c.tcsetattr(stdin, .FLUSH, &saved);
    };

    if (std.c.pipe(&wake_fds) != 0) return error.Pipe;
    defer {
        _ = std.c.close(wake_fds[0]);
        _ = std.c.close(wake_fds[1]);
        wake_fds = .{ -1, -1 };
    }
    _ = std.c.fcntl(wake_fds[1], F_SETFL, @as(c_int, O_NONBLOCK));
    _ = std.c.fcntl(wake_fds[0], F_SETFL, @as(c_int, O_NONBLOCK));
    ed.wake_fn = wake;
    if (tty) ed.registers.clipboard = .{ .get = clipboardGet, .set = clipboardSet };

    var grid: Grid = .{};
    defer grid.deinit(gpa);
    gfx.grid = &grid;
    defer gfx.grid = null;
    var prev: []Grid.Cell = &.{};
    defer gpa.free(prev);
    var font = Font.cells();

    var pending: std.ArrayList(u8) = .empty;
    defer pending.deinit(gpa);
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(gpa);

    var script = std.mem.splitSequence(u8, opts.test_keys orelse "", "<Wait>");
    var script_done = opts.test_keys == null;
    var frames: usize = 0;

    while (!ed.should_quit) : (frames += 1) {
        // Scripted keys: one segment per few frames (results arrive between).
        if (!script_done and frames % 8 == 0) {
            if (script.next()) |segment| {
                ed.feed(segment) catch {};
            } else script_done = true;
        }
        ed.tick();

        // Draw.
        const size = termSize(tty);
        try grid.resize(gpa, size[0], size[1]);
        const l = render.prepare(ed, &font, @intFromFloat(@as(f32, @floatFromInt(size[0])) * Grid.cell_w), @intFromFloat(@as(f32, @floatFromInt(size[1])) * Grid.cell_h));
        render.draw(ed, &font, Theme.get(ed.theme_index), l);
        if (prev.len != grid.cells.len) {
            gpa.free(prev);
            prev = try gpa.alloc(Grid.Cell, grid.cells.len);
            @memset(prev, .{ .cp = 0 }); // force a full redraw
        }
        if (tty) {
            try frame(gpa, &out, &grid, prev);
            writeAll(out.items);
        }
        @memcpy(prev, grid.cells);

        if (script_done and opts.test_snapshot != null) {
            try snapshot(gpa, io, &grid, opts.test_snapshot.?);
            return;
        }

        // Wait for input, a wake-up, or (to notice resizes) a quarter second.
        var fds = [_]std.c.pollfd{
            .{ .fd = if (tty) stdin else -1, .events = std.c.POLL.IN, .revents = 0 },
            .{ .fd = wake_fds[0], .events = std.c.POLL.IN, .revents = 0 },
        };
        // Sooner when something on screen is due to change by itself.
        const timeout: c_int = if (pending.items.len > 0) 25 else if (!script_done) 60 else if (ed.wantsFrames()) 40 else 250;
        const ready = std.c.poll(&fds, fds.len, timeout);
        if (fds[1].revents != 0) {
            var drain: [64]u8 = undefined;
            while (std.c.read(wake_fds[0], &drain, drain.len) > 0) {}
        }
        if (tty and fds[0].revents != 0) {
            var buf: [4096]u8 = undefined;
            const n = std.c.read(stdin, &buf, buf.len);
            if (n > 0) try pending.appendSlice(gpa, buf[0..@intCast(n)]);
        }
        // An escape sequence that stopped arriving is just <Esc>.
        try handleInput(ed, &font, &pending, ready == 0);
    }
}

fn handleInput(ed: *Editor, font: *const Font, pending: *std.ArrayList(u8), idle: bool) !void {
    var i: usize = 0;
    while (i < pending.items.len) {
        switch (input.decode(pending.items[i..], idle)) {
            .incomplete => break,
            .skip => |n| i += n,
            .event => |e| {
                i += e.len;
                switch (e.ev) {
                    .key => |k| ed.handleKey(k),
                    .paste => |text| paste(ed, text),
                    .mouse => |m| mouse(ed, font, m),
                    .focus => |in| if (!in) ed.focusLost(),
                }
            },
        }
    }
    pending.replaceRangeAssumeCapacity(0, i, &.{});
}

/// A paste goes where typing would: the terminal popup, a prompt or picker
/// query, insert mode; in normal mode it's put after the cursor.
fn paste(ed: *Editor, text: []const u8) void {
    if (ed.popupTerminal()) |t| return t.paste(text);
    if (ed.activeInput()) |inp| {
        var it = std.unicode.Utf8View.initUnchecked(text).iterator();
        while (it.nextCodepoint()) |cp| if (cp != '\n' and cp != '\r') inp.insert(ed.gpa, cp) catch return;
        ed.inputChanged() catch {};
        return;
    }
    if (ed.mode == .insert) {
        ed.insertText(text) catch {};
        return;
    }
    ed.registers.store(null, .yank, text, false) catch return;
    ed.feed("p") catch {};
}

fn mouse(ed: *Editor, font: *const Font, m: input.Mouse) void {
    const x = (@as(f32, @floatFromInt(m.col)) + 0.5) * Grid.cell_w;
    const y = (@as(f32, @floatFromInt(m.row)) + 0.5) * Grid.cell_h;
    if (ed.popupTerminal()) |t| {
        switch (m.kind) {
            .wheel_up => t.scroll(-3),
            .wheel_down => t.scroll(3),
            else => {},
        }
        return;
    }
    if (ed.picker != null or ed.cmd_float != null) return;
    const w = ed.windows.at(x, y) orelse return;
    if (w.term) |t| {
        ed.focusWindow(w);
        switch (m.kind) {
            .wheel_up => t.scroll(-3),
            .wheel_down => t.scroll(3),
            else => {},
        }
        return;
    }
    switch (m.kind) {
        .wheel_up, .wheel_down => {
            ed.focusWindow(w);
            ed.scrollLines(if (m.kind == .wheel_up) -3 else 3);
        },
        .press => {
            ed.focusWindow(w);
            const l = render.windowLayout(ed, font, w);
            const now = @as(f64, @floatFromInt(Io.Timestamp.now(ed.io, .awake).toNanoseconds())) / std.time.ns_per_s;
            if (l.cellAt(font, x - l.x0, y - l.y0)) |cell| ed.mousePress(cell.row, cell.col, clicks.count(cell.row, cell.col, now));
        },
        .drag => {
            const l = render.windowLayout(ed, font, ed.window);
            if (l.cellAt(font, x - l.x0, y - l.y0)) |cell| ed.mouseDrag(cell.row, cell.col);
        },
        .release => ed.mouseRelease(),
    }
}

/// Double and triple clicks (as in the window).
var clicks: struct {
    last_time: f64 = -10,
    row: usize = 0,
    col: usize = 0,
    n: u8 = 0,

    fn count(c: *@This(), row: usize, col: usize, now: f64) u8 {
        const again = now - c.last_time < 0.4 and row == c.row and col == c.col;
        c.n = if (again) @min(c.n + 1, 3) else 1;
        c.last_time = now;
        c.row = row;
        c.col = col;
        return c.n;
    }
} = .{};

/// The escape sequences that turn the previous frame into this one.
fn frame(gpa: Allocator, out: *std.ArrayList(u8), g: *const Grid, prev: []const Grid.Cell) !void {
    out.clearRetainingCapacity();
    try out.appendSlice(gpa, "\x1b[?2026h\x1b[?25l");
    var pen: ?Grid.Cell = null;
    var at: ?[2]usize = null; // where the terminal's cursor is after writing
    for (0..g.rows) |r| for (0..g.cols) |c| {
        const i = r * g.cols + c;
        const cell = g.cells[i];
        if (cell.eql(prev[i])) continue;
        if (at == null or at.?[0] != r or at.?[1] != c) try out.print(gpa, "\x1b[{d};{d}H", .{ r + 1, c + 1 });
        const same_pen = if (pen) |p| p.eql(.{ .cp = p.cp, .fg = cell.fg, .bg = cell.bg, .ul = cell.ul }) else false;
        if (!same_pen) {
            try out.print(gpa, "\x1b[0;38;2;{d};{d};{d};48;2;{d};{d};{d}", .{ cell.fg.r, cell.fg.g, cell.fg.b, cell.bg.r, cell.bg.g, cell.bg.b });
            if (cell.ul) |u| try out.print(gpa, ";4;58;2;{d};{d};{d}", .{ u.r, u.g, u.b });
            try out.append(gpa, 'm');
            pen = cell;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(if (cell.cp < 0x20) ' ' else cell.cp, &buf) catch 1;
        try out.appendSlice(gpa, buf[0..n]);
        at = .{ r, c + 1 };
    };
    try out.appendSlice(gpa, "\x1b[0m");
    if (g.cursor) |cur| {
        const shape: u8 = switch (cur.shape) {
            .block => 2,
            .underline => 4,
            .bar => 6,
        };
        try out.print(gpa, "\x1b[{d};{d}H\x1b[{d} q\x1b[?25h", .{ cur.row + 1, cur.col + 1, shape });
    }
    try out.appendSlice(gpa, "\x1b[?2026l");
}

/// Switches to the alternate screen at once, before the editor loads
/// anything: opened from a program that leaves its own screen to start us
/// (yazi), the terminal's old contents would otherwise show meanwhile.
/// `run` keeps it (asking again is harmless); `leaveEarly` undoes it if we
/// never get there.
pub fn enterEarly() bool {
    if (std.c.isatty(stdin) != 1 or std.c.isatty(stdout) != 1) return false;
    writeAll("\x1b[?1049h\x1b[?25l\x1b[2J");
    return true;
}

pub fn leaveEarly() void {
    writeAll("\x1b[?25h\x1b[?1049l");
}

fn writeAll(bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(stdout, rest.ptr, rest.len);
        if (n <= 0) {
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

/// The screen as plain text (tests, without a terminal).
fn snapshot(gpa: Allocator, io: Io, g: *const Grid, path: []const u8) !void {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(gpa);
    for (0..g.rows) |r| {
        var line: std.ArrayList(u8) = .empty;
        defer line.deinit(gpa);
        for (0..g.cols) |c| {
            var buf: [4]u8 = undefined;
            const cp = g.cells[r * g.cols + c].cp;
            const n = std.unicode.utf8Encode(if (cp < 0x20) ' ' else cp, &buf) catch 1;
            try line.appendSlice(gpa, buf[0..n]);
        }
        try text.appendSlice(gpa, std.mem.trimEnd(u8, line.items, " "));
        try text.append(gpa, '\n');
    }
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = text.items });
}

// The system clipboard over the terminal (OSC 52): copying works through
// SSH; reading it back isn't something terminals allow synchronously, so
// pasting uses the terminal's paste (bracketed) instead.

fn clipboardGet(_: Allocator) ?[]u8 {
    return null;
}

fn clipboardSet(gpa: Allocator, text: []const u8) void {
    const enc = std.base64.standard.Encoder;
    const buf = gpa.alloc(u8, enc.calcSize(text.len)) catch return;
    defer gpa.free(buf);
    writeAll("\x1b]52;c;");
    writeAll(enc.encode(buf, text));
    writeAll("\x07");
}
