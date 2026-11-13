//! Git blame (mini.git): who last changed a line, shown after the cursor's line.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Blame = @import("../git/Blame.zig");
const Editor = @import("../Editor.zig");
const lsp_actions = @import("lsp_actions.zig");

pub fn blameFor(ed: *const Editor, b: *const Buffer) ?*Blame {
    for (ed.blames.items) |e| if (e.buffer == b) return e.blame;
    return null;
}

/// Starts blaming the current buffer when inline blame is on (each frame;
/// a no-op once started).
pub fn ensureBlame(ed: *Editor) void {
    if (!ed.options.git_blame) return;
    const b = ed.buffer;
    if (b.git == null or blameFor(ed, b) != null) return;
    const rel = repoPath(ed, b) orelse return;
    defer ed.gpa.free(rel.path);
    const blame = Blame.start(ed.gpa, ed.io, rel.root, rel.path, ed.wake_fn) catch return;
    ed.blames.append(ed.gpa, .{ .buffer = b, .blame = blame }) catch blame.destroy();
}

/// `b`'s repository and its path inside it (`path` is owned by the caller).
pub fn repoPath(ed: *Editor, b: *const Buffer) ?struct { root: []const u8, path: []u8 } {
    const proj = b.project orelse return null;
    if (!proj.git) return null;
    const abs = ed.absolutePath(b.path orelse return null) catch return null;
    defer ed.gpa.free(abs);
    if (!(abs.len > proj.root.len + 1 and std.mem.startsWith(u8, abs, proj.root))) return null;
    return .{ .root = proj.root, .path = ed.gpa.dupe(u8, abs[proj.root.len + 1 ..]) catch return null };
}

pub fn dropBlame(ed: *Editor, b: *const Buffer) void {
    for (ed.blames.items, 0..) |e, i| if (e.buffer == b) {
        e.blame.destroy();
        _ = ed.blames.orderedRemove(i);
        return;
    };
}

pub fn dropAllBlames(ed: *Editor) void {
    for (ed.blames.items) |e| e.blame.destroy();
    ed.blames.clearRetainingCapacity();
}

/// The HEAD line that buffer line `line` still is, or null if the line was
/// added or changed since.
pub fn headLineOf(ed: *const Editor, line: usize) ?usize {
    const g = ed.buffer.git orelse return null;
    var delta: isize = 0;
    for (g.hunks.items) |h| {
        if (line < h.new_start) break;
        if (line < h.new_start + h.new_count) return null;
        delta += @as(isize, @intCast(h.old_count)) - @as(isize, @intCast(h.new_count));
    }
    return @intCast(@as(isize, @intCast(line)) + delta);
}

pub const BlameLine = union(enum) {
    /// Still being computed, or not a tracked file.
    unknown,
    uncommitted,
    commit: *const Blame.Commit,
};

/// Who last changed the current buffer's line `line`.
pub fn blameLine(ed: *const Editor, line: usize) BlameLine {
    const blame = blameFor(ed, ed.buffer) orelse return .unknown;
    if (!blame.done.load(.acquire)) return .unknown;
    const head = headLineOf(ed, line) orelse return .uncommitted;
    return if (blame.at(head)) |c| .{ .commit = c } else .unknown;
}

/// `SPC g l`: the commit that last changed the cursor's line, in a popup.
pub fn showLineCommit(ed: *Editor) !void {
    const gpa = ed.gpa;
    const rel = repoPath(ed, ed.buffer) orelse return ed.setMessage(.info, "not a file in a git repository", .{});
    defer gpa.free(rel.path);
    const head = headLineOf(ed, ed.cursorLine()) orelse return ed.setMessage(.info, "this line isn't committed yet", .{});
    var range_buf: [48]u8 = undefined;
    const range = try std.fmt.bufPrint(&range_buf, "{d},{d}", .{ head + 1, head + 1 });
    const blamed = std.process.run(gpa, ed.io, .{
        .argv = &.{ "git", "blame", "--porcelain", "-L", range, "HEAD", "--", rel.path },
        .cwd = .{ .path = rel.root },
    }) catch |err| return ed.setMessage(.err, "git blame: {s}", .{@errorName(err)});
    defer gpa.free(blamed.stdout);
    defer gpa.free(blamed.stderr);
    if (!blamed.term.success() or blamed.stdout.len < 40) return ed.setMessage(.err, "git blame: {s}", .{std.mem.sliceTo(blamed.stderr, '\n')});
    const shown = std.process.run(gpa, ed.io, .{
        .argv = &.{ "git", "show", "--stat", "--date=relative", "--format=%h  %an, %ad%n%n%B", blamed.stdout[0..40] },
        .cwd = .{ .path = rel.root },
    }) catch |err| return ed.setMessage(.err, "git show: {s}", .{@errorName(err)});
    defer gpa.free(shown.stdout);
    defer gpa.free(shown.stderr);
    try lsp_actions.showHover(ed, std.mem.trim(u8, shown.stdout, " \n"));
}
