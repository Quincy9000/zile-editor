//! Jumplist: where you were before each jump. `<C-o>` goes back, `<C-i>` forward.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const motions = @import("../core/motions.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const Mark = Editor.Mark;

pub const max_jumps = 100;

/// Records the cursor's place before a jump.
pub fn pushJump(ed: *Editor) void {
    pushJumpAt(ed, ed.view.cursor);
}

pub fn pushJumpAt(ed: *Editor, pos: usize) void {
    if (ed.replaying) return;
    const b = ed.buffer;
    const t = ed.text();
    const p = @min(pos, t.len());
    const line = t.lineOf(p);
    var i: usize = 0;
    while (i < ed.jumps.items.len) {
        const j = ed.jumps.items[i];
        if (j.buffer == b and t.lineOf(@min(j.pos, t.len())) == line) {
            if (j.path) |jp| ed.gpa.free(jp);
            _ = ed.jumps.orderedRemove(i);
        } else i += 1;
    }
    if (ed.jumps.items.len >= max_jumps) {
        if (ed.jumps.items[0].path) |jp| ed.gpa.free(jp);
        _ = ed.jumps.orderedRemove(0);
    }
    const path = if (b.path) |bp| ed.gpa.dupe(u8, bp) catch null else null;
    ed.jumps.append(ed.gpa, .{ .buffer = b, .path = path, .pos = p }) catch {
        if (path) |jp| ed.gpa.free(jp);
    };
    ed.jump_index = ed.jumps.items.len;
}

/// `<C-o>`: back to an older place.
pub fn jumpOlder(ed: *Editor, count: usize) !void {
    if (ed.jump_index >= ed.jumps.items.len) {
        // Leaving the newest place: remember it, so `<C-i>` comes back.
        pushJump(ed);
        ed.jump_index = ed.jumps.items.len - 1;
    }
    if (count > ed.jump_index) return ed.setMessage(.info, "at the oldest jump", .{});
    try goJump(ed, ed.jump_index - count);
}

/// `` SPC ` ``: back to where the last jump left from, and again: here again
/// (vim's `''`, across files).
pub fn jumpToggle(ed: *Editor) !void {
    if (ed.jump_index + 1 >= ed.jumps.items.len) return jumpOlder(ed, 1);
    try jumpNewer(ed, 1);
}

/// `<C-i>` / `<Tab>`: forward to a newer place.
pub fn jumpNewer(ed: *Editor, count: usize) !void {
    const target = ed.jump_index + count;
    if (target >= ed.jumps.items.len) return ed.setMessage(.info, "at the newest jump", .{});
    try goJump(ed, target);
}

/// Goes to jump `i` (reopening its file if its buffer was closed).
pub fn goJump(ed: *Editor, i: usize) !void {
    const j = ed.jumps.items[i];
    ed.jump_index = i;
    if (j.buffer) |b| {
        ed.switchTo(b);
    } else if (j.path) |p| {
        try ed.openFile(p);
        // Entries for that file point at the new buffer again.
        for (ed.jumps.items) |*o| if (o.buffer == null and o.path != null and std.mem.eql(u8, o.path.?, p)) {
            o.buffer = ed.buffer;
        };
    } else return;
    const t = ed.text();
    const pos = @min(j.pos, t.len());
    row_model.revealLine(ed, t.lineOf(pos));
    ed.setCursor(pos);
}

// Marks: `m{letter}` sets one, `'{letter}` goes to its line, `` `{letter} ``
// to the exact place; `SPC f m` lists them.

/// The mark `name` as seen from the current buffer.
pub fn findMark(ed: *Editor, name: u21) ?*Mark {
    const n = std.math.cast(u8, name) orelse return null;
    const global = std.ascii.isUpper(n);
    for (ed.marks.items) |*m| {
        if (m.name == n and (global or m.buffer == ed.buffer)) return m;
    }
    return null;
}

pub fn setMark(ed: *Editor, name: u21) void {
    const n = std.math.cast(u8, name) orelse 0;
    if (!std.ascii.isAlphabetic(n)) return ed.setMessage(.info, "marks are letters: a-z in this file, A-Z across files", .{});
    const b = ed.buffer;
    const path = if (b.path) |p| ed.gpa.dupe(u8, p) catch null else null;
    if (findMark(ed, n)) |m| {
        if (m.path) |old| ed.gpa.free(old);
        m.* = .{ .name = n, .buffer = b, .path = path, .pos = ed.view.cursor };
    } else ed.marks.append(ed.gpa, .{ .name = n, .buffer = b, .path = path, .pos = ed.view.cursor }) catch {
        if (path) |p| ed.gpa.free(p);
        return;
    };
    ed.setMessage(.info, "mark {c} set", .{n});
}

/// Goes to a mark, reopening its file if its buffer was closed.
pub fn goMark(ed: *Editor, m: Mark, exact: bool) !void {
    if (m.buffer) |b| {
        ed.switchTo(b);
    } else if (m.path) |p| {
        const path = try ed.gpa.dupe(u8, p);
        defer ed.gpa.free(path);
        try ed.openFile(path);
        for (ed.marks.items) |*o| if (o.buffer == null and o.path != null and std.mem.eql(u8, o.path.?, path)) {
            o.buffer = ed.buffer;
        };
    } else return;
    const t = ed.text();
    const pos = @min(m.pos, t.len());
    row_model.revealLine(ed, t.lineOf(pos));
    ed.setCursor(if (exact) pos else motions.firstNonBlank(t, t.lineOf(pos)));
}

/// A closed buffer's own marks go; global ones keep their file.
pub fn forgetMarks(ed: *Editor, b: *Buffer) void {
    var i: usize = 0;
    while (i < ed.marks.items.len) {
        const m = &ed.marks.items[i];
        if (m.buffer == b) {
            if (std.ascii.isLower(m.name) or m.path == null) {
                if (m.path) |p| ed.gpa.free(p);
                _ = ed.marks.orderedRemove(i);
                continue;
            }
            m.buffer = null;
        }
        i += 1;
    }
}
