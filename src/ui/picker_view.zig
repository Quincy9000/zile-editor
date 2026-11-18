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
const LineInput = @import("../input/LineInput.zig");
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
    return sources.itemActions(p.kind).len > 0 or sources.rowKeys(p.kind).len > 0 or sources.scopeGroup(p.kind) != null or Editor.opensPlaces(p.kind);
}

/// `Tab project · open · recent · disk`, the current scope bright.
fn drawScopes(p: *const Picker, f: *Flow) void {
    const group = sources.scopeGroup(p.kind) orelse return;
    var need: usize = 4;
    for (group) |sc| need += cells(sc.name) + 3;
    f.fit(need);
    if (f.line < f.paint) {
        var x = f.font.drawText("Tab", f.x, f.y(), f.theme.whichkey_group) + f.font.cell_w;
        for (group, 0..) |sc, i| {
            if (i > 0) x = f.font.drawText(" · ", x, f.y(), f.theme.status_dim);
            x = f.font.drawText(sc.name, x, f.y(), if (sc.kind == p.kind) f.theme.fg else f.theme.status_dim);
        }
    }
    f.x += @as(f32, @floatFromInt(need + 3)) * f.font.cell_w;
}

/// The bottom lines: the picker's keys. <Tab> and the scopes, where Enter
/// and the split keys open the row, then its actions: after <Esc> their
/// letters, while typing their Ctrl keys (`Esc c` for one with a letter
/// only); <S-Tab> lists them all. Over as many lines as they take. Returns that many; draws
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
    const places = Editor.opensPlaces(p.kind);
    const actions = sources.itemActions(p.kind);
    if (!places and actions.len == 0) return f.line + 1;
    var buf: [16]u8 = undefined;
    if (places) {
        f.put("⏎", "open");
        f.put("C-v", "split right");
        f.put("C-s", "split below");
    }
    if (sources.altAccept(p.kind)) |alt| f.put("C-⏎", alt.label);
    for (actions) |a| {
        const key = if (!typing and a.key != 0)
            std.fmt.bufPrint(&buf, "{c}", .{a.key}) catch continue
        else if (a.ctrl != 0)
            std.fmt.bufPrint(&buf, "C-{c}", .{a.ctrl}) catch continue
        else if (a.key != 0)
            std.fmt.bufPrint(&buf, "Esc {c}", .{a.key}) catch continue
        else
            continue;
        f.put(key, a.label);
    }
    f.put("S-Tab", "all");
    if (typing) f.put("Esc", "normal mode");
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
        // A diff: added and removed lines in their colours, the rest dimmer.
        if (pv.diff) {
            const color = if (line.len == 0) theme.fg else switch (line[0]) {
                '+' => if (std.mem.startsWith(u8, line, "+++")) theme.status_dim else theme.diff_add,
                '-' => if (std.mem.startsWith(u8, line, "---")) theme.status_dim else theme.diff_delete,
                '@' => theme.diff_change,
                ' ' => theme.status_fg,
                else => theme.fg,
            };
            if (n == pv.focus_line and pv.focus_line > 0) rect(x0 - font.cell_w, y, @as(f32, @floatFromInt(cols + 2)) * font.cell_w, font.cell_h, theme.cursorline_bg);
            _ = font.drawText(clipCells(line, cols), x, y, color);
            continue;
        }
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
// Find and replace across the project (`SPC c`; `<C-r>` in the grep picker)

/// One field of the form: its name, and its text with the cursor when it
/// is the one typed into.
fn drawField(font: *const Font, theme: *const Theme, name: []const u8, input: *const LineInput, focused: bool, x0: f32, y: f32, color: rl.Color) void {
    var x = font.drawText(name, x0, y, if (focused) theme.mode_picker else theme.status_dim);
    x = font.drawText(" › ", x, y, theme.status_dim);
    const text = input.items();
    const at = @min(input.cursor, text.len);
    x = font.drawText(text[0..at], x, y, color);
    _ = font.drawText(text[at..], x, y, color);
    if (!focused) return;
    if (gfx.grid == null) rect(x, y + 2, 2, font.cell_h - 4, theme.cursor);
    gfx.cursor(x, y, .bar);
}

