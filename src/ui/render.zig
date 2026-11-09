//! Draws editor state. Reads `Editor`, never mutates it.

const std = @import("std");
const rl = @import("raylib");
const Editor = @import("../Editor.zig");
const motions = @import("../core/motions.zig");
const Font = @import("Font.zig");
const Theme = @import("Theme.zig");
const keymap = @import("../input/keymap.zig");
const keys = @import("../input/keys.zig");
const picker_view = @import("picker_view.zig");
const operators = @import("../operators.zig");
const Syntax = @import("../syntax/Syntax.zig");
const Lsp = @import("../lsp/Lsp.zig");

/// Screen geometry in pixels and cells, recomputed every frame.
pub const Layout = struct {
    /// Gutter width in cells (line numbers + padding).
    gutter_cols: usize,
    text_x: f32,
    rows: usize,
    cols: usize,
    status_y: f32,
    width: f32,

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

pub fn draw(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    rl.ClearBackground(theme.bg);
    drawText(ed, font, theme, l);
    drawWhichKey(ed, font, theme, l);
    drawStatus(ed, font, theme, l);
    drawHover(ed, font, theme, l);
    drawCompletion(ed, font, theme, l);
    if (ed.picker) |p| picker_view.draw(p, font, theme, l);
    if (ed.search_prompt) |*sp| if (sp.kind == .rename) {
        picker_view.drawPromptBox(font, theme, l, "Rename symbol", sp.input.items());
    };
}

/// The which-key menu: a grid of `key → label` above the status line while a
/// key sequence is pending. Groups show as "+name".
fn drawWhichKey(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    var buf: [128]keymap.Continuation = undefined;
    const items = ed.whichKey(&buf);
    if (items.len == 0) return;

    // Column width from the widest entry: key, " → ", label (+ "+" for groups).
    var key_w: usize = 1;
    var label_w: usize = 1;
    for (items) |it| {
        key_w = @max(key_w, keyCells(it.key));
        label_w = @max(label_w, cells(it.label) + @intFromBool(it.kind == .group));
    }
    const pad = 2;
    const col_w = key_w + 3 + label_w + pad;
    const total_cols: usize = @intFromFloat(l.width / font.cell_w);
    const columns = @max((total_cols -| pad) / col_w, 1);
    const rows = (items.len + columns - 1) / columns;

    const h = @as(f32, @floatFromInt(rows)) * font.cell_h + font.cell_h; // + half a row padding above and below
    const y0 = l.status_y - h;
    rect(0, y0, l.width, h, theme.popup_bg);
    rect(0, y0, l.width, 1, theme.popup_border);

    for (items, 0..) |it, i| {
        // Fill down columns first, like which-key.
        const col = i / rows;
        const row = i % rows;
        var x = @as(f32, @floatFromInt(pad + col * col_w)) * font.cell_w;
        const y = y0 + font.cell_h / 2 + @as(f32, @floatFromInt(row)) * font.cell_h;

        var key_buf: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&key_buf);
        keys.formatDisplay(it.key, &w) catch {};
        const key_text = w.buffered();
        // Right-align keys so the arrows line up.
        x += @as(f32, @floatFromInt(key_w - cells(key_text))) * font.cell_w;
        x = font.drawText(key_text, x, y, theme.whichkey_key);
        x = font.drawText(" → ", x, y, theme.popup_border);
        switch (it.kind) {
            .group => {
                x = font.drawText("+", x, y, theme.whichkey_group);
                _ = font.drawText(it.label, x, y, theme.whichkey_group);
            },
            .command => _ = font.drawText(it.label, x, y, theme.whichkey_command),
        }
    }
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
    rl.DrawRectangleRec(.{ .x = x, .y = y, .width = w, .height = h }, color);
}

