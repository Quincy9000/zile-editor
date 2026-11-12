//! Draws editor state. Reads `Editor`, never mutates it.

const std = @import("std");
const debugging = @import("../debugging.zig");
const rl = @import("raylib");
const Editor = @import("../Editor.zig");
const Completion = @import("../lsp/Completion.zig");
const motions = @import("../core/motions.zig");
const Font = @import("Font.zig");
const Theme = @import("Theme.zig");
const keymap = @import("../input/keymap.zig");
const keys = @import("../input/keys.zig");
const picker_view = @import("picker_view.zig");
const gfx = @import("gfx.zig");
const operators = @import("../operators.zig");
const Syntax = @import("../syntax/Syntax.zig");
const Lsp = @import("../lsp/Lsp.zig");
const hipatterns = @import("../core/hipatterns.zig");
const indent = @import("../core/indent.zig");
const search = @import("../core/search.zig");
const Blame = @import("../git/Blame.zig");

/// Screen geometry in pixels and cells, recomputed every frame.
pub const Layout = struct {
    /// Gutter width in cells (line numbers + padding).
    gutter_cols: usize,
    text_x: f32,
    rows: usize,
    cols: usize,
    status_y: f32,
    width: f32,
    /// Screen position of this area (windows; 0 for the whole screen).
    x0: f32 = 0,
    y0: f32 = 0,

    /// Maps a pixel to a (row, col) cell of the text area, if inside it.
    pub fn cellAt(l: Layout, font: *const Font, x: f32, y: f32) ?struct { row: usize, col: usize } {
        if (y < 0 or y >= l.status_y) return null;
        const col = if (x < l.text_x) 0 else (x - l.text_x) / font.cell_w;
        return .{ .row = @intFromFloat(y / font.cell_h), .col = @intFromFloat(col) };
    }
};

pub fn layout(ed: *Editor, font: *const Font, width: i32, height: i32) Layout {
    const w: f32 = @floatFromInt(@max(width, 1));
    const h: f32 = @floatFromInt(@max(height, 1));
    const digits = std.math.log10_int(ed.text().lineCount()) + 1;
    const gutter_cols = @max(digits, 3) + 2;
    const text_x = @as(f32, @floatFromInt(gutter_cols)) * font.cell_w;
    const status_y = @max(h - font.cell_h, 0);
    return .{
        .gutter_cols = gutter_cols,
        .text_x = text_x,
        .rows = @max(@as(usize, @intFromFloat(status_y / font.cell_h)), 1),
        .cols = @max(@as(usize, @intFromFloat((w - text_x) / font.cell_w)), 1),
        .status_y = status_y,
        .width = w,
    };
}

/// Lays out the windows for a `width` x `height` screen and sizes their
/// views. Returns the whole-screen layout (status line, popups).
pub fn prepare(ed: *Editor, font: *const Font, width: i32, height: i32) Layout {
    const screen = layout(ed, font, width, height);
    ed.windows.layout(.{ .w = screen.width, .h = screen.status_y }, font.cell_w, font.cell_h);
    // The terminal popup's grid; the shown terminal follows its size.
    const pr = popupRect(font, screen);
    ed.term_size = .{
        .cols = @intFromFloat(@max(pr.w / font.cell_w - 2, 1)),
        .rows = @intFromFloat(@max(pr.h / font.cell_h - 1, 1)),
        .cell_w = @intFromFloat(font.cell_w),
        .cell_h = @intFromFloat(font.cell_h),
    };
    if (ed.popupTerminal()) |t| t.resize(ed.term_size.cols, ed.term_size.rows, ed.term_size.cell_w, ed.term_size.cell_h);
    if (ed.cmd_float) |f| {
        f.rect = cmdFloatRect(ed, font, screen);
        const fl = floatLayout(ed, font, f);
        if (f == ed.window) ed.setViewSize(fl.rows, fl.cols) else {
            f.view.rows = fl.rows;
            f.view.cols = fl.cols;
        }
    }
    for (ed.window_list.items) |w| {
        if (w.term) |t| {
            // Its screen: the window less a header row and a cell of padding.
            const cols: u16 = @intFromFloat(@max(w.rect.w / font.cell_w - 2, 1));
            const rows: u16 = @intFromFloat(@max(w.rect.h / font.cell_h - 1, 1));
            t.resize(cols, rows, @intFromFloat(font.cell_w), @intFromFloat(font.cell_h));
        }
        const wl = windowLayout(ed, font, w);
        if (w == ed.window and ed.cmd_float == null) {
            ed.setViewSize(wl.rows, wl.cols);
        } else {
            w.view.rows = wl.rows;
            w.view.cols = wl.cols;
        }
    }
    return screen;
}

/// The text area of window `w`: below its header (when there are several
/// windows), in coordinates local to `x0`/`y0`.
pub fn windowLayout(ed: *Editor, font: *const Font, w: *Editor.Windows.Window) Layout {
    const header: f32 = if (ed.window_list.items.len > 1) font.cell_h else 0;
    const lines = ed.windowBuffer(w).text.lineCount();
    const gutter_cols = @max(std.math.log10_int(lines) + 1, 3) + 2;
    const text_x = @as(f32, @floatFromInt(gutter_cols)) * font.cell_w;
    const text_h = @max(w.rect.h - header, 0);
    return .{
        .gutter_cols = gutter_cols,
        .text_x = text_x,
        .rows = @max(@as(usize, @intFromFloat(text_h / font.cell_h)), 1),
        .cols = @max(@as(usize, @intFromFloat(@max(w.rect.w - text_x, 0) / font.cell_w)), 1),
        .status_y = text_h,
        .width = w.rect.w,
        .x0 = w.rect.x,
        .y0 = w.rect.y + header,
    };
}


pub fn draw(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    gfx.clear(theme.bg);
    for (ed.window_list.items) |w| drawWindow(ed, font, theme, w);
    if (ed.cmd_float) |f| drawCmdFloat(ed, font, theme, f, l);
    // Popups at the focused window's cursor.
    const fl = if (ed.cmd_float != null and ed.window == ed.cmd_float.?) floatLayout(ed, font, ed.window) else windowLayout(ed, font, ed.window);
    gfx.pushOffset(fl.x0, fl.y0);
    drawHover(ed, font, theme, fl);
    drawSignature(ed, font, theme, fl);
    drawCompletion(ed, font, theme, fl);
    gfx.popOffset();
    drawPopup(ed, font, theme, l);
    gfx.pushOffset(fl.x0, fl.y0);
    drawColorPicker(ed, font, theme, fl);
    gfx.popOffset();
    drawStatus(ed, font, theme, l);
    drawToasts(ed, font, theme, l);
    if (ed.picker) |p| picker_view.draw(p, font, theme, l);
    if (ed.search_prompt) |*sp| if (sp.kind.boxed()) {
        if (sp.kind == .replace) {
            if (ed.replace) |r| picker_view.drawReplace(r, font, theme, l, sp.input.items());
        } else picker_view.drawPromptBox(font, theme, l, sp.kind.title(), sp.input.items());
    };
}


pub fn cells(s: []const u8) usize {
    return std.unicode.utf8CountCodepoints(s) catch s.len;
}

fn keyCells(k: keys.KeyEvent) usize {
    var b: [32]u8 = undefined;
    var w: std.Io.Writer = .fixed(&b);
    keys.formatDisplay(k, &w) catch return 1;
    return cells(w.buffered());
}

pub fn rect(x: f32, y: f32, w: f32, h: f32, color: rl.Color) void {
    gfx.rect(x, y, w, h, color);
}

/// A path for lists: relative inside the current project, else its last
/// two parts.
fn shortPath(ed: *Editor, path: []const u8) []const u8 {
    const root = ed.projectRoot();
    if (path.len > root.len + 1 and std.mem.startsWith(u8, path, root) and path[root.len] == '/') return path[root.len + 1 ..];
    if (!std.fs.path.isAbsolute(path)) return path;
    const base = std.mem.lastIndexOfScalar(u8, path, '/') orelse return path;
    const parent = std.mem.lastIndexOfScalar(u8, path[0..base], '/') orelse return path;
    return path[parent + 1 ..];
}

/// The command editor: a box growing with its text (3 to 16 lines), at the
/// upper third of the screen.
fn cmdFloatRect(ed: *Editor, font: *const Font, screen: Layout) Editor.Windows.Rect {
    const lines = ed.windowBuffer(ed.cmd_float.?).text.lineCount();
    const rows: f32 = @floatFromInt(std.math.clamp(lines + 1, 3, 16));
    const w = @max(@min(@floor(screen.width * 0.7 / font.cell_w), 120), 30) * font.cell_w;
    const h = (rows + 1) * font.cell_h; // + the title row
    return .{ .x = @floor((screen.width - w) / 2), .y = @floor(@max(screen.status_y / 3 - h / 2, font.cell_h)), .w = w, .h = h };
}

fn floatLayout(ed: *Editor, font: *const Font, f: *Editor.Windows.Window) Layout {
    const lines = ed.windowBuffer(f).text.lineCount();
    const gutter_cols = @max(std.math.log10_int(lines) + 1, 2) + 2;
    const text_x = @as(f32, @floatFromInt(gutter_cols)) * font.cell_w;
    const text_h = f.rect.h - font.cell_h;
    return .{
        .gutter_cols = gutter_cols,
        .text_x = text_x,
        .rows = @max(@as(usize, @intFromFloat(text_h / font.cell_h)), 1),
        .cols = @max(@as(usize, @intFromFloat(@max(f.rect.w - text_x, 0) / font.cell_w)), 1),
        .status_y = text_h,
        .width = f.rect.w,
        .x0 = f.rect.x,
        .y0 = f.rect.y + font.cell_h,
    };
}

