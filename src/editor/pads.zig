//! The scratch pads (`SPC n`; also a row of the toggles, `SPC t`): files of your own, one for each
//! thing you are keeping notes on, kept for every project together. A pad
//! is markdown unless its name says what it is (`query.sql`, `try.zig`):
//! then it is a file of that kind, with its language's colours, its
//! language server and, for SQL, the database of the project you are in. They
//! show in a panel docked along the bottom, as Claude's conversation does:
//! their names on the left, the selected one's text on the right. Tab goes
//! into the text (the file itself, with all of vim's keys; saved on the way
//! back).
//!
//! The pads are the files of `scratch/` in zile's data folder, and
//! `scratch.md` beside it (the one pad there was before there were more).

const std = @import("std");
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Editor = @import("../Editor.zig");
const config = @import("../config/config.zig");
const claude_chat = @import("claude_chat.zig");
const claude_panel = @import("claude_panel.zig");
const side_float = @import("side_float.zig");
const project_ops = @import("project_ops.zig");
const prompts = @import("prompts.zig");
const git_ops = @import("git_ops.zig");

/// A pad: the name it goes by, and its file (absolute; both owned).
pub const Pad = struct { name: []u8, path: []u8 };

/// The pads there are, and the text of the selected one as last read.
pub const List = struct {
    pads: std.ArrayList(Pad) = .empty,
    text: std.ArrayList(u8) = .empty,
    /// The pad `text` is of (an index; null: to be read).
    loaded: ?usize = null,
    /// `x` was pressed on this pad: again deletes it.
    deleting: ?usize = null,
    /// The text side was gone into last frame (coming back reads it again).
    was_in_text: bool = false,

    pub fn deinit(l: *List, gpa: std.mem.Allocator) void {
        l.clear(gpa);
        l.pads.deinit(gpa);
        l.text.deinit(gpa);
    }

    fn clear(l: *List, gpa: std.mem.Allocator) void {
        for (l.pads.items) |p| {
            gpa.free(p.name);
            gpa.free(p.path);
        }
        l.pads.clearRetainingCapacity();
        l.loaded = null;
        l.deleting = null;
    }
};

/// The folder zile keeps its data in (in tests, the state folder). Caller frees.
fn dataFile(ed: *Editor, name: []const u8) ?[]u8 {
    if (ed.state_dir) |d| return std.fs.path.join(ed.gpa, &.{ d, name }) catch null;
    if (@import("builtin").is_test) return null;
    return config.dir(ed.gpa, .data, name);
}

/// Finds the pads again: the first pad, then the others by name. There is
/// always the first (its file is made when it is first written).
pub fn refresh(ed: *Editor) !void {
    const l = &ed.pad_list;
    l.clear(ed.gpa);
    const first = dataFile(ed, "scratch.md") orelse return error.NoDataFolder;
    errdefer ed.gpa.free(first);
    try l.pads.append(ed.gpa, .{ .name = try ed.gpa.dupe(u8, "scratch"), .path = first });
    const dir_path = dataFile(ed, "scratch") orelse return;
    defer ed.gpa.free(dir_path);
    var dir = Io.Dir.cwd().openDir(ed.io, dir_path, .{ .iterate = true }) catch return;
    defer dir.close(ed.io);
    var it = dir.iterate();
    const from = l.pads.items.len;
    while (it.next(ed.io) catch null) |entry| {
        if (entry.kind != .file or entry.name[0] == '.') continue;
        const name = try ed.gpa.dupe(u8, shownName(entry.name));
        errdefer ed.gpa.free(name);
        const path = try std.fs.path.join(ed.gpa, &.{ dir_path, entry.name });
        errdefer ed.gpa.free(path);
        try l.pads.append(ed.gpa, .{ .name = name, .path = path });
    }
    std.mem.sort(Pad, l.pads.items[from..], {}, struct {
        fn less(_: void, a: Pad, b: Pad) bool {
            return std.ascii.lessThanIgnoreCase(a.name, b.name);
        }
    }.less);
    ed.pad_panel.sel = @min(ed.pad_panel.sel, l.pads.items.len - 1);
}

