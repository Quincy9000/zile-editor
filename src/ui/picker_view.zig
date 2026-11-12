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
const Replace = @import("../Replace.zig");
const ResultGrid = @import("../ResultGrid.zig");

const rect = render.rect;
const cells = render.cells;

/// Below this many columns the preview pane is hidden.
const preview_min_cols = 90;

/// Where pickers and prompts go: docked full width at the bottom, right
/// above the status line, like telescope's ivy layout; the code stays in
/// view above it. `want_rows` is clamped to what fits.
const Dock = struct { bx: f32, by: f32, bw: f32, bh: f32, cols: usize, rows: usize };

fn dock(font: *const Font, l: render.Layout, want_rows: usize) Dock {
    const ch = font.cell_h;
    const total_cols: usize = @intFromFloat(l.width / font.cell_w);
    const above: usize = @intFromFloat(l.status_y / ch); // rows above the status line
    const rows = @max(@min(want_rows, above -| 2), @min(above, 3));
    const bh = @as(f32, @floatFromInt(rows)) * ch;
    return .{ .bx = 0, .by = l.status_y - bh, .bw = l.width, .bh = bh, .cols = total_cols, .rows = rows };
}

/// The panel: its background and a line along its top.
fn drawPanel(theme: *const Theme, d: Dock) void {
    rect(d.bx, d.by, d.bw, d.bh, theme.popup_bg);
    rect(d.bx, d.by, d.bw, 1, theme.popup_border);
}

/// A list's height: about 45% of the window, 8 to 24 rows.
fn listRows(font: *const Font, l: render.Layout) usize {
    const above: usize = @intFromFloat(l.status_y / font.cell_h);
    return std.math.clamp(above * 45 / 100, 8, 24);
}

pub fn draw(p: *Picker, font: *const Font, theme: *const Theme, l: render.Layout) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const d = dock(font, l, listRows(font, l));
    const box_cols = d.cols;
    const box_rows = d.rows;
    const bx = d.bx;
    const by = d.by;
    const bw = d.bw;
    const bh = d.bh;
    drawPanel(theme, d);

    drawQueryLine(p, font, theme, bx, by, box_cols);
    rect(bx, by + ch, bw, 1, theme.popup_border);

    const show_preview = box_cols >= preview_min_cols;
    const list_cols = if (show_preview) box_cols * 2 / 5 else box_cols;
    // The picker's actions along the bottom, when it has any.
    // As many lines as its keys need: a key that isn't shown isn't found.
    const bar: usize = if (actionBar(p)) @min(actionBarLines(p, font, theme, bx, 0, box_cols, 0), box_rows -| 4) else 0;
    const visible = box_rows - 1 - bar;
    drawList(p, font, theme, bx, by + ch, list_cols, visible);

    if (show_preview) {
        const px = bx + @as(f32, @floatFromInt(list_cols)) * cw;
        rect(px, by + ch, 1, @as(f32, @floatFromInt(visible)) * ch, theme.popup_border);
        drawPreview(p, font, theme, px + cw, by + ch, box_cols - list_cols - 2, visible);
    }
    if (bar > 0) _ = actionBarLines(p, font, theme, bx, by + bh - @as(f32, @floatFromInt(bar)) * ch, box_cols, bar);
}

/// Where the action bar's next part goes: parts flow left to right and
/// onto a new line when one is full.
const Flow = struct {
    font: *const Font,
    theme: *const Theme,
    x0: f32,
    end: f32,
    y0: f32,
    /// Lines there's room for when painting (0 while measuring).
    paint: usize,
    x: f32,
    line: usize = 0,

    fn y(f: *const Flow) f32 {
        return f.y0 + @as(f32, @floatFromInt(f.line)) * f.font.cell_h;
    }

    /// Room for `n` cells on this line, else the start of the next.
    fn fit(f: *Flow, n: usize) void {
        if (f.x > f.x0 and f.x + @as(f32, @floatFromInt(n)) * f.font.cell_w > f.end) {
            f.x = f.x0;
            f.line += 1;
        }
    }

    /// One `key label`.
    fn put(f: *Flow, key: []const u8, label: []const u8) void {
        f.fit(cells(key) + 1 + cells(label));
        const cw = f.font.cell_w;
        if (f.line < f.paint) {
            _ = f.font.drawText(key, f.x, f.y(), f.theme.whichkey_group);
            _ = f.font.drawText(label, f.x + @as(f32, @floatFromInt(cells(key) + 1)) * cw, f.y(), f.theme.status_dim);
        }
        f.x += @as(f32, @floatFromInt(cells(key) + 1 + cells(label) + 3)) * cw;
    }
};

