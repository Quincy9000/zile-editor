//! Claude Code (`SPC a`): `claude` in a side panel, connected to the editor.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Text = @import("../core/Text.zig");
const motions = @import("../core/motions.zig");
const Git = @import("../git/Git.zig");
const Lsp = @import("../lsp/Lsp.zig");
const Claude = @import("../ai/Claude.zig");
const Syntax = @import("../syntax/Syntax.zig");
const Windows = @import("../Windows.zig");
const Terminal = @import("../terminal/Terminal.zig");
const formatting = @import("formatting.zig");
const notifications = @import("notifications.zig");
const window_ops = @import("window_ops.zig");
const project_ops = @import("project_ops.zig");
const Editor = @import("../Editor.zig");
const row_model = @import("row_model.zig");
const code_motion = @import("code_motion.zig");
const prompts = @import("prompts.zig");
const git_ops = @import("git_ops.zig");
const lsp_ops = @import("lsp_ops.zig");
const diagnostics = lsp_ops.diagnostics;

pub fn tickClaude(ed: *Editor) void {
    // Files changed by other programs (Claude, a build, git) reload when
    // they have no unsaved edits; checked at most once a second.
    const now = Io.Timestamp.now(ed.io, .awake);
    if (ed.last_disk_check.durationTo(now).nanoseconds > std.time.ns_per_s) {
        ed.last_disk_check = now;
        checkDiskChanges(ed);
    }
    const c = ed.claude orelse return;
    c.tick(ed);
    if (c.term) |t| if (!t.isRunning()) {
        // `claude` exited: its window closes.
        while (window_ops.windowShowing(ed, t)) |w| {
            window_ops.focusWindow(ed, w);
            window_ops.closeWindow(ed);
        }
        t.destroy();
        c.term = null;
        ed.setMessage(.info, "Claude Code exited (SPC a a starts it again)", .{});
    };
}

/// Reloads buffers whose files changed on disk (when they have no unsaved
/// edits of their own).
pub fn checkDiskChanges(ed: *Editor) void {
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        const known = b.disk_mtime orelse continue;
        if (b.modified) continue;
        const st = Io.Dir.cwd().statFile(ed.io, path, .{}) catch continue;
        if (st.mtime.nanoseconds == known.nanoseconds) continue;
        git_ops.reloadBuffer(ed, b) catch continue;
        notifications.notify(ed, .info, "reloaded {s} (changed on disk)", .{b.displayName()});
    }
}

/// `SPC a a`: shows Claude Code in a panel on the right (starting it, and
/// the connection, the first time), focuses it, or hides it if focused.
pub fn toggleClaude(ed: *Editor) !void {
    if (ed.claude == null) ed.claude = try Claude.start(ed);
    const c = ed.claude.?;
    if (c.term) |t| if (window_ops.windowShowing(ed, t)) |w| {
        if (w == ed.window) {
            window_ops.closeWindow(ed); // hidden; it keeps running
        } else window_ops.focusWindow(ed, w);
        return;
    };
    try showClaude(ed);
}

/// Makes sure the panel is open (and focused).
pub fn showClaude(ed: *Editor) !void {
    if (ed.claude == null) ed.claude = try Claude.start(ed);
    const c = ed.claude.?;
    if (c.term) |t| if (window_ops.windowShowing(ed, t)) |w| return window_ops.focusWindow(ed, w);
    if (c.term == null) {
        var env_buf: [64]u8 = undefined;
        const env = c.env(&env_buf);
        c.term = try Terminal.create(ed.gpa, ed.io, .{
            .argv = &.{ "/bin/sh", "-c", "exec claude" },
            .cwd = project_ops.projectRoot(ed),
            .cols = 80,
            .rows = 24,
            .fg = ed.term_fg,
            .bg = ed.term_bg,
            .env = &.{env},
            .wake = ed.wake_fn,
        });
    }
    window_ops.focusEditorWindow(ed);
    try window_ops.splitWindow(ed, .right);
    ed.window.term = c.term;
    ed.window.term_normal = false;
    // The panel takes about 40% of the width.
    Windows.resize(ed.window, .horizontal, -0.1);
}

