//! The text side of a bottom panel (Claude's conversation, the scratch
//! pads) gone into with Tab: a buffer in a window outside the splits,
//! placed over that side of the panel, with all of vim's keys. Tab or Esc
//! (normal mode) goes back to the panel's rows.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Windows = @import("../Windows.zig");
const Editor = @import("../Editor.zig");
const window_ops = @import("window_ops.zig");
const inlay = @import("inlay.zig");

/// Shows `b` there and goes into it. `owned`: the buffer is the float's own
/// (a copy of a row's text), freed when it closes; else one of the
/// editor's (a file), saved when it closes.
pub fn open(ed: *Editor, b: *Buffer, owned: bool) !void {
    close(ed);
    const w = try ed.gpa.create(Windows.Window);
    w.* = .{ .buffer = b, .view = .{ .rows = ed.view.rows, .cols = ed.view.cols }, .node = undefined };
    ed.side_window = w;
    ed.side_owned = owned;
    ed.side_return = ed.window;
    window_ops.focusWindow(ed, w);
}

pub fn focused(ed: *const Editor) bool {
    return if (ed.side_window) |w| ed.window == w else false;
}

/// Back to the panel's rows (the window it was gone into from).
pub fn close(ed: *Editor) void {
    const w = ed.side_window orelse return;
    const b = w.buffer;
    if (ed.window == w) {
        if (ed.mode != .normal) ed.setMode(.normal);
        ed.cursors.clearRetainingCapacity();
        const back = blk: {
            if (ed.side_return) |r| for (ed.window_list.items) |o| if (o == r) break :blk r;
            break :blk ed.window_list.items[0];
        };
        window_ops.focusWindow(ed, back);
    }
    ed.side_window = null;
    ed.side_return = null;
    if (ed.side_owned) {
        inlay.forgetJumps(ed, b);
        b.deinit(ed.gpa);
        ed.gpa.destroy(b);
    } else if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch {};
    }
    ed.side_owned = false;
    ed.gpa.destroy(w);
}

/// Keys that aren't vim's while in it (normal mode, nothing pending): Tab
/// or Esc goes back to the rows (`q` too, where the text can't be changed);
/// SPC is refused (the leader's commands are for the code). True when the
/// key was used.
pub fn key(ed: *Editor, ev: Editor.KeyEvent) bool {
    if (!focused(ed)) return false;
    if (ed.mode != .normal or !ed.isIdle() or ed.cursors.items.len > 0 or ed.picker != null or ed.search_prompt != null) return false;
    if (ev.mods.any()) return false;
    switch (ev.key) {
        .special => |sp| switch (sp) {
            .escape, .tab => close(ed),
            else => return false,
        },
        .codepoint => |cp| switch (cp) {
            'q' => if (ed.buffer.read_only) close(ed) else return false,
            ' ' => ed.setMessage(.info, "Tab (or Esc) goes back to the rows first", .{}),
            else => return false,
        },
    }
    return true;
}