fn drawText(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const selection: ?operators.Range = if (ed.mode == .visual) ed.visualRange() else null;
    const syntax: ?*const Syntax = if (ed.buffer.syntax) |*s| s else null;
    const diags = ed.diagnostics(ed.buffer);
    const t = ed.text();
    const v = &ed.view;
    const cursor_line = ed.cursorLine();
    const tab_width = ed.options.tab_width;

    // Rows walk visible lines: a closed fold is drawn as its first line plus a
    // marker, and the lines it hides are skipped.
    var row: usize = 0;
    var next_line: usize = v.top;
    while (row < l.rows) : (row += 1) {
        const line = next_line;
        if (line >= t.lineCount()) break;
        const fold = ed.foldAt(line);
        next_line = if (fold) |f| f.last + 1 else line + 1;
        const y = @as(f32, @floatFromInt(row)) * font.cell_h;
        const is_current = line == cursor_line;
        if (fold != null) rect(0, y, l.width, font.cell_h, theme.fold_bg);

        if (is_current) rect(0, y, l.width, font.cell_h, theme.cursorline_bg);
        if (selection) |sel| drawSelection(ed, font, theme, l, sel, line, y);

        // Line number, right-aligned in the gutter with one cell of padding.
        var num_buf: [24]u8 = undefined;
        const num = std.fmt.bufPrint(&num_buf, "{d}", .{line + 1}) catch unreachable;
        const num_x = @as(f32, @floatFromInt(l.gutter_cols - 1 - num.len)) * font.cell_w;
        const line_diag = firstDiagnostic(diags, line);
        const num_color = if (line_diag) |d| diagColor(theme, d.severity) else if (fold != null) theme.fold_fg else if (is_current) theme.gutter_current_fg else theme.gutter_fg;
        _ = font.drawText(num, num_x, y, num_color);

        if (ed.search_highlight) drawSearchMatches(ed, font, theme, l, line, y);

        // Text, starting at the first visible display column, colored by syntax.
        const ls = t.lineStart(line);
        const bytes = t.lineSlice(line);
        var it = Font.Utf8Lossy{ .bytes = bytes };
        var col: usize = 0;
        while (true) {
            const offset = it.i;
            const cp = it.next() orelse break;
            const next_col = if (cp == '\t') motions.nextTabStop(col, tab_width) else col + 1;
            defer col = next_col;
            if (next_col <= v.left) continue;
            if (col >= v.left + l.cols) break;
            if (cp == '\t' or cp == ' ') continue;
            const x = l.text_x + @as(f32, @floatFromInt(col - v.left)) * font.cell_w;
            const style = if (syntax) |s| s.styleAt(ls + offset) else .none;
            font.drawCodepoint(cp, x, y, theme.syntax.get(style));
        }
        if (fold) |f| {
            // "… 12 lines" after the fold's first line.
            const end_col = motions.displayCol(bytes, bytes.len, tab_width) + 2;
            if (end_col >= v.left and end_col < v.left + l.cols) {
                var buf: [32]u8 = undefined;
                const label = std.fmt.bufPrint(&buf, "… {d} lines", .{f.last - f.first}) catch "…";
                _ = font.drawText(label, l.text_x + @as(f32, @floatFromInt(end_col - v.left)) * font.cell_w, y, theme.fold_fg);
            }
        } else if (line_diag != null) drawDiagnostics(ed, font, theme, l, diags, line, y);
    }

    drawCursor(ed, font, theme, l);
}

