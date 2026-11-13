//! Windows (SPC w): splits showing buffers, each with its own view.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Windows = @import("../Windows.zig");
const Terminal = @import("../terminal/Terminal.zig");
const Pty = @import("../terminal/Pty.zig");
const state_files = @import("state_files.zig");
const Editor = @import("../Editor.zig");
const project_ops = @import("project_ops.zig");
const run_popup = @import("run_popup.zig");
const View = Editor.View;

pub fn refreshWindowList(ed: *Editor) void {
    ed.windows.list(&ed.window_list) catch {};
}

/// The buffer and view `w` shows (the live ones for the focused window).
pub fn windowBuffer(ed: *Editor, w: *Windows.Window) *Buffer {
    return if (w == ed.window) ed.buffer else w.buffer;
}

pub fn windowView(ed: *Editor, w: *Windows.Window) *View {
    return if (w == ed.window) &ed.view else &w.view;
}

/// Moves focus to `w`, keeping the current window's state in it.
pub fn focusWindow(ed: *Editor, w: *Windows.Window) void {
    if (w == ed.window) return;
    if (ed.window.term == null) ed.last_editor_window = ed.window;
    ed.window.view = ed.view;
    ed.window.buffer = ed.buffer;
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    if (w.buffer != ed.buffer) state_files.leaveBuffer(ed, ed.buffer);
    loadWindow(ed, w);
}

pub fn loadWindow(ed: *Editor, w: *Windows.Window) void {
    ed.window = w;
    ed.cursors.clearRetainingCapacity();
    ed.ghost = null;
    if (ed.mode == .visual or ed.mode == .operator) ed.mode = .normal;
    ed.op = null;
    ed.buffer = w.buffer;
    ed.view = w.view;
    project_ops.enterProject(ed, ed.buffer.project);
    ed.use_counter += 1;
    ed.buffer.last_used = ed.use_counter;
    w.used = ed.use_counter;
    ed.placeCursor(@min(ed.view.cursor, ed.text().len()));
    ed.scrollToCursor();
}

/// Swaps what windows `a` and `b` show (buffer and place, or terminal);
/// focus stays where it is.
pub fn swapWindows(ed: *Editor, a: *Windows.Window, b: *Windows.Window) void {
    if (a == b) return;
    // The focused window's live state back into it first.
    ed.window.view = ed.view;
    ed.window.buffer = ed.buffer;
    std.mem.swap(*Buffer, &a.buffer, &b.buffer);
    std.mem.swap(View, &a.view, &b.view);
    std.mem.swap(?*Terminal, &a.term, &b.term);
    std.mem.swap(bool, &a.term_normal, &b.term_normal);
    loadWindow(ed, ed.window);
}

/// The sizes before a window was maximised (`z` in the windows picker):
/// the splits on its way to the root and their ratios. Dropped when windows
/// are split or closed (the tree changed under it).
pub const Zoom = struct { n: usize = 0, splits: [16]*Windows.Split = undefined, ratios: [16]f32 = undefined };

/// `z` in the windows picker: window `w` takes nearly all the room, the
/// others a sliver; again: the sizes they had.
pub fn toggleZoom(ed: *Editor, w: *Windows.Window) void {
    if (ed.zoom) |z| {
        for (z.splits[0..z.n], z.ratios[0..z.n]) |sp, r| sp.ratio = r;
        ed.zoom = null;
        return ed.setMessage(.info, "window sizes back", .{});
    }
    var z: Zoom = .{};
    var node = w.node;
    while (node.parent) |parent| : (node = parent) {
        if (z.n == z.splits.len) break;
        const sp = &parent.kind.split;
        z.splits[z.n] = sp;
        z.ratios[z.n] = sp.ratio;
        z.n += 1;
        sp.ratio = if (sp.first == node) 0.92 else 0.08;
    }
    if (z.n == 0) return ed.setMessage(.info, "only one window", .{});
    ed.zoom = z;
    ed.setMessage(.info, "maximised (z again: back)", .{});
}

/// `SPC w s` + direction: a new window on that side, showing this buffer.
pub fn splitWindow(ed: *Editor, dir: Windows.Dir) !void {
    ed.zoom = null; // the tree changes: the saved sizes no longer fit
    const nw = try ed.windows.split(ed.window, dir, ed.view, ed.buffer);
    refreshWindowList(ed);
    focusWindow(ed, nw);
}

