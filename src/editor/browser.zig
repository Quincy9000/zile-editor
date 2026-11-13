//! The file browser: the picker on one folder at a time, and its file operations.

const std = @import("std");
const Io = std.Io;
const formatting = @import("formatting.zig");
const file_ops = @import("file_ops.zig");
const Editor = @import("../Editor.zig");
const picker_query = @import("picker_query.zig");
const prompts = @import("prompts.zig");
const git_ops = @import("git_ops.zig");
const PromptKind = Editor.PromptKind;

/// `SPC .`: browses the current file's folder (else the working directory).
pub fn browse(ed: *Editor) !void {
    const start = if (ed.buffer.path) |p| blk: {
        const abs = try ed.absolutePath(p);
        defer ed.gpa.free(abs);
        break :blk try ed.gpa.dupe(u8, std.fs.path.dirname(abs) orelse "/");
    } else try ed.gpa.dupe(u8, ed.cwd);
    defer ed.gpa.free(start);
    try setBrowseDir(ed, start);
    try ed.openPicker(.browse, "");
}

/// Enters folder `name` (relative to the browsed one, or absolute).
pub fn browseInto(ed: *Editor, name: []const u8) !void {
    // `~/x` is in your home folder.
    var home_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const named = if (std.mem.eql(u8, name, "~") or std.mem.startsWith(u8, name, "~/"))
        std.fmt.bufPrint(&home_buf, "{s}{s}", .{ std.mem.span(std.c.getenv("HOME") orelse ""), name[1..] }) catch name
    else
        name;
    const target = try std.fs.path.resolve(ed.gpa, &.{ ed.browse_dir.items, named });
    defer ed.gpa.free(target);
    var dir = Io.Dir.cwd().openDir(ed.io, target, .{ .iterate = true }) catch |err|
        return ed.setMessage(.err, "can't open {s}: {s}", .{ target, @errorName(err) });
    dir.close(ed.io);
    try setBrowseDir(ed, target);
    if (ed.picker) |p| if (p.base == .browse) return p.restart(null);
    try ed.openPicker(.browse, "");
}

/// Goes up one folder, selecting the one we came from.
pub fn browseUp(ed: *Editor) !void {
    const cur = ed.browse_dir.items;
    const parent = std.fs.path.dirname(cur) orelse return; // at the root
    var came_from: [Io.Dir.max_name_bytes + 1]u8 = undefined;
    const sel = try std.fmt.bufPrint(&came_from, "{s}/", .{std.fs.path.basename(cur)});
    const up = try ed.gpa.dupe(u8, parent);
    defer ed.gpa.free(up);
    try setBrowseDir(ed, up);
    if (ed.picker) |p| try p.restart(sel);
}

/// An owned absolute path for `name` inside the browsed folder.
pub fn browsePath(ed: *Editor, name: []const u8) ![]u8 {
    // Files from elsewhere (typed search): `~/...` and absolute paths.
    if (std.mem.startsWith(u8, name, "~/")) if (std.c.getenv("HOME")) |h| return std.fs.path.join(ed.gpa, &.{ std.mem.span(h), name[2..] });
    if (std.fs.path.isAbsolute(name)) return ed.gpa.dupe(u8, name);
    return std.fs.path.join(ed.gpa, &.{ ed.browse_dir.items, name });
}

pub fn setBrowseDir(ed: *Editor, dir: []const u8) !void {
    ed.browse_dir.clearRetainingCapacity();
    try ed.browse_dir.appendSlice(ed.gpa, dir);
    // The display form: "~" for home, always ending in "/".
    ed.browse_label.clearRetainingCapacity();
    const home: []const u8 = if (std.c.getenv("HOME")) |h| std.mem.span(h) else "";
    if (home.len > 1 and std.mem.startsWith(u8, dir, home) and
        (dir.len == home.len or dir[home.len] == '/'))
    {
        try ed.browse_label.append(ed.gpa, '~');
        try ed.browse_label.appendSlice(ed.gpa, dir[home.len..]);
    } else try ed.browse_label.appendSlice(ed.gpa, dir);
    if (ed.browse_label.items[ed.browse_label.items.len - 1] != '/') try ed.browse_label.append(ed.gpa, '/');
}

// File operations in the browser's list (normal mode): `o` new folder,
// `n` new file, `r` rename, `m` move, `x` / `dd` delete, `yy` copy and `p`
// paste into the folder shown.