/// The key that starts typing in a menu: `/`, unless that's a row (the
/// leader's grep), then `i`.
fn filterKey(p: *const Picker) []const u8 {
    return if (std.mem.indexOfScalar(u8, sources.rowKeys(p.kind), '/') != null) "i" else "/";
}

fn actionBar(p: *const Picker) bool {
    return sources.itemActions(p.kind).len > 0 or sources.rowKeys(p.kind).len > 0 or sources.scopeGroup(p.kind) != null;
}

/// `C-t project · open · recent · disk`, the current scope bright.
fn drawScopes(p: *const Picker, f: *Flow) void {
    const group = sources.scopeGroup(p.kind) orelse return;
    var need: usize = 4;
    for (group) |sc| need += cells(sc.name) + 3;
    f.fit(need);
    if (f.line < f.paint) {
        var x = f.font.drawText("C-t", f.x, f.y(), f.theme.whichkey_group) + f.font.cell_w;
        for (group, 0..) |sc, i| {
            if (i > 0) x = f.font.drawText(" · ", x, f.y(), f.theme.status_dim);
            x = f.font.drawText(sc.name, x, f.y(), if (sc.kind == p.kind) f.theme.fg else f.theme.status_dim);
        }
    }
    f.x += @as(f32, @floatFromInt(need + 3)) * f.font.cell_w;
}

/// The bottom lines: what the picker does besides Enter. After <Esc>, the
/// letters; while typing, the Ctrl keys; <Tab> for all of them. Every key
/// is there, over as many lines as they take. Returns that many; draws
/// `paint` lines of them (0: none, to know the height first).
fn actionBarLines(p: *const Picker, font: *const Font, theme: *const Theme, x0: f32, y: f32, cols: usize, paint: usize) usize {
    const cw = font.cell_w;
    if (paint > 0) rect(x0, y, @as(f32, @floatFromInt(cols)) * cw, 1, theme.popup_border);
    var f: Flow = .{ .font = font, .theme = theme, .x0 = x0 + cw, .x = x0 + cw, .end = x0 + @as(f32, @floatFromInt(cols -| 1)) * cw, .y0 = y, .paint = paint };
    const typing = p.ed.mode == .picker;
    if (sources.rowKeys(p.kind).len > 0) {
        f.put("key", "runs its row");
        f.put(filterKey(p), "type to filter");
        return f.line + 1;
    }
    drawScopes(p, &f);
    if (sources.itemActions(p.kind).len == 0) return f.line + 1;
    var buf: [16]u8 = undefined;
    f.put("Tab", if (typing) "actions" else "all actions");
    if (sources.altAccept(p.kind)) |alt| f.put("C-⏎", alt.label);
    for (sources.itemActions(p.kind)) |a| {
        const key = if (typing)
            (if (a.ctrl != 0) std.fmt.bufPrint(&buf, "C-{c}", .{a.ctrl}) catch continue else continue)
        else if (a.key != 0) std.fmt.bufPrint(&buf, "{c}", .{a.key}) catch continue else continue;
        f.put(key, a.label);
    }
    if (typing) f.put("Esc", "for the letters");
    return f.line + 1;
}

