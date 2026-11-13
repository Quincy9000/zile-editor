//! Git: the diff against HEAD, ghost lines, and the simple actions (`SPC g`).

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Text = @import("../core/Text.zig");
const motions = @import("../core/motions.zig");
const diff = @import("../git/diff.zig");
const Git = @import("../git/Git.zig");
const GitJob = @import("../git/Job.zig");
const Project = @import("../core/Project.zig");
const blame = @import("blame.zig");
const notifications = @import("notifications.zig");
const project_ops = @import("project_ops.zig");
const row_model = @import("row_model.zig");
const prompts = @import("prompts.zig");
const Editor = @import("../Editor.zig");
const lsp_ops = @import("lsp_ops.zig");

/// Loads `b`'s HEAD version for diffing, if it is tracked in a repository.
pub fn loadGitBase(ed: *Editor, b: *Buffer) void {
    const path = b.path orelse return;
    const proj = b.project orelse return;
    if (!proj.git) return;
    const root = proj.root;
    const abs = ed.absolutePath(path) catch return;
    defer ed.gpa.free(abs);
    const raw = Git.headVersion(ed.gpa, ed.io, root, abs) orelse return;
    defer ed.gpa.free(raw);
    const norm = Git.normalize(ed.gpa, raw) catch return;
    defer ed.gpa.free(norm);
    const base = Text.init(ed.gpa, norm) catch return;
    if (b.git) |*g| g.deinit(ed.gpa);
    b.git = .{ .base = base };
}

// Simple git actions (SPC g g): each runs in the background.

/// Whether we are in a repository (says so if not).
pub fn inRepo(ed: *Editor) bool {
    if (project_ops.gitRoot(ed) != null) return true;
    ed.setMessage(.info, "not in a git repository", .{});
    return false;
}

pub fn startGitJob(ed: *Editor, kind: GitJob.Kind, busy: []const u8, steps: []const []const []const u8) !void {
    if (!inRepo(ed)) return;
    if (ed.git_job != null) return ed.setMessage(.info, "git is still busy...", .{});
    ed.git_job = try GitJob.start(ed.gpa, ed.io, kind, project_ops.gitRoot(ed).?, steps, ed.wake_fn);
    ed.setMessage(.info, "git: {s}...", .{busy});
}

/// Reports a finished job and refreshes what it changed.
pub fn pollGitJob(ed: *Editor) void {
    const job = ed.git_job orelse return;
    if (!job.done.load(.acquire)) return;
    ed.git_job = null;
    defer job.destroy();
    if (!job.ok) {
        const hint: []const u8 = if (job.kind == .push and std.mem.indexOf(u8, job.message, "origin") != null)
            "  (set one with SPC g g > Set remote URL)"
        else
            "";
        return notifications.notify(ed, .err, "git: {s}{s}", .{ job.message, hint });
    }
    switch (job.kind) {
        .commit => notifications.notify(ed, .info, "committed: {s}", .{job.message}),
        .push => notifications.notify(ed, .info, "pushed", .{}),
        .pull => notifications.notify(ed, .info, "pulled: {s}", .{job.message}),
        .switch_branch, .create_branch => notifications.notify(ed, .info, "{s}", .{job.message}),
        .set_remote => notifications.notify(ed, .info, "remote origin set", .{}),
        .init => {
            notifications.notify(ed, .info, "{s}", .{job.message});
            adoptNewRepository(ed, job.root);
        },
    }
    // Files may have changed on disk; HEAD has moved.
    if (job.kind == .pull or job.kind == .switch_branch or job.kind == .create_branch) reloadFromDisk(ed);
    reloadGit(ed);
}

/// Re-reads every unmodified buffer from disk (after a pull or branch switch).
pub fn reloadFromDisk(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        if (b.path == null or b.modified) continue;
        reloadBuffer(ed, b) catch continue;
    }
}

/// Replaces `b`'s text with the file on disk (discarding unsaved changes).
pub fn reloadBuffer(ed: *Editor, b: *Buffer) !void {
    const path = b.path orelse return error.NoPath;
    var fresh = try Buffer.load(ed.gpa, ed.io, path);
    fresh.line_listener = b.line_listener;
    const cursor = if (b == ed.buffer) ed.view.cursor else b.saved.cursor;
    lsp_ops.lspCloseBuffer(ed, b);
    const saved = b.saved;
    const last_used = b.last_used;
    b.deinit(ed.gpa);
    fresh.saved = saved;
    fresh.last_used = last_used;
    fresh.project = b.project;
    b.* = fresh;
    loadGitBase(ed, b);
    for (ed.window_list.items) |w| if (w != ed.window and w.buffer == b) {
        w.view.cursor = @min(w.view.cursor, b.text.len());
        w.view.anchor = w.view.cursor;
    };
    if (b == ed.buffer) {
        ed.cursors.clearRetainingCapacity();
        ed.setCursor(@min(cursor, b.text.len()));
    }
}