/// The command editor: title, then the buffer drawn like any window.
fn drawCmdFloat(ed: *Editor, font: *const Font, theme: *const Theme, f: *Editor.Windows.Window, screen: Layout) void {
    const r = f.rect;
    rect(0, 0, screen.width, screen.status_y, theme.backdrop);
    rect(r.x - 1, r.y - 1, r.w + 2, r.h + 2, theme.popup_border);
    rect(r.x, r.y, r.w, r.h, theme.bg);
    rect(r.x, r.y, r.w, font.cell_h, theme.status_bg);
    const debug = ed.cmd_purpose == .debug;
    _ = font.drawText(if (debug) "Debug command (this session)" else "Run command", r.x + font.cell_w, r.y, theme.mode_picker);
    const hint = if (ed.mode == .normal)
        (if (debug) "Enter debugs   Esc cancels" else "Enter runs   Esc cancels")
    else if (debug) "Esc, then Enter debugs" else "Esc, then Enter runs";
    _ = font.drawText(hint, r.x + r.w - @as(f32, @floatFromInt(cells(hint) + 1)) * font.cell_w, r.y, theme.status_dim);

    const fl = floatLayout(ed, font, f);
    gfx.beginClip(r.x, r.y, r.w, r.h);
    defer gfx.endClip();
    const peek: ?Editor.Peek = if (f == ed.window) null else ed.peekWindow(f);
    defer if (peek) |p| ed.unpeekWindow(p);
    gfx.pushOffset(fl.x0, fl.y0);
    defer gfx.popOffset();
    drawText(ed, font, theme, fl, f == ed.window);
}

/// The terminal popup: most of the screen, centered over the text, on whole cells.
fn popupRect(font: *const Font, screen: Layout) Editor.Windows.Rect {
    const w = @max(@floor(screen.width * 0.9 / font.cell_w), 20) * font.cell_w;
    const h = @max(@floor(screen.status_y * 0.85 / font.cell_h), 4) * font.cell_h;
    return .{ .x = @floor((screen.width - w) / 2), .y = @floor((screen.status_y - h) / 2), .w = w, .h = h };
}

fn rgbColor(c: Editor.Terminal.Rgb) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
}

/// A terminal (shell or run) in the popup: a header line, then its screen.
fn drawPopup(ed: *Editor, font: *const Font, theme: *const Theme, screen: Layout) void {
    const t = ed.popupTerminal() orelse return;
    const r = popupRect(font, screen);
    const cw = font.cell_w;
    const ch = font.cell_h;
    rect(0, 0, screen.width, screen.status_y, theme.backdrop);
    rect(r.x - 1, r.y - 1, r.w + 2, r.h + 2, theme.popup_border);
    rect(r.x, r.y, r.w, r.h, theme.popup_bg);

    // Header: what runs here and how it is going.
    rect(r.x, r.y, r.w, ch, theme.status_bg);
    var buf: [160]u8 = undefined;
    const title: []const u8 = switch (ed.popup.?) {
        .shell => "Terminal",
        .run => std.fmt.bufPrint(&buf, "$ {s}", .{ed.run_command orelse ""}) catch "$",
    };
    _ = font.drawText(title, r.x + cw, r.y, theme.status_fg);
    var right_buf: [96]u8 = undefined;
    const right, const right_color = if (ed.popup.? == .shell)
        .{ "Esc Esc hides", theme.status_dim }
    else if (ed.run_debug and ed.dbg.session != null)
        .{ "debugging   Esc Esc hides", theme.status_dim }
    else if (ed.run_debug and ed.dbg.outcome != null)
        // The program's own end: the terminal's process only stood in for it.
        switch (ed.dbg.outcome.?) {
            .exited => |code| if (code == 0)
                .{ "done   r: again   q: close", theme.diff_add }
            else
                .{ std.fmt.bufPrint(&right_buf, "failed ({d})   r: again   q: close", .{code}) catch "", theme.diag_error },
            .ended => .{ "ended (no exit code)   r: again   q: close", theme.diag_error },
            .stopped => .{ "stopped   r: again   q: close", theme.status_dim },
        }
    else if (t.isRunning())
        .{ std.fmt.bufPrint(&right_buf, "running {d:.1}s   Esc Esc hides", .{ed.runSeconds()}) catch "", theme.status_dim }
    else if (t.exit_code == 0)
        .{ "done   r: again   q: close", theme.diff_add }
    else
        .{ if (ed.run_errors.items.len > 0)
            std.fmt.bufPrint(&right_buf, "failed ({d})   e: {d} errors   r: again   q: close", .{ t.exit_code, ed.run_errors.items.len }) catch ""
        else
            std.fmt.bufPrint(&right_buf, "failed ({d})   r: again   q: close", .{t.exit_code}) catch "", theme.diag_error };
    _ = font.drawText(right, r.x + r.w - @as(f32, @floatFromInt(cells(right) + 1)) * cw, r.y, right_color);

    // The screen, one cell of padding at the sides.
    drawTerminalScreen(t, font, theme, r.x + cw, r.y + ch, true);
}

/// A terminal's screen with its top-left cell at (x0, y0), and its cursor
/// (drawn if `focused`, hinted to the terminal either way).
fn drawTerminalScreen(t: *Editor.Terminal, font: *const Font, theme: *const Theme, x0: f32, y0: f32, focused: bool) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const Ctx = struct {
        font: *const Font,
        x0: f32,
        y0: f32,
        /// The character under the cursor, to draw on its block.
        under: *?u21,
        pub fn cell(self: @This(), cl: Editor.Terminal.Cell) void {
            const f = self.font;
            if (cl.cursor and cl.text.len > 0) self.under.* = std.math.cast(u21, cl.text[0]);
            const x = self.x0 + @as(f32, @floatFromInt(cl.x)) * f.cell_w;
            const y = self.y0 + @as(f32, @floatFromInt(cl.y)) * f.cell_h;
            const w = @as(f32, @floatFromInt(cl.width)) * f.cell_w;
            if (cl.has_bg) rect(x, y, w, f.cell_h, rgbColor(cl.bg));
            var fg = rgbColor(cl.fg);
            if (cl.faint) fg.a = 150;
            if (cl.text.len > 0) if (std.math.cast(u21, cl.text[0])) |cp| f.drawCodepoint(cp, x, y, fg);
            if (cl.underline) rect(x, y + f.cell_h - 2, w, 1, fg);
        }
    };
    var under: ?u21 = null;
    const cur = t.draw(Ctx{ .font = font, .x0 = x0, .y0 = y0, .under = &under }) orelse return;
    const x = x0 + @as(f32, @floatFromInt(cur.x)) * cw;
    const y = y0 + @as(f32, @floatFromInt(cur.y)) * ch;
    var c = theme.cursor;
    if (!focused) {
        c.a = 70;
        return rect(x, y, cw, ch, c);
    }
    gfx.cursor(x, y, switch (cur.style) {
        .bar => .bar,
        .underline => .underline,
        .block, .hollow => .block,
    });
    // In a terminal its own cursor is drawn over the cell (see drawCursorAt).
    if (gfx.grid != null) return;
    switch (cur.style) {
        .block => {
            rect(x, y, cw, ch, c);
            if (under) |cp| if (cp != ' ') font.drawCodepoint(cp, x, y, theme.cursor_text);
        },
        .bar => rect(x, y, 2, ch, c),
        .underline => rect(x, y + ch - 2, cw, 2, c),
        .hollow => {
            rect(x, y, cw, 1, c);
            rect(x, y + ch - 1, cw, 1, c);
            rect(x, y, 1, ch, c);
            rect(x + cw - 1, y, 1, ch, c);
        },
    }
}

/// A window showing a terminal (the Claude panel): a header, then its screen.
fn drawTermWindow(ed: *Editor, font: *const Font, theme: *const Theme, w: *Editor.Windows.Window, t: *Editor.Terminal) void {
    const focused = w == ed.window;
    const r = w.rect;
    gfx.beginClip(r.x, r.y, r.w, r.h);
    defer gfx.endClip();
    rect(r.x, r.y, r.w, r.h, theme.popup_bg);
    rect(r.x, r.y, r.w, font.cell_h, if (focused) theme.status_bg else theme.bg);
    rect(r.x, r.y + font.cell_h - 1, r.w, 1, theme.popup_border);
    const is_claude = if (ed.claude) |c| c.term == t else false;
    const title: []const u8 = if (is_claude) "Claude Code" else "Terminal";
    _ = font.drawText(title, r.x + font.cell_w, r.y, if (focused) theme.status_fg else theme.status_dim);
    if (is_claude) {
        const c = ed.claude.?;
        const status: []const u8 = if (c.ready) "connected" else "connecting…";
        const hint = if (!focused) "" else if (w.term_normal) "   NORMAL (i types)" else "   Esc Esc: normal";
        var buf: [64]u8 = undefined;
        const right = std.fmt.bufPrint(&buf, "{s}{s}", .{ status, hint }) catch status;
        _ = font.drawText(right, r.x + r.w - @as(f32, @floatFromInt(cells(right) + 1)) * font.cell_w, r.y, if (c.ready) theme.diff_add else theme.status_dim);
    }
    if (!is_claude and focused) {
        const hint: []const u8 = if (w.term_normal) "NORMAL (i types)" else "Esc Esc: normal";
        _ = font.drawText(hint, r.x + r.w - @as(f32, @floatFromInt(cells(hint) + 1)) * font.cell_w, r.y, theme.status_dim);
    }
    if (r.x > 0) rect(r.x, r.y, 1, r.h, theme.popup_border);
    drawTerminalScreen(t, font, theme, r.x + font.cell_w, r.y + font.cell_h, focused);
}

/// One window: its header (when there are several), then its text, clipped
/// to its rectangle.
fn drawWindow(ed: *Editor, font: *const Font, theme: *const Theme, w: *Editor.Windows.Window) void {
    if (w.term) |t| return drawTermWindow(ed, font, theme, w, t);
    const focused = w == ed.window;
    const wl = windowLayout(ed, font, w);
    const r = w.rect;
    gfx.beginClip(r.x, r.y, r.w, r.h);
    defer gfx.endClip();

    const peek: ?Editor.Peek = if (focused) null else ed.peekWindow(w);
    defer if (peek) |p| ed.unpeekWindow(p);
    ed.highlightView();

    if (ed.window_list.items.len > 1) {
        rect(r.x, r.y, r.w, font.cell_h, if (focused) theme.status_bg else theme.bg);
        rect(r.x, r.y + font.cell_h - 1, r.w, 1, theme.popup_border);
        var x = r.x + font.cell_w;
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (ed.buffer.project) |p| {
            // Name the project when it isn't the one we started in.
            if (!std.mem.eql(u8, p.root, ed.cwd)) {
                x = font.drawText(p.name(), x, r.y, theme.whichkey_group);
                x += font.cell_w * 2;
            }
        }
        x = font.drawText(projectPath(ed, &path_buf), x, r.y, if (focused) theme.status_fg else theme.status_dim);
        if (ed.buffer.modified) x = font.drawText(" [+]", x, r.y, if (focused) theme.status_fg else theme.status_dim);
    }
    if (r.x > 0) rect(r.x, r.y, 1, r.h, theme.popup_border);

    // The text stays below the header while a scroll glides.
    gfx.endClip();
    gfx.beginClip(r.x, wl.y0, r.w, @max(r.y + r.h - wl.y0, 0));
    gfx.pushOffset(wl.x0, wl.y0);
    defer gfx.popOffset();
    drawText(ed, font, theme, wl, focused);
}