/// Shows a proposed edit of `path` as a diff: a buffer holding the proposal
/// with the file as it is now as its base (removed lines show as ghost
/// lines, new ones are marked). The user can edit it before accepting.
pub fn openProposal(ed: *Editor, path: []const u8, contents: []const u8) !*Buffer {
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    const norm = try Git.normalize(ed.gpa, contents);
    defer ed.gpa.free(norm);
    try b.text.insert(ed.gpa, 0, norm);
    b.final_newline = contents.len == 0 or contents[contents.len - 1] == '\n';
    b.syntax = Syntax.forPath(path);
    b.project = project_ops.projectOf(ed, path);
    const rel = try ed.normalizePath(path);
    defer ed.gpa.free(rel);
    b.label = try std.fmt.allocPrint(ed.gpa, "Claude: {s}", .{rel});
    // The base: the file as the editor has it (unsaved edits included), else on disk.
    const base: []u8 = if (bufferForPath(ed, path)) |open| try ed.gpa.dupe(u8, open.text.slice(0, open.text.len())) else blk: {
        const raw = Io.Dir.cwd().readFileAlloc(ed.io, path, ed.gpa, .limited(64 << 20)) catch break :blk try ed.gpa.dupe(u8, "");
        defer ed.gpa.free(raw);
        break :blk try Git.normalize(ed.gpa, raw);
    };
    defer ed.gpa.free(base);
    b.git = .{ .base = try Text.init(ed.gpa, base) };
    try ed.buffers.append(ed.gpa, b);
    window_ops.focusEditorWindow(ed);
    ed.switchTo(b);
    git_ops.updateGit(ed);
    // Start at the first change.
    if (b.git.?.hunks.items.len > 0) {
        const line = @min(b.git.?.hunks.items[0].new_start, b.text.lineCount() - 1);
        row_model.revealLine(ed, line);
        ed.setCursor(motions.firstNonBlank(&b.text, line));
    }
    ed.setMessage(.info, "Claude proposes changes to {s}: SPC a y accept, SPC a n reject (edit it first if you like)", .{rel});
    return b;
}

/// Removes a proposal; windows showing it go back to the file.
pub fn closeProposal(ed: *Editor, b: *Buffer, path: []const u8) void {
    var still_open = false;
    for (ed.buffers.items) |o| still_open = still_open or o == b;
    if (!still_open) return;
    if (ed.buffer == b) ed.openFile(path) catch {};
    b.modified = false;
    ed.killBuffer(b) catch {};
}

/// The open buffer for `path` (absolute or relative), if any.
pub fn bufferForPath(ed: *Editor, path: []const u8) ?*Buffer {
    const norm = ed.normalizePath(path) catch return null;
    defer ed.gpa.free(norm);
    return formatting.findBuffer(ed, norm);
}

/// Claude's `openFile`: in an editor window, at `start_text` if given.
pub fn openFromClaude(ed: *Editor, path: []const u8, start_text: ?[]const u8) !void {
    window_ops.focusEditorWindow(ed);
    try ed.openFile(path);
    const s0 = start_text orelse return;
    if (s0.len == 0) return;
    const t = ed.text();
    if (std.mem.indexOf(u8, t.slice(0, t.len()), s0)) |at| {
        row_model.revealLine(ed, t.lineOf(at));
        ed.setCursor(at);
    }
}

/// The current selection for Claude (`selection_changed`), as JSON; null
/// when no file is focused. Lines and characters are 0-based, the end
/// exclusive.
pub fn selectionJson(ed: *Editor, gpa: Allocator) ?[]u8 {
    if (ed.window.term != null) return null;
    const path = ed.buffer.path orelse return null;
    const abs = ed.absolutePath(path) catch return null;
    defer ed.gpa.free(abs);
    const t = ed.text();
    var start = ed.view.cursor;
    var end = ed.view.cursor;
    if (ed.mode == .visual) {
        const r = code_motion.visualRange(ed);
        start = r.start;
        end = @min(r.end, t.len());
    }
    const pos = struct {
        fn of(x: *const Text, p: usize) struct { line: usize, character: usize } {
            const l = x.lineOf(p);
            return .{ .line = l, .character = p - x.lineStart(l) };
        }
    }.of;
    const url = std.fmt.allocPrint(gpa, "file://{s}", .{abs}) catch return null;
    defer gpa.free(url);
    return std.json.Stringify.valueAlloc(gpa, .{
        .text = t.slice(start, @min(end, start + (100 << 10))),
        .filePath = abs,
        .fileUrl = url,
        .selection = .{ .start = pos(t, start), .end = pos(t, end), .isEmpty = start == end },
    }, .{}) catch null;
}

/// Open files, for Claude's `getOpenEditors`.
pub fn openEditorsJson(ed: *Editor, gpa: Allocator) ![]u8 {
    const Tab = struct { uri: []const u8, isActive: bool, label: []const u8, isDirty: bool };
    var tabs: std.ArrayList(Tab) = .empty;
    defer {
        for (tabs.items) |tab| gpa.free(tab.uri);
        tabs.deinit(gpa);
    }
    for (ed.buffers.items) |b| {
        const path = b.path orelse continue;
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        try tabs.append(gpa, .{ .uri = try std.fmt.allocPrint(gpa, "file://{s}", .{abs}), .isActive = b == ed.buffer, .label = std.fs.path.basename(path), .isDirty = b.modified });
    }
    return std.json.Stringify.valueAlloc(gpa, .{ .tabs = tabs.items }, .{});
}

