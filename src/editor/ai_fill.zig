//! AI completion asked for by hand (`SPC a f`; `<A-f>` while typing): a
//! model writes what belongs at the cursor, and it shows there as gray
//! text to take (`<A-;>` all of it, `<A-l>` a line, `<A-Right>` a
//! character) or drop (`<Esc>`, or go on typing something else). Nothing
//! is put in the file until it is taken.
//!
//! Who answers is `ai_backend`: the local model, Anthropic's (`ai_model`)
//! when $ANTHROPIC_API_KEY is set, or DeepSeek's (`deepseek_model`) when
//! $DEEPSEEK_API_KEY is. `SPC a b` picks, and the pick is remembered
//! (written to config.zon as `aibackend`). The asking itself is
//! `ai/fill.zig`; this is the editor's side of it: where the cursor is,
//! what is shown, what a key does.

const std = @import("std");
const fill = @import("../ai/fill.zig");
const ai_ghost = @import("ai_ghost.zig");
const code_motion = @import("code_motion.zig");
const commands = @import("../commands.zig");
const notifications = @import("notifications.zig");
const settings = @import("../config/settings.zig");
const Buffer = @import("../core/Buffer.zig");
const Editor = @import("../Editor.zig");

pub const Backend = fill.Backend;

/// A file larger than this isn't sent (Anthropic gets the whole file).
const max_file = 1 << 20;

/// A completion on show, not in the file.
pub const Preview = struct {
    buffer: *Buffer,
    pos: usize,
    /// Owned.
    text: []u8,
    /// Who wrote it.
    backend: Backend,
};

const Asked = struct { buffer: *Buffer, pos: usize, version: u64, backend: Backend };

pub const State = struct {
    /// The question on its way, and where it was asked: its answer is for
    /// that spot, in the buffer as it was.
    job: ?*fill.Job = null,
    asked: ?Asked = null,
    preview: ?Preview = null,
    /// The key and the network: tests put their own here.
    key: *const fn (Backend) ?[]const u8 = envKey,
    transport: fill.Transport = fill.http,

    pub fn deinit(s: *State, gpa: std.mem.Allocator) void {
        if (s.job) |j| j.destroy();
        if (s.preview) |p| gpa.free(p.text);
        s.job = null;
        s.asked = null;
        s.preview = null;
    }
};

/// `b`'s key, from the environment zile was started in (the first of its
/// variables that is set). Read when asked for; kept nowhere.
pub fn envKey(b: Backend) ?[]const u8 {
    const api = fill.apiOf(b) orelse return null;
    for (api.key_names) |name| {
        var z: [64]u8 = undefined;
        if (name.len >= z.len) continue;
        @memcpy(z[0..name.len], name);
        z[name.len] = 0;
        const v = std.mem.span(std.c.getenv(z[0..name.len :0]) orelse continue);
        if (fill.hasKey(v)) return v;
    }
    return null;
}

/// Whether `b` can be asked now (a service: only with its key).
pub fn available(ed: *const Editor, b: Backend) bool {
    return fill.available(b, ed.ai_request.key(b));
}

/// The backend that answers. When Anthropic is selected and its key has
/// gone, that is the local model from here on, and it is said, once.
pub fn selected(ed: *Editor) Backend {
    const wanted = ed.options.ai_backend;
    const c = fill.choose(wanted, ed.ai_request.key(wanted));
    if (c.fell_back) {
        ed.options.ai_backend = .local;
        notifications.notify(ed, .info, "No {s}: the local model answers", .{fill.keyName(wanted)});
    }
    return c.backend;
}

/// `SPC a b`'s choice, remembered: it is written to config.zon as
/// `aibackend`, so it is the one zile starts with. One that can't be
/// asked isn't taken.
pub fn setBackend(ed: *Editor, b: Backend) void {
    if (!available(ed, b)) {
        return ed.setMessage(.err, "{s} needs {s} in the environment zile starts in", .{ b.title(), fill.keyName(b) });
    }
    ed.options.ai_backend = b;
    const model = config(ed, b).modelName();
    const value = switch (b) {
        inline else => |tag| "." ++ @tagName(tag),
    };
    if (settings.store(ed, "aibackend", value)) |_| {
        ed.setMessage(.info, "AI completion: {s} ({s}), kept in config.zon", .{ b.title(), model });
    } else |err| switch (err) {
        error.ConfigHasAMistake => ed.setMessage(.err, "AI completion: {s} ({s}) until zile closes: config.zon has a mistake in it (SPC o), so it wasn't written", .{ b.title(), model }),
        else => ed.setMessage(.err, "AI completion: {s} ({s}) until zile closes: config.zon couldn't be written ({s})", .{ b.title(), model, @errorName(err) }),
    }
}

