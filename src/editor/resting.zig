//! Resting: the text cursor or the mouse staying on a diagnostic pops its message up.

const std = @import("std");
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Lsp = @import("../lsp/Lsp.zig");
const borders = @import("borders.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const Row = Editor.Row;

/// How long something rests before a diagnostic pops up.
pub const hover_delay_ns = 350 * std.time.ns_per_ms;

/// Since when something has stayed put, on which buffer and version.
pub const Rest = struct {
    buffer: *const Buffer,
    version: u64,
    since: Io.Timestamp,
    /// Whether a diagnostic is there (frames come until it shows).
    shows: bool = false,

    pub fn start(ed: *const Editor) Rest {
        return .{ .buffer = ed.buffer, .version = ed.buffer.edit_version, .since = Io.Timestamp.now(ed.io, .awake) };
    }

    /// Nothing under it has changed.
    pub fn still(r: Rest, ed: *const Editor) bool {
        return r.buffer == ed.buffer and r.version == ed.buffer.edit_version;
    }

    /// Still, for long enough.
    pub fn long(r: Rest, ed: *const Editor) bool {
        return r.still(ed) and r.since.durationTo(ed.now).nanoseconds >= hover_delay_ns;
    }

    /// A diagnostic is due to pop up: frames have to come.
    pub fn waiting(r: Rest, ed: *const Editor) bool {
        return r.shows and r.still(ed) and !r.long(ed);
    }
};

/// The text cursor resting at `pos`.
pub const CursorRest = struct { pos: usize, rest: Rest };

/// The mouse resting on cell (`row`, `col`) of the focused window, with the
/// window scrolled to `top`: on byte `pos` of `line`, or (null) on that
/// line's message rows.
pub const MouseHover = struct { row: usize, col: usize, top: Row, line: usize, pos: ?usize, rest: Rest };

pub fn tickCursorRest(ed: *Editor) void {
    if (ed.cursor_rest) |c| if (c.pos == ed.view.cursor and c.rest.still(ed)) return;
    var rest = Rest.start(ed);
    var one: [1]*const Lsp.Diagnostic = undefined;
    rest.shows = diagnosticsAt(ed, ed.view.cursor, &one).len > 0;
    ed.cursor_rest = .{ .pos = ed.view.cursor, .rest = rest };
}

/// The diagnostics whose range covers text position `pos`.
pub fn diagnosticsAt(ed: *const Editor, pos: usize, out: []*const Lsp.Diagnostic) []*const Lsp.Diagnostic {
    const t = &ed.buffer.text;
    const line = t.lineOf(pos);
    return row_model.diagnosticsOn(ed, line, pos - t.lineStart(line), out);
}

/// The diagnostics the text cursor has rested on, in normal mode, with
/// nothing else popped up over it.
pub fn cursorDiagnostics(ed: *const Editor, out: []*const Lsp.Diagnostic) []*const Lsp.Diagnostic {
    if (ed.mode != .normal or ed.hover != null or ed.ghost != null) return out[0..0];
    const c = ed.cursor_rest orelse return out[0..0];
    if (c.pos != ed.view.cursor or !c.rest.long(ed)) return out[0..0];
    return diagnosticsAt(ed, ed.view.cursor, out);
}

/// The mouse is over cell (`row`, `col`) of the focused window's text
/// (null: not over it).
pub fn mouseHover(ed: *Editor, cell: ?[2]usize) void {
    const c = cell orelse {
        ed.mouse_hover = null;
        return;
    };
    const top = row_model.topRow(ed);
    if (ed.mouse_hover) |h| if (h.row == c[0] and h.col == c[1] and h.top.eql(top) and h.rest.still(ed)) return;
    ed.mouse_hover = null;
    const r = row_model.stepRows(ed, top, @intCast(c[0]));
    if (r.ghost != null or r.line >= ed.text().lineCount() or borders.isLensRow(ed, r)) return;
    var h: MouseHover = .{ .row = c[0], .col = c[1], .top = top, .line = r.line, .pos = if (row_model.isTextRow(ed, r)) row_model.cellOffset(ed, r, c[1]) else null, .rest = Rest.start(ed) };
    var one: [1]*const Lsp.Diagnostic = undefined;
    h.rest.shows = borders.diagnosticsUnder(ed, h, &one).len > 0;
    ed.mouse_hover = h;
}