/// Language server diagnostics, for Claude's `getDiagnostics` (one file's,
/// by `file://` URI, or all).
pub fn diagnosticsJson(ed: *Editor, gpa: Allocator, uri: ?[]const u8) ![]u8 {
    const Pos = struct { line: u32, character: u32 };
    const D = struct { message: []const u8, severity: []const u8, range: struct { start: Pos, end: Pos }, source: []const u8 };
    const F = struct { uri: []u8, diagnostics: []D };
    var files: std.ArrayList(F) = .empty;
    defer {
        for (files.items) |f| {
            gpa.free(f.uri);
            gpa.free(f.diagnostics);
        }
        files.deinit(gpa);
    }
    const want: ?[]const u8 = if (uri) |u| (if (std.mem.startsWith(u8, u, "file://")) u[7..] else u) else null;
    for (ed.lsps.items) |l| {
        for (l.diagnostics.keys(), l.diagnostics.values()) |path, list| {
            const abs = try ed.absolutePath(path);
            defer ed.gpa.free(abs);
            if (want) |w| if (!std.mem.eql(u8, w, abs)) continue;
            const ds = try gpa.alloc(D, list.len);
            for (list, ds) |d, *o| o.* = .{
                .message = d.message,
                .severity = switch (d.severity) {
                    .err => "Error",
                    .warning => "Warning",
                    .info => "Information",
                    .hint => "Hint",
                },
                .range = .{ .start = .{ .line = d.line, .character = d.col }, .end = .{ .line = d.end_line, .character = d.end_col } },
                .source = Lsp.servers[l.index].name,
            };
            try files.append(gpa, .{ .uri = try std.fmt.allocPrint(gpa, "file://{s}", .{abs}), .diagnostics = ds });
        }
    }
    return std.json.Stringify.valueAlloc(gpa, files.items, .{});
}

/// `SPC a s`: mentions the selected lines (visual mode) or the file in
/// Claude's prompt, and shows the panel.
pub fn claudeMention(ed: *Editor) !void {
    const target = try claudeTarget(ed) orelse return;
    defer ed.gpa.free(target.path);
    try showClaude(ed);
    ed.claude.?.mention(target.path, target.lines);
}

pub const ClaudeTarget = struct { path: []u8, lines: ?[2]usize };

/// The file (absolute) and lines (the visual selection's) to send.
pub fn claudeTarget(ed: *Editor) !?ClaudeTarget {
    if (ed.window.term != null) return null;
    const path = ed.buffer.path orelse {
        ed.setMessage(.info, "save the file first: Claude refers to files by path", .{});
        return null;
    };
    const abs = try ed.absolutePath(path);
    var lines: ?[2]usize = null;
    if (ed.mode == .visual) {
        const t = ed.text();
        lines = .{ t.lineOf(@min(ed.view.anchor, ed.view.cursor)), t.lineOf(@max(ed.view.anchor, ed.view.cursor)) };
        code_motion.exitVisual(ed);
    }
    return .{ .path = abs, .lines = lines };
}

/// `SPC a i`: asks for an instruction to send along with the selection.
pub fn claudeAskPrompt(ed: *Editor) !void {
    const target = try claudeTarget(ed) orelse return;
    if (ed.claude_ask) |a| ed.gpa.free(a.path);
    ed.claude_ask = .{ .path = target.path, .lines = target.lines };
    prompts.startSearch(ed, true, .ask_claude);
}

pub fn finishAskClaude(ed: *Editor) !void {
    const raw = try git_ops.takePromptText(ed) orelse return;
    defer ed.gpa.free(raw);
    const ask = ed.claude_ask orelse return;
    ed.claude_ask = null;
    defer ed.gpa.free(ask.path);
    const instruction = std.mem.trim(u8, raw, " \t");
    try showClaude(ed);
    const c = ed.claude.?;
    c.mention(ask.path, ask.lines);
    // Typed into Claude's prompt, after the mention; <CR> in the panel sends it.
    if (instruction.len > 0) if (c.term) |t| t.paste(instruction);
}

/// `SPC a y` / `SPC a n`: accepts or rejects the proposal shown (or shows
/// the first one waiting, if another buffer is shown).
pub fn claudeResolve(ed: *Editor, accept: bool) void {
    const c = ed.claude orelse return ed.setMessage(.info, "no proposed changes", .{});
    if (c.diffFor(ed.buffer)) |i| return c.resolve(ed, i, accept);
    if (c.diffs.items.len == 0) return ed.setMessage(.info, "no proposed changes", .{});
    window_ops.focusEditorWindow(ed);
    ed.switchTo(c.diffs.items[0].buffer);
    ed.setMessage(.info, "Claude's proposal for {s}: SPC a y accept, SPC a n reject", .{std.fs.path.basename(c.diffs.items[0].path)});
}
