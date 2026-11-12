//! What zile keeps on disk between runs, as a list to look at and clear
//! (the "Stored data" picker), and the limits that keep it small.
//!
//! State (`$XDG_STATE_HOME/zile`): `visits`, `sessions/`, `undo/`,
//! `run-commands`, `projects`, `theme`. Cache (`$XDG_CACHE_HOME/zile`): the
//! language servers' and gdb's logs. The files limit themselves (500
//! visits, 50 projects, 100 commands a project and 2000 in all); the
//! folders, one file per project or per edited file, are pruned here:
//! the oldest go first.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

pub const Store = enum {
    visits,
    sessions,
    undo,
    runner,
    projects,
    theme,
    logs,

    pub fn label(s: Store) []const u8 {
        return switch (s) {
            .visits => "Recent files",
            .sessions => "Sessions",
            .undo => "Undo histories",
            .runner => "Runner commands",
            .projects => "Projects",
            .theme => "Theme",
            .logs => "Logs",
        };
    }

    /// Its file or folder under the state (or, for logs, cache) folder.
    pub fn name(s: Store) []const u8 {
        return switch (s) {
            .visits => "visits",
            .sessions => "sessions",
            .undo => "undo",
            .runner => "run-commands",
            .projects => "projects",
            .theme => "theme",
            .logs => "",
        };
    }

    pub fn isFolder(s: Store) bool {
        return s == .sessions or s == .undo or s == .logs;
    }

    /// What it holds.
    pub fn about(s: Store) []const u8 {
        return switch (s) {
            .visits => "Files you opened: how often, when, where the cursor was.",
            .sessions => "Per project: the open files, cursors, window splits.",
            .undo => "Each edited file's undo history, so undo survives closing it.",
            .runner => "Your SPC r commands, per project.",
            .projects => "Projects you opened, for SPC p p.",
            .theme => "The theme you picked.",
            .logs => "The language servers' and gdb's error output.",
        };
    }

    /// What clearing it means for you.
    pub fn effect(s: Store) []const u8 {
        return switch (s) {
            .visits => "Files no longer rank by use, and reopen at the top.",
            .sessions => "Projects open as new (this one's is saved again when you leave).",
            .undo => "Closed files lose the undo history from before; open files keep theirs.",
            .runner => "SPC r starts empty in every project.",
            .projects => "SPC p p lists only projects opened from now on.",
            .theme => "The default theme, from the next start.",
            .logs => "Nothing: they are written again when a server or gdb starts.",
        };
    }
};

/// Most files kept in `sessions/` and `undo/`, and most bytes in `undo/`.
pub const max_sessions = 100;
pub const max_undo_files = 300;
pub const max_undo_bytes: u64 = 256 << 20;

pub const Usage = struct { files: usize = 0, bytes: u64 = 0 };

/// How much `path` holds: a file, or a folder's files (not below it).
pub fn usage(io: Io, path: []const u8) Usage {
    const cwd = Io.Dir.cwd();
    var d = cwd.openDir(io, path, .{ .iterate = true }) catch {
        const st = cwd.statFile(io, path, .{}) catch return .{};
        return .{ .files = 1, .bytes = st.size };
    };
    defer d.close(io);
    var u: Usage = .{};
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = d.statFile(io, e.name, .{}) catch continue;
        u.files += 1;
        u.bytes += st.size;
    }
    return u;
}

/// Removes `path`'s file, or the files in its folder (the folder stays).
pub fn clear(io: Io, path: []const u8) void {
    const cwd = Io.Dir.cwd();
    var d = cwd.openDir(io, path, .{ .iterate = true }) catch {
        cwd.deleteFile(io, path) catch {};
        return;
    };
    defer d.close(io);
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind == .file) d.deleteFile(io, e.name) catch {};
    }
}

/// Keeps the newest `max_files` files in `folder` (and no more than
/// `max_bytes` of them); the rest are removed, oldest first.
pub fn prune(gpa: Allocator, io: Io, folder: []const u8, max_files: usize, max_bytes: u64) void {
    var d = Io.Dir.cwd().openDir(io, folder, .{ .iterate = true }) catch return;
    defer d.close(io);
    const File = struct { name: []u8, time: i96, size: u64 };
    var files: std.ArrayList(File) = .empty;
    defer {
        for (files.items) |f| gpa.free(f.name);
        files.deinit(gpa);
    }
    var it = d.iterate();
    while (it.next(io) catch null) |e| {
        if (e.kind != .file) continue;
        const st = d.statFile(io, e.name, .{}) catch continue;
        const n = gpa.dupe(u8, e.name) catch return;
        files.append(gpa, .{ .name = n, .time = st.mtime.nanoseconds, .size = st.size }) catch {
            gpa.free(n);
            return;
        };
    }
    std.mem.sort(File, files.items, {}, struct {
        fn newer(_: void, a: File, b: File) bool {
            return a.time > b.time;
        }
    }.newer);
    var bytes: u64 = 0;
    for (files.items, 0..) |f, i| {
        bytes += f.size;
        if (i >= max_files or bytes > max_bytes) d.deleteFile(io, f.name) catch {};
    }
}

/// "12 files · 3.4 MB".
pub fn describe(buf: []u8, store: Store, u: Usage) []const u8 {
    if (u.files == 0) return "nothing";
    var size_buf: [32]u8 = undefined;
    const size = if (u.bytes < 1024)
        std.fmt.bufPrint(&size_buf, "{d} B", .{u.bytes}) catch ""
    else if (u.bytes < 1 << 20)
        std.fmt.bufPrint(&size_buf, "{d:.1} KB", .{@as(f64, @floatFromInt(u.bytes)) / 1024}) catch ""
    else
        std.fmt.bufPrint(&size_buf, "{d:.1} MB", .{@as(f64, @floatFromInt(u.bytes)) / (1 << 20)}) catch "";
    if (!store.isFolder()) return std.fmt.bufPrint(buf, "{s}", .{size}) catch "";
    return std.fmt.bufPrint(buf, "{d} file{s} · {s}", .{ u.files, if (u.files == 1) "" else "s", size }) catch "";
}

test "prune keeps the newest files, by count and by size" {
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    for ([_][]const u8{ "a", "b", "c", "d" }, 0..) |n, i| {
        try tmp.dir.writeFile(io, .{ .sub_path = n, .data = "12345" });
        // Older the earlier: a, b, c, d.
        const f = try tmp.dir.openFile(io, n, .{ .mode = .read_write });
        defer f.close(io);
        const t: Io.Timestamp = .{ .nanoseconds = @as(i96, @intCast(i + 1)) * std.time.ns_per_s * 1000 };
        try f.setTimestamps(io, .{ .access_timestamp = .{ .new = t }, .modify_timestamp = .{ .new = t } });
    }
    var buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(io, &buf)];
    prune(std.testing.allocator, io, dir, 3, 1 << 20);
    try std.testing.expectEqual(3, usage(io, dir).files);
    try std.testing.expectError(error.FileNotFound, tmp.dir.statFile(io, "a", .{}));
    // 12 bytes at most: the two newest (10 bytes).
    prune(std.testing.allocator, io, dir, 100, 12);
    try std.testing.expectEqual(2, usage(io, dir).files);
    _ = try tmp.dir.statFile(io, "d", .{});
    clear(io, dir);
    try std.testing.expectEqual(0, usage(io, dir).files);
}
