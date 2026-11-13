//! Folds: a closed fold shows as one line.

const std = @import("std");
const Folds = @import("../core/Folds.zig");
const Editor = @import("../Editor.zig");

/// The closed fold hiding `line` (outermost), if any.
pub fn foldAt(ed: *const Editor, line: usize) ?Folds.Lines {
    if (ed.buffer.folds.isEmpty()) return null;
    return ed.buffer.folds.region(&ed.buffer.text, line);
}

/// The line that represents `line` on screen (its fold's first line).
pub fn visibleLine(ed: *const Editor, line: usize) usize {
    return if (foldAt(ed, line)) |f| f.first else line;
}

/// The line `delta` visible lines away from `line`, clamped to the text.
pub fn stepVisible(ed: *const Editor, line: usize, delta: isize) usize {
    const last = ed.buffer.text.lineCount() - 1;
    if (ed.buffer.folds.isEmpty()) {
        return @intCast(std.math.clamp(@as(isize, @intCast(line)) + delta, 0, @as(isize, @intCast(last))));
    }
    var l = visibleLine(ed, @min(line, last));
    var n = @abs(delta);
    while (n > 0) : (n -= 1) {
        if (delta > 0) {
            const end = if (foldAt(ed, l)) |f| f.last else l;
            if (end >= last) break;
            l = end + 1;
        } else {
            if (l == 0) break;
            l = visibleLine(ed, l - 1);
        }
    }
    return l;
}