pub const Row = struct { text: []const u8, detail: []const u8 };

/// A row of `SPC a b`: `b` and its model, and whether it is the one in
/// use or can't be (in `buf`).
pub fn row(ed: *Editor, b: Backend, buf: []u8) Row {
    const text = std.fmt.bufPrint(buf, "{s}: {s}", .{ b.title(), config(ed, b).modelName() }) catch b.title();
    if (!available(ed, b)) return .{ .text = text, .detail = "no API key" };
    const current = selectedQuietly(ed) == b;
    return .{ .text = text, .detail = if (current) "current" else "" };
}

/// The backend that answers, nothing said.
fn selectedQuietly(ed: *const Editor) Backend {
    const wanted = ed.options.ai_backend;
    return fill.choose(wanted, ed.ai_request.key(wanted)).backend;
}

/// The model `b` is asked for: config.zon's, else the service's own.
fn modelOf(ed: *const Editor, b: Backend) []const u8 {
    const set = switch (b) {
        .local => "",
        .anthropic => ed.options.ai_model,
        .deepseek => ed.options.deepseek_model,
    };
    if (set.len > 0) return set;
    return if (fill.apiOf(b)) |api| api.model else "";
}

fn config(ed: *Editor, b: Backend) fill.Config {
    const local = ai_ghost.aiConfig();
    return .{
        .backend = b,
        .host = local.host,
        .local_model = local.model,
        .model = modelOf(ed, b),
        // The key goes only to the one request that needs it.
        .key = ed.ai_request.key(b) orelse "",
    };
}

/// Something is being asked or shown: the suggestions that come while
/// typing wait meanwhile.
pub fn busy(ed: *const Editor) bool {
    return ed.ai_request.job != null or ed.ai_request.preview != null;
}

fn dropPreview(ed: *Editor) void {
    const p = ed.ai_request.preview orelse return;
    ed.gpa.free(p.text);
    ed.ai_request.preview = null;
}

/// Stops the question on its way (its request is abandoned).
fn cancel(ed: *Editor) void {
    const j = ed.ai_request.job orelse return;
    j.destroy();
    ed.ai_request.job = null;
    ed.ai_request.asked = null;
}

/// The cursor is where the question was asked, in the text as it was.
fn stillThere(ed: *const Editor, a: Asked) bool {
    return ed.buffer == a.buffer and ed.mode == .insert and ed.view.cursor == a.pos and ed.buffer.edit_version == a.version;
}

/// The command (`SPC a f`, `<A-f>`): asks for what belongs at the cursor.
/// While an answer is on its way, stops asking instead. From normal mode
/// the spot is after the cursor's character, as `a` has it.
pub fn press(ed: *Editor) !void {
    const s = &ed.ai_request;
    if (s.job != null) {
        cancel(ed);
        return ed.setMessage(.info, "AI completion: stopped asking", .{});
    }
    if (ed.cmd_float != null) return;
    if (ed.window.term != null or ed.buffer.read_only) return ed.setMessage(.info, "nothing here for a model to complete", .{});
    if (ed.cursors.items.len > 0) return ed.setMessage(.info, "AI completion works at one cursor", .{});
    dropPreview(ed);
    ai_ghost.clearAiSuggestion(ed);
    if (ed.mode == .visual) code_motion.exitVisual(ed);
    if (ed.mode != .insert) {
        const c = commands.find("insert_after") orelse return;
        try ed.runCommand(c);
        if (ed.mode != .insert) return;
    }
    const t = ed.text();
    if (t.len() > max_file) return ed.setMessage(.err, "AI completion: this file is too large to send ({d} KB; the most is {d})", .{ t.len() / 1024, max_file / 1024 });

    const backend = selected(ed);
    const pos = ed.view.cursor;
    const tail: []const u8 = if (ed.buffer.final_newline) "\n" else "";
    // A service reads the whole file; the local model, the stretch around
    // the cursor it is given while typing too (it holds no more).
    const from: usize, const to: usize = switch (backend) {
        .local => blk: {
            const w = ai_ghost.window(ed, pos);
            break :blk .{ w.from, w.to };
        },
        else => .{ 0, t.len() },
    };
    const suffix = try std.mem.concat(ed.gpa, u8, &.{ t.slice(pos, to), if (to == t.len()) tail else "" });
    defer ed.gpa.free(suffix);
    const q: fill.Query = .{ .prefix = t.slice(from, pos), .suffix = suffix, .file = std.fs.path.basename(ed.buffer.displayName()) };
    s.job = fill.Job.start(ed.gpa, ed.io, ed.wake_fn, s.transport, config(ed, backend), q) catch |err| {
        return ed.setMessage(.err, "AI completion couldn't start ({s})", .{@errorName(err)});
    };
    s.asked = .{ .buffer = ed.buffer, .pos = pos, .version = ed.buffer.edit_version, .backend = backend };
}