pub const BrowseOp = enum { new_folder, new_file, rename, move, delete, copy, paste };

pub fn setBrowseSlot(ed: *Editor, slot: *?[]u8, path: []const u8) !void {
    const owned = try ed.gpa.dupe(u8, path);
    if (slot.*) |old| ed.gpa.free(old);
    slot.* = owned;
}

/// Reopens the browser on its folder, on the entry `select` if given.
pub fn reopenBrowser(ed: *Editor, select: ?[]const u8) void {
    ed.openPicker(.browse, "") catch return;
    ed.mode = .picker_normal;
    if (select) |s| ed.picker.?.want_select = ed.gpa.dupe(u8, s) catch null;
}

pub fn browseOp(ed: *Editor, op: BrowseOp) !void {
    const p = ed.picker orelse return;
    if (p.kind != .browse) return;
    p.sync();
    switch (op) {
        .new_folder, .new_file => {
            picker_query.closePicker(ed);
            prompts.startSearch(ed, true, if (op == .new_folder) .browse_new_folder else .browse_new_file);
            return;
        },
        .paste => return browsePaste(ed),
        else => {},
    }
    // The rest act on the selected entry.
    const item = p.itemAt(p.selected) orelse return ed.setMessage(.info, "nothing selected", .{});
    const is_dir = std.mem.endsWith(u8, item.text, "/");
    const name = try ed.gpa.dupe(u8, std.mem.trimEnd(u8, item.text, "/"));
    defer ed.gpa.free(name);
    const abs = try browsePath(ed, name);
    defer ed.gpa.free(abs);
    switch (op) {
        .copy => {
            if (is_dir) return ed.setMessage(.info, "copying a whole folder isn't supported (m moves one)", .{});
            try setBrowseSlot(ed, &ed.browse_clip, abs);
            ed.setMessage(.info, "copied \"{s}\": p pastes it into the folder shown", .{name});
        },
        .rename, .move => {
            try setBrowseSlot(ed, &ed.browse_target, abs);
            picker_query.closePicker(ed);
            prompts.startSearch(ed, true, if (op == .rename) .browse_rename else .browse_move);
            try ed.search_prompt.?.input.set(ed.gpa, if (op == .rename) name else abs);
        },
        .delete => {
            try setBrowseSlot(ed, &ed.browse_target, abs);
            picker_query.closePicker(ed);
            try ed.openPicker(.confirm_remove, "");
        },
        else => unreachable,
    }
}

pub fn browsePaste(ed: *Editor) !void {
    const src = ed.browse_clip orelse return ed.setMessage(.info, "nothing copied (yy on a file copies it)", .{});
    const base = std.fs.path.basename(src);
    var dest = try browsePath(ed, base);
    defer ed.gpa.free(dest);
    if (formatting.fileExists(ed, dest)) {
        // Next to the original: "name copy.ext".
        const ext = std.fs.path.extension(base);
        const named = try std.fmt.allocPrint(ed.gpa, "{s} copy{s}", .{ base[0 .. base.len - ext.len], ext });
        defer ed.gpa.free(named);
        ed.gpa.free(dest);
        dest = try browsePath(ed, named);
        if (formatting.fileExists(ed, dest)) return ed.setMessage(.err, "\"{s}\" already exists here", .{named});
    }
    Io.Dir.copyFile(Io.Dir.cwd(), src, Io.Dir.cwd(), dest, ed.io, .{}) catch |err|
        return ed.setMessage(.err, "could not copy: {s}", .{@errorName(err)});
    const shown = try ed.gpa.dupe(u8, std.fs.path.basename(dest));
    defer ed.gpa.free(shown);
    if (ed.picker) |p| {
        try p.restart(shown);
        ed.mode = .picker_normal;
    }
    ed.setMessage(.info, "pasted \"{s}\"", .{shown});
}

