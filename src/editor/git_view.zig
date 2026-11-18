//! What the git pickers (`SPC g`: changes, files, history, branches) list
//! and do: the changes not committed yet, read from `git diff`; restoring
//! one, or a whole file; a file or a commit side by side.

const std = @import("std");
const Git = @import("../git/Git.zig");
const patch = @import("../git/patch.zig");
const Editor = @import("../Editor.zig");
const project_ops = @import("project_ops.zig");
const git_ops = @import("git_ops.zig");
const formatting = @import("formatting.zig");
const compare = @import("compare.zig");

pub const State = struct {
    /// `git diff HEAD` with no lines around each change: a row for each
    /// (what the gutter marks, and what restoring one puts back).
    rows_diff: []u8 = &.{},
    rows: std.ArrayList(patch.Change) = .empty,
    /// The same with lines around: what a row's preview shows.
    shown_diff: []u8 = &.{},
    shown: std.ArrayList(patch.Change) = .empty,
    /// The commit whose files are listed (its short hash).
    commit_buf: [40]u8 = undefined,
    commit_len: u8 = 0,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        gpa.free(s.rows_diff);
        gpa.free(s.shown_diff);
        s.rows.deinit(gpa);
        s.shown.deinit(gpa);
        s.* = .{};
    }

    pub fn commit(s: *const State) []const u8 {
        return s.commit_buf[0..s.commit_len];
    }

    pub fn setCommit(s: *State, hash: []const u8) void {
        s.commit_len = @intCast(@min(hash.len, s.commit_buf.len));
        @memcpy(s.commit_buf[0..s.commit_len], hash[0..s.commit_len]);
    }
};

/// Reads what isn't committed (as it is on disk) into `ed.git_lists`.
pub fn loadChanges(ed: *Editor, root: []const u8) !void {
    const s = &ed.git_lists;
    const commit = s.commit_buf;
    const commit_len = s.commit_len;
    s.deinit(ed.gpa);
    s.commit_buf = commit;
    s.commit_len = commit_len;
    const gpa = ed.gpa;
    const base = [_][]const u8{ "git", "-C", root, "-c", "core.quotePath=false", "diff", "HEAD", "--no-color", "--no-ext-diff" };
    if (runGit(ed, &(base ++ .{"-U0"}))) |out| {
        s.rows_diff = out;
        try patch.changes(gpa, out, &s.rows);
    }
    if (runGit(ed, &base)) |out| {
        s.shown_diff = out;
        try patch.changes(gpa, out, &s.shown);
    }
}

fn runGit(ed: *Editor, argv: []const []const u8) ?[]u8 {
    const r = std.process.run(ed.gpa, ed.io, .{ .argv = argv, .stdout_limit = .limited(64 << 20) }) catch return null;
    ed.gpa.free(r.stderr);
    if (!r.term.success()) {
        ed.gpa.free(r.stdout);
        return null;
    }
    return r.stdout;
}

/// The text a change's row previews: the change with the lines around it,
/// and the line of that text its first changed line is on.
pub fn changeText(ed: *const Editor, id: usize) ?struct { text: []const u8, focus: usize } {
    const s = &ed.git_lists;
    if (id >= s.rows.items.len) return null;
    const c = s.rows.items[id];
    for (s.shown.items) |w| {
        if (!std.mem.eql(u8, w.path, c.path)) continue;
        if (c.line < w.new_start or c.line > w.new_start + w.new_len) continue;
        const text = s.shown_diff[w.start..w.end];
        // The line of the hunk where the file's line `c.line` is reached.
        var n: u32 = w.new_start;
        var focus: usize = 0;
        var it = std.mem.splitScalar(u8, text, '\n');
        _ = it.next(); // the @@ line
        var i: usize = 1;
        while (it.next()) |line| : (i += 1) {
            if (line.len > 0 and (line[0] == '+' or line[0] == '-') and n >= c.line) {
                focus = i;
                break;
            }
            if (line.len == 0 or line[0] != '-') n += 1;
        }
        return .{ .text = text, .focus = focus };
    }
    return .{ .text = s.rows_diff[c.start..c.end], .focus = 0 };
}

/// `path` (as the editor has it) from the top of its repository; null if
/// it isn't in the one we are in. Caller frees.
pub fn repoRel(ed: *Editor, root: []const u8, path: []const u8) ?[]u8 {
    const abs = ed.absolutePath(path) catch return null;
    defer ed.gpa.free(abs);
    if (!(abs.len > root.len + 1 and std.mem.startsWith(u8, abs, root) and abs[root.len] == '/')) return null;
    return ed.gpa.dupe(u8, abs[root.len + 1 ..]) catch null;
}

/// Goes to the change at `line` (0-based) of `path` and puts HEAD's lines
/// back there (undoable, as `git_restore_hunk` is).
pub fn restoreChange(ed: *Editor, path: []const u8, line: usize) !void {
    try ed.jumpTo(path, line, 0);
    git_ops.updateGit(ed);
    const h = git_ops.hunkAtCursor(ed) orelse
        return ed.setMessage(.info, "no change here any more (the list is of the files as they are saved)", .{});
    try git_ops.restoreHunk(ed, h);
    ed.setMessage(.info, "restored from HEAD (u brings your lines back)", .{});
}

/// The whole of `path` as HEAD has it: in its buffer, undoable (a deleted
/// file is put back by git).
pub fn restoreFile(ed: *Editor, path: []const u8, status: []const u8) !void {
    if (std.mem.eql(u8, status, "new")) return ed.setMessage(.info, "{s} is new: HEAD has nothing to put back", .{path});
    if (std.mem.eql(u8, status, "deleted")) {
        const root = project_ops.gitRoot(ed) orelse return;
        const rel = repoRel(ed, root, path) orelse return;
        defer ed.gpa.free(rel);
        if (!Git.checkoutHead(ed.gpa, ed.io, root, rel)) return ed.setMessage(.err, "git could not put {s} back", .{path});
        try ed.openFile(path);
        return ed.setMessage(.info, "{s} is back, as HEAD has it", .{path});
    }
    try ed.openFile(path);
    const g = &(ed.buffer.git orelse return ed.setMessage(.info, "{s} isn't in HEAD", .{path}));
    const base = try ed.gpa.dupe(u8, g.base.slice(0, g.base.len()));
    defer ed.gpa.free(base);
    try formatting.replaceTextKeepingCursor(ed, base);
    git_ops.updateGit(ed);
    ed.setMessage(.info, "{s} is as HEAD has it (u brings your changes back; not saved yet)", .{path});
}

/// `path` beside HEAD's version of it, at `line` (0-based).
pub fn sideBySide(ed: *Editor, path: []const u8, line: usize) !void {
    compare.close(ed);
    try ed.jumpTo(path, line, 0);
    try compare.toggleFile(ed);
}

/// `path` beside HEAD's version of it, where its cursor is (or, outside a
/// change, at its first one).
pub fn sideBySideFile(ed: *Editor, path: []const u8) !void {
    compare.close(ed);
    try ed.openFile(path);
    try compare.toggleFile(ed);
}