/// The inlay hints of the line being drawn (set per line by `drawText`; the
/// helpers below read it so every column on the line allows for them).
var line_hints: []const Editor.LineHint = &.{};

/// The part of the line on the row being drawn: visual columns
/// `[win_left, win_right)`, drawn `win_indent` cells in (one row of a
/// wrapped line). Unwrapped: from `view.left` across the window.
var win_left: usize = 0;
var win_right: usize = std.math.maxInt(usize);
var win_indent: usize = 0;

/// The first visual column past what this row shows.
fn winEnd(l: Layout) usize {
    return @min(win_right, win_left + (l.cols -| win_indent));
}

/// Where visual column `c` (at or after `win_left`) is drawn.
fn colX(font: *const Font, l: Layout, c: usize) f32 {
    return l.text_x + @as(f32, @floatFromInt(c - win_left + win_indent)) * font.cell_w;
}

/// The whole width, from `view.left` (ghost rows, which don't wrap).
fn unwrappedWindow(ed: *const Editor) void {
    win_left = ed.view.left;
    win_right = std.math.maxInt(usize);
    win_indent = 0;
}

/// The screen column of byte `off` of the line being drawn: where its
/// character is, after the hints in front of it.
fn dcol(bytes: []const u8, off: usize, tab: usize) usize {
    return motions.displayCol(bytes, off, tab) + Editor.hintShift(line_hints, off);
}

/// The screen column where a range ending at byte `off` ends: a hint in
/// front of the next character isn't part of it.
fn dcolEnd(bytes: []const u8, off: usize, tab: usize) usize {
    return motions.displayCol(bytes, off, tab) + Editor.hintShiftBefore(line_hints, off);
}