/// After each key: a question whose spot was left (the cursor moved, the
/// text changed, insert mode ended) is stopped, and a completion on show
/// that no longer fits where the cursor is goes.
pub fn afterKey(ed: *Editor) void {
    const s = &ed.ai_request;
    if (s.asked) |a| if (s.job != null and !stillThere(ed, a)) {
        cancel(ed);
        ed.setMessage(.info, "AI completion: stopped asking (the cursor moved on)", .{});
    };
    if (s.preview != null and previewHere(ed) == null) dropPreview(ed);
}

/// Each tick: the answer, when it has come, becomes the completion on
/// show, or what went wrong is said.
pub fn poll(ed: *Editor) void {
    const s = &ed.ai_request;
    const j = s.job orelse return;
    if (!j.finished()) return;
    const a = s.asked.?;
    defer cancel(ed);
    if (!stillThere(ed, a)) return;
    switch (j.outcome) {
        // In the status line: it has room for what the backend said.
        .failed => |why| ed.setMessage(.err, "{s}", .{why}),
        .text => |text| {
            if (std.mem.trim(u8, text, " \t\r\n").len == 0) {
                return ed.setMessage(.info, "AI completion: {s} has nothing to add here", .{a.backend.title()});
            }
            // The small local model drifting into Chinese or Japanese in a
            // file that has none: said, not shown.
            if (a.backend == .local) {
                const w = ai_ghost.window(ed, a.pos);
                if (@import("../ai/Ghost.zig").foreignScript(text, ed.text().slice(w.from, w.to))) {
                    return ed.setMessage(.info, "AI completion: the local model answered in another language (CJK); dropped. Ask again, or try Anthropic (SPC a b)", .{});
                }
            }
            const owned = ed.gpa.dupe(u8, text) catch return;
            dropPreview(ed);
            s.preview = .{ .buffer = a.buffer, .pos = a.pos, .text = owned, .backend = a.backend };
        },
    }
}

/// What of the completion on show is still ahead of the cursor, if it
/// fits there (typing it out keeps the rest on show).
pub fn previewHere(ed: *const Editor) ?[]const u8 {
    const p = ed.ai_request.preview orelse return null;
    if (p.buffer != ed.buffer or ed.mode != .insert) return null;
    const c = ed.view.cursor;
    if (c < p.pos or c - p.pos > p.text.len) return null;
    if (!std.mem.eql(u8, ed.buffer.text.slice(p.pos, c), p.text[0 .. c - p.pos])) return null;
    const rest = p.text[c - p.pos ..];
    return if (rest.len > 0) rest else null;
}

/// Takes the completion on show: all of it (one undo step of its own), a
/// line, or a character. False when there is none.
pub fn accept(ed: *Editor, part: ai_ghost.AiPart) !bool {
    const rest = previewHere(ed) orelse return false;
    const taken = try ed.gpa.dupe(u8, ai_ghost.partOf(rest, part));
    defer ed.gpa.free(taken);
    if (part == .all) try ed.buffer.history.commit(ed.gpa);
    try ed.insertText(taken);
    if (part == .all) try ed.buffer.history.commit(ed.gpa);
    if (previewHere(ed) == null) dropPreview(ed);
    return true;
}

/// For the status line: that a model is being asked, or whose completion
/// is on show and the keys for it.
pub fn indicator(ed: *const Editor, buf: []u8) []const u8 {
    const s = &ed.ai_request;
    if (s.job != null) {
        const a = s.asked orelse return "";
        return std.fmt.bufPrint(buf, "asking {s}… (A-f stops)", .{a.backend.title()}) catch "";
    }
    if (previewHere(ed) != null) {
        return std.fmt.bufPrint(buf, "{s}: A-; takes it, Esc drops it", .{s.preview.?.backend.title()}) catch "";
    }
    return "";
}
