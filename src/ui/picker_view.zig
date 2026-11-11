//! Draws the picker: a centered box with the query line, the result list
//! (matched characters highlighted) and, when wide enough, a preview pane.

const std = @import("std");
const rl = @import("raylib");
const Picker = @import("../picker/Picker.zig");
const sources = @import("../picker/sources.zig");
const Editor = @import("../Editor.zig");
const Engine = @import("../picker/Engine.zig");
const fuzzy = @import("../picker/fuzzy.zig");
const Font = @import("Font.zig");
const Theme = @import("Theme.zig");
const render = @import("render.zig");
const gfx = @import("gfx.zig");
const icons = @import("icons.zig");

const rect = render.rect;
const cells = render.cells;

/// Below this many columns the preview pane is hidden.
const preview_min_cols = 90;

pub fn draw(p: *Picker, font: *const Font, theme: *const Theme, l: render.Layout) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const total_cols: usize = @intFromFloat(l.width / cw);
    const total_rows: usize = @intFromFloat((l.status_y + ch) / ch);

    const box_cols = @max(@min(total_cols -| 4, total_cols * 9 / 10), @min(total_cols, 30));
    const box_rows = @max(@min(total_rows -| 4, total_rows * 3 / 4), @min(total_rows, 6));
    const bx = @as(f32, @floatFromInt((total_cols - box_cols) / 2)) * cw;
    const by = @as(f32, @floatFromInt(@max((total_rows - box_rows) / 3, 1))) * ch;
    const bw = @as(f32, @floatFromInt(box_cols)) * cw;
    const bh = @as(f32, @floatFromInt(box_rows)) * ch;

    // Dim the editor behind the picker.
    rect(0, 0, l.width, l.status_y + ch, theme.backdrop);
    rect(bx - 1, by - 1, bw + 2, bh + 2, theme.popup_border);
    rect(bx, by, bw, bh, theme.popup_bg);

    drawQueryLine(p, font, theme, bx, by, box_cols);
    rect(bx, by + ch, bw, 1, theme.popup_border);

    const show_preview = box_cols >= preview_min_cols;
    const list_cols = if (show_preview) box_cols * 2 / 5 else box_cols;
    const visible = box_rows - 1;
    drawList(p, font, theme, bx, by + ch, list_cols, visible);

    if (show_preview) {
        const px = bx + @as(f32, @floatFromInt(list_cols)) * cw;
        rect(px, by + ch, 1, bh - ch, theme.popup_border);
        drawPreview(p, font, theme, px + cw, by + ch, box_cols - list_cols - 2, visible);
    }
}

fn drawQueryLine(p: *Picker, font: *const Font, theme: *const Theme, bx: f32, y: f32, box_cols: usize) void {
    const cw = font.cell_w;
    var x = bx + cw;
    x = font.drawText(p.title(), x, y, theme.mode_picker);
    x = font.drawText(" › ", x, y, theme.status_dim);
    x = font.drawText(p.query.items(), x, y, theme.fg);
    // Typing shows a cursor; moving through results shows the keys instead.
    if (p.ed.mode == .picker) {
        // In a terminal its own cursor is the bar; drawing one too makes two.
        if (gfx.grid == null) rect(x, y + 2, 2, font.cell_h - 4, theme.cursor);
        gfx.cursor(x, y, .bar);
    } else {
        const hint = switch (p.kind) {
            .browse => "  o folder · n file · r rename · m move · x delete · yy p copy · i type",
            .buffers => "  j/k move · Enter open · x close it · n new · i type",
            .runner => "  j/k move · Enter run · Tab edit it · x forget · i type",
            .quickfix => "  j/k move · Enter open · x clear the list · i type",
            else => "  j/k move · Enter open · i type · q close",
        };
        _ = font.drawText(hint, x, y, theme.status_dim);
    }

    // "matched/total", with an ellipsis while the source is still producing.
    var buf: [48]u8 = undefined;
    const s = &p.snap;
    const count = std.fmt.bufPrint(&buf, "{d}/{d}{s}", .{ s.matched, s.total, if (s.done) "" else "…" }) catch "";
    const cx = bx + @as(f32, @floatFromInt(box_cols -| (cells(count) + 1))) * cw;
    _ = font.drawText(count, cx, y, theme.status_dim);
}

