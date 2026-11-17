//! Rewriting a selection with Claude, in place (`SPC a w`): the lines are
//! selected, what to do with them is typed in the box, and what Claude
//! writes instead shows as a diff in the code window, to change, accept
//! (`SPC a y`) or drop (`SPC a n`). No conversation, no tools: one question
//! to `claude -p`, given the lines and what is around them.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const Editor = @import("../Editor.zig");
const claude_panel = @import("claude_panel.zig");
const code_motion = @import("code_motion.zig");
const notifications = @import("notifications.zig");
const project_ops = @import("project_ops.zig");
const run_popup = @import("run_popup.zig");
const state_files = @import("state_files.zig");

/// The key of the notification shown while Claude writes.
const toast: u64 = 0x636c617564_7277;
/// Lines given around the selection, before and after.
const context_before = 80;
const context_after = 40;

/// One question to the CLI, on its own thread.
const Job = struct {
    gpa: Allocator,
    io: Io,
    wake: *const fn () void,
    /// Owned.
    prompt: []u8,
    root: []u8,
    model: ?[]u8,
    thread: std.Thread = undefined,
    done: std.atomic.Value(bool) = .init(false),
    /// Valid once `done`: what it wrote (owned), or that it couldn't.
    out: []u8 = &.{},
    failed: bool = false,

    fn run(j: *Job) void {
        defer {
            j.done.store(true, .release);
            j.wake();
        }
        j.ask() catch {
            j.failed = true;
        };
    }

    fn ask(j: *Job) !void {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(j.gpa);
        // No tools: it only writes. Nothing can ask for permission.
        try argv.appendSlice(j.gpa, &.{ "claude", "-p", "--output-format", "text", "--tools", "", "--permission-prompts", "none" });
        if (j.model) |m| try argv.appendSlice(j.gpa, &.{ "--model", m });
        var child = try std.process.spawn(j.io, .{ .argv = argv.items, .cwd = .{ .path = j.root }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
        defer child.kill(j.io);
        if (child.stdin) |in| {
            in.writeStreamingAll(j.io, j.prompt) catch {};
            in.close(j.io);
            child.stdin = null;
        }
        var out: std.ArrayList(u8) = .empty;
        errdefer out.deinit(j.gpa);
        var chunk: [16 * 1024]u8 = undefined;
        while (true) {
            const n = child.stdout.?.readStreaming(j.io, &.{&chunk}) catch break;
            try out.appendSlice(j.gpa, chunk[0..n]);
        }
        if (out.items.len == 0) return error.Nothing;
        j.out = try out.toOwnedSlice(j.gpa);
    }

    fn destroy(j: *Job) void {
        j.thread.join();
        j.gpa.free(j.prompt);
        j.gpa.free(j.root);
        if (j.model) |m| j.gpa.free(m);
        j.gpa.free(j.out);
        j.gpa.destroy(j);
    }
};

/// A rewrite, from the lines chosen to the diff answered.
pub const State = struct {
    /// The buffer and the lines (0-based, both included) to rewrite, and
    /// the buffer as it was then (a change since drops what comes back).
    target: ?*Buffer = null,
    lines: [2]usize = .{ 0, 0 },
    version: u64 = 0,
    /// Claude is writing.
    job: ?*Job = null,
    /// What it wrote, showing as a diff: that buffer, and the file's path
    /// (absolute, owned).
    proposal: ?*Buffer = null,
    path: ?[]u8 = null,

    pub fn deinit(s: *State, gpa: Allocator) void {
        if (s.job) |j| j.destroy();
        if (s.path) |p| gpa.free(p);
        s.* = .{};
    }
};

/// `SPC a w`: the selected lines (in normal mode, the cursor's line) are
/// what to rewrite; the box asks how.
pub fn prompt(ed: *Editor) !void {
    if (ed.cmd_float != null) return;
    const s = &ed.inline_edit;
    if (s.job != null) return ed.setMessage(.info, "Claude is still writing the last one", .{});
    if (ed.window.term != null or ed.buffer.read_only) return ed.setMessage(.info, "nothing here for Claude to rewrite", .{});
    drop(ed);
    const t = ed.text();
    s.lines = if (ed.mode == .visual)
        .{ t.lineOf(@min(ed.view.anchor, ed.view.cursor)), t.lineOf(@max(ed.view.anchor, ed.view.cursor)) }
    else
        .{ ed.cursorLine(), ed.cursorLine() };
    if (ed.mode == .visual) code_motion.exitVisual(ed);
    s.target = ed.buffer;
    s.version = ed.buffer.edit_version;
    try run_popup.editCommand(ed, "", .claude_inline, null);
}

/// The box's title: the lines it is about.
pub fn title(ed: *const Editor, buf: []u8) []const u8 {
    const s = &ed.inline_edit;
    const b = s.target orelse return "Rewrite with Claude";
    const name = std.fs.path.basename(b.displayName());
    return (if (s.lines[0] == s.lines[1])
        std.fmt.bufPrint(buf, "Rewrite {s}:{d} with Claude", .{ name, s.lines[0] + 1 })
    else
        std.fmt.bufPrint(buf, "Rewrite {s}:{d}-{d} with Claude", .{ name, s.lines[0] + 1, s.lines[1] + 1 })) catch "Rewrite with Claude";
}

/// What Claude is asked: the instruction, the lines, and what is around
/// them. Caller frees.
pub fn question(ed: *Editor, b: *const Buffer, lines: [2]usize, instruction: []const u8) ![]u8 {
    const t = &b.text;
    const last = @min(lines[1], t.lineCount() -| 1);
    const before_from = lines[0] -| context_before;
    const after_to = @min(last + context_after, t.lineCount() -| 1);
    const before = if (lines[0] > 0) t.slice(t.lineStart(before_from), t.lineEnd(lines[0] - 1)) else "";
    const after = if (last < after_to) t.slice(t.lineStart(last + 1), t.lineEnd(after_to)) else "";
    return std.fmt.allocPrint(ed.gpa,
        \\You are rewriting part of a file in the user's editor. Rewrite the text between <selected> and </selected> as the instruction says.
        \\Reply with only the text that replaces it: no explanation, no code fence, nothing before or after. Keep its indentation. The lines around it are there so you know where it sits; do not repeat them.
        \\
        \\File: {s}
        \\Instruction: {s}
        \\
        \\<before>
        \\{s}
        \\</before>
        \\<selected>
        \\{s}
        \\</selected>
        \\<after>
        \\{s}
        \\</after>
        \\
    , .{ b.displayName(), instruction, before, t.slice(t.lineStart(lines[0]), t.lineEnd(last)), after });
}

/// Enter in the box: Claude is asked.
pub fn start(ed: *Editor, instruction: []const u8) !void {
    const s = &ed.inline_edit;
    const b = s.target orelse return;
    if (!state_files.bufferAlive(ed, b) or b.edit_version != s.version) {
        s.target = null;
        return ed.setMessage(.info, "the text changed meanwhile: select it again", .{});
    }
    // (The tests never ask a real Claude: they give its answer to `finish`.)
    if (@import("builtin").is_test) return;
    const q = try question(ed, b, s.lines, instruction);
    errdefer ed.gpa.free(q);
    const root = try ed.gpa.dupe(u8, project_ops.projectRoot(ed));
    errdefer ed.gpa.free(root);
    const model: ?[]u8 = if (ed.chat) |c| (if (c.want_model) |m| try ed.gpa.dupe(u8, m) else null) else null;
    errdefer if (model) |m| ed.gpa.free(m);
    const j = try ed.gpa.create(Job);
    j.* = .{ .gpa = ed.gpa, .io = ed.io, .wake = ed.wake_fn, .prompt = q, .root = root, .model = model };
    j.thread = std.Thread.spawn(.{}, Job.run, .{j}) catch |err| {
        ed.gpa.destroy(j);
        return err;
    };
    s.job = j;
    notifications.progress(ed, toast, true, "Claude is rewriting {d} line{s}…", .{ s.lines[1] - s.lines[0] + 1, if (s.lines[1] == s.lines[0]) "" else "s" });
}

/// Takes what Claude wrote, when it has.
pub fn tick(ed: *Editor) void {
    const s = &ed.inline_edit;
    const j = s.job orelse return;
    if (!j.done.load(.acquire)) return;
    s.job = null;
    defer j.destroy();
    if (j.failed) {
        notifications.progress(ed, toast, false, "Claude could not rewrite it", .{});
        s.target = null;
        return;
    }
    notifications.progress(ed, toast, false, "Claude's rewrite is here: SPC a y accepts, SPC a n drops it", .{});
    finish(ed, j.out) catch |err| ed.setMessage(.err, "could not show Claude's rewrite: {s}", .{@errorName(err)});
}

/// What Claude wrote, without a code fence around it or blank lines at its
/// ends (it is asked for none, and adds them at times).
pub fn clean(text: []const u8) []const u8 {
    var t = std.mem.trim(u8, text, "\r\n");
    if (std.mem.startsWith(u8, std.mem.trimStart(u8, t, " \t"), "```")) {
        const first = std.mem.indexOfScalar(u8, t, '\n') orelse return "";
        t = t[first + 1 ..];
        if (std.mem.lastIndexOf(u8, t, "```")) |close| {
            if (std.mem.indexOfNone(u8, t[close + 3 ..], " \t\r\n") == null) t = t[0..close];
        }
        t = std.mem.trimEnd(u8, t, "\r\n");
    }
    return t;
}

/// `answer` is what Claude wrote for the lines: shown as a diff of the file
/// in the code window (a file without a name is changed at once: `u`
/// undoes it).
pub fn finish(ed: *Editor, answer: []const u8) !void {
    const s = &ed.inline_edit;
    const b = s.target orelse return;
    if (!state_files.bufferAlive(ed, b) or b.edit_version != s.version) {
        s.target = null;
        return ed.setMessage(.info, "the text changed while Claude wrote: its rewrite was dropped", .{});
    }
    const t = &b.text;
    const last = @min(s.lines[1], t.lineCount() -| 1);
    const from = t.lineStart(s.lines[0]);
    const to = t.lineEnd(last);
    // Its first line starts where the selection's did (the CLI trims the
    // start of what Claude writes, so that line's indentation is lost).
    const was = t.slice(from, to);
    const indent = was[0 .. std.mem.indexOfNone(u8, was, " \t") orelse was.len];
    const new = std.mem.trimStart(u8, clean(answer), " \t");
    const whole = try std.mem.concat(ed.gpa, u8, &.{ t.slice(0, from), indent, new, t.slice(to, t.len()), if (b.final_newline and t.len() > 0) "\n" else "" });
    defer ed.gpa.free(whole);
    const path = b.path orelse {
        // No file to show a diff of.
        s.target = null;
        try apply(ed, b, std.mem.trimEnd(u8, whole, "\n"));
        return ed.setMessage(.info, "rewritten by Claude (u undoes it)", .{});
    };
    const abs = try ed.absolutePath(path);
    errdefer ed.gpa.free(abs);
    s.proposal = try claude_panel.openProposal(ed, abs, whole);
    s.path = abs;
}

/// Makes `b`'s text `new`, as one change (what differs between them: the
/// start and the end they share are left alone).
fn apply(ed: *Editor, b: *Buffer, new: []const u8) !void {
    if (ed.buffer != b) ed.switchTo(b);
    const old = try ed.gpa.dupe(u8, b.text.slice(0, b.text.len()));
    defer ed.gpa.free(old);
    var pre: usize = 0;
    while (pre < old.len and pre < new.len and old[pre] == new[pre]) pre += 1;
    var post: usize = 0;
    while (post < old.len - pre and post < new.len - pre and old[old.len - 1 - post] == new[new.len - 1 - post]) post += 1;
    // (Not in the middle of a character.)
    while (pre > 0 and (old[pre - 1] & 0x80) != 0) pre -= 1;
    while (post > 0 and (old[old.len - post] & 0xc0) == 0x80) post -= 1;
    try ed.deleteRangeKeepCursor(pre, old.len - post);
    try ed.insertAt(pre, new[pre .. new.len - post]);
    try ed.buffer.history.commit(ed.gpa);
    ed.buffer.modified = ed.buffer.history.isModified();
    ed.setCursor(@min(pre, ed.text().len()));
}

/// Forgets the rewrite that is showing (its diff goes).
fn drop(ed: *Editor) void {
    const s = &ed.inline_edit;
    if (s.proposal) |p| if (state_files.bufferAlive(ed, p)) claude_panel.closeProposal(ed, p, s.path.?);
    if (s.path) |p| ed.gpa.free(p);
    s.proposal = null;
    s.path = null;
    s.target = null;
}

/// `SPC a y` / `SPC a n` while a rewrite shows: taken into the file (as it
/// is in the diff now, if it was changed there) or dropped. False if none
/// shows.
pub fn resolve(ed: *Editor, accept: bool) bool {
    const s = &ed.inline_edit;
    const p = s.proposal orelse return false;
    if (!state_files.bufferAlive(ed, p)) {
        drop(ed);
        return false;
    }
    const b = s.target;
    const text = if (accept) ed.gpa.dupe(u8, p.text.slice(0, p.text.len())) catch return true else null;
    defer if (text) |x| ed.gpa.free(x);
    drop(ed);
    if (text) |new| if (b) |target| if (state_files.bufferAlive(ed, target)) {
        apply(ed, target, new) catch |err| ed.setMessage(.err, "could not take the rewrite: {s}", .{@errorName(err)});
        ed.setMessage(.info, "took Claude's rewrite (u undoes it; not saved yet)", .{});
        return true;
    };
    ed.setMessage(.info, "dropped Claude's rewrite", .{});
    return true;
}