/// A pad's name for its file's: markdown is what a pad is unless it says
/// otherwise, so `.md` isn't shown.
fn shownName(file: []const u8) []const u8 {
    return if (std.mem.endsWith(u8, file, ".md") and file.len > 3) file[0 .. file.len - 3] else file;
}

/// The file of the pad named `typed` (in `scratch/`; caller frees): the
/// name as it is if it says what kind of file it is, else with `.md`. Null
/// (with a message) if it can't be a pad's name.
fn pathFor(ed: *Editor, typed: []const u8) !?[]u8 {
    const name = std.mem.trim(u8, typed, " \t");
    if (name.len == 0) {
        ed.setMessage(.info, "cancelled: no name", .{});
        return null;
    }
    if (std.mem.indexOfAny(u8, name, "/\\") != null or name[0] == '.') {
        ed.setMessage(.err, "a pad's name is a file's name: no / in it, no . first", .{});
        return null;
    }
    const dir_path = dataFile(ed, "scratch") orelse return null;
    defer ed.gpa.free(dir_path);
    try Io.Dir.cwd().createDirPath(ed.io, dir_path);
    const file = if (std.fs.path.extension(name).len > 1) try ed.gpa.dupe(u8, name) else try std.fmt.allocPrint(ed.gpa, "{s}.md", .{name});
    defer ed.gpa.free(file);
    return try std.fs.path.join(ed.gpa, &.{ dir_path, file });
}

pub fn hide(ed: *Editor) void {
    if (ed.pad_panel.shown) side_float.close(ed);
    ed.pad_panel.shown = false;
    ed.pad_panel.focus = false;
}

/// `SPC n`: the pads, and into their list; from it, hidden.
pub fn toggle(ed: *Editor) !void {
    const p = &ed.pad_panel;
    if (p.shown and p.focus) return hide(ed);
    // One panel along the bottom at a time.
    claude_chat.hide(ed);
    try refresh(ed);
    p.shown = true;
    p.focus = true;
    p.tail = false;
}

pub fn selected(ed: *const Editor) ?Pad {
    const l = &ed.pad_list;
    if (ed.pad_panel.sel >= l.pads.items.len) return null;
    return l.pads.items[ed.pad_panel.sel];
}

/// Keeps the text shown that of the selected pad: as its buffer has it if
/// it is open, else as its file has it.
pub fn tick(ed: *Editor) void {
    const p = &ed.pad_panel;
    if (!p.shown) return;
    const l = &ed.pad_list;
    const in_text = ed.side_window != null;
    if (l.was_in_text and !in_text) l.loaded = null;
    l.was_in_text = in_text;
    if (in_text or l.loaded == p.sel) return;
    const pad = selected(ed) orelse return;
    l.loaded = p.sel;
    l.text.clearRetainingCapacity();
    if (claude_panel.bufferForPath(ed, pad.path)) |b| {
        l.text.appendSlice(ed.gpa, b.text.slice(0, b.text.len())) catch {};
        return;
    }
    const raw = Io.Dir.cwd().readFileAlloc(ed.io, pad.path, ed.gpa, .limited(4 << 20)) catch return;
    defer ed.gpa.free(raw);
    l.text.appendSlice(ed.gpa, raw) catch {};
}

fn select(ed: *Editor, row: usize) void {
    const n = ed.pad_list.pads.items.len;
    if (n == 0) return;
    const p = &ed.pad_panel;
    p.sel = @min(row, n - 1);
    p.tail = false;
    p.scroll = 0;
    ed.pad_list.deleting = null;
}

/// The wheel over the panel (as `claude_chat.wheel`).
pub fn wheel(ed: *Editor, x: f32, y: f32, lines: isize) bool {
    const p = &ed.pad_panel;
    const side = p.under(x, y) orelse return false;
    if (lines == 0) return true;
    if (ed.side_window) |f| {
        if (ed.window == f) ed.scrollLines(lines);
    } else switch (side) {
        .rows => select(ed, if (lines > 0) p.sel + 1 else p.sel -| 1),
        .text => scrollText(ed, lines),
    }
    return true;
}