/// Commit: asks for a message (saving open files first).
pub fn gitCommitPrompt(ed: *Editor) void {
    if (!inRepo(ed)) return;
    prompts.startSearch(ed, true, .git_commit);
}

pub fn finishGitCommit(ed: *Editor) !void {
    const message = try takePromptText(ed) orelse return;
    defer ed.gpa.free(message);
    if (std.mem.trim(u8, message, " ").len == 0) return ed.setMessage(.info, "commit cancelled: empty message", .{});
    // Commit what you see: save modified files first.
    for (ed.buffers.items) |b| if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch {};
        if (lsp_ops.lspFor(ed, b)) |l| l.didSave(b);
    };
    try startGitJob(ed, .commit, "committing", &.{
        &.{ "git", "add", "-A" },
        &.{ "git", "commit", "-m", message },
    });
}

/// `SPC g i`: makes the current project (else the working folder) a git
/// repository.
pub fn gitInit(ed: *Editor) !void {
    if (project_ops.gitRoot(ed)) |root| return ed.setMessage(.info, "already in a git repository ({s})", .{root});
    if (ed.git_job != null) return ed.setMessage(.info, "git is still busy...", .{});
    ed.git_job = try GitJob.start(ed.gpa, ed.io, .init, project_ops.projectRoot(ed), &.{&.{ "git", "init" }}, ed.wake_fn);
    ed.setMessage(.info, "git: initializing...", .{});
}

/// A repository was just made at `root`: the projects there (and the files
/// in them) are git projects from now on, so the gutter, ghost lines,
/// commits and the rest work without reopening anything.
pub fn adoptNewRepository(ed: *Editor, root: []const u8) void {
    for (ed.projects.items) |p| if (std.mem.eql(u8, p.root, root)) {
        p.git = true;
    };
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        b.project = project_ops.projectOf(ed, path);
    }
    if (Project.detect(ed.io, root)) |f| ed.last_project = project_ops.internProject(ed, f.root, f.git);
}

pub fn gitPush(ed: *Editor) !void {
    try startGitJob(ed, .push, "pushing", &.{&.{ "git", "push", "-u", "origin", "HEAD" }});
}

pub fn gitPull(ed: *Editor) !void {
    try startGitJob(ed, .pull, "pulling", &.{&.{ "git", "pull", "--ff-only" }});
}

pub fn gitSwitch(ed: *Editor, name: []const u8, create: bool) !void {
    if (create) {
        try startGitJob(ed, .create_branch, "creating branch", &.{&.{ "git", "switch", "-c", name }});
    } else {
        try startGitJob(ed, .switch_branch, "switching branch", &.{&.{ "git", "switch", name }});
    }
}

/// Set remote: asks for the URL, prefilled with the current one.
pub fn gitRemotePrompt(ed: *Editor) !void {
    if (!inRepo(ed)) return;
    prompts.startSearch(ed, true, .git_remote);
    if (Git.originUrl(ed.gpa, ed.io, project_ops.gitRoot(ed).?)) |url| {
        defer ed.gpa.free(url);
        try ed.search_prompt.?.input.set(ed.gpa, url);
    }
}

pub fn finishGitRemote(ed: *Editor) !void {
    const url = try takePromptText(ed) orelse return;
    defer ed.gpa.free(url);
    const trimmed = std.mem.trim(u8, url, " ");
    if (trimmed.len == 0) return;
    const has_origin = if (Git.originUrl(ed.gpa, ed.io, project_ops.gitRoot(ed).?)) |u| blk: {
        ed.gpa.free(u);
        break :blk true;
    } else false;
    if (has_origin) {
        try startGitJob(ed, .set_remote, "setting remote", &.{&.{ "git", "remote", "set-url", "origin", trimmed }});
    } else {
        try startGitJob(ed, .set_remote, "adding remote", &.{&.{ "git", "remote", "add", "origin", trimmed }});
    }
}