/// `SPC w d`: closes the focused window (not the last one).
/// Windows of your own (not the Claude panel; a shell shown in a window
/// still counts: the window has its file underneath).
pub fn codeWindowCount(ed: *const Editor) usize {
    var n: usize = 0;
    for (ed.window_list.items) |w| n += @intFromBool(if (w.term) |t| std.mem.indexOfScalar(*Terminal, ed.shells.items, t) != null else true);
    return n;
}

pub fn closeWindow(ed: *Editor) void {
    const closing = ed.window;
    const shell = closing.term;
    // Never leave only a terminal panel on screen.
    if (closing.term == null and codeWindowCount(ed) <= 1 and ed.window_list.items.len > 1)
        return ed.setMessage(.info, "this is the last code window (SPC a a hides Claude)", .{});
    // The only window, showing a shell: the shell ends, the file shows.
    if (shell != null and ed.window_list.items.len == 1 and !isClaudeTerm(ed, shell.?)) {
        closing.term = null;
        if (std.mem.indexOfScalar(*Terminal, ed.shells.items, shell.?)) |i| _ = ed.shells.orderedRemove(i);
        shell.?.destroy();
        return ed.setMessage(.info, "terminal closed", .{});
    }
    ed.buffer.saved = .{ .cursor = ed.view.cursor, .top = ed.view.top, .left = ed.view.left };
    ed.zoom = null;
    const target = ed.windows.close(closing) orelse
        return ed.setMessage(.info, "this is the last window (SPC q closes the buffer, then quits)", .{});
    refreshWindowList(ed);
    loadWindow(ed, target);
    // A shell window's shell ends with it (the Claude panel just hides).
    if (shell) |t| for (ed.shells.items, 0..) |o, i| if (o == t) {
        _ = ed.shells.orderedRemove(i);
        t.destroy();
        break;
    };
}

pub fn isClaudeTerm(ed: *const Editor, t: *const Terminal) bool {
    const c = ed.claude orelse return false;
    return c.term == t;
}

/// `SPC r w`: the current window becomes your shell (the file stays
/// underneath). A shell hidden earlier comes back; else a new one starts in
/// the project root.
pub fn openTermWindow(ed: *Editor) !void {
    focusEditorWindow(ed);
    const t = for (ed.shells.items) |o| {
        if (windowShowing(ed, o) == null) break o;
    } else blk: {
        const fresh = try run_popup.spawnTerminal(ed, &.{Pty.userShell()});
        errdefer fresh.destroy();
        try ed.shells.append(ed.gpa, fresh);
        break :blk fresh;
    };
    ed.window.term = t;
    ed.window.term_normal = false;
}

/// Shells that exited: their windows show their files again.
pub fn pollShellWindows(ed: *Editor) void {
    var i = ed.shells.items.len;
    while (i > 0) {
        i -= 1;
        const t = ed.shells.items[i];
        if (t.isRunning()) continue;
        _ = ed.shells.orderedRemove(i);
        for (ed.window_list.items) |w| if (w.term == t) {
            w.term = null;
        };
        t.destroy();
    }
}

/// `SPC w o`: closes every other window.
pub fn onlyWindow(ed: *Editor) !void {
    ed.zoom = null;
    try ed.windows.only(ed.window);
    refreshWindowList(ed);
}

/// Back to an editor window (from a terminal window).
pub fn focusEditorWindow(ed: *Editor) void {
    if (ed.window.term == null) return;
    if (ed.last_editor_window) |w| for (ed.window_list.items) |o| if (o == w) return focusWindow(ed, w);
    for (ed.window_list.items) |o| if (o.term == null) return focusWindow(ed, o);
}

/// The window showing terminal `t`, if any.
pub fn windowShowing(ed: *Editor, t: *const Terminal) ?*Windows.Window {
    for (ed.window_list.items) |w| if (w.term == t) return w;
    return null;
}

/// `SPC w h/j/k/l`: focus the window on that side.
pub fn focusDirection(ed: *Editor, dir: Windows.Dir) void {
    const w = ed.windows.neighbor(ed.window, dir) orelse return;
    focusWindow(ed, w);
}

/// `SPC w w`: the next window, wrapping around.
pub fn focusNext(ed: *Editor) void {
    focusWindow(ed, ed.windows.next(ed.window));
}