fn scrollText(ed: *Editor, delta: isize) void {
    const p = &ed.pad_panel;
    const last = p.lines -| p.page;
    const from: isize = @intCast(@min(p.scroll, last));
    p.scroll = @intCast(std.math.clamp(from + delta, 0, @as(isize, @intCast(last))));
    p.tail = false;
}

/// The pad's file as a buffer (made empty if there is none yet), without
/// showing it in a window.
fn bufferFor(ed: *Editor, pad: Pad) !*Buffer {
    if (claude_panel.bufferForPath(ed, pad.path)) |b| return b;
    if (std.fs.path.dirname(pad.path)) |d| Io.Dir.cwd().createDirPath(ed.io, d) catch {};
    if (Io.Dir.cwd().statFile(ed.io, pad.path, .{})) |_| {} else |_| try Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = pad.path, .data = "" });
    const norm = try ed.normalizePath(pad.path);
    defer ed.gpa.free(norm);
    var loaded = try Buffer.load(ed.gpa, ed.io, norm);
    errdefer loaded.deinit(ed.gpa);
    loaded.project = project_ops.projectOf(ed, norm);
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = loaded;
    try ed.buffers.append(ed.gpa, b);
    return b;
}

/// Tab / Enter on a pad: into its text, to write in it.
fn intoText(ed: *Editor) !void {
    const pad = selected(ed) orelse return;
    const b = try bufferFor(ed, pad);
    try side_float.open(ed, b, false);
}

/// `n`: asks for a new pad's name.
fn askNew(ed: *Editor) void {
    prompts.startSearch(ed, true, .new_pad);
}

/// The name was typed: the pad is made, selected and gone into.
pub fn finishNew(ed: *Editor) !void {
    const raw = try git_ops.takePromptText(ed) orelse return;
    defer ed.gpa.free(raw);
    const path = try pathFor(ed, raw) orelse return;
    defer ed.gpa.free(path);
    if (Io.Dir.cwd().statFile(ed.io, path, .{})) |_| {} else |_| try Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = path, .data = "" });
    try refresh(ed);
    for (ed.pad_list.pads.items, 0..) |p, i| if (std.mem.eql(u8, p.path, path)) select(ed, i);
    try intoText(ed);
    if (ed.mode == .normal) ed.setMode(.insert);
}

/// `r`: asks for the pad's new name (the one it has, to change).
fn askRename(ed: *Editor) void {
    const pad = selected(ed) orelse return;
    prompts.startSearch(ed, true, .rename_pad);
    ed.search_prompt.?.input.set(ed.gpa, shownName(std.fs.path.basename(pad.path))) catch {};
}

/// The new name was typed: the pad's file is renamed, and is what the name
/// says it is from now on (`notes` to `notes.sql`: a SQL file).
pub fn finishRename(ed: *Editor) !void {
    const raw = try git_ops.takePromptText(ed) orelse return;
    defer ed.gpa.free(raw);
    const pad = selected(ed) orelse return;
    const path = try pathFor(ed, raw) orelse return;
    defer ed.gpa.free(path);
    if (std.mem.eql(u8, path, pad.path)) return ed.setMessage(.info, "that is already its name", .{});
    if (Io.Dir.cwd().statFile(ed.io, path, .{})) |_| {
        return ed.setMessage(.err, "there is a pad \"{s}\" already", .{shownName(std.fs.path.basename(path))});
    } else |_| {}
    // Its buffer, if it is open: written first, then it follows the file.
    const open = claude_panel.bufferForPath(ed, pad.path);
    if (open) |b| if (b.modified) {
        _ = b.save(ed.gpa, ed.io) catch {};
    };
    if (Io.Dir.cwd().statFile(ed.io, pad.path, .{})) |_| {
        Io.Dir.rename(Io.Dir.cwd(), pad.path, Io.Dir.cwd(), path, ed.io) catch |err|
            return ed.setMessage(.err, "could not rename the pad: {s}", .{@errorName(err)});
    } else |_| try Io.Dir.cwd().writeFile(ed.io, .{ .sub_path = path, .data = "" });
    if (open) |b| {
        const norm = try ed.normalizePath(path);
        defer ed.gpa.free(norm);
        try @import("file_ops.zig").setBufferPath(ed, b, norm);
    }
    ed.setMessage(.info, "the pad is \"{s}\" now", .{shownName(std.fs.path.basename(path))});
    try refresh(ed);
    for (ed.pad_list.pads.items, 0..) |q, i| if (std.mem.eql(u8, q.path, path)) select(ed, i);
}