/// Closes a boxed prompt and returns its text (owned), restoring the mode.
pub fn takePromptText(ed: *Editor) !?[]u8 {
    var sp = ed.search_prompt orelse return null;
    ed.search_prompt = null;
    defer sp.input.deinit(ed.gpa);
    ed.mode = sp.return_mode;
    ed.view.cursor = sp.origin;
    return try ed.gpa.dupe(u8, sp.input.items());
}

/// Re-reads HEAD for every buffer (after committing outside the editor).
pub fn reloadGit(ed: *Editor) void {
    blame.dropAllBlames(ed);
    for (ed.buffers.items) |b| {
        if (b.git) |*g| g.deinit(ed.gpa);
        b.git = null;
        loadGitBase(ed, b);
    }
    updateGit(ed);
}

/// Recomputes the current buffer's diff if it changed.
pub fn updateGit(ed: *Editor) void {
    const b = ed.buffer;
    if (b.git) |*g| g.update(ed.gpa, &b.text, b.edit_version) catch {};
    row_model.validateGhost(ed);
}

/// The hunk at the cursor: the one whose ghost line it is on, whose new lines
/// contain its line, or a deletion right next to it.
pub fn hunkAtCursor(ed: *Editor) ?diff.Hunk {
    if (ed.ghost) |g| return row_model.ghostHunk(ed, g.line);
    const g = ed.buffer.git orelse return null;
    const line = ed.cursorLine();
    for (g.hunks.items) |h| {
        if (h.new_count > 0 and line >= h.new_start and line < h.new_start + h.new_count) return h;
        if (h.new_count == 0 and (line == h.new_start or line + 1 == h.new_start)) return h;
    }
    return null;
}

/// Puts a hunk's HEAD text back in place of the buffer's version (undoable).
pub fn restoreHunk(ed: *Editor, h: diff.Hunk) !void {
    const g = &(ed.buffer.git orelse return);
    var old: std.ArrayList(u8) = .empty;
    defer old.deinit(ed.gpa);
    for (0..h.old_count) |i| {
        if (i > 0) try old.append(ed.gpa, '\n');
        try old.appendSlice(ed.gpa, g.baseLine(h.old_start + i));
    }
    ed.ghost = null;
    const t = ed.text();
    if (h.new_count > 0) {
        var start = t.lineStart(h.new_start);
        var end = t.lineEnd(h.new_start + h.new_count - 1);
        if (h.old_count == 0) {
            // Pure addition: remove the lines and one line break.
            if (end < t.len()) end += 1 else if (start > 0) start -= 1;
            try ed.deleteRange(start, end);
        } else {
            try ed.deleteRange(start, end);
            try ed.insertAt(start, old.items);
        }
    } else if (h.new_start < t.lineCount() and t.len() > 0) {
        try old.append(ed.gpa, '\n');
        try ed.insertAt(t.lineStart(h.new_start), old.items);
    } else {
        const at = t.len();
        if (at > 0) try old.insert(ed.gpa, 0, '\n');
        try ed.insertAt(at, old.items);
    }
    ed.setCursor(motions.firstNonBlank(t, @min(h.new_start, t.lineCount() - 1)));
    updateGit(ed);
}

/// Jumps to the next/previous hunk's first line.
pub fn jumpHunk(ed: *Editor, forward: bool) void {
    const g = ed.buffer.git orelse return ed.setMessage(.info, "not in a git repository", .{});
    const line = ed.cursorLine();
    var target: ?usize = null;
    for (g.hunks.items) |h| {
        const at: usize = h.new_start;
        if (forward and at > line) {
            target = at;
            break;
        }
        if (!forward and at < line) target = at;
    }
    const t = ed.text();
    const l = @min(target orelse return ed.setMessage(.info, "no more changes", .{}), t.lineCount() - 1);
    ed.ghost = null;
    row_model.revealLine(ed, l);
    ed.setCursor(motions.firstNonBlank(t, l));
}

/// Yanks ghost lines `from..to` (inclusive) before `line`, linewise.
pub fn yankGhostLines(ed: *Editor, line: usize, from: u32, to: u32, register: ?u8) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(ed.gpa);
    var k = @min(from, to);
    while (k <= @max(from, to)) : (k += 1) {
        try buf.appendSlice(ed.gpa, row_model.ghostText(ed, line, k));
        try buf.append(ed.gpa, '\n');
    }
    try ed.registers.store(register, .yank, buf.items, true);
    ed.setMessage(.info, "yanked {d} ghost line(s)", .{@max(from, to) - @min(from, to) + 1});
}