fn drawList(p: *Picker, font: *const Font, theme: *const Theme, x0: f32, y0: f32, list_cols: usize, visible: usize) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const rows = p.rowCount();

    // Keep the selection on screen.
    if (p.selected < p.top) p.top = p.selected;
    if (p.selected >= p.top + visible) p.top = p.selected + 1 - visible;

    const query = fuzzy.Query.init(p.activeQuery());
    const create_row = p.createRow();
    var row = p.top;
    while (row < rows and row < p.top + visible) : (row += 1) {
        const y = y0 + @as(f32, @floatFromInt(row - p.top)) * ch;
        const width = @as(f32, @floatFromInt(list_cols)) * cw;
        if (row == p.selected) {
            rect(x0, y, width, ch, theme.selection_bg);
            rect(x0, y, 2, ch, theme.cursor);
        }
        const tx = x0 + cw;
        if (create_row == row) {
            const x = font.drawText(sources.createLabel(p.kind), tx, y, theme.whichkey_group);
            _ = font.drawText(p.activeQuery(), x, y, theme.fg);
            continue;
        }
        const item = p.itemAt(row) orelse continue;

        // Detail right-aligned (at most 60% of the row); the text gets the
        // rest. Both truncate from the left so file names stay visible.
        const detail_cells = @min(cells(item.detail), list_cols * 3 / 5);
        if (detail_cells > 0) {
            const dx = x0 + @as(f32, @floatFromInt(list_cols -| (detail_cells + 1))) * cw;
            drawHighlighted(font, theme, item.detail, &.{}, dx, y, detail_cells, theme.status_dim, false);
        }
        var avail = list_cols -| (2 + detail_cells + @as(usize, if (detail_cells > 0) 2 else 0));
        var pos_buf: [Engine.max_query_len]usize = undefined;
        const positions = fuzzy.positions(query, item.text, &p.pos_scratch, &pos_buf) orelse &.{};
        const is_folder = p.kind == .browse and std.mem.endsWith(u8, item.text, "/");
        // A file-type icon in front of rows that are files (mini.icons).
        var text_x = tx;
        const is_file = switch (p.kind) {
            .files, .browse, .recent, .frecent, .buffers, .git_changes, .files_anywhere, .folders_anywhere => true,
            .start => sources.startItemIsFile(item.id),
            else => false,
        };
        if (is_file and p.ed.options.icons and font.has_icons and avail > 4) {
            const ic = icons.forPath(item.text);
            font.drawCodepoint(ic.cp, tx, y, .{ .r = ic.color[0], .g = ic.color[1], .b = ic.color[2], .a = 255 });
            text_x += cw * 2;
            avail -= 2;
        }
        // Prose reads from its start; paths keep their end (the file name).
        const prose = switch (p.kind) {
            .todos, .messages, .quickfix, .registers, .marks, .undo, .help, .runner => true,
            else => false,
        };
        drawHighlighted(font, theme, item.text, positions, text_x, y, avail, if (is_folder) theme.whichkey_group else theme.fg, prose);
    }

    if (rows == 0 and p.isCurrent() and p.snap.done) {
        _ = font.drawText("no matches", x0 + cw, y0, theme.status_dim);
    }
}

/// Draws `text` in at most `max_cells`, highlighting codepoints whose bytes are
/// in `positions` (sorted byte offsets). Text that doesn't fit loses its
/// start, or its end with `keep_head`.
fn drawHighlighted(font: *const Font, theme: *const Theme, text: []const u8, positions: []const usize, x: f32, y: f32, max_cells: usize, color: rl.Color, keep_head: bool) void {
    if (max_cells == 0) return;
    const total = cells(text);
    var cx = x;
    var skip: usize = 0;
    if (total > max_cells and !keep_head) {
        // Keep the tail (file names), unless that would hide the first match.
        skip = total - (max_cells - 1);
        if (positions.len > 0) {
            const first = cells(text[0..@min(positions[0], text.len)]);
            if (first < skip) skip = first -| 2;
        }
        if (skip > 0) {
            font.drawCodepoint('…', cx, y, theme.status_dim);
            cx += font.cell_w;
        }
    }
    var drawn: usize = if (skip > 0) 1 else 0;
    var it = Font.Utf8Lossy{ .bytes = text };
    var index: usize = 0;
    var pi: usize = 0;
    while (true) : (index += 1) {
        const start = it.i;
        const cp = it.next() orelse break;
        while (pi < positions.len and positions[pi] < start) pi += 1;
        const matched = pi < positions.len and positions[pi] < it.i;
        if (index < skip) continue;
        if (drawn == max_cells) break;
        if (cp != ' ') font.drawCodepoint(cp, cx, y, if (matched) theme.match_fg else color);
        cx += font.cell_w;
        drawn += 1;
    }
}