fn drawCursor(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const v = &ed.view;
    const line = ed.cursorLine();
    const row = ed.screenRow(line) orelse return;
    const col = ed.cursorCol();
    if (col < v.left or col >= v.left + l.cols) return;

    const x = l.text_x + @as(f32, @floatFromInt(col - v.left)) * font.cell_w;
    const y = @as(f32, @floatFromInt(row)) * font.cell_h;
    switch (ed.mode) {
        .insert => rect(x, y, 2, font.cell_h, theme.cursor),
        // Half block: an operator is waiting for its motion.
        .operator => rect(x, y + font.cell_h / 2, font.cell_w, font.cell_h / 2, theme.cursor),
        .normal, .picker, .visual, .search => {
            rect(x, y, font.cell_w, font.cell_h, theme.cursor);
            // Redraw the character under the block in the contrasting color.
            const t = ed.text();
            if (v.cursor < t.lineEnd(line)) {
                var it = Font.Utf8Lossy{ .bytes = t.slice(v.cursor, @min(v.cursor + 4, t.len())) };
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
    const mode_name, const mode_color = switch (ed.mode) {
        .normal => .{ " NORMAL ", theme.mode_normal },
        .insert => .{ " INSERT ", theme.mode_insert },
        .picker => .{ " PICKER ", theme.mode_picker },
        .visual => if (ed.visual_line) .{ " V-LINE ", theme.mode_visual } else .{ " VISUAL ", theme.mode_visual },
        .operator => .{ " NORMAL ", theme.mode_normal },
        .search => switch (if (ed.search_prompt) |sp| sp.kind else .search) {
            .search => .{ " SEARCH ", theme.mode_visual },
            .snipe => .{ " SNIPE ", theme.mode_visual },
            .rename => .{ " RENAME ", theme.mode_insert },
        },
    };
    rect(0, y, @as(f32, @floatFromInt(mode_name.len)) * font.cell_w, font.cell_h, mode_color);
    var x = font.drawText(mode_name, 0, y, theme.mode_text);

    // The search prompt, the latest message, or the file name.
    x += font.cell_w;
    if (ed.search_prompt != null and ed.search_prompt.?.kind != .rename) {
        const sp = &ed.search_prompt.?;
        const label = switch (sp.kind) {
            .search => if (sp.forward) "/" else "?",
            .snipe => "snipe › ",
            .rename => "rename to › ",
        };
        x = font.drawText(label, x, y, theme.status_dim);
        x = font.drawText(sp.input.items(), x, y, theme.fg);
        rect(x, y + 2, 2, font.cell_h - 4, theme.cursor);
    } else if (ed.message.len > 0) {
        const color = if (ed.message.kind == .err) theme.message_err else theme.message_info;
        _ = font.drawText(ed.message.text(), x, y, color);
    } else {
        x = font.drawText(ed.buffer.displayName(), x, y, theme.status_fg);
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

fn writeRight(ed: *Editor, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (ed.macro_register) |r| try w.print("recording @{c}   ", .{r});
    const typed = ed.showcmdKeys();
    try keys.formatSequenceDisplay(typed, w);
    if (typed.len > 0) try w.writeAll("-   ");
    if (ed.buffers.items.len > 1) try w.print("[{d}/{d}]  ", .{ ed.bufferIndex(ed.buffer) + 1, ed.buffers.items.len });

    const line = ed.cursorLine();
    const total = ed.text().lineCount();
    try w.print("{d}:{d}  ", .{ line + 1, ed.cursorCol() + 1 });
    if (total <= 1) try w.writeAll("All ") else try w.print("{d: >3}% ", .{line * 100 / (total - 1)});
}

/// Highlights the part of `line` inside the visual selection.
fn drawSelection(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, sel: operators.Range, line: usize, y: f32) void {
    const t = ed.text();
    const ls = t.lineStart(line);
    const le = t.lineEnd(line);
    // Linewise ranges stop before the last line's break; still highlight it.
    const sel_end = if (sel.linewise) t.lineEnd(t.lineOf(sel.end)) + 1 else sel.end;
    if (sel_end <= ls or sel.start > le) return;
    const tab = ed.options.tab_width;
    const bytes = t.lineSlice(line);
    const c0 = motions.displayCol(bytes, @max(sel.start, ls) - ls, tab);
    // Selecting past the end of the line covers one extra cell for the break.
    const c1 = if (sel_end > le) motions.displayCol(bytes, bytes.len, tab) + 1 else motions.displayCol(bytes, sel_end - ls, tab);
    const left = ed.view.left;
    if (c1 <= left) return;
    const x0 = l.text_x + @as(f32, @floatFromInt(@max(c0, left) - left)) * font.cell_w;
    const w = @as(f32, @floatFromInt(c1 - @max(c0, left))) * font.cell_w;
    rect(x0, y, w, font.cell_h, theme.selection_bg);
}

/// Background for every match of the active search on `line`; the match
/// under the cursor is brighter.
fn drawSearchMatches(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, line: usize, y: f32) void {
    const pattern = ed.searchPattern() orelse return;
    if (pattern.needle.len == 0) return;
    const t = ed.text();
    const ls = t.lineStart(line);
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    var i: usize = 0;
    while (pattern.forward(bytes, i)) |m| : (i = m + 1) {
        const c0 = motions.displayCol(bytes, m, tab);
        const c1 = motions.displayCol(bytes, m + pattern.needle.len, tab);
        if (c1 <= ed.view.left or c0 >= ed.view.left + l.cols) continue;
        const start = @max(c0, ed.view.left);
        const x = l.text_x + @as(f32, @floatFromInt(start - ed.view.left)) * font.cell_w;
        const w = @as(f32, @floatFromInt(c1 - start)) * font.cell_w;
        const current = ls + m == ed.view.cursor;
        rect(x, y, w, font.cell_h, if (current) theme.search_current else theme.search_match);
    }
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
fn drawDiagnostics(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout, diags: []const Lsp.Diagnostic, line: usize, y: f32) void {
    const t = ed.text();
    const bytes = t.lineSlice(line);
    const tab = ed.options.tab_width;
    const left = ed.view.left;
    for (diags) |d| {
        if (d.line != line) continue;
        const end_byte = if (d.end_line == d.line) @max(d.end_col, d.col + 1) else bytes.len;
        const c0 = motions.displayCol(bytes, @min(d.col, bytes.len), tab);
        const c1 = @max(motions.displayCol(bytes, @min(end_byte, bytes.len), tab), c0 + 1);
        if (c1 <= left) continue;
        const x = l.text_x + @as(f32, @floatFromInt(@max(c0, left) - left)) * font.cell_w;
        const w = @as(f32, @floatFromInt(c1 - @max(c0, left))) * font.cell_w;
        rect(x, y + font.cell_h - 2, w, 2, diagColor(theme, d.severity));
    }
    // Virtual text: the first (most severe) message, after the line.
    const d = firstDiagnostic(diags, line).?;
    const end_col = motions.displayCol(bytes, bytes.len, tab) + 3;
    if (end_col >= left + l.cols) return;
    const x = l.text_x + @as(f32, @floatFromInt(end_col - left)) * font.cell_w;
    const msg = std.mem.sliceTo(d.message, '\n');
    const room = left + l.cols - end_col;
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
    const t = ed.text();
    const line = t.lineOf(pos);
    const row = ed.screenRow(line) orelse return null;
    if (row >= l.rows) return null;
    const col = motions.displayCol(t.lineSlice(line), pos - t.lineStart(line), ed.options.tab_width);
    if (col < ed.view.left) return null;
    return .{
        .x = l.text_x + @as(f32, @floatFromInt(col - ed.view.left)) * font.cell_w,
        .y = @as(f32, @floatFromInt(row)) * font.cell_h,
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

fn drawCompletion(ed: *Editor, font: *const Font, theme: *const Theme, l: Layout) void {
    const c = &(ed.completion orelse return);
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
}