/// The replace form: what to find and what to put there, over the lines
/// with matches, grouped by file, each as it is (matches in red) and as it
/// will be (replacements in green). Skipped lines are dimmed. Below: the
/// options (and, with regex on, what a regex can say), then the keys.
pub fn drawReplace(r: *Replace, font: *const Font, theme: *const Theme, l: render.Layout, replacement: *const LineInput) void {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const d = dock(font, l, listRows(font, l) + 2);
    const box_cols = d.cols;
    const box_rows = d.rows;
    const bx = d.bx;
    const by = d.by;
    const bw = d.bw;
    const bh = d.bh;
    drawPanel(theme, d);

    // Find    › needle                                  12 in 4 files
    // Replace › replacement
    drawField(font, theme, "Find   ", &r.find, r.field == .find, bx + cw, by, theme.diff_delete);
    drawField(font, theme, "Replace", replacement, r.field == .with, bx + cw, by + ch, theme.diff_add);
    var buf: [64]u8 = undefined;
    const rows = r.matches();
    const c = r.counts();
    const count = if (r.busy()) "searching…" else if (r.failed()) "rg failed" else if (r.find.items().len == 0) "" else std.fmt.bufPrint(&buf, "{d} in {d} file{s}{s}", .{
        c.matches, c.files, if (c.files == 1) "" else "s", if (r.truncated()) " (first 10000)" else "",
    }) catch "";
    _ = font.drawText(count, bx + @as(f32, @floatFromInt(box_cols -| (cells(count) + 1))) * cw, by, theme.status_dim);
    rect(bx, by + 2 * ch, bw, 1, theme.popup_border);

    // The options, and the keys.
    const max_cells = box_cols -| 2;
    {
        const y = by + bh - 2 * ch;
        var x = font.drawText("C-r regex ", bx + cw, y, theme.status_dim);
        x = font.drawText(if (r.options.regex) "on" else "off", x, y, if (r.options.regex) theme.diff_add else theme.status_dim);
        x = font.drawText(" · C-b whole word ", x, y, theme.status_dim);
        x = font.drawText(if (r.options.word) "on" else "off", x, y, if (r.options.word) theme.diff_add else theme.status_dim);
        const used: usize = @intFromFloat((x - bx) / cw);
        const help = if (r.options.regex)
            "· . any character · \\w+ a word · \\d+ a number · \\s a space · (…) a group, $1 in the replacement · a|b either · ^ $ the line's ends · \\. a real dot"
        else
            "· the text exactly as typed (a capital makes it case-sensitive)";
        drawMarked(font, help, &.{}, x + cw, y, max_cells -| (used + 1), theme.status_dim, theme.status_dim);
    }
    const hint = if (r.field == .find)
        "Tab the replacement · Enter the replacement · ↑↓ move · C-x skip line · C-f skip file · Esc close"
    else
        "Tab what to find · Enter replace all · ↑↓ move · C-x skip line · C-f skip file · Esc close";
    drawMarked(font, hint, &.{}, bx + cw, by + bh - ch, max_cells, theme.status_dim, theme.status_dim);

    const visible = box_rows -| 5; // the fields, the list, options, keys
    const list_y = by + 2 * ch;
    if (rows.len == 0) {
        var eb: [256]u8 = undefined;
        const said = if (r.find.items().len == 0)
            "type what to find"
        else if (r.busy())
            ""
        else if (r.complaintOf()) |e|
            std.fmt.bufPrint(&eb, "rg can't read that{s}: {s}", .{ if (r.options.regex) " regex yet" else "", e }) catch e
        else if (r.failed())
            "rg could not search here"
        else
            "no matches";
        drawMarked(font, said, &.{}, bx + cw, list_y, max_cells, theme.status_dim, theme.status_dim);
        return;
    }

    // Keep the selection on screen (rows: a header per file, two per line).
    if (r.selected < r.top) r.top = r.selected;
    while (r.top < r.selected and replaceRows(r, r.top, r.selected) > visible) r.top += 1;

    var y = list_y;
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
        const n = @min(m.subs.len, spans.len);
        for (m.subs[0..n], spans[0..n]) |sub, *sp| sp.* = .{ sub.start, sub.end };
        drawMarked(font, m.text, spans[0..n], tx, y, text_cols, theme.fg, theme.diff_delete);
        y += ch;
        if (y >= y_end) break;
        // As it will be: each replacement marked.
        var line_buf: [2048]u8 = undefined;
        var len: usize = 0;
        var from: usize = 0;
        var k: usize = 0;
        var new_spans: [32][2]usize = undefined;
        for (m.subs[0..n]) |sub| {
            const before = m.text[from..sub.start];
            if (len + before.len + sub.with.len > line_buf.len) break;
            @memcpy(line_buf[len..][0..before.len], before);
            len += before.len;
            @memcpy(line_buf[len..][0..sub.with.len], sub.with);
            new_spans[k] = .{ len, len + sub.with.len };
            k += 1;
            len += sub.with.len;
            from = sub.end;
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
    const rows = r.matches();
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
            // The cell under the cursor, all of it, is the cursor: in a
            // terminal its own cursor isn't put there too (drawn over a
            // cursor-coloured cell, it hides the letter it sits on).
            var color = theme.fg;
            if (here) {
                rect(cx, y, cell_w, ch, theme.cursor);
                color = theme.cursor_text;
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

test "terminal mode: the results grid's cell is the cursor (no terminal cursor over its first letter)" {
    const Grid = @import("../tui/Grid.zig");
    const gpa = std.testing.allocator;
    const rows = [_][]const []const u8{ &.{ "52721", "Testeban" }, &.{ "52698", "Testeban" } };
    var g = try ResultGrid.init(gpa, &.{ "id", "Name" }, &rows);
    defer g.deinit();
    g.col = 1;
    var grid: Grid = .{};
    defer grid.deinit(gpa);
    try grid.resize(gpa, 60, 16);
    grid.clear(.{ .r = 0, .g = 0, .b = 0, .a = 255 });
    gfx.grid = &grid;
    defer gfx.grid = null;
    var font = Font.cells();
    const theme = Theme.get(0);
    const l: render.Layout = .{ .gutter_cols = 0, .text_x = 0, .rows = 16, .cols = 60, .status_y = 15 * Grid.cell_h, .width = 60 * Grid.cell_w, .x0 = 0, .y0 = 0 };
    drawGrid(&g, &font, theme, l);
    try std.testing.expectEqual(null, grid.cursor);
    // The selected cell's `T` is there, in the cursor's text colour.
    const at = for (grid.cells, 0..) |cell, i| {
        if (cell.cp == 'T' and std.meta.eql(cell.bg, theme.cursor)) break i;
    } else return error.TestUnexpectedResult;
    try std.testing.expect(std.meta.eql(grid.cells[at].fg, theme.cursor_text));
}

// ---------------------------------------------------------------------------
// Claude's conversation (`SPC a a`)

const Chat = @import("../ai/Chat.zig");

/// Lines of `text` as they fit in `width` cells: broken at a space where
/// there is one in the last third, else mid-word.
const Wrap = struct {
    text: []const u8,
    width: usize,
    i: usize = 0,
    done: bool = false,

    fn next(w: *Wrap) ?[]const u8 {
        if (w.done) return null;
        const rest = w.text[w.i..];
        const nl = std.mem.indexOfScalar(u8, rest, '\n');
        const line = rest[0 .. nl orelse rest.len];
        // The bytes that fit.
        var cells_n: usize = 0;
        var end: usize = 0;
        var last_space: ?usize = null;
        var it = Font.Utf8Lossy{ .bytes = line };
        while (true) {
            const at = it.i;
            const cp = it.next() orelse {
                end = line.len;
                break;
            };
            const wide: usize = if (cp == '\t') 4 else 1;
            if (cells_n + wide > w.width and at > 0) {
                end = at;
                if (last_space) |sp| if (sp * 3 >= at * 2) {
                    end = sp + 1;
                };
                break;
            }
            if (cp == ' ') last_space = at;
            cells_n += wide;
        }
        if (end == line.len) {
            if (nl) |n| w.i += n + 1 else w.done = true;
        } else w.i += end;
        return line[0..end];
    }
};

/// One line of text at (`x`, `y`), indentation kept, tabs as four cells.
fn drawPlain(font: *const Font, line: []const u8, x: f32, y: f32, max_cells: usize, color: rl.Color) void {
    var it = Font.Utf8Lossy{ .bytes = line };
    var col: usize = 0;
    while (it.next()) |cp| {
        if (col >= max_cells) break;
        if (cp == '\t') {
            col += 4;
            continue;
        }
        if (cp != ' ' and cp != '\r') font.drawCodepoint(cp, x + @as(f32, @floatFromInt(col)) * font.cell_w, y, color);
        col += 1;
    }
}

/// Where a two-sided bottom panel goes: docked above `bottom`, a title
/// row, then rows on the left and text on the right.
pub const PaneGeometry = struct {
    by: f32,
    bh: f32,
    /// Rows of the panel, the title's included.
    rows: usize,
    total_cols: usize,
    list_cols: usize,
    /// The text side (where `side_float` puts its window).
    text: Editor.Windows.Rect,
};

pub fn paneGeometry(font: *const Font, l: render.Layout, bottom: f32) ?PaneGeometry {
    const cw = font.cell_w;
    const ch = font.cell_h;
    const total_cols: usize = @intFromFloat(l.width / cw);
    const above: usize = @intFromFloat(@max(bottom, 0) / ch);
    const rows = @min(listRows(font, l) + 2, above -| 2);
    if (rows < 3 or total_cols < 20) return null;
    const bh = @as(f32, @floatFromInt(rows)) * ch;
    const by = bottom - bh;
    const list_cols = std.math.clamp(total_cols * 35 / 100, 16, 48);
    const tx = @as(f32, @floatFromInt(list_cols)) * cw + 1;
    return .{
        .by = by,
        .bh = bh,
        .rows = rows,
        .total_cols = total_cols,
        .list_cols = list_cols,
        .text = .{ .x = tx, .y = by + ch, .w = @max(l.width - tx, 0), .h = bh - ch },
    };
}

/// A row of a panel's list.
pub const PaneRow = struct { mark: []const u8 = "  ", text: []const u8, color: rl.Color };

/// What a two-sided panel shows this frame.
pub const PaneSpec = struct {
    title: []const u8,
    /// After the title, dimmer (in `about_color`).
    about: []const u8 = "",
    about_color: rl.Color,
    /// The keys, at the title's right when there is room.
    hint: []const u8,
    /// How many rows, and what to say when there are none.
    count: usize,
    empty: []const u8,
    /// The whole of the selected row, for the text side.
    text: []const u8,
    /// Its lines are program text (a `+` or `-` first is a diff's), not prose.
    plain: bool = false,
    color: rl.Color,
};

/// A two-sided panel: `rows(ctx, i)` on the left, one line each, the
/// selected one's `text` wrapped on the right (its end while `p.tail`).
/// While `side_float` shows a buffer over the text side, that side is its.
fn drawPanes(ed: *Editor, font: *const Font, theme: *const Theme, l: render.Layout, bottom: f32, p: *Editor.claude_chat.Panel, spec: PaneSpec, ctx: anytype) void {
    const g = paneGeometry(font, l, bottom) orelse return;
    const cw = font.cell_w;
    const ch = font.cell_h;
    const by = g.by;
    p.area = .{ .x = 0, .y = by, .w = l.width, .h = g.bh };
    p.text_x = g.text.x;
    rect(0, by, l.width, g.bh, theme.popup_bg);
    rect(0, by, l.width, 1, theme.popup_border);

    var x = font.drawText(spec.title, cw, by, if (p.focus) theme.mode_picker else theme.status_dim);
    x = font.drawText(spec.about, x, by, spec.about_color);
    const used: usize = @intFromFloat(x / cw);
    if (used + cells(spec.hint) + 3 <= g.total_cols) _ = font.drawText(spec.hint, l.width - @as(f32, @floatFromInt(cells(spec.hint) + 1)) * cw, by, theme.status_dim);

    const body = g.rows - 1;
    const body_y = by + ch;
    if (spec.count == 0) {
        _ = font.drawText(spec.empty, cw, body_y, theme.status_dim);
        return;
    }
    p.sel = @min(p.sel, spec.count - 1);

    // The rows: the selection kept in sight.
    const in_text = ed.side_window != null;
    if (p.sel < p.top) p.top = p.sel;
    if (p.sel >= p.top + body) p.top = p.sel + 1 - body;
    if (p.top + body > spec.count) p.top = spec.count -| body;
    for (0..body) |r| {
        const i = p.top + r;
        if (i >= spec.count) break;
        const row: PaneRow = ctx.row(theme, i);
        const y = body_y + @as(f32, @floatFromInt(r)) * ch;
        if (i == p.sel) {
            rect(0, y, @as(f32, @floatFromInt(g.list_cols)) * cw, ch, theme.selection_bg);
            if (p.focus and !in_text) rect(0, y, 2, ch, theme.cursor);
        }
        const tx = font.drawText(row.mark, cw, y, row.color);
        drawPlain(font, row.text, tx, y, g.list_cols -| 4, row.color);
    }
    rect(g.text.x - 1, body_y, 1, g.bh - ch, theme.popup_border);
    if (in_text) return;

    // The whole of the selected row.
    const text_cols = g.total_cols -| (g.list_cols + 3);
    if (text_cols < 8) return;
    var total: usize = 0;
    var count = Wrap{ .text = spec.text, .width = text_cols };
    while (count.next()) |_| total += 1;
    p.lines = total;
    p.page = body;
    const first = if (p.tail) total -| body else @min(p.scroll, total -| body);
    if (!p.tail) p.scroll = first;
    const tx = g.text.x + 2 * cw;
    var w = Wrap{ .text = spec.text, .width = text_cols };
    var n: usize = 0;
    var in_code = false;
    while (w.next()) |line| : (n += 1) {
        const fence = std.mem.startsWith(u8, std.mem.trimStart(u8, line, " "), "```");
        if (fence) in_code = !in_code;
        if (n < first) continue;
        if (n >= first + body) break;
        const color = if (fence)
            theme.status_dim
        else if ((in_code or spec.plain) and line.len > 0 and line[0] == '+')
            theme.diff_add
        else if (in_code and line.len > 0 and line[0] == '-' or spec.plain and line.len > 1 and line[0] == '-' and line[1] != ' ')
            theme.diff_delete
        else if (!in_code and std.mem.startsWith(u8, line, "#"))
            theme.whichkey_group
        else if (in_code)
            theme.status_fg
        else
            spec.color;
        drawPlain(font, line, tx, body_y + @as(f32, @floatFromInt(n - first)) * ch, text_cols, color);
    }
    // More above or below what shows.
    if (total > body) {
        var pb: [32]u8 = undefined;
        const where = std.fmt.bufPrint(&pb, "{d}-{d}/{d}", .{ first + 1, @min(first + body, total), total }) catch "";
        _ = font.drawText(where, l.width - @as(f32, @floatFromInt(cells(where) + 1)) * cw, by + g.bh - ch, theme.status_dim);
    }
}

/// Claude's conversation, docked above `bottom`: a title row (what Claude
/// is doing, the keys), then the rows on the left, one line each (what you
/// said, what Claude said, a tool, a question), and on the right the whole
/// of the selected one. While it follows, that is the end of what is being
/// written.
pub fn drawChat(ed: *Editor, font: *const Font, theme: *const Theme, l: render.Layout, bottom: f32) void {
    const c = ed.chat orelse return;
    const p = &ed.chat_panel;
    var buf: [160]u8 = undefined;
    const state = c.stateText();
    // Claude · the model · plan · working…
    var w: std.Io.Writer = .fixed(&buf);
    if (c.model.len > 0) w.print(" · {s}", .{c.model[0..@min(c.model.len, 28)]}) catch {};
    if (c.effort.len > 0) w.print(" {s}", .{c.effort[0..@min(c.effort.len, 8)]}) catch {};
    if (c.usage.five_hour) |pct| w.print(" · 5h {d:.0}%", .{pct}) catch {};
    if (c.mode.len > 0 and !std.mem.eql(u8, c.mode, "default")) w.print(" · {s}", .{c.mode[0..@min(c.mode.len, 20)]}) catch {};
    if (state.len > 0) w.print(" · {s}", .{state}) catch {} else if (c.cost > 0) w.print(" · ${d:.2}", .{c.cost}) catch {};
    const about = w.buffered();
    const ask = c.asking();
    const asking = ask != null;
    const question = if (ask) |a| a.question else false;
    const hint: []const u8 = if (ed.side_window != null)
        "vim's keys: y copies   Tab / Esc back to the rows"
    else if (p.focus)
        (if (question) "1-9 picks an answer   Tab into the text   i tell Claude   Esc / q hide" else if (asking) "y allow   a allow from now on   n refuse   Tab into the text   i tell Claude   Esc / q hide" else "j/k rows   Tab text   y copy   i tell   / commands   m model   e effort   u usage   r resume   C-c stop   Esc hide")
    else if (question) "SPC a y to answer   Esc hides" else if (asking) "SPC a y allows   SPC a n refuses   Esc hides" else "SPC a a here   SPC a i tell Claude   Esc hides";
    const entries = c.entries.items;
    const sel: ?*const Chat.Entry = if (entries.len > 0) &entries[@min(p.sel, entries.len - 1)] else null;
    const Rows = struct {
        entries: []const Chat.Entry,
        pub fn row(r: @This(), th: *const Theme, i: usize) PaneRow {
            const e = &r.entries[i];
            const mark: []const u8, const color = switch (e.kind) {
                .you => .{ "› ", th.mode_picker },
                .claude => .{ "  ", th.fg },
                .tool => .{ "· ", th.status_dim },
                .ask => .{ "? ", th.diff_add },
                .note => .{ "  ", th.status_dim },
            };
            return .{ .mark = mark, .text = Chat.rowLine(e), .color = color };
        }
    };
    drawPanes(ed, font, theme, l, bottom, p, .{
        .title = "Claude",
        .about = about,
        .about_color = if (c.state == .asking) theme.diff_add else theme.status_dim,
        .hint = hint,
        .count = entries.len,
        .empty = "nothing said yet: SPC a i tells Claude something",
        .text = if (sel) |e| e.text.items else "",
        // A tool's row is its input and what came back; an ask's, the edit.
        .plain = if (sel) |e| e.kind == .tool or e.kind == .ask else false,
        .color = if (sel) |e| (if (e.kind == .you) theme.mode_picker else theme.fg) else theme.fg,
    }, Rows{ .entries = entries });
}

/// The scratch pads (`SPC n`): their names on the left, the selected
/// one's text on the right.
pub fn drawPads(ed: *Editor, font: *const Font, theme: *const Theme, l: render.Layout, bottom: f32) void {
    const p = &ed.pad_panel;
    const list = ed.pad_list.pads.items;
    var buf: [48]u8 = undefined;
    const about = std.fmt.bufPrint(&buf, " · {d}", .{list.len}) catch "";
    const hint: []const u8 = if (ed.side_window != null)
        "vim's keys   Tab / Esc back to the pads (saved)"
    else if (p.focus)
        "j/k pads   Tab / i write in it   n new   r rename   x delete   y copy   o in a window   Esc / q hide"
    else
        "SPC n here   Esc hides";
    const Rows = struct {
        pads: []const Editor.pads.Pad,
        pub fn row(r: @This(), th: *const Theme, i: usize) PaneRow {
            return .{ .text = r.pads[i].name, .color = th.fg };
        }
    };
    drawPanes(ed, font, theme, l, bottom, p, .{
        .title = "Scratch pads",
        .about = about,
        .about_color = theme.status_dim,
        .hint = hint,
        .count = list.len,
        .empty = "no pads",
        .text = ed.pad_list.text.items,
        .color = theme.fg,
    }, Rows{ .pads = list });
}

test "text wrapped to a width: at spaces, mid-word when it must" {
    var w = Wrap{ .text = "one two three four\n\n  abcdefghijklmnop", .width = 10 };
    try std.testing.expectEqualStrings("one two ", w.next().?);
    try std.testing.expectEqualStrings("three four", w.next().?);
    try std.testing.expectEqualStrings("", w.next().?);
    try std.testing.expectEqualStrings("  abcdefgh", w.next().?);
    try std.testing.expectEqualStrings("ijklmnop", w.next().?);
    try std.testing.expectEqual(null, w.next());
    var empty = Wrap{ .text = "", .width = 10 };
    try std.testing.expectEqualStrings("", empty.next().?);
    try std.testing.expectEqual(null, empty.next());
}
