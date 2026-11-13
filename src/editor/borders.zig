//! Window borders and the mouse: the pointer over a border shows resize, dragging moves it.

const Lsp = @import("../lsp/Lsp.zig");
const Windows = @import("../Windows.zig");
const run_popup = @import("run_popup.zig");
const Editor = @import("../Editor.zig");
const resting = @import("resting.zig");
const row_model = @import("row_model.zig");
const Row = Editor.Row;
const MouseHover = resting.MouseHover;

/// The pointer's shape for what it is over.
pub const Pointer = enum { normal, resize_columns, resize_rows };

/// The border within `slop` of screen point (`x`, `y`), unless something is
/// open over the windows or text is being selected.
pub fn borderUnder(ed: *Editor, x: f32, y: f32, slop: f32) ?*Windows.Split {
    if (ed.cmd_float != null or run_popup.popupTerminal(ed) != null or ed.picker != null or ed.mouse_drag != null) return null;
    return ed.windows.borderAt(x, y, slop);
}

pub fn pointerAt(ed: *Editor, x: f32, y: f32, slop: f32) Pointer {
    const b = ed.border_drag orelse borderUnder(ed, x, y, slop) orelse return .normal;
    return if (b.axis == .horizontal) .resize_columns else .resize_rows;
}

/// A press at (`x`, `y`): true if it took a border (the press is used up).
pub fn borderPress(ed: *Editor, x: f32, y: f32, slop: f32) bool {
    ed.border_drag = borderUnder(ed, x, y, slop);
    if (ed.border_drag != null) ed.mouse_hover = null;
    return ed.border_drag != null;
}

/// The pointer moved with the button down: true while it drags a border.
pub fn borderDrag(ed: *Editor, x: f32, y: f32) bool {
    const s = ed.border_drag orelse return false;
    // Its split may have gone (a window closed meanwhile).
    if (!ed.windows.hasSplit(s)) {
        ed.border_drag = null;
        return false;
    }
    Windows.dragBorder(s, if (s.axis == .horizontal) x else y);
    return true;
}

/// The button was let go: true if it was dragging a border.
pub fn borderRelease(ed: *Editor) bool {
    defer ed.border_drag = null;
    return ed.border_drag != null;
}

pub fn isLensRow(ed: *const Editor, r: Row) bool {
    return r.ghost == null and row_model.layered(ed) and r.sub < row_model.lensRows(ed, r.line);
}

/// The diagnostics the mouse has rested on long enough, into `out`: under
/// it in the text, or the line's own on its message's rows.
pub fn hoveredDiagnostics(ed: *const Editor, out: []*const Lsp.Diagnostic) []*const Lsp.Diagnostic {
    const h = ed.mouse_hover orelse return out[0..0];
    if (!h.rest.long(ed) or !h.top.eql(row_model.topRow(ed))) return out[0..0];
    return diagnosticsUnder(ed, h, out);
}

pub fn diagnosticsUnder(ed: *const Editor, h: MouseHover, out: []*const Lsp.Diagnostic) []*const Lsp.Diagnostic {
    const pos = h.pos orelse {
        if (out.len == 0 or !ed.options.diagnostic_text) return out[0..0];
        out[0] = row_model.lineDiagnostic(ed, h.line) orelse return out[0..0];
        return out[0..1];
    };
    return row_model.diagnosticsOn(ed, h.line, pos - ed.buffer.text.lineStart(h.line), out);
}