pub fn finishBrowsePrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try git_ops.takePromptText(ed) orelse return;
    defer ed.gpa.free(raw);
    const typed = std.mem.trim(u8, raw, " ");
    if (typed.len == 0) {
        ed.setMessage(.info, "cancelled: no name", .{});
        return reopenBrowser(ed, null);
    }
    const cwd = Io.Dir.cwd();
    // Relative names are inside the folder shown.
    const dest = try std.fs.path.resolve(ed.gpa, &.{ ed.browse_dir.items, typed });
    defer ed.gpa.free(dest);
    switch (kind) {
        .browse_new_folder => {
            cwd.createDirPath(ed.io, dest) catch |err| {
                ed.setMessage(.err, "could not make the folder: {s}", .{@errorName(err)});
                return reopenBrowser(ed, null);
            };
            ed.setMessage(.info, "made folder \"{s}\"", .{typed});
        },
        .browse_new_file => {
            if (formatting.fileExists(ed, dest)) {
                ed.setMessage(.err, "\"{s}\" already exists", .{typed});
                return reopenBrowser(ed, null);
            }
            if (std.fs.path.dirname(dest)) |dir| cwd.createDirPath(ed.io, dir) catch {};
            cwd.writeFile(ed.io, .{ .sub_path = dest, .data = "" }) catch |err| {
                ed.setMessage(.err, "could not make the file: {s}", .{@errorName(err)});
                return reopenBrowser(ed, null);
            };
            // A new file is for writing in: open it.
            return ed.openFile(dest);
        },
        .browse_rename, .browse_move => {
            const old = ed.browse_target orelse return;
            if (std.mem.eql(u8, old, dest)) return reopenBrowser(ed, null);
            if (formatting.fileExists(ed, dest)) {
                ed.setMessage(.err, "\"{s}\" already exists", .{typed});
                return reopenBrowser(ed, null);
            }
            if (std.fs.path.dirname(dest)) |dir| cwd.createDirPath(ed.io, dir) catch {};
            Io.Dir.rename(cwd, old, cwd, dest, ed.io) catch |err| {
                ed.setMessage(.err, "could not move it: {s}", .{@errorName(err)});
                return reopenBrowser(ed, null);
            };
            try retargetBuffers(ed, old, dest);
            ed.setMessage(.info, "\"{s}\" is now \"{s}\"", .{ std.fs.path.basename(old), typed });
        },
        else => unreachable,
    }
    // Show the result where it now is.
    if (std.fs.path.dirname(dest)) |dir| setBrowseDir(ed, dir) catch {};
    var sel_buf: [Io.Dir.max_name_bytes + 1]u8 = undefined;
    const base = std.fs.path.basename(dest);
    const st = cwd.statFile(ed.io, dest, .{}) catch null;
    const is_dir = st != null and st.?.kind == .directory;
    const sel = if (is_dir) std.fmt.bufPrint(&sel_buf, "{s}/", .{base}) catch base else base;
    reopenBrowser(ed, sel);
}

/// Open buffers of a file (or of files in a folder) that moved from `old`
/// to `new` follow it.
pub fn retargetBuffers(ed: *Editor, old: []const u8, new: []const u8) !void {
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        const inside = abs.len > old.len and std.mem.startsWith(u8, abs, old) and abs[old.len] == '/';
        if (!std.mem.eql(u8, abs, old) and !inside) continue;
        const moved = try std.mem.concat(ed.gpa, u8, &.{ new, abs[old.len..] });
        defer ed.gpa.free(moved);
        const norm = try ed.normalizePath(moved);
        defer ed.gpa.free(norm);
        try file_ops.setBufferPath(ed, b, norm);
    }
}

/// The delete confirmation answered: removes `browse_target` (a folder with
/// everything in it) and closes unmodified buffers of what is gone.
pub fn browseRemove(ed: *Editor, confirmed: bool) !void {
    const target = ed.browse_target orelse return;
    defer reopenBrowser(ed, null);
    if (!confirmed) return ed.setMessage(.info, "kept \"{s}\"", .{std.fs.path.basename(target)});
    const cwd = Io.Dir.cwd();
    const st = cwd.statFile(ed.io, target, .{}) catch null;
    const is_dir = st != null and st.?.kind == .directory;
    (if (is_dir) cwd.deleteTree(ed.io, target) else cwd.deleteFile(ed.io, target)) catch |err|
        return ed.setMessage(.err, "could not delete: {s}", .{@errorName(err)});
    var i = ed.buffers.items.len;
    while (i > 0) {
        i -= 1;
        if (i >= ed.buffers.items.len) continue;
        const b = ed.buffers.items[i];
        const path = b.path orelse continue;
        if (b.modified) continue;
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        const inside = abs.len > target.len and std.mem.startsWith(u8, abs, target) and abs[target.len] == '/';
        if (std.mem.eql(u8, abs, target) or inside) try ed.killBuffer(b);
    }
    ed.setMessage(.info, "deleted \"{s}\"", .{std.fs.path.basename(target)});
}