fn drawText(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, focused: bool) void {
    defer line_hints = &.{};
    unwrappedWindow(ed);
    defer unwrappedWindow(ed);
    const selection: ?operators.Range = if (ed.mode == .visual) ed.visualRange() else null;
    const syntax: ?*const Syntax = if (ed.buffer.syntax) |*s| s else null;
    const diags = ed.diagnostics(ed.buffer);
    const t = ed.text();
    const v = &ed.view;
    const cursor_line = ed.cursorLine();
    // Breakpoints and the debugger's stop are kept by absolute path.
    var abs_buf: [std.fs.max_path_bytes]u8 = undefined;
    // (Resolved as `Editor.absolutePath` does, so `./a.c` is `a.c`.)
    var abs_fba: std.heap.FixedBufferAllocator = .init(&abs_buf);
    const debug_path: ?[]const u8 = if (ed.dbg.breakpoints.items.len == 0 and ed.dbg.session == null) null else if (ed.buffer.path) |bp|
        (std.fs.path.resolve(abs_fba.allocator(), &.{ ed.cwd, bp }) catch null)
    else
        null;
    const tab_width = ed.options.tab_width;
    var ghost_below: ?struct { text: []const u8, y: f32 } = null;

    // mini.nvim decorations, worked out once per window.
    const cword: ?search.Pattern = if (cursorWord(ed, focused)) |w| .{ .needle = w, .case_sensitive = true, .whole_word = true } else null;
    // The indent guide appears once the cursor has settled in a scope
    // (`Editor.tickIndentGuide`), so it doesn't flash while travelling.
    const guide: ?Editor.IndentGuide = if (focused) (if (ed.indent_guide) |g| (if (g.buffer == ed.buffer) g else null) else null) else null;
    const guide_reach: f32 = if (guide) |g| g.reach(ed.now) else 0;
    const show_trail = ed.options.trailing_space and ed.buffer.path != null;
    const find: ?motions.Find = if (focused and ed.find_shown) ed.last_find else null;
    const exchange: ?operators.Range = if (ed.exchange_mark) |m| (if (m.buffer == ed.buffer and m.version == ed.buffer.edit_version) m.range else null) else null;

    // A gliding scroll: everything is drawn `scroll_offset` rows lower (or
    // higher), with the rows that slide in from beyond the top or bottom.
    const y_off = scrollPx(ed, font);
    const draw_off = v.drawOffset();
    // The first row in view, and where it is relative to `top`: rows above
    // `top` while the text is lower, rows below it while it is higher.
    var first_row = ed.topRow();
    var first_index: f32 = 0;
    if (draw_off > 0) {
        var n: usize = @intFromFloat(@ceil(draw_off));
        while (n > 0) : (n -= 1) {
            const prev = ed.prevRow(first_row);
            if (prev.eql(first_row)) break;
            first_row = prev;
            first_index -= 1;
        }
    } else if (draw_off < 0) {
        var n: usize = @intFromFloat(@floor(-draw_off));
        while (n > 0) : (n -= 1) {
            const next = ed.nextRow(first_row);
            if (next.eql(first_row)) break;
            first_row = next;
            first_index += 1;
        }
    }
    const area_h = @as(f32, @floatFromInt(l.rows)) * font.cell_h;

    // Rows walk visible lines: a closed fold is drawn as its first line plus a
    // marker, and the lines it hides are skipped.
    // Rows: text lines (a closed fold is one) and ghost lines (old HEAD text).
    var row: usize = 0;
    // Rows taken by an AI suggestion's extra lines (pushing the text below
    // down, like inserted lines).
    var virtual: usize = 0;
    var r = first_row;
    while (true) : (row += 1) {
        if (row > 0) {
            const next = ed.nextRow(r);
            if (next.eql(r)) break;
            r = next;
        }
        const y = (@as(f32, @floatFromInt(row + virtual)) + first_index) * font.cell_h + y_off;
        if (y >= area_h) break;
        if (r.ghost) |k| {
            line_hints = &.{};
            unwrappedWindow(ed);
            drawGhostRow(ed, font, theme, l, r.line, k, y);
            continue;
        }
        const line = r.line;
        if (line >= t.lineCount()) break;
        // A code lens row: the server's note above the line, at its indent.
        const lens_n = ed.lensRows(line);
        if (r.sub < lens_n) {
            const lb = t.lineSlice(line);
            const ind = motions.displayCol(lb, std.mem.indexOfNone(u8, lb, " \t") orelse 0, tab_width) -| v.left;
            if (ed.lensText(line)) |lt| _ = font.drawText(clip(lt, l.cols -| ind), l.text_x + @as(f32, @floatFromInt(ind)) * font.cell_w, y, theme.inlay_fg);
            continue;
        }
        var seg_buf: [Editor.max_segments]Editor.Seg = undefined;
        const segs = ed.segments(line, &seg_buf);
        const piece = @min(@as(usize, r.sub) - lens_n, segs.len - 1);
        const first_piece = piece == 0;
        const last_piece = piece + 1 == segs.len;
        if (ed.options.wrap) {
            win_left = segs[piece].start;
            win_right = segs[piece].end;
            win_indent = segs[piece].indent;
        } else unwrappedWindow(ed);
        var hint_buf: [Editor.max_line_hints]Editor.LineHint = undefined;
        const hints = ed.lineHints(ed.buffer, line, &hint_buf);
        line_hints = hints;
        const fold = ed.foldAt(line);
        const is_current = line == cursor_line;
        if (fold != null) rect(0, y, l.width, font.cell_h, theme.fold_bg);

        if (is_current and focused) rect(0, y, l.width, font.cell_h, theme.cursorline_bg);
        const marks: debugging.Marks = if (debug_path) |dp| debugging.marks(ed, dp, line) else .{};
        // Where the debugger stopped: the line tinted.
        if (marks.here) rect(0, y, l.width, font.cell_h, withAlpha(theme.diag_warning, 40));
        if (selection) |sel| drawSelection(ed, font, theme, l, sel, line, y);
        if (selection != null) for (ed.cursors.items) |c| {
            drawSelection(ed, font, theme, l, ed.selectionRange(c.anchor, c.pos), line, y);
        };
        // Snippet placeholders: the current one (typing replaces it) like a
        // selection, the ones still ahead faintly.
        if (focused) if (ed.snippet) |sn| if (sn.buffer == ed.buffer) {
            for (sn.stops, 0..) |stop, i| {
                if (stop[1] <= stop[0] or i < sn.current) continue;
                const current = i == sn.current;
                if (current and !sn.fresh) continue;
                drawRange(ed, font, l, .{ .start = stop[0], .end = stop[1] }, line, y, if (current) theme.selection_bg else theme.fold_bg);
            }
        };

        // Line number, right-aligned in the gutter with one cell of padding.
        var num_buf: [24]u8 = undefined;
        // Relative numbers: distance to the cursor line (the cursor line keeps
        // its absolute number).
        const shown = if (ed.options.relative_numbers and !is_current)
            (if (line > cursor_line) line - cursor_line else cursor_line - line)
        else
            line + 1;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{shown}) catch unreachable;
        const num_x = @as(f32, @floatFromInt(l.gutter_cols - 1 - num.len)) * font.cell_w;
        const line_diag = firstDiagnostic(diags, line);
        const num_color = if (line_diag) |d| diagColor(theme, d.severity) else if (fold != null) theme.fold_fg else if (is_current) theme.gutter_current_fg else theme.gutter_fg;
        // The number on a line's first row only (later rows continue it).
        if (first_piece) _ = font.drawText(num, num_x, y, num_color);
        drawGitSign(ed, theme, line, y, font.cell_h);
        if (first_piece and (marks.breakpoint or marks.here)) {
            // Breakpoints switched off stay, hollow.
            const glyph = if (marks.here) "▶" else if (ed.dbg.breakpoints_on) "●" else "○";
            _ = font.drawText(glyph, 0, y, if (marks.here) theme.diag_warning else if (ed.dbg.breakpoints_on) theme.diag_error else theme.gutter_fg);
        }

        if (ed.search_highlight) drawSearchMatches(ed, font, theme, l, line, y);
        drawYankFlash(ed, font, theme, l, line, y);

        // Text, starting at the first visible display column, colored by syntax.
        const ls = t.lineStart(line);
        const bytes = t.lineSlice(line);

        // Backgrounds under the text: the text marked for exchange, the word
        // under the cursor, f/t targets, trailing whitespace, todo words and
        // colour literals.
        if (exchange) |x| drawRange(ed, font, l, x, line, y, theme.search_match);
        if (cword) |p| {
            var i: usize = 0;
            while (p.forward(bytes, i)) |m| : (i = m + p.needle.len) drawSpan(ed, font, l, bytes, m, m + p.needle.len, y, font.cell_h, theme.cursorword_bg);
        }
        if (find) |f| {
            var i: usize = 0;
            while (motions.indexOfFold(bytes, i, f.needle())) |m| : (i = m + f.len) drawSpan(ed, font, l, bytes, m, m + f.len, y, font.cell_h, theme.search_match);
        }
        if (show_trail and !(is_current and ed.mode == .insert)) {
            const keep = std.mem.trimEnd(u8, bytes, " \t").len;
            if (keep < bytes.len) drawSpan(ed, font, l, bytes, keep, bytes.len, y, font.cell_h, theme.trail_bg);
        }
        var hp_buf: [24]hipatterns.Match = undefined;
        var hps: []hipatterns.Match = if (ed.options.highlight_patterns) hipatterns.scan(bytes, &hp_buf) else hp_buf[0..0];
        {
            // Todo words count only in comments (anywhere without a grammar).
            var kept: usize = 0;
            for (hps) |m| {
                if (m.kind == .todo) if (syntax) |s| if (s.styleAt(ls + m.start) != .comment) continue;
                hps[kept] = m;
                kept += 1;
            }
            hps = hps[0..kept];
        }
        // The literal under the colour wheel shows the wheel's colour, live.
        if (ed.color_picker) |*p| if (p.buffer == ed.buffer) for (hps) |*m| {
            if (ls + m.start != p.start) continue;
            const c = p.color();
            const rgb: hipatterns.Rgb = .{ .r = c.r, .g = c.g, .b = c.b };
            m.kind = if (m.kind == .hex_number) .{ .hex_number = rgb } else .{ .color = rgb };
        };
        for (hps) |m| switch (m.kind) {
            .todo => |class| drawSpan(ed, font, l, bytes, m.start, m.end, y, font.cell_h, todoColor(theme, class)),
            .color => |c| drawSpan(ed, font, l, bytes, m.start, m.end, y, font.cell_h, .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 }),
            .hex_number => |c| drawSpan(ed, font, l, bytes, m.start, m.end, y + font.cell_h - 2, 2, .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 }),
        };
        // The indent scope's guide: a line down the scope at its border's indent.
        // It grows out from where the cursor was, a row at a time: the rows
        // it has reached are whole, the one it is in is part drawn.
        if (guide) |g| if (line >= g.scope.first and line <= g.scope.last and g.scope.guide_col >= v.left and g.scope.guide_col < v.left + l.cols and (first_piece or g.scope.guide_col < win_indent)) {
            const below = line >= g.origin;
            const away: f32 = @floatFromInt(if (below) line - g.origin else g.origin - line);
            // The origin's own row is there from the start.
            var part = std.math.clamp(guide_reach - (away - 1), 0, 1);
            // A terminal has whole cells only.
            if (gfx.grid != null) part = @floor(part);
            if (part > 0) {
                const h = @round(part * font.cell_h);
                const x = l.text_x + @as(f32, @floatFromInt(g.scope.guide_col - v.left)) * font.cell_w;
                rect(x, if (below) y else y + font.cell_h - h, 1, h, theme.indent_guide);
            }
        };
        var hp_i: usize = 0;
        // An AI suggestion at the cursor: its first line goes inline (the
        // rest of the line moves right), more lines are drawn below.
        const ghost: ?[]const u8 = if (focused and is_current) ed.aiSuggestionHere() else null;
        const ghost_at = if (ghost != null) v.cursor - ls else bytes.len + 1;
        const ghost_first = if (ghost) |g| std.mem.sliceTo(g, '\n') else "";
        const ghost_cells = cells(ghost_first);
        var it = Font.Utf8Lossy{ .bytes = bytes };
        var col: usize = 0;
        while (true) {
            const offset = it.i;
            const cp = it.next() orelse break;
            const next_col = if (cp == '\t') motions.nextTabStop(col, tab_width) else col + 1;
            defer col = next_col;
            const shift: usize = (if (offset >= ghost_at) ghost_cells else 0) + Editor.hintShift(hints, offset);
            if (next_col + shift <= win_left) continue;
            if (col + shift >= winEnd(l)) break;
            if (cp == '\t' or cp == ' ') continue;
            const x = colX(font, l, col + shift);
            const style = if (syntax) |s| s.styleAt(ls + offset) else .none;
            var color = theme.syntax.get(style);
            // On a todo word or a colour: text that reads on that background.
            while (hp_i < hps.len and hps[hp_i].end <= offset) hp_i += 1;
            if (hp_i < hps.len and hps[hp_i].start <= offset) switch (hps[hp_i].kind) {
                .todo => color = theme.bg,
                .color => |c| color = Theme.contrast(.{ .r = c.r, .g = c.g, .b = c.b, .a = 255 }),
                .hex_number => {},
            };
            font.drawCodepoint(cp, x, y, color);
        }
        // Inlay hints: the server's labels, in front of the text they belong to.
        for (hints, 0..) |h, j| {
            const c = motions.displayCol(bytes, @min(h.off, bytes.len), tab_width) + Editor.hintShift(hints[0..j], std.math.maxInt(usize));
            const w = h.cells();
            if (c < win_left or c >= winEnd(l)) continue;
            const hx = colX(font, l, c);
            rect(hx, y, @as(f32, @floatFromInt(w)) * font.cell_w, font.cell_h, theme.inlay_bg);
            _ = font.drawText(clip(h.text, winEnd(l) - c), hx, y, theme.inlay_fg);
        }
        if (ghost) |g| {
            const gc = motions.displayCol(bytes, ghost_at, tab_width);
            if (gc >= win_left and gc <= winEnd(l)) _ = font.drawText(ghost_first, colX(font, l, gc), y, theme.ai_fg);
            if (g.len > ghost_first.len) ghost_below = .{ .text = g[ghost_first.len + 1 ..], .y = y };
        }
        if (fold) |f| {
            // "… 12 lines" after the fold's first line.
            const end_col = dcol(bytes, bytes.len, tab_width) + 2;
            if (end_col >= win_left and end_col < winEnd(l)) {
                var buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "… {d} lines", .{f.last - f.first}) catch "…";
                _ = font.drawText(label, colX(font, l, end_col), y, theme.fold_fg);
            }
        } else if (line_diag != null and ghost == null) drawDiagnostics(ed, font, theme, l, diags, line, y, last_piece);
        // Inline blame: who last changed the cursor's line.
        if (last_piece and focused and is_current and ed.options.git_blame and fold == null and ghost == null and ed.ghost == null and
            !(line_diag != null and ed.options.diagnostic_text)) drawBlame(ed, font, theme, l, bytes, line, y);

        // The suggestion's further lines: rows of their own under this one
        // (no line numbers: they aren't in the file yet).
        if (ghost_below) |gb| {
            var lines = std.mem.splitScalar(u8, gb.text, '\n');
            while (lines.next()) |gl| {
                if (row + virtual + 1 >= l.rows) break;
                virtual += 1;
                const yy = @as(f32, @floatFromInt(row + virtual)) * font.cell_h;
                _ = font.drawText(gl, l.text_x - @as(f32, @floatFromInt(v.left)) * font.cell_w, yy, theme.ai_fg);
            }
            ghost_below = null;
        }
    }

    drawContext(ed, font, theme, l);

    // Extra cursors: the same shape, a little dimmer.
    var extra = theme.cursor;
    extra.a = 150;
    for (ed.cursors.items) |c| drawCursorAt(ed, font, theme, l, @min(c.pos, ed.text().len()), extra);
    if (ed.ghost) |g| return drawGhostCursor(ed, font, theme, l, g);
    // An unfocused window's cursor is a faint block.
    var cursor_color = theme.cursor;
    if (!focused) cursor_color.a = 70;
    drawCursorAt(ed, font, theme, l, ed.view.cursor, cursor_color);
}

/// How far (in pixels) a gliding scroll still has the text from its place.
fn scrollPx(ed: *Editor, font: *const Font) f32 {
    return @round(ed.view.drawOffset() * font.cell_h);
}

/// The word under the cursor, when its other occurrences should stand out.
fn cursorWord(ed: *Editor, focused: bool) ?[]const u8 {
    if (!focused or !ed.options.cursor_word or ed.ghost != null) return null;
    if (ed.mode != .normal and ed.mode != .operator) return null;
    const t = ed.text();
    const pos = ed.view.cursor;
    if (pos >= t.len() or !search.isWord(t.byteAt(pos))) return null;
    const line = t.lineOf(pos);
    var start = pos;
    var end = pos;
    while (start > t.lineStart(line) and search.isWord(t.byteAt(start - 1))) start -= 1;
    while (end < t.lineEnd(line) and search.isWord(t.byteAt(end))) end += 1;
    // One letter (`i`, `x`) would light up half the file.
    if (end - start < 2) return null;
    return t.slice(start, end);
}

fn todoColor(theme: *const Theme, class: hipatterns.Class) rl.Color {
    return switch (class) {
        .todo => theme.diag_info,
        .fixme => theme.diag_error,
        .hack => theme.diag_warning,
        .note => theme.diff_add,
    };
}

/// A rectangle of height `h` at `y` behind bytes `[a, b)` of the line `bytes`.
fn drawSpan(ed: *Editor, font: *const Font, l: Layout, bytes: []const u8, a: usize, b: usize, y: f32, h: f32, color: rl.Color) void {
    const tab = ed.options.tab_width;
    const c0 = dcol(bytes, a, tab);
    const c1 = @min(dcolEnd(bytes, b, tab), winEnd(l));
    if (c1 <= win_left or c0 >= winEnd(l)) return;
    const start = @max(c0, win_left);
    rect(colX(font, l, start), y, @as(f32, @floatFromInt(c1 - start)) * font.cell_w, h, color);
}

