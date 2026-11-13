//! Notifications (mini.notify): toasts at the top right for things that happen in the background.

const std = @import("std");
const Io = std.Io;
const indents = @import("../core/indent.zig");
const Editor = @import("../Editor.zig");
const inlay = @import("inlay.zig");
const IndentGuide = Editor.IndentGuide;
const indent_guide_delay_ms = Editor.indent_guide_delay_ms;
const Toast = Editor.Toast;
const max_toasts = Editor.max_toasts;
const Message = Editor.Message;

pub fn timeAfter(ed: *const Editor, ms: i64) Io.Timestamp {
    const now = Io.Timestamp.now(ed.io, .awake);
    return .{ .nanoseconds = now.nanoseconds + @as(i96, ms) * std.time.ns_per_ms };
}

pub fn pushToast(ed: *Editor, t: Toast) void {
    if (ed.toasts.items.len >= max_toasts) _ = ed.toasts.orderedRemove(0);
    ed.toasts.append(ed.gpa, t) catch return;
    ed.wake_fn();
}

pub fn notify(ed: *Editor, kind: Message.Kind, comptime fmt: []const u8, args: anytype) void {
    var t: Toast = .{ .kind = kind, .expires = timeAfter(ed, Toast.lifetime_ms) };
    t.set(fmt, args);
    ed.remember(kind, t.text());
    pushToast(ed, t);
}

/// A notification for work in progress, updated in place: the same `key`
/// changes its text; `busy` false ends it (it lingers a moment, then goes).
pub fn progress(ed: *Editor, key: u64, busy: bool, comptime fmt: []const u8, args: anytype) void {
    for (ed.toasts.items) |*t| if (t.key == key and key != 0) {
        t.set(fmt, args);
        t.busy = busy;
        t.expires = timeAfter(ed, 1500);
        return ed.wake_fn();
    };
    if (!busy) return;
    var t: Toast = .{ .key = key, .busy = true };
    t.set(fmt, args);
    pushToast(ed, t);
}

pub fn pruneToasts(ed: *Editor) void {
    var i: usize = 0;
    while (i < ed.toasts.items.len) {
        const t = ed.toasts.items[i];
        if (!t.busy and t.expires.nanoseconds <= ed.now.nanoseconds) {
            _ = ed.toasts.orderedRemove(i);
        } else i += 1;
    }
}

/// Something on screen is moving (a gliding scroll, a fading toast): the UI
/// should keep drawing frames instead of sleeping until the next key.
pub fn wantsFrames(ed: *const Editor) bool {
    if (ed.view.scroll_offset != 0 or ed.view.scroll_frac != 0) return true;
    for (ed.window_list.items) |w| if (w != ed.window and (w.view.scroll_offset != 0 or w.view.scroll_frac != 0)) return true;
    for (ed.toasts.items) |t| if (!t.busy) return true;
    if (ed.yank_flash != null) return true;
    // Hints waiting out their debounce: a frame has to come to ask for them.
    if (inlay.inlayHintsDue(ed)) return true;
    // A guide is waiting out its delay, or growing: frames have to come.
    if (ed.indent_candidate != null) return true;
    if (ed.indent_guide) |g| if (g.growing(ed.now, ed.view.top, ed.view.top + ed.view.rows)) return true;
    // The pointer resting on a diagnostic: a frame has to come to show it.
    if (ed.mouse_hover) |h| if (h.rest.waiting(ed)) return true;
    if (ed.cursor_rest) |c| if (ed.mode == .normal and c.rest.waiting(ed)) return true;
    return false;
}

/// Decides which indent scope guide is drawn this frame: the cursor's scope
/// once it has been the same for a moment. Moving on to another block hides
/// the guide at once; the new one appears when the cursor settles.
pub fn tickIndentGuide(ed: *Editor) void {
    const want: ?IndentGuide = blk: {
        if (!ed.options.indent_scope or ed.ghost != null or ed.window.term != null) break :blk null;
        const s = indents.scope(ed.text(), ed.cursorLine(), ed.options.tab_width, true) orelse break :blk null;
        break :blk .{ .buffer = ed.buffer, .scope = s };
    };
    if (IndentGuide.same(want, ed.indent_guide)) {
        if (ed.indent_guide) |*g| g.scope = want.?.scope; // its end may have moved
        ed.indent_candidate = null;
        return;
    }
    ed.indent_guide = null;
    if (want == null) {
        ed.indent_candidate = null;
    } else if (!IndentGuide.same(want, ed.indent_candidate)) {
        ed.indent_candidate = want;
        ed.indent_since = ed.now;
    } else if (ed.indent_since.durationTo(ed.now).nanoseconds >= indent_guide_delay_ms * std.time.ns_per_ms) {
        ed.indent_guide = want;
        ed.indent_guide.?.origin = std.math.clamp(ed.cursorLine(), want.?.scope.first, want.?.scope.last);
        ed.indent_guide.?.born = ed.now;
        ed.indent_candidate = null;
    }
}
