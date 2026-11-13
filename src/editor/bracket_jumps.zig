//! Bracketed jumps (mini.bracketed): `]d` `[d` diagnostics, `]x` `[x` conflicts and the like.

const std = @import("std");
const motions = @import("../core/motions.zig");
const Lsp = @import("../lsp/Lsp.zig");
const textops = @import("../textops.zig");
const comment = @import("../core/comment.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const lsp_ops = @import("lsp_ops.zig");

pub fn goLine(ed: *Editor, line: usize, col: usize) void {
    const t = ed.text();
    const l = @min(line, t.lineCount() - 1);
    ed.ghost = null;
    row_model.revealLine(ed, l);
    ed.setCursor(t.lineStart(l) + @min(col, t.lineLen(l)));
}

pub fn jumpDiagnostic(ed: *Editor, forward: bool) void {
    const diags = lsp_ops.diagnostics(ed, ed.buffer);
    if (diags.len == 0) return ed.setMessage(.info, "no diagnostics in this file", .{});
    const line = ed.cursorLine();
    const col = ed.view.cursor - ed.text().lineStart(line);
    var target: ?*const Lsp.Diagnostic = null;
    for (diags) |*d| {
        const after = d.line > line or (d.line == line and d.col > col);
        const before = d.line < line or (d.line == line and d.col < col);
        if (forward and after) {
            target = d;
            break;
        }
        if (!forward and before) target = d;
    }
    // Past the last one: around to the other end.
    const d = target orelse if (forward) &diags[0] else &diags[diags.len - 1];
    goLine(ed, d.line, d.col);
    ed.setMessage(if (d.severity == .err) .err else .info, "{s}", .{std.mem.sliceTo(d.message, '\n')});
}

pub fn isConflictMarker(line: []const u8) bool {
    return std.mem.startsWith(u8, line, "<<<<<<< ") or std.mem.startsWith(u8, line, ">>>>>>> ") or
        std.mem.startsWith(u8, line, "||||||| ") or std.mem.eql(u8, line, "=======");
}

pub fn jumpConflict(ed: *Editor, forward: bool) void {
    const t = ed.text();
    var line = ed.cursorLine();
    while (true) {
        if (forward) {
            line += 1;
            if (line >= t.lineCount()) break;
        } else {
            if (line == 0) break;
            line -= 1;
        }
        if (isConflictMarker(t.lineSlice(line))) return goLine(ed, line, 0);
    }
    ed.setMessage(.info, "no more conflict markers", .{});
}

pub fn jumpComment(ed: *Editor, forward: bool) void {
    const t = ed.text();
    const line = comment.nextBlock(t, ed.cursorLine(), textops.commentStyle(ed, ed.cursorLine()), forward) orelse
        return ed.setMessage(.info, "no more comments", .{});
    goLine(ed, line, motions.firstNonBlank(t, line) - t.lineStart(line));
}