/// "author, 3 days ago · summary" after the end of the line.
fn drawBlame(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, bytes: []const u8, line: usize, y: f32) void {
    var buf: [200]u8 = undefined;
    var ago_buf: [32]u8 = undefined;
    const text = switch (ed.blameLine(line)) {
        .unknown => return,
        .uncommitted => "not committed yet",
        .commit => |c| std.fmt.bufPrint(&buf, "{s}, {s} \u{b7} {s}", .{ c.author, Blame.ago(&ago_buf, ed.unixNow() - c.time), c.summary }) catch return,
    };
    const end_col = dcol(bytes, bytes.len, ed.options.tab_width) + 4;
    if (end_col < win_left or end_col >= winEnd(l)) return;
    _ = font.drawText(clip(text, winEnd(l) - end_col), colX(font, l, end_col), y, theme.ai_fg);
}

fn rlColor(c: Editor.ColorPicker.Rgba) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = 255 };
}

/// The colour wheel (`SPC l c`), next to the literal it edits: hue around
/// the wheel, saturation from centre to rim, brightness on the bar beside
/// it; the old and new colours, the literal as it will be written, and the
/// keys. In a terminal (no circles there) the three are strips.
fn drawColorPicker(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const p = &(ed.color_picker orelse return);
    if (p.buffer != ed.buffer) return;
    const at = cellPos(ed, font, l, p.start) orelse return;
    const cw = font.cell_w;
    const ch = font.cell_h;
    const tui = gfx.grid != null;
    const wheel_rows: usize = if (tui) 5 else 9;
    // The wheel is as many pixels wide as it is tall.
    const wheel_px = @as(f32, @floatFromInt(wheel_rows)) * ch;
    const wheel_cols: usize = if (tui) 26 else @intFromFloat(@ceil(wheel_px / cw));
    const text_cols = 24;
    const gap: usize = if (tui) 2 else 6;
    const cols = 2 + wheel_cols + gap + text_cols;
    const rows = wheel_rows + 5;
    const box = popupBox(font, theme, l, at.x, at.y, cols, rows);
    const hsv = p.hsv;
    const now = p.color();
    const x0 = box.x + cw * 2;
    const y0 = box.y + ch;

    if (tui) {
        // Strips: each shows its range with the other two as they are.
        const n = wheel_cols;
        const strips = [_]struct { []const u8, f32 }{ .{ "H", hsv.h / 360 }, .{ "S", hsv.s }, .{ "V", hsv.v } };
        for (strips, 0..) |s, row| {
            const y = y0 + @as(f32, @floatFromInt(row * 2)) * ch;
            _ = font.drawText(s[0], box.x + cw * 0.5, y, theme.status_dim);
            for (0..n) |i| {
                const f = @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(n - 1));
                const c: Editor.ColorPicker.Hsv = switch (row) {
                    0 => .{ .h = f * 359.9, .s = 1, .v = 1 },
                    1 => .{ .h = hsv.h, .s = f, .v = hsv.v },
                    else => .{ .h = hsv.h, .s = hsv.s, .v = f },
                };
                rect(x0 + @as(f32, @floatFromInt(i)) * cw, y, cw, ch, rlColor(Editor.ColorPicker.toRgb(c)));
            }
            const mark: usize = @intFromFloat(@round(s[1] * @as(f32, @floatFromInt(n - 1))));
            font.drawCodepoint(0x25CF, x0 + @as(f32, @floatFromInt(mark)) * cw, y, Theme.contrast(rlColor(now)));
        }
    } else {
        // The wheel: rings of wedges, each its hue and saturation at the
        // current brightness.
        const radius = wheel_px / 2;
        const center: rl.Vector2 = .{ .x = @round(x0 + radius), .y = @round(y0 + radius) };
        const bands = 28;
        const wedges = 72;
        for (0..bands) |band| {
            const inner = radius * @as(f32, @floatFromInt(band)) / bands;
            const outer = radius * @as(f32, @floatFromInt(band + 1)) / bands;
            const s = (@as(f32, @floatFromInt(band)) + 0.5) / bands;
            for (0..wedges) |w| {
                const a0 = @as(f32, @floatFromInt(w)) * 360 / wedges;
                const a1 = a0 + 360.0 / @as(f32, wedges);
                const c = Editor.ColorPicker.toRgb(.{ .h = a0 + 180.0 / @as(f32, wedges), .s = s, .v = hsv.v });
                // A hair of overlap hides the seams between wedges.
                rl.DrawRing(center, @max(inner - 0.5, 0), outer + 0.5, a0 - 0.3, a1 + 0.3, 2, rlColor(c));
            }
        }
        // Where the colour is on it.
        const angle = hsv.h * std.math.pi / 180.0;
        const mark: rl.Vector2 = .{ .x = center.x + @cos(angle) * hsv.s * radius, .y = center.y + @sin(angle) * hsv.s * radius };
        rl.DrawCircleV(mark, 7, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        rl.DrawCircleV(mark, 6, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
        rl.DrawCircleV(mark, 4, rlColor(now));

        // The brightness bar: this hue and saturation, dark to light.
        const bar_x = x0 + wheel_px + cw * 1.5;
        const bar_w = cw * 2;
        const slices = 48;
        const slice_h = wheel_px / slices;
        for (0..slices) |i| {
            const v = 1 - (@as(f32, @floatFromInt(i)) + 0.5) / slices;
            const c = Editor.ColorPicker.toRgb(.{ .h = hsv.h, .s = hsv.s, .v = v });
            rect(bar_x, y0 + @as(f32, @floatFromInt(i)) * slice_h, bar_w, slice_h + 1, rlColor(c));
        }
        const mark_y = @round(y0 + (1 - hsv.v) * wheel_px);
        rect(bar_x - 3, mark_y - 2, bar_w + 6, 4, .{ .r = 0, .g = 0, .b = 0, .a = 255 });
        rect(bar_x - 2, mark_y - 1, bar_w + 4, 2, .{ .r = 255, .g = 255, .b = 255, .a = 255 });
    }

    // Old and new, the literal, and the numbers.
    const tx = x0 + @as(f32, @floatFromInt(wheel_cols + gap)) * cw;
    rect(tx, y0, cw * 8, ch * 2, rlColor(p.original));
    rect(tx + cw * 8, y0, cw * 8, ch * 2, rlColor(now));
    _ = font.drawText("was", tx + cw * 0.5, y0, Theme.contrast(rlColor(p.original)));
    _ = font.drawText("now", tx + cw * 8.5, y0, Theme.contrast(rlColor(now)));
    var lit_buf: [16]u8 = undefined;
    _ = font.drawText(p.write(&lit_buf), tx, y0 + ch * 3, theme.fg);
    var num_buf: [48]u8 = undefined;
    const numbers = [_]struct { []const u8, []const u8, f32, bool }{
        .{ "hue", "h l", hsv.h, true },
        .{ "saturation", "j k", hsv.s * 100, false },
        .{ "brightness", "J K", hsv.v * 100, false },
        .{ "opacity", "a A", p.alpha * 100, false },
    };
    for (numbers, 0..) |n, i| {
        if (i == 3 and !p.hasAlpha()) continue;
        const y = y0 + ch * @as(f32, @floatFromInt(4 + i));
        var x = font.drawText(n[1], tx, y, theme.whichkey_key);
        x = font.drawText(n[0], x + cw, y, theme.status_dim);
        const value = std.fmt.bufPrint(&num_buf, "{d:.0}{s}", .{ n[2], if (n[3]) "\u{b0}" else "%" }) catch "";
        _ = font.drawText(value, tx + cw * @as(f32, @floatFromInt(text_cols -| (cells(value) + 2))), y, theme.fg);
    }
    // Keys, along the bottom.
    const hints = [_][2][]const u8{ .{ "Enter", "set" }, .{ "y", "copy" }, .{ "r", "reset" }, .{ "Esc", "cancel" }, .{ "5l", "count" } };
    var hx = box.x + cw * 2;
    const hy = box.y + @as(f32, @floatFromInt(rows - 2)) * ch;
    rect(box.x, hy - ch * 0.5, @as(f32, @floatFromInt(cols)) * cw, 1, theme.popup_border);
    for (hints) |h| {
        hx = font.drawText(h[0], hx, hy, theme.whichkey_key);
        hx = font.drawText(h[1], hx + cw, hy, theme.status_dim) + cw * 2;
    }
}

/// Notifications (mini.notify): stacked at the top right, newest lowest,
/// fading out as they expire.
fn drawToasts(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const max_cols = 60;
    var y = font.cell_h;
    for (ed.toasts.items) |*toast| {
        const text = clip(toast.text(), max_cols);
        const cols = cells(text) + 4;
        const w = @as(f32, @floatFromInt(cols)) * font.cell_w;
        const x = l.width - w - font.cell_w;
        if (x < 0 or y + font.cell_h > l.status_y) break;
        // The last half second fades (windows; a terminal has no alpha).
        var alpha: f32 = 1;
        if (!toast.busy and gfx.grid == null) {
            const left_ms = @as(f32, @floatFromInt(@divTrunc(toast.expires.nanoseconds - ed.now.nanoseconds, std.time.ns_per_ms)));
            alpha = std.math.clamp(left_ms / Editor.Toast.fade_ms, 0, 1);
        }
        const accent = if (toast.kind == .err) theme.message_err else if (toast.busy) theme.diag_warning else theme.mode_normal;
        rect(x - 1, y - 1, w + 2, font.cell_h + 2, faded(theme.popup_border, alpha));
        rect(x, y, w, font.cell_h, faded(theme.status_bg, alpha));
        rect(x, y, font.cell_w, font.cell_h, faded(accent, alpha));
        _ = font.drawText(text, x + font.cell_w * 2, y, faded(if (toast.kind == .err) theme.message_err else theme.fg, alpha));
        y += font.cell_h + 4;
    }
}

fn faded(c: rl.Color, alpha: f32) rl.Color {
    var out = c;
    out.a = @intFromFloat(@as(f32, @floatFromInt(c.a)) * alpha);
    return out;
}

/// The screen row of text position `pos` and its visual column, with the
/// column window set to the row it is on (a wrapped line's piece).
fn posRow(ed: *Editor, pos: usize) ?struct { row: usize, col: usize } {
    const t = ed.text();
    const line = t.lineOf(pos);
    const col = ed.visualCol(line, pos - t.lineStart(line));
    if (!ed.layered()) {
        unwrappedWindow(ed);
        return .{ .row = ed.screenRow(line) orelse return null, .col = col };
    }
    var seg_buf: [Editor.max_segments]Editor.Seg = undefined;
    const vis = ed.visibleLine(line);
    const segs = ed.segments(vis, &seg_buf);
    const k = if (vis == line) Editor.segmentIndex(segs, col) else 0;
    if (ed.options.wrap) {
        win_left = segs[k].start;
        win_right = segs[k].end;
        win_indent = segs[k].indent;
    } else unwrappedWindow(ed);
    const row = ed.rowOnScreen(.{ .line = vis, .sub = @intCast(ed.lensRows(vis) + k) }) orelse return null;
    return .{ .row = row, .col = col };
}

fn drawCursorAt(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, pos: usize, color: rl.Color) void {
    const at = posRow(ed, pos) orelse return;
    const row = at.row;
    const col = at.col;
    // At the end of a wrapped row the cursor sits at its last cell.
    if (col < win_left or col > winEnd(l) or (col == winEnd(l) and win_right == std.math.maxInt(usize))) return;
    const x = colX(font, l, @min(col, winEnd(l)));
    const y = @as(f32, @floatFromInt(row)) * font.cell_h + scrollPx(ed, font);
    // The terminal's own cursor goes on the focused one (a no-op in a window).
    if (color.a == 255) gfx.cursor(x, y, switch (ed.mode) {
        .insert => .bar,
        .operator => .underline,
        else => .block,
    });
    // In a terminal the real cursor is the focused one, drawn over the cell
    // as it is: painting our block under it too would hand the terminal a
    // cursor-colored cell, and a terminal whose cursor text is "the cell's
    // background" (kitty's `cursor_text_color background`) would then draw
    // the letter in the cursor's own color.
    if (gfx.grid != null and color.a == 255) return;
    switch (ed.mode) {
        .insert => rect(x, y, 2, font.cell_h, color),
        // Half block: an operator is waiting for its motion.
        .operator => rect(x, y + font.cell_h / 2, font.cell_w, font.cell_h / 2, color),
        .normal, .picker, .picker_normal, .visual, .search => {
            rect(x, y, font.cell_w, font.cell_h, color);
            // Redraw the character under the block in the contrasting color.
            const t = ed.text();
            if (pos < t.lineEnd(t.lineOf(pos))) {
                var it = Font.Utf8Lossy{ .bytes = t.slice(pos, @min(pos + 4, t.len())) };
                if (it.next()) |cp| {
                    if (cp != '\t' and cp != ' ') font.drawCodepoint(cp, x, y, theme.cursor_text);
                }
            }
        },
    }
}

fn drawStatus(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const y = l.status_y;
    rect(0, y, l.width, font.cell_h, theme.status_bg);

    // Mode pill.
    const mode_name, const mode_color = if (ed.window.term != null and ed.popup == null) .{ " TERM ", theme.mode_insert } else if (ed.popup) |pp| switch (pp) {
        .shell => .{ " TERM ", theme.mode_insert },
        .run => .{ " RUN ", theme.mode_insert },
    } else switch (ed.mode) {
        .normal => .{ " NORMAL ", theme.mode_normal },
        .insert => .{ " INSERT ", theme.mode_insert },
        .picker => .{ " PICKER ", theme.mode_picker },
        .picker_normal => .{ " PICKER ", theme.mode_normal },
        .visual => if (ed.visual_line) .{ " V-LINE ", theme.mode_visual } else .{ " VISUAL ", theme.mode_visual },
        .operator => .{ " NORMAL ", theme.mode_normal },
        .search => switch (if (ed.search_prompt) |sp| sp.kind else .search) {
            .search => .{ " SEARCH ", theme.mode_visual },
            .snipe => .{ " SNIPE ", theme.mode_visual },
            .select_in => .{ " SELECT ", theme.mode_visual },
            .rename => .{ " RENAME ", theme.mode_insert },
            .replace => .{ " REPLACE ", theme.mode_insert },
            .git_commit, .git_remote => .{ " GIT ", theme.mode_insert },
            .new_file, .save_as, .rename_file, .copy_file => .{ " FILE ", theme.mode_insert },
            .run_command => .{ " RUN ", theme.mode_insert },
            .ask_claude => .{ " CLAUDE ", theme.mode_insert },
            .browse_new_folder, .browse_new_file, .browse_rename, .browse_move => .{ " FILE ", theme.mode_insert },
        },
    };
    rect(0, y, @as(f32, @floatFromInt(mode_name.len)) * font.cell_w, font.cell_h, mode_color);
    var x = font.drawText(mode_name, 0, y, theme.mode_text);

    // The search prompt, the latest message, or the file name.
    x += font.cell_w;
    if (ed.search_prompt != null and !ed.search_prompt.?.kind.boxed()) {
        const sp = &ed.search_prompt.?;
        const label = switch (sp.kind) {
            .search => if (sp.forward) "/" else "?",
            .snipe => "snipe › ",
            .select_in => "in selection › ",
            else => "",
        };
        x = font.drawText(label, x, y, theme.status_dim);
        x = font.drawText(sp.input.items(), x, y, theme.fg);
        if (gfx.grid == null) rect(x, y + 2, 2, font.cell_h - 4, theme.cursor);
        gfx.cursor(x, y, .bar);
    } else if (ed.message.len > 0) {
        const color = if (ed.message.kind == .err) theme.message_err else theme.message_info;
        _ = font.drawText(ed.message.text(), x, y, color);
    } else {
        // "project  path/in/project"
        var path_buf: [std.fs.max_path_bytes]u8 = undefined;
        if (ed.buffer.project) |p| {
            x = font.drawText(p.name(), x, y, theme.whichkey_group);
            x += font.cell_w * 2;
        }
        x = font.drawText(projectPath(ed, &path_buf), x, y, theme.status_fg);
        if (ed.buffer.hex) x = font.drawText(" [hex]", x, y, theme.whichkey_group);
        if (ed.buffer.modified) _ = font.drawText(" [+]", x, y, theme.status_fg);
    }

    // Right side: pending keys and position, e.g. "2d   12:5  40%".
    var buf: [128]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    writeRight(ed, &w) catch {};
    const right = w.buffered();
    const right_x = l.width - @as(f32, @floatFromInt(std.unicode.utf8CountCodepoints(right) catch right.len + 1)) * font.cell_w;
    _ = font.drawText(right, right_x, y, theme.status_dim);
}

/// The current file's path inside its project (else as the buffer has it).
fn projectPath(ed: *Editor, buf: []u8) []const u8 {
    const b = ed.buffer;
    const path = b.path orelse return b.displayName();
    const p = b.project orelse return path;
    const abs = if (std.fs.path.isAbsolute(path)) path else std.fmt.bufPrint(buf, "{s}/{s}", .{ ed.cwd, path }) catch return path;
    if (abs.len > p.root.len + 1 and std.mem.startsWith(u8, abs, p.root) and abs[p.root.len] == '/') return abs[p.root.len + 1 ..];
    return path;
}

fn writeRight(ed: *Editor, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (ed.macro_register) |r| try w.print("recording @{c}   ", .{r});
    if (ed.cursors.items.len > 0) try w.print("{d} cursors   ", .{ed.cursors.items.len + 1});
    const typed = ed.showcmdKeys();
    try keys.formatSequenceDisplay(typed, w);
    if (typed.len > 0) try w.writeAll("-   ");
    if (ed.buffers.items.len > 1 and ed.cmd_float == null) try w.print("[{d}/{d}]  ", .{ ed.bufferIndex(ed.buffer) + 1, ed.buffers.items.len });

    const line = ed.cursorLine();
    const total = ed.text().lineCount();
    if (ed.ghost) |g| {
        const h = ed.ghostHunk(g.line);
        if (h) |hh| try w.print("HEAD:{d}  ", .{hh.old_start + g.k + 1});
    }
    try w.print("{d}:{d}  ", .{ line + 1, ed.cursorCol() + 1 });
    if (total <= 1) try w.writeAll("All ") else try w.print("{d: >3}% ", .{line * 100 / (total - 1)});
}

/// Highlights the part of `line` inside the visual selection.
fn drawSelection(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, sel: operators.Range, line: usize, y: f32) void {
    drawRange(ed, font, l, sel, line, y, theme.selection_bg);
}

/// Colors the part of `line` inside `sel`.
fn drawRange(ed: *Editor, font: *const Font, l: Layout, sel: operators.Range, line: usize, y: f32, color: rl.Color) void {
    const t = ed.text();
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    // Linewise ranges stop before the last line's break; still highlight it.
    const sel_end = if (sel.linewise) t.lineEnd(t.lineOf(sel.end)) + 1 else sel.end;
    if (sel_end <= ls or sel.start > le) return;
    const tab = ed.options.tab_width;
    const bytes = t.lineSlice(line);
    const c0 = dcol(bytes, @max(sel.start, ls) - ls, tab);
    // Selecting past the end of the line covers one extra cell for the break.
    const c1 = if (sel_end > le) dcol(bytes, bytes.len, tab) + 1 else dcolEnd(bytes, sel_end - ls, tab);
    // On a wrapped line's row: the part of the range on that row (the line
    // break's extra cell goes on its last row).
    const end = @min(c1, winEnd(l));
    if (end <= win_left or c0 >= winEnd(l)) return;
    const x0 = colX(font, l, @max(c0, win_left));
    const w = @as(f32, @floatFromInt(end - @max(c0, win_left))) * font.cell_w;
    rect(x0, y, w, font.cell_h, color);
}

/// Background for every match of the active search on `line`; the match
/// under the cursor is brighter.
fn drawSearchMatches(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, line: usize, y: f32) void {
    const t = ed.text();
    const ls = t.lineStart(line);
    const at_cursor: ?usize = if (ed.ghost == null and ed.view.cursor >= ls) ed.view.cursor - ls else null;
    drawMatchesIn(ed, font, theme, l, t.lineSlice(line), at_cursor, y);
}

/// Search match backgrounds in `bytes` (a text or ghost line); the match
/// starting at `cursor_col` is brighter.
fn drawMatchesIn(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, bytes: []const u8, cursor_col: ?usize, y: f32) void {
    const pattern = ed.searchPattern() orelse return;
    if (pattern.needle.len == 0) return;
    const tab = ed.options.tab_width;
    var i: usize = 0;
    while (pattern.forward(bytes, i)) |m| : (i = m + 1) {
        const c0 = dcol(bytes, m, tab);
        const c1 = dcolEnd(bytes, m + pattern.needle.len, tab);
        if (c1 <= win_left or c0 >= winEnd(l)) continue;
        const start = @max(c0, win_left);
        const x = colX(font, l, start);
        const w = @as(f32, @floatFromInt(@min(c1, winEnd(l)) - start)) * font.cell_w;
        const current = cursor_col != null and cursor_col.? == m;
        rect(x, y, w, font.cell_h, if (current) theme.search_current else theme.search_match);
    }
}

/// The text just yanked, lit and fading.
fn drawYankFlash(ed: *Editor, font: *const Font, _: *const Theme, l: Layout, line: usize, y: f32) void {
    const f = ed.yank_flash orelse return;
    if (f.buffer != ed.buffer) return;
    const t = ed.text();
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    if (f.end < ls or f.start > le or f.start >= t.len() and !f.linewise) return;
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    const from = if (f.linewise) 0 else (if (f.start > ls) f.start - ls else 0);
    const to = if (f.linewise) bytes.len else @min(f.end -| ls, bytes.len);
    const c0 = dcol(bytes, from, tab);
    // An empty line, or one whose break is yanked, still shows a cell.
    const c1 = @max(dcolEnd(bytes, to, tab), c0 + 1);
    if (c1 <= win_left or c0 >= winEnd(l)) return;
    const start = @max(c0, win_left);
    const x = colX(font, l, start);
    const w = @as(f32, @floatFromInt(@min(c1, winEnd(l)) - start)) * font.cell_w;
    // Yellow on any theme, see-through enough to read the text under it.
    const alpha: u8 = @intFromFloat(140 * f.strength(ed.now));
    rect(x, y, w, font.cell_h, .{ .r = 255, .g = 214, .b = 51, .a = alpha });
}

fn diagColor(theme: *const Theme, sev: Lsp.Severity) rl.Color {
    return switch (sev) {
        .err => theme.diag_error,
        .warning => theme.diag_warning,
        .info => theme.diag_info,
        .hint => theme.diag_hint,
    };
}

/// The most severe diagnostic starting on `line` (the list is sorted).
fn firstDiagnostic(diags: []const Lsp.Diagnostic, line: usize) ?*const Lsp.Diagnostic {
    for (diags) |*d| {
        if (d.line == line) return d;
        if (d.line > line) break;
    }
    return null;
}

/// Underlines each diagnostic's range on `line` and shows the first message
/// after the end of the line.
fn drawDiagnostics(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, diags: []const Lsp.Diagnostic, line: usize, y: f32, last_piece: bool) void {
    const t = ed.text();
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    for (diags) |d| {
        if (d.line != line) continue;
        const end_byte = if (d.end_line == d.line) @max(d.end_col, d.col + 1) else bytes.len;
        const c0 = dcol(bytes, @min(d.col, bytes.len), tab);
        const c1 = @min(@max(dcolEnd(bytes, @min(end_byte, bytes.len), tab), c0 + 1), winEnd(l));
        if (c1 <= win_left or c0 >= winEnd(l)) continue;
        const x = colX(font, l, @max(c0, win_left));
        const w = @as(f32, @floatFromInt(c1 - @max(c0, win_left))) * font.cell_w;
        rect(x, y + font.cell_h - 2, w, 2, diagColor(theme, d.severity));
    }
    // Virtual text: the first (most severe) message, after the line.
    if (!ed.options.diagnostic_text or !last_piece) return;
    const d = firstDiagnostic(diags, line).?;
    const end_col = dcol(bytes, bytes.len, tab) + 3;
    if (end_col < win_left or end_col >= winEnd(l)) return;
    const x = colX(font, l, end_col);
    const msg = std.mem.sliceTo(d.message, '\n');
    const room = winEnd(l) - end_col;
    var color = diagColor(theme, d.severity);
    color.a = 200;
    _ = font.drawText(clip(msg, room), x, y, color);
}

/// The first `cells` codepoints of `s`.
fn clip(s: []const u8, max_cells: usize) []const u8 {
    var it = Font.Utf8Lossy{ .bytes = s };
    var n: usize = 0;
    while (n < max_cells) : (n += 1) _ = it.next() orelse return s;
    return s[0..it.i];
}

/// Screen position of a text position, if visible.
fn cellPos(ed: *Editor, font: *const Font, l: Layout, pos: usize) ?struct { x: f32, y: f32 } {
    const at = posRow(ed, pos) orelse return null;
    if (at.row >= l.rows or at.col < win_left) return null;
    return .{
        .x = colX(font, l, @min(at.col, winEnd(l))),
        .y = @as(f32, @floatFromInt(at.row)) * font.cell_h,
    };
}

/// A bordered box of `rows` x `cols` cells next to the line at `anchor_y`:
/// below it if there is room, else above. Returns its top-left.
fn popupBox(font: *const Font, theme: *const Theme, l: Layout, x0: f32, anchor_y: f32, cols: usize, rows: usize) struct { x: f32, y: f32 } {
    const w = @as(f32, @floatFromInt(cols)) * font.cell_w;
    const h = @as(f32, @floatFromInt(rows)) * font.cell_h;
    const below = anchor_y + font.cell_h;
    const y = if (below + h <= l.status_y) below else @max(anchor_y - h, 0);
    const x = @max(@min(x0, l.width - w - 1), 0);
    rect(x - 1, y - 1, w + 2, h + 2, theme.popup_border);
    rect(x, y, w, h, theme.popup_bg);
    return .{ .x = x, .y = y };
}

fn drawHover(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const text = ed.hover orelse return;
    const at = cellPos(ed, font, l, ed.view.cursor) orelse return;
    // Markdown fences are noise in a plain-text box.
    var lines: [24][]const u8 = undefined;
    var n: usize = 0;
    var width: usize = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (std.mem.startsWith(u8, line, "```")) continue;
        if (n == lines.len) break;
        lines[n] = line;
        n += 1;
        width = @max(width, cells(line));
    }
    while (n > 0 and std.mem.trim(u8, lines[n - 1], " ").len == 0) n -= 1;
    if (n == 0) return;
    const cols = @min(width + 2, 80);
    const box = popupBox(font, theme, l, at.x, at.y, cols, n);
    for (lines[0..n], 0..) |line, i| {
        _ = font.drawText(clip(line, cols - 2), box.x + font.cell_w, box.y + @as(f32, @floatFromInt(i)) * font.cell_h, theme.fg);
    }
}