fn drawQueryLine(p: *Picker, font: *const Font, theme: *const Theme, bx: f32, y: f32, box_cols: usize) void {
    const cw = font.cell_w;
    var x = bx + cw;
    x = font.drawText(p.title(), x, y, theme.mode_picker);
    x = font.drawText(" › ", x, y, theme.status_dim);
    const q = p.query.items();
    const qx = x;
    x = font.drawText(q, x, y, theme.fg);
    // The query's cursor: a bar while typing, a block on its character in
    // normal mode (where vim keys edit the query).
    const cur = @min(p.query.cursor, q.len);
    const qcx = qx + @as(f32, @floatFromInt(cells(q[0..cur]))) * cw;
    if (p.ed.mode == .picker) {
        // In a terminal its own cursor is the bar; drawing one too makes two.
        if (gfx.grid == null) rect(qcx, y + 2, 2, font.cell_h - 4, theme.cursor);
        gfx.cursor(qcx, y, .bar);
    } else if (q.len > 0) {
        gfx.cursor(qcx, y, .block);
        if (gfx.grid == null) {
            rect(qcx, y, cw, font.cell_h, theme.cursor);
            var it = Font.Utf8Lossy{ .bytes = q[cur..] };
            if (it.next()) |ch| if (ch != ' ') font.drawCodepoint(ch, qcx, y, theme.cursor_text);
        }
    }
    if (p.ed.mode != .picker) {
        const hint = switch (p.kind) {
            .browse => "  o folder · n file · r rename · m move · x delete · yy p copy · i type",
            .buffers => "  j/k move · Enter open · i type",
            .runner => "  j/k move · Enter run · i type",
            .quickfix => "  j/k move · Enter open · x clear the list · i type",
            else => if (sources.rowKeys(p.kind).len > 0) blk: {
                // `q` may be a row (the start screen's Quit): then Esc closes.
                const q_row = std.mem.indexOfScalar(u8, sources.rowKeys(p.kind), 'q') != null;
                const slash = std.mem.eql(u8, filterKey(p), "/");
                break :blk if (q_row)
                    (if (slash) "  j/k move · Enter run · / type · Esc close" else "  j/k move · Enter run · i type · Esc close")
                else
                    (if (slash) "  j/k move · Enter run · / type · q close" else "  j/k move · Enter run · i type · q close");
            } else "  j/k move · Enter open · i type · q close",
        };
        x = font.drawText(hint, x, y, theme.status_dim);
    }

    // "matched/total", with an ellipsis while the source is still producing.
    var buf: [48]u8 = undefined;
    const s = &p.snap;
    const elsewhere = p.globalLen();
    const count = if (elsewhere > 0)
        std.fmt.bufPrint(&buf, "{d}/{d}{s} · {d} elsewhere", .{ s.matched, s.total, if (s.done) "" else "…", elsewhere }) catch ""
    else
        std.fmt.bufPrint(&buf, "{d}/{d}{s}", .{ s.matched, s.total, if (s.done) "" else "…" }) catch "";
    const cx = bx + @as(f32, @floatFromInt(box_cols -| (cells(count) + 1))) * cw;
    _ = font.drawText(count, cx, y, theme.status_dim);
    // A reminder of what else this picker does, before the count.
    const extra: ?[]const u8 = switch (p.kind) {
        .grep => "C-r replace",
        else => null,
    };
    if (extra) |e| {
        const hx = cx - @as(f32, @floatFromInt(cells(e) + 3)) * cw;
        if (hx > x + 2 * cw) {
            const kx = font.drawText("C-r", hx, y, theme.whichkey_group);
            _ = font.drawText(e[3..], kx, y, theme.status_dim);
        }
    }
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
        // Found elsewhere (the explorer's second search): under a line.
        if (row > p.top and p.isGlobalRow(row) and !p.isGlobalRow(row - 1)) rect(x0, y, width, 1, theme.popup_border);
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
    const first = (pv.focus_line -| visible / 3) + p.previewScroll();
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

/// A one-line prompt (rename, commit message, new file...), docked at the
/// bottom like the pickers: its title, then the input.
pub fn drawPromptBox(font: *const Font, theme: *const Theme, l: render.Layout, title: []const u8, text: []const u8) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const d = dock(font, l, 3); // title, gap, input
    const box_cols = d.cols;
    const bx = d.bx;
    const by = d.by;
    const bw = d.bw;
    drawPanel(theme, d);
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

// ---------------------------------------------------------------------------
// Search and replace across the project (`<C-r>` in the grep picker)

/// The replace prompt: "Replace <needle> with › <replacement>" over the
/// lines with matches, grouped by file, each as it is (matches in red) and
/// as it will be (replacements in green). Skipped lines are dimmed.
pub fn drawReplace(r: *Replace, font: *const Font, theme: *const Theme, l: render.Layout, replacement: []const u8) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const d = dock(font, l, listRows(font, l));
    const box_cols = d.cols;
    const box_rows = d.rows;
    const bx = d.bx;
    const by = d.by;
    const bw = d.bw;
    const bh = d.bh;
    drawPanel(theme, d);

    // Replace "needle" with › replacement            12 in 4 files
    var x = font.drawText("Replace ", bx + cw, by, theme.mode_picker);
    x = font.drawText(r.needle, x, by, theme.diff_delete);
    x = font.drawText(" with › ", x, by, theme.status_dim);
    x = font.drawText(replacement, x, by, theme.diff_add);
    if (gfx.grid == null) rect(x, by + 2, 2, ch - 4, theme.cursor);
    gfx.cursor(x, by, .bar);
    var buf: [64]u8 = undefined;
    const done = r.isDone();
    const c: @TypeOf(r.counts()) = if (done) r.counts() else .{ .matches = 0, .files = 0 };
    const count = if (!done) "searching…" else if (r.failed) "rg failed" else std.fmt.bufPrint(&buf, "{d} in {d} file{s}{s}", .{
        c.matches, c.files, if (c.files == 1) "" else "s", if (r.truncated) " (first 10000)" else "",
    }) catch "";
    _ = font.drawText(count, bx + @as(f32, @floatFromInt(box_cols -| (cells(count) + 1))) * cw, by, theme.status_dim);
    rect(bx, by + ch, bw, 1, theme.popup_border);

    const hint = "↑↓ move · Tab skip line · S-Tab skip file · Enter replace · Esc back";
    _ = font.drawText(hint, bx + cw, by + bh - ch, theme.status_dim);
    const visible = box_rows -| 3; // query, list, hint
    if (!done) return;
    const rows = r.matches.items;
    if (rows.len == 0) {
        _ = font.drawText(if (r.failed) "rg could not search here" else "no matches", bx + cw, by + ch, theme.status_dim);
        return;
    }

    // Keep the selection on screen (rows: a header per file, two per line).
    if (r.selected < r.top) r.top = r.selected;
    while (r.top < r.selected and replaceRows(r, r.top, r.selected) > visible) r.top += 1;

    var y = by + ch;
    const y_end = y + @as(f32, @floatFromInt(visible)) * ch;
    const text_cols = box_cols -| 9;
    var i = r.top;
    while (i < rows.len and y < y_end) : (i += 1) {
        const m = rows[i];
        if (i == r.top or !std.mem.eql(u8, rows[i - 1].path, m.path)) {
            _ = font.drawText(m.path, bx + cw, y, if (m.skip) theme.status_dim else theme.whichkey_group);
            y += ch;
            if (y >= y_end) break;
        }
        const n_rows: f32 = if (m.skip) 1 else 2;
        if (i == r.selected) {
            rect(bx, y, bw, ch * n_rows, theme.selection_bg);
            rect(bx, y, 2, ch * n_rows, theme.cursor);
        }
        var nb: [16]u8 = undefined;
        const num = std.fmt.bufPrint(&nb, "{d: >5}  ", .{m.line + 1}) catch "";
        const tx = font.drawText(num, bx + cw, y, theme.gutter_fg);
        if (m.skip) {
            drawMarked(font, m.text, &.{}, tx, y, text_cols, theme.status_dim, theme.status_dim);
            y += ch;
            continue;
        }
        // As it is: each match marked.
        var spans: [32][2]usize = undefined;
        var n: usize = 0;
        for (m.cols) |col| {
            if (n == spans.len) break;
            if (!r.matchesAt(m.text, col)) continue;
            spans[n] = .{ col, col + r.needle.len };
            n += 1;
        }
        drawMarked(font, m.text, spans[0..n], tx, y, text_cols, theme.fg, theme.diff_delete);
        y += ch;
        if (y >= y_end) break;
        // As it will be: each replacement marked.
        var line_buf: [2048]u8 = undefined;
        var len: usize = 0;
        var from: usize = 0;
        var k: usize = 0;
        var new_spans: [32][2]usize = undefined;
        for (spans[0..n]) |sp| {
            const before = m.text[from..sp[0]];
            if (len + before.len + replacement.len > line_buf.len) break;
            @memcpy(line_buf[len..][0..before.len], before);
            len += before.len;
            @memcpy(line_buf[len..][0..replacement.len], replacement);
            new_spans[k] = .{ len, len + replacement.len };
            k += 1;
            len += replacement.len;
            from = sp[1];
        }
        const rest = m.text[@min(from, m.text.len)..];
        const take = @min(rest.len, line_buf.len - len);
        @memcpy(line_buf[len..][0..take], rest[0..take]);
        len += take;
        drawMarked(font, line_buf[0..len], new_spans[0..k], tx, y, text_cols, theme.fg, theme.diff_add);
        y += ch;
    }
}

