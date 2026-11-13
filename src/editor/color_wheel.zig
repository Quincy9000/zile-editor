//! The colour wheel (`SPC l c`): see ColorPicker.zig.

const std = @import("std");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const ColorPicker = @import("../ColorPicker.zig");
const hipatterns = @import("../core/hipatterns.zig");
const Editor = @import("../Editor.zig");

/// Opens the wheel on the colour literal at the cursor, else the next one on
/// the line, else the last one before it.
pub fn openColorPicker(ed: *Editor) void {
    const t = ed.text();
    const line = ed.cursorLine();
    const ls = t.lineStart(line);
    const col = ed.view.cursor - ls;
    const bytes = t.lineSlice(line);
    var buf: [64]hipatterns.Match = undefined;
    var found: ?hipatterns.Match = null;
    for (hipatterns.scan(bytes, &buf)) |m| {
        if (m.kind == .todo) continue;
        found = m;
        if (m.end > col) break; // at or after the cursor
    }
    const m = found orelse return ed.setMessage(.info, "no colour on this line (#rrggbb, #rgb, #rrggbbaa or 0xRRGGBB)", .{});
    const parsed = ColorPicker.parse(bytes[m.start..m.end]) orelse return;
    ed.color_picker = .init(ed.buffer, ls + m.start, ls + m.end, parsed);
    ed.setCursor(ls + m.start);
    ed.clearMessage();
}

/// Keys while the wheel is open. False when it isn't (or just went away
/// because the text under it changed).
pub fn colorKey(ed: *Editor, ev: KeyEvent) bool {
    const p = &(ed.color_picker orelse return false);
    if (p.buffer != ed.buffer or p.version != ed.buffer.edit_version) {
        ed.color_picker = null;
        return false;
    }
    const action: ColorPicker.Action = switch (ev.key) {
        .special => |s| switch (s) {
            .escape => .cancel,
            .enter => .apply,
            else => .none,
        },
        .codepoint => |cp| if (ev.mods.ctrl or ev.mods.alt) .none else p.key(cp),
    };
    var buf: [16]u8 = undefined;
    switch (action) {
        .none => {},
        .cancel => ed.color_picker = null,
        .yank => {
            const literal = p.write(&buf);
            ed.registers.store(null, .yank, literal, false) catch {};
            ed.setMessage(.info, "copied {s}", .{literal});
        },
        .apply => {
            const literal = p.write(&buf);
            const start = p.start;
            const end = p.end;
            ed.color_picker = null;
            if (!std.mem.eql(u8, literal, ed.text().slice(start, end))) {
                ed.deleteRange(start, end) catch return true;
                ed.insertAt(start, literal) catch return true;
            }
            ed.setCursor(start);
            ed.afterKey(); // one undo step
            ed.setMessage(.info, "colour: {s}", .{literal});
        },
    }
    ed.wake_fn();
    return true;
}