/// Signature help: the call's signature above the cursor with the current
/// parameter highlighted, and its documentation's first line.
fn drawSignature(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const sig = ed.signature orelse return;
    const at = cellPos(ed, font, l, ed.view.cursor) orelse return;
    const max_cols: usize = @min(@as(usize, @intFromFloat(l.width / font.cell_w)) -| 4, 100);
    const label_cells = cells(sig.label);
    // Long signatures: show the window around the current parameter.
    var skip: usize = 0;
    if (label_cells > max_cols) {
        const param_end_cells = cells(sig.label[0..sig.param_end]);
        if (param_end_cells + 2 > max_cols) skip = param_end_cells + 2 - max_cols;
    }
    const shown_cells = @min(label_cells - skip, max_cols);
    const doc_cells = @min(cells(sig.doc), max_cols);
    const cols = @max(shown_cells, doc_cells) + 2;
    const rows: usize = if (sig.doc.len > 0) 2 else 1;
    const w = @as(f32, @floatFromInt(cols)) * font.cell_w;
    const h = @as(f32, @floatFromInt(rows)) * font.cell_h;
    // Above the cursor line (completion uses below), else below.
    const y = if (at.y - h >= 0) at.y - h else at.y + font.cell_h;
    const x = @max(@min(at.x - font.cell_w, l.width - w - 1), 0);
    rect(x - 1, y - 1, w + 2, h + 2, theme.popup_border);
    rect(x, y, w, h, theme.popup_bg);

    var cx = x + font.cell_w;
    var it = Font.Utf8Lossy{ .bytes = sig.label };
    var n: usize = 0;
    while (true) : (n += 1) {
        const offset = it.i;
        const cp = it.next() orelse break;
        if (n < skip) continue;
        if (n - skip >= shown_cells) break;
        const in_param = offset >= sig.param_start and offset < sig.param_end;
        if (in_param) rect(cx, y + font.cell_h - 2, font.cell_w, 1, theme.whichkey_key);
        if (cp != ' ') font.drawCodepoint(cp, cx, y, if (in_param) theme.whichkey_key else theme.fg);
        cx += font.cell_w;
    }
    if (sig.doc.len > 0) _ = font.drawText(clip(sig.doc, max_cols), x + font.cell_w, y + font.cell_h, theme.status_dim);
}