/// Screen rows the list takes from line `from` through line `to`.
fn replaceRows(r: *const Replace, from: usize, to: usize) usize {
    var n: usize = 0;
    const rows = r.matches.items;
    for (from..to + 1) |i| {
        if (i == from or !std.mem.eql(u8, rows[i - 1].path, rows[i].path)) n += 1;
        n += if (rows[i].skip) 1 else 2;
    }
    return n;
}

/// A code line without its indentation, tabs as spaces, in at most
/// `max_cells`; the byte ranges `marks` (ascending) in `mark_color`.
fn drawMarked(font: *const Font, line: []const u8, marks: []const [2]usize, x: f32, y: f32, max_cells: usize, color: rl.Color, mark_color: rl.Color) void {
    var start: usize = 0;
    while (start < line.len and (line[start] == ' ' or line[start] == '\t')) start += 1;
    var it = Font.Utf8Lossy{ .bytes = line[start..] };
    var col: usize = 0;
    var mi: usize = 0;
    while (true) {
        const at = start + it.i;
        const cp = it.next() orelse break;
        if (col >= max_cells) break;
        while (mi < marks.len and marks[mi][1] <= at) mi += 1;
        const marked = mi < marks.len and marks[mi][0] <= at;
        if (cp == '\t') {
            col += 4;
            continue;
        }
        if (cp != ' ' and cp != '\r') font.drawCodepoint(cp, x + @as(f32, @floatFromInt(col)) * font.cell_w, y, if (marked) mark_color else color);
        col += 1;
    }
}