fn drawPreview(p: *Picker, font: *const Font, theme: *const Theme, x0: f32, y0: f32, cols: usize, visible: usize) void {
    const pv = &p.preview;
    if (pv.text.items.len == 0) {
        if (p.createRow() == p.selected and p.rowCount() > 0) {
            _ = font.drawText("(new file: created when saved)", x0, y0, theme.status_dim);
        }
        return;
    }
    // Show the focus line about a third of the way down.
    const first = pv.focus_line -| visible / 3;
    const gutter: usize = if (pv.numbered) 5 else 0;
    var lines = std.mem.splitScalar(u8, pv.text.items, '\n');
    var n: usize = 0;
    while (lines.next()) |line| : (n += 1) {
        if (n < first) continue;
        if (n >= first + visible) break;
        const y = y0 + @as(f32, @floatFromInt(n - first)) * font.cell_h;
        if (pv.numbered and n == pv.focus_line and pv.focus_line > 0) {
            rect(x0 - font.cell_w, y, @as(f32, @floatFromInt(cols + 2)) * font.cell_w, font.cell_h, theme.cursorline_bg);
        }
        var x = x0;
        if (pv.numbered) {
            var nb: [16]u8 = undefined;
            const num = std.fmt.bufPrint(&nb, "{d: >4} ", .{n + 1}) catch "";
            x = font.drawText(num, x, y, theme.gutter_fg);
        }
        const offset = @intFromPtr(line.ptr) - @intFromPtr(pv.text.items.ptr);
        const styles = if (pv.styles.items.len == pv.text.items.len) pv.styles.items[offset..][0..line.len] else &.{};
        drawLine(font, theme, line, styles, x, y, cols -| gutter);
    }
}

/// A preview line with tabs expanded, clipped to `max_cells`, colored by
/// `styles` (one per byte) when present.
fn drawLine(font: *const Font, theme: *const Theme, line: []const u8, styles: []const @import("../syntax/highlight.zig").Style, x: f32, y: f32, max_cells: usize) void {
    var it = Font.Utf8Lossy{ .bytes = line };
    var col: usize = 0;
    while (true) {
        const offset = it.i;
        const cp = it.next() orelse break;
        if (col >= max_cells) break;
        if (cp == '\t') {
            col = (col / 4 + 1) * 4;
            continue;
        }
        const color = if (offset < styles.len) theme.syntax.get(styles[offset]) else theme.fg;
        if (cp != ' ' and cp != '\r') font.drawCodepoint(cp, x + @as(f32, @floatFromInt(col)) * font.cell_w, y, color);
        col += 1;
    }
}

/// A small centered input box in the picker's style, sized to its content:
/// at least `min_cols` wide, growing with the text, capped at 80% of the
/// window. Used for one-line prompts (rename, ...).
pub fn drawPromptBox(font: *const Font, theme: *const Theme, l: render.Layout, title: []const u8, text: []const u8) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const total_cols: usize = @intFromFloat(l.width / cw);
    const total_rows: usize = @intFromFloat((l.status_y + ch) / ch);
    const min_cols = 40;
    const want = @max(min_cols, @max(cells(title), cells(text) + 2) + 4);
    const box_cols = @min(want, @max(total_cols * 4 / 5, @min(total_cols, min_cols)));
    const box_rows = 3; // title, separator gap, input
    const bx = @as(f32, @floatFromInt((total_cols -| box_cols) / 2)) * cw;
    const by = @as(f32, @floatFromInt(@max(total_rows / 3, 1))) * ch;
    const bw = @as(f32, @floatFromInt(box_cols)) * cw;
    const bh = @as(f32, @floatFromInt(box_rows)) * ch;

    rect(0, 0, l.width, l.status_y + ch, theme.backdrop);
    rect(bx - 1, by - 1, bw + 2, bh + 2, theme.popup_border);
    rect(bx, by, bw, bh, theme.popup_bg);
    _ = font.drawText(title, bx + cw, by, theme.mode_picker);
    rect(bx, by + ch * 1.5, bw, 1, theme.popup_border);

    // The input, scrolled so its end (and the cursor) stays visible.
    const y = by + ch * 2;
    var x = font.drawText("› ", bx + cw, y, theme.status_dim);
    const room = box_cols -| 5;
    const n = cells(text);
    var visible = text;
    if (n > room) {
        var it = Font.Utf8Lossy{ .bytes = text };
        for (0..n - room) |_| _ = it.next();
        visible = text[it.i..];
    }
    x = font.drawText(visible, x, y, theme.fg);
    if (gfx.grid == null) rect(x, y + 2, 2, ch - 4, theme.cursor);
    gfx.cursor(x, y, .bar);
}