fn drawCompletion(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const c = ed.completionShown() orelse return;
    const at = cellPos(ed, font, l, c.word_start) orelse return;
    const max_rows = 10;
    const rows = @min(c.shown.items.len, max_rows);
    // Scroll so the selection is visible.
    const first = if (c.selected >= max_rows) c.selected + 1 - max_rows else 0;
    var label_w: usize = 1;
    var detail_w: usize = 0;
    for (c.shown.items[first .. first + rows]) |i| {
        label_w = @max(label_w, cells(c.items[i].label));
        detail_w = @max(detail_w, cells(c.items[i].detail));
    }
    label_w = @min(label_w, 40);
    detail_w = @min(detail_w, 40);
    const cols = label_w + (if (detail_w > 0) detail_w + 2 else 0) + 2;
    const box = popupBox(font, theme, l, at.x - font.cell_w, at.y, cols, rows);
    for (c.shown.items[first .. first + rows], first..) |i, row| {
        const item = c.items[i];
        const y = box.y + @as(f32, @floatFromInt(row - first)) * font.cell_h;
        if (row == c.selected) {
            rect(box.x, y, @as(f32, @floatFromInt(cols)) * font.cell_w, font.cell_h, theme.selection_bg);
        }
        _ = font.drawText(clip(item.label, label_w), box.x + font.cell_w, y, theme.fg);
        if (item.detail.len > 0) {
            const dx = box.x + @as(f32, @floatFromInt(label_w + 3)) * font.cell_w;
            _ = font.drawText(clip(item.detail, detail_w), dx, y, theme.status_dim);
        }
    }
    drawCompletionDoc(c, font, theme, l, box.x, box.y, cols);
}