// ---------------------------------------------------------------------------
// The SQL results grid

/// `value` in at most `width` cells at `x`, a line break or tab as a space;
/// "…" where it is cut.
fn drawCell(font: *const Font, value: []const u8, x: f32, y: f32, width: usize, color: rl.Color) void {
    var it = Font.Utf8Lossy{ .bytes = value };
    var n: usize = 0;
    while (it.next()) |cp| {
        if (n + 1 == width and it.i < value.len) {
            font.drawCodepoint(0x2026, x + @as(f32, @floatFromInt(n)) * font.cell_w, y, color);
            return;
        }
        if (n == width) return;
        if (cp > ' ') font.drawCodepoint(cp, x + @as(f32, @floatFromInt(n)) * font.cell_w, y, color);
        n += 1;
    }
}

/// Docked at the bottom like a picker: a title line, the column names, the
/// rows, then the cell under the cursor in full and the keys.
pub fn drawGrid(g: *ResultGrid, font: *const Font, theme: *const Theme, l: render.Layout) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const d = dock(font, l, listRows(font, l) + 4);
    drawPanel(theme, d);
    const x0 = d.bx + cw;
    const cols = d.cols -| 2;
    // Title, rows, column names, the value, the keys: 5 lines that aren't rows.
    const body = d.rows -| 5;
    g.scrollTo(@max(body, 1), cols);

    var buf: [160]u8 = undefined;
    const mode: []const u8 = switch (g.visual) {
        .none => "",
        .cells => "  -- VISUAL --",
        .rows => "  -- VISUAL LINE --",
    };
    var x = font.drawText("SQL results", x0, d.by, theme.mode_picker);
    const where = std.fmt.bufPrint(&buf, "   row {d}/{d} · column {d}/{d}{s}", .{ g.row + 1, g.rows.len, g.col + 1, g.columns.len, mode }) catch "";
    x = font.drawText(where, x, d.by, theme.status_dim);
    if (g.typing) {
        x = font.drawText("   /", x, d.by, theme.fg);
        x = font.drawText(g.input.items, x, d.by, theme.fg);
        gfx.cursor(x, d.by, .bar);
        if (gfx.grid == null) rect(x, d.by + 2, 2, ch - 4, theme.cursor);
    } else if (g.search.items.len > 0) {
        const shown = std.fmt.bufPrint(&buf, "   /{s}", .{g.search.items}) catch "";
        _ = font.drawText(shown, x, d.by, theme.status_dim);
    }

    // The columns that fit, from `left`.
    var last = g.left;
    var used: usize = 0;
    while (last < g.columns.len) : (last += 1) {
        const need = g.widths[last] + (if (last > g.left) @as(usize, 3) else 0);
        if (used + need > cols and last > g.left) break;
        used += need;
    }
    const header_y = d.by + ch;
    rect(d.bx, header_y + ch, d.bw, 1, theme.popup_border);
    {
        var cx = x0;
        for (g.left..last) |c| {
            if (c > g.left) {
                _ = font.drawText(" │ ", cx, header_y, theme.popup_border);
                cx += 3 * cw;
            }
            const w = g.widths[c];
            drawCell(font, g.columns[c], cx, header_y, w, if (c == g.col) theme.fg else theme.whichkey_group);
            cx += @as(f32, @floatFromInt(w)) * cw;
        }
    }
    const rows_y = header_y + ch;
    for (0..body) |i| {
        const r = g.top + i;
        if (r >= g.rows.len) break;
        const y = rows_y + @as(f32, @floatFromInt(i)) * ch;
        if (r == g.row) rect(d.bx, y, d.bw, ch, theme.cursorline_bg);
        var cx = x0;
        for (g.left..last) |c| {
            if (c > g.left) {
                _ = font.drawText(" │ ", cx, y, theme.popup_border);
                cx += 3 * cw;
            }
            const w = g.widths[c];
            const cell_w = @as(f32, @floatFromInt(w)) * cw;
            const here = r == g.row and c == g.col;
            if (g.selected(r, c)) rect(cx, y, cell_w, ch, theme.selection_bg);
            if (g.matches(r, c) and !here) rect(cx, y, cell_w, ch, theme.search_match);
            var color = theme.fg;
            if (here) {
                rect(cx, y, cell_w, ch, theme.cursor);
                color = theme.cursor_text;
                gfx.cursor(cx, y, .block);
            }
            drawCell(font, g.cell(r, c), cx, y, w, color);
            cx += cell_w;
        }
    }
    if (last < g.columns.len or g.left > 0) {
        const more = std.fmt.bufPrint(&buf, "{s}{d} more columns{s}", .{ if (g.left > 0) "‹ " else "", g.columns.len - (last - g.left), if (last < g.columns.len) " ›" else "" }) catch "";
        _ = font.drawText(more, d.bx + @as(f32, @floatFromInt(d.cols -| (cells(more) + 1))) * cw, header_y, theme.status_dim);
    }

    // The cell under the cursor, all of it (on one line).
    const value_y = d.by + @as(f32, @floatFromInt(d.rows - 2)) * ch;
    rect(d.bx, value_y, d.bw, 1, theme.popup_border);
    const name = if (g.col < g.columns.len) g.columns[g.col] else "";
    x = font.drawText(name, x0, value_y, theme.whichkey_group);
    x = font.drawText(" = ", x, value_y, theme.status_dim);
    const room = cols -| (cells(name) + 3);
    drawCell(font, g.cell(g.row, g.col), x, value_y, room, theme.fg);

    const hint = "hjkl move · w/b next/prev cell · v cells · V rows · y yank · Y row · / search · o open as buffer · q close";
    _ = font.drawText(clipCells(hint, cols), x0, value_y + ch, theme.status_dim);
}

fn clipCells(s: []const u8, max: usize) []const u8 {
    var it = Font.Utf8Lossy{ .bytes = s };
    var n: usize = 0;
    while (n < max) : (n += 1) _ = it.next() orelse return s;
    return s[0..it.i];
}