/// `x`, twice: the pad's file is deleted (the first pad is only emptied:
/// there is always one).
fn delete(ed: *Editor) !void {
    const l = &ed.pad_list;
    const p = &ed.pad_panel;
    const pad = selected(ed) orelse return;
    if (l.deleting != p.sel) {
        l.deleting = p.sel;
        return ed.setMessage(.info, "x again deletes the pad \"{s}\" for good", .{pad.name});
    }
    if (claude_panel.bufferForPath(ed, pad.path)) |b| {
        b.modified = false;
        ed.killBuffer(b) catch {};
    }
    Io.Dir.cwd().deleteFile(ed.io, pad.path) catch {};
    ed.setMessage(.info, "deleted the pad \"{s}\"", .{pad.name});
    try refresh(ed);
}

/// The panel's keys, while it has the keyboard. True when the key was the
/// panel's (all are, but SPC: the leader menu is the code's). While it is
/// only shown, Esc in normal mode hides it.
pub fn key(ed: *Editor, ev: Editor.KeyEvent) bool {
    const p = &ed.pad_panel;
    if (!p.shown or side_float.focused(ed)) return false;
    if (ed.picker != null or ed.cmd_float != null or ed.search_prompt != null or ed.popup != null) return false;
    if (!p.focus) {
        const esc = ev.key == .special and ev.key.special == .escape and !ev.mods.any();
        if (esc and ed.mode == .normal and ed.isIdle() and ed.cursors.items.len == 0 and ed.window.term == null) hide(ed);
        return false;
    }
    const n = ed.pad_list.pads.items.len;
    const half: isize = @intCast(@max(p.page / 2, 1));
    const was_g = p.pending_g;
    p.pending_g = false;
    const was_deleting = ed.pad_list.deleting;
    ed.pad_list.deleting = null;
    switch (ev.key) {
        .special => |sp| switch (sp) {
            .escape => hide(ed),
            .tab, .enter => intoText(ed) catch |err| ed.setMessage(.err, "could not open the pad: {s}", .{@errorName(err)}),
            .down => select(ed, p.sel + 1),
            .up => select(ed, p.sel -| 1),
            else => {},
        },
        .codepoint => |cp| if (ev.mods.ctrl) switch (cp) {
            'w' => p.focus = false,
            'd' => scrollText(ed, half),
            'u' => scrollText(ed, -half),
            'n' => select(ed, p.sel + 1),
            'p' => select(ed, p.sel -| 1),
            else => {},
        } else switch (cp) {
            'j' => select(ed, p.sel + 1),
            'k' => select(ed, p.sel -| 1),
            'J' => scrollText(ed, 1),
            'K' => scrollText(ed, -1),
            'G' => select(ed, n -| 1),
            'g' => if (was_g) select(ed, 0) else {
                p.pending_g = true;
            },
            'i', 'a' => {
                intoText(ed) catch return true;
                ed.setMode(.insert);
            },
            'n' => askNew(ed),
            'r' => askRename(ed),
            'x' => {
                ed.pad_list.deleting = was_deleting;
                delete(ed) catch {};
            },
            'y' => {
                tick(ed);
                ed.registers.store(null, .yank, ed.pad_list.text.items, false) catch {};
                ed.setMessage(.info, "yanked the pad", .{});
            },
            'o' => if (selected(ed)) |pad| {
                const path = ed.gpa.dupe(u8, pad.path) catch return true;
                defer ed.gpa.free(path);
                hide(ed);
                _ = bufferFor(ed, .{ .name = pad.name, .path = path }) catch {};
                ed.openFile(path) catch {};
            },
            'q' => hide(ed),
            ' ' => {
                p.focus = false;
                return false;
            },
            else => {},
        },
    }
    return true;
}