/// The selected suggestion's documentation, beside the list (on the side
/// with room for it; none when neither has).
fn drawCompletionDoc(c: *Completion, font: *const Font, theme: *const Theme, l: Layout, list_x: f32, list_y: f32, list_cols: usize) void {
    const text = c.docText();
    if (text.len == 0) return;
    const max_rows = 16;
    var lines: [max_rows][]const u8 = undefined;
    var n: usize = 0;
    var width: usize = 1;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (n == lines.len) {
            lines[n - 1] = "…";
            break;
        }
        lines[n] = line;
        n += 1;
        width = @max(width, cells(line));
    }
    const cols = @min(width, Completion.doc_cols) + 2;
    const w = @as(f32, @floatFromInt(cols)) * font.cell_w;
    const h = @as(f32, @floatFromInt(n)) * font.cell_h;
    const list_w = @as(f32, @floatFromInt(list_cols)) * font.cell_w;
    const right = list_x + list_w + 2;
    const x = if (right + w + 1 <= l.width) right else if (list_x - w - 2 >= 0) list_x - w - 2 else return;
    // Kept on the screen when the list is near the bottom.
    const y = @max(@min(list_y, l.status_y - h - 1), 0);
    rect(x - 1, y - 1, w + 2, h + 2, theme.popup_border);
    rect(x, y, w, h, theme.popup_bg);
    for (lines[0..n], 0..) |line, i| {
        _ = font.drawText(clip(line, cols - 2), x + font.cell_w, y + @as(f32, @floatFromInt(i)) * font.cell_h, theme.fg);
    }
}

/// A ghost line: an old HEAD line of a git hunk, shown inline (read-only).
fn drawGhostRow(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, line: usize, k: u32, y: f32) void {
    rect(0, y, l.width, font.cell_h, theme.ghost_bg);
    if (ed.ghost) |g| {
        // A visual selection of ghost lines.
        if (ed.mode == .visual and g.line == line) if (g.anchor) |a| {
            if (k >= @min(a, g.k) and k <= @max(a, g.k)) rect(l.text_x, y, l.width - l.text_x, font.cell_h, theme.selection_bg);
        };
        if (g.line == line and g.k == k and ed.mode != .visual) rect(0, y, l.width, font.cell_h, theme.ghost_current_bg);
    }
    const sign_x = @as(f32, @floatFromInt(l.gutter_cols - 2)) * font.cell_w;
    _ = font.drawText("-", sign_x, y, theme.ghost_fg);
    if (ed.search_highlight) {
        const on_it: ?usize = if (ed.ghost) |g| (if (g.line == line and g.k == k) g.col else null) else null;
        drawMatchesIn(ed, font, theme, l, ed.ghostText(line, k), on_it, y);
    }
    rect(0, y, 3, font.cell_h, theme.diff_delete);
    const text = ed.ghostText(line, k);
    var it = Font.Utf8Lossy{ .bytes = text };
    var col: usize = 0;
    const left = ed.view.left;
    while (it.next()) |cp| {
        const next_col = if (cp == '\t') motions.nextTabStop(col, ed.options.tab_width) else col + 1;
        defer col = next_col;
        if (next_col <= left) continue;
        if (col >= left + l.cols) break;
        if (cp == '\t' or cp == ' ') continue;
        font.drawCodepoint(cp, l.text_x + @as(f32, @floatFromInt(col - left)) * font.cell_w, y, theme.ghost_fg);
    }
}

fn drawGhostCursor(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, g: Editor.GhostCursor) void {
    const row = ed.rowOnScreen(.{ .line = g.line, .ghost = g.k }) orelse return;
    const text = ed.ghostText(g.line, g.k);
    const col = motions.displayCol(text, @min(g.col, text.len), ed.options.tab_width);
    if (col < ed.view.left or col >= ed.view.left + l.cols) return;
    const x = l.text_x + @as(f32, @floatFromInt(col - ed.view.left)) * font.cell_w;
    const y = @as(f32, @floatFromInt(row)) * font.cell_h + scrollPx(ed, font);
    rect(x, y, font.cell_w, font.cell_h, theme.cursor);
    if (g.col < text.len) {
        var it = Font.Utf8Lossy{ .bytes = text[g.col..] };
        if (it.next()) |cp| if (cp != ' ' and cp != '\t') font.drawCodepoint(cp, x, y, theme.cursor_text);
    }
}

/// Gutter bar for git changes: green added, yellow changed; with ghost lines
/// off, a red tick where lines were deleted.
fn drawGitSign(ed: *Editor, theme: *const Theme, line: usize, y: f32, h: f32) void {
    const g = ed.buffer.git orelse return;
    for (g.hunks.items) |hunk| {
        if (hunk.new_start > line + 1) break;
        if (hunk.new_count > 0 and line >= hunk.new_start and line < hunk.new_start + hunk.new_count) {
            rect(0, y, 3, h, if (hunk.old_count == 0) theme.diff_add else theme.diff_change);
            return;
        }
        if (hunk.new_count == 0 and !ed.options.ghost_lines and hunk.new_start == line) {
            rect(0, y, 8, 3, theme.diff_delete);
            return;
        }
    }
}

test "terminal mode: the focused cursor's cell keeps its colors" {
    // The terminal draws its own cursor over the cell; a cursor-colored
    // cell under it turns `cursor_text_color background` into blue on blue.
    const Grid = @import("../tui/Grid.zig");
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, std.testing.io);
    defer ed.deinit();
    try ed.text().insert(gpa, 0, "hello\n");
    var grid: Grid = .{};
    defer grid.deinit(gpa);
    try grid.resize(gpa, 40, 10);
    gfx.grid = &grid;
    defer gfx.grid = null;
    var font = Font.cells();
    const theme = Theme.get(ed.theme_index);
    const l = prepare(&ed, &font, 40 * Grid.cell_w, 10 * Grid.cell_h);
    draw(&ed, &font, theme, l);
    const cur = grid.cursor orelse return error.NoCursor;
    const cell = grid.cells[cur.row * grid.cols + cur.col];
    try std.testing.expectEqual('h', cell.cp);
    try std.testing.expect(!std.meta.eql(cell.bg, theme.cursor));
    try std.testing.expect(!std.meta.eql(cell.fg, cell.bg));
}

test "terminal mode: a popup over the cursor hides the terminal's cursor" {
    const Grid = @import("../tui/Grid.zig");
    const gpa = std.testing.allocator;
    var ed = try Editor.init(gpa, std.testing.io);
    defer ed.deinit();
    try ed.text().insert(gpa, 0, "1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n");
    var grid: Grid = .{};
    defer grid.deinit(gpa);
    try grid.resize(gpa, 60, 12);
    gfx.grid = &grid;
    defer gfx.grid = null;
    var font = Font.cells();
    const theme = Theme.get(ed.theme_index);
    try ed.feed("9G");
    var l = prepare(&ed, &font, 60 * Grid.cell_w, 12 * Grid.cell_h);
    draw(&ed, &font, theme, l);
    try std.testing.expect(grid.cursor != null);
    // SPC: which-key fills the rows above the status line, over line 9.
    try ed.feed("<Space>");
    l = prepare(&ed, &font, 60 * Grid.cell_w, 12 * Grid.cell_h);
    draw(&ed, &font, theme, l);
    try std.testing.expect(grid.cursor == null);
    try ed.feed("<Esc>");
    l = prepare(&ed, &font, 60 * Grid.cell_w, 12 * Grid.cell_h);
    draw(&ed, &font, theme, l);
    try std.testing.expect(grid.cursor != null);
}

/// Sticky context: the first lines of the scopes the top of the window is
/// inside (function, `if`, JSX element...) pinned over its top rows,
/// highlighted, with a line under them.
fn drawContext(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    var buf: [3]usize = undefined;
    const lines = ed.contextLines(&buf);
    if (lines.len == 0) return;
    const t = ed.text();
    const syntax = ed.buffer.syntax;
    for (lines, 0..) |line, i| {
        const y = @as(f32, @floatFromInt(i)) * font.cell_h;
        rect(0, y, l.width, font.cell_h, theme.fold_bg);
        // Its line number in the gutter.
        var num_buf: [24]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{line + 1}) catch "";
        const nx = l.text_x - @as(f32, @floatFromInt(num.len + 1)) * font.cell_w;
        if (nx >= 0) _ = font.drawText(num, nx, y, theme.gutter_fg);
        // The line, highlighted on its own (tabs as spaces, from `view.left`).
        const text = t.lineSlice(line);
        var styles: std.ArrayList(Syntax.Style) = .empty;
        defer styles.deinit(ed.gpa);
        if (syntax) |sx| Syntax.highlightText(ed.gpa, sx.lang, text, &styles) catch {};
        var it = Font.Utf8Lossy{ .bytes = text };
        var col: usize = 0;
        while (true) {
            const off = it.i;
            const cp = it.next() orelse break;
            if (cp == '\t') {
                col = (col / ed.options.tab_width + 1) * ed.options.tab_width;
                continue;
            }
            defer col += 1;
            if (col < ed.view.left) continue;
            const c = col - ed.view.left;
            if (c >= l.cols) break;
            const color = if (off < styles.items.len) theme.syntax.get(styles.items[off]) else theme.fg;
            if (cp != ' ') font.drawCodepoint(cp, l.text_x + @as(f32, @floatFromInt(c)) * font.cell_w, y, color);
        }
    }
    const bottom = @as(f32, @floatFromInt(lines.len)) * font.cell_h;
    rect(0, bottom - 1, l.width, 1, theme.popup_border);
}

fn withAlpha(c: rl.Color, a: u8) rl.Color {
    return .{ .r = c.r, .g = c.g, .b = c.b, .a = a };
}
