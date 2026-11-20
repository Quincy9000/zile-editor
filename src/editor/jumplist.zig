//! Jumplist: where you were before each jump. `<C-o>` goes back, `<C-i>` forward.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const motions = @import("../core/motions.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const state_files = @import("state_files.zig");
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
    ed.jumps.append(ed.gpa, .{ .buffer = b, .path = path, .pos = p, .project = b.project }) catch {
        if (path) |jp| ed.gpa.free(jp);
    };
    ed.jump_index = ed.jumps.items.len;
    // Where it lands goes in the middle of the view (`scrollToCursor`).
    ed.center_from = .{ .buffer = b, .line = line };
}

/// `<C-o>`: back to an older place.
pub fn jumpOlder(ed: *Editor, count: usize) !void {
    if (ed.jump_index >= ed.jumps.items.len) {
        // Leaving the newest place: remember it, so `<C-i>` comes back.
        pushJump(ed);
        ed.jump_index = ed.jumps.items.len - 1;
    }
    if (count > ed.jump_index) return ed.setMessage(.info, "at the oldest jump", .{});
    // Not to where the cursor already is (it got there some other way).
    var target = ed.jump_index - count;
    while (isHere(ed, ed.jumps.items[target])) {
        if (target == 0) return ed.setMessage(.info, "at the oldest jump", .{});
        target -= 1;
    }
    try goJump(ed, target);
}

/// The jump is the line the cursor is on.
pub fn isHere(ed: *Editor, j: Editor.Jump) bool {
    if (j.buffer != ed.buffer) return false;
    const t = ed.text();
    return t.lineOf(@min(j.pos, t.len())) == ed.cursorLine();
}

/// `` SPC ` ``: back to where the last jump left from, and again: here again
/// (vim's `''`, across files).
pub fn jumpToggle(ed: *Editor) !void {
    if (ed.jump_index + 1 >= ed.jumps.items.len) return jumpOlder(ed, 1);
    try jumpNewer(ed, 1);
}

/// `<C-i>` / `<Tab>`: forward to a newer place.
pub fn jumpNewer(ed: *Editor, count: usize) !void {
    var target = ed.jump_index + count;
    while (target < ed.jumps.items.len and isHere(ed, ed.jumps.items[target])) target += 1;
    if (target >= ed.jumps.items.len) return ed.setMessage(.info, "at the newest jump", .{});
    try goJump(ed, target);
}

/// Picked from the list (`SPC j`): a jump of its own. The place left goes
/// on top of the list (`<C-o>` returns to it), and the place gone to sinks
/// to the bottom, so the top is never where you already are.
pub fn pickJump(ed: *Editor, i: usize) !void {
    if (i >= ed.jumps.items.len) return;
    const picked = ed.jumps.orderedRemove(i);
    pushJump(ed);
    ed.jumps.insert(ed.gpa, 0, picked) catch {
        if (picked.path) |p| ed.gpa.free(p);
        return;
    };
    if (ed.jumps.items.len > max_jumps) {
        if (ed.jumps.items[1].path) |p| ed.gpa.free(p);
        _ = ed.jumps.orderedRemove(1);
    }
    try goJump(ed, 0);
    ed.jump_index = ed.jumps.items.len;
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

// Bookmarks (vim's marks, and one feature with them): `m` and a key puts
// one on the cursor's line under that key, `'{key}` goes to its line,
// `` `{key} `` to the exact place, `SPC m` lists them. A name is one place,
// whichever file it is in.

pub fn findMark(ed: *Editor, name: u21) ?*Mark {
    if (name == 0) return null;
    for (ed.marks.items) |*m| if (m.name == name) return m;
    return null;
}

/// The bookmark on `line` of the current buffer.
pub fn bookmarkOn(ed: *const Editor, line: usize) ?usize {
    const t = &ed.buffer.text;
    for (ed.marks.items, 0..) |m, i| {
        if (m.buffer == ed.buffer and t.lineOf(@min(m.pos, t.len())) == line) return i;
    }
    return null;
}

/// `m{key}`: bookmarks the cursor's place under `key` (Space: without a
/// name). The same key on its own line takes the bookmark off; a name in
/// use elsewhere moves here.
pub fn setMark(ed: *Editor, key: u21) void {
    const name: u21 = if (key == ' ') 0 else key;
    const line = ed.cursorLine();
    const t = ed.text();
    var buf: [4]u8 = undefined;
    for (ed.marks.items, 0..) |m, i| {
        if (m.name == name and m.buffer == ed.buffer and t.lineOf(@min(m.pos, t.len())) == line) {
            removeMark(ed, i);
            return ed.setMessage(.info, "bookmark removed", .{});
        }
    }
    if (findMark(ed, name)) |m| removeMark(ed, @divExact(@intFromPtr(m) - @intFromPtr(ed.marks.items.ptr), @sizeOf(Mark)));
    const path = if (ed.buffer.path) |p| ed.gpa.dupe(u8, p) catch null else null;
    const mark: Mark = .{ .name = name, .buffer = ed.buffer, .path = path, .pos = ed.view.cursor, .project = ed.buffer.project };
    ed.marks.append(ed.gpa, mark) catch {
        if (path) |p| ed.gpa.free(p);
        return;
    };
    if (ed.buffer.path) |bp| state_files.savePlaces(ed, bp, ed.buffer.project);
    ed.setMessage(.info, "bookmarked: {s} (SPC m lists them)", .{mark.shown(&buf)});
}

/// Jumped to: it goes to the end of the list (`SPC m` has the bookmarks
/// longest left alone first).
pub fn markVisited(ed: *Editor, i: usize) void {
    if (i >= ed.marks.items.len) return;
    const m = ed.marks.orderedRemove(i);
    ed.marks.appendAssumeCapacity(m);
}

pub fn removeMark(ed: *Editor, i: usize) void {
    if (i >= ed.marks.items.len) return;
    const m = ed.marks.orderedRemove(i);
    const p = m.path orelse return;
    state_files.savePlaces(ed, p, m.project); // its file's bookmarks, now without it
    ed.gpa.free(p);
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

/// A closed buffer's bookmarks keep their file (and go without one).
pub fn forgetMarks(ed: *Editor, b: *Buffer) void {
    var i: usize = 0;
    while (i < ed.marks.items.len) {
        const m = &ed.marks.items[i];
        if (m.buffer == b) {
            if (m.path == null) {
                _ = ed.marks.orderedRemove(i);
                continue;
            }
            m.buffer = null;
        }
        i += 1;
    }
}
