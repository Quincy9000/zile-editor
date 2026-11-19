//! Claude Code drawn by zile (`SPC a a`): the conversation is a list in a
//! panel docked along the bottom (where the pickers and the SQL results
//! go), a row for each thing said, each tool used, each thing asked
//! (`ai/Chat.zig` keeps them); beside the list, the whole of the selected
//! row. What you say is typed in the box under it (`SPC a i`).
//!
//! Only the panel's state and keys are here; `ui/picker_view.zig` draws it.

const std = @import("std");
const Io = std.Io;
const Chat = @import("../ai/Chat.zig");
const fill = @import("../ai/fill.zig");
const ai_fill = @import("ai_fill.zig");
const settings = @import("../config/settings.zig");
const Buffer = @import("../core/Buffer.zig");
const Syntax = @import("../syntax/Syntax.zig");
const Editor = @import("../Editor.zig");
const project_ops = @import("project_ops.zig");
const notifications = @import("notifications.zig");
const side_float = @import("side_float.zig");
const state_files = @import("state_files.zig");
const Claude = @import("../ai/Claude.zig");

/// The panel: what it shows of the conversation.
pub const Panel = struct {
    shown: bool = false,
    /// It has the keyboard.
    focus: bool = false,
    /// The selected row. `follow`: it is the last one, and stays the last
    /// as rows come.
    sel: usize = 0,
    follow: bool = true,
    /// The first row the list shows (the view keeps the selection in sight).
    top: usize = 0,
    /// The first line shown of the selected row's text; `tail`: its end
    /// instead (what is being written).
    scroll: usize = 0,
    tail: bool = true,
    /// How the panel was when the picker to answer Claude took its place,
    /// to put it back so.
    back: enum { no, shown, focused } = .no,
    /// `g` was typed: `gg` goes to the first row.
    pending_g: bool = false,
    /// From the last draw: how many lines the selected row's text is, and
    /// how many of them fit (half of that is Ctrl-d's step).
    lines: usize = 0,
    page: usize = 10,
    /// The conversation as it was last looked at, and what Claude was
    /// doing then.
    version: usize = 0,
    state: Chat.State = .idle,
    /// From the last draw: where the panel is, and where its text side
    /// starts (for the mouse).
    area: Editor.Windows.Rect = .{ .x = 0, .y = 0, .w = 0, .h = 0 },
    text_x: f32 = 0,

    pub const Side = enum { rows, text };

    /// The side of the panel the pointer is over, if it is over it.
    pub fn under(p: *const Panel, x: f32, y: f32) ?Side {
        if (!p.shown or y < p.area.y or y >= p.area.y + p.area.h or x < p.area.x or x >= p.area.x + p.area.w) return null;
        return if (x >= p.text_x) .text else .rows;
    }
};

/// The key of the notification shown while Claude waits for an answer.
const ask_toast: u64 = 0x636c617564_61736b;

fn chat(ed: *Editor) !*Chat {
    if (ed.chat == null) {
        ed.chat = try Chat.create(ed.gpa, ed.io, project_ops.projectRoot(ed), ed.wake_fn);
        ed.chat.?.environ = ed.environ;
        ed.chat.?.backend = ed.options.chat_backend;
        // (The tests never start a real CLI.)
        if (@import("builtin").is_test) ed.chat.?.offline = true;
    }
    const c = ed.chat.?;
    // config.zon changed who answers (saved from zile, or `SPC a d`).
    _ = c.setBackend(ed.options.chat_backend);
    return c;
}

/// Whether `b` can answer: Claude always (as the CLI is signed in), a
/// service with its key in zile's environment.
pub fn backendAvailable(ed: *const Editor, b: Chat.Backend) bool {
    _ = ed;
    const svc = b.service() orelse return true;
    return ai_fill.envKey(svc) != null;
}

/// `SPC a d`'s choice: who answers in the conversation from now on (a new
/// one), remembered in config.zon as `chatbackend`.
pub fn setBackend(ed: *Editor, b: Chat.Backend) void {
    if (!backendAvailable(ed, b)) {
        return ed.setMessage(.err, "{s} needs {s} in the environment zile starts in", .{ b.title(), fill.keyName(b.service().?) });
    }
    const changed = ed.options.chat_backend != b;
    ed.options.chat_backend = b;
    if (ed.chat) |c| _ = c.setBackend(b);
    const value = switch (b) {
        inline else => |tag| "." ++ @tagName(tag),
    };
    const what = if (changed) "answers from here on (a new conversation)" else "answers";
    if (settings.store(ed, "chatbackend", value)) |_| {
        ed.setMessage(.info, "{s} {s}, kept in config.zon", .{ b.title(), what });
    } else |err| switch (err) {
        error.ConfigHasAMistake => ed.setMessage(.err, "{s} {s} until zile closes: config.zon has a mistake in it (SPC o)", .{ b.title(), what }),
        else => ed.setMessage(.err, "{s} {s} until zile closes: config.zon couldn't be written ({s})", .{ b.title(), what, @errorName(err) }),
    }
}

/// The CLI, started if it wasn't (nothing is said to Claude by that): its
/// slash commands and models are known a moment later. It is told how to
/// reach zile's own server (`ai/Claude.zig`), which it can ask for the
/// diagnostics of the files that are open.
fn awake(ed: *Editor) !*Chat {
    const c = try chat(ed);
    if (!c.offline and c.mcp_config == null) connect: {
        if (ed.claude == null) ed.claude = Claude.start(ed) catch break :connect;
        const file = ed.claude.?.mcpConfigFile() orelse break :connect;
        c.mcp_config = ed.gpa.dupe(u8, file) catch break :connect;
        c.mcp_allowed = "mcp__ide__getDiagnostics";
    }
    c.wake_up();
    return c;
}

/// What something said to Claude is about: lines selected in a file.
pub const About = struct { path: []const u8, lines: [2]usize };

/// What Claude is told along with what is said, as its editor extensions
/// tell it: the lines selected (with their text), else the file in the
/// code window and where the cursor is. Caller frees.
fn context(ed: *Editor, about: ?About) !?[]u8 {
    if (about) |a| {
        const b = @import("claude_panel.zig").bufferForPath(ed, a.path) orelse return null;
        const t = &b.text;
        const last = @min(a.lines[1], t.lineCount() -| 1, a.lines[0] + 400);
        if (a.lines[0] > last) return null;
        return try std.fmt.allocPrint(ed.gpa, "<ide_selection>The user selected the lines {d} to {d} from {s}:\n{s}\n\nThis may or may not be related to the current task.</ide_selection>", .{
            a.lines[0] + 1, last + 1, a.path, t.slice(t.lineStart(a.lines[0]), t.lineEnd(last)),
        });
    }
    if (ed.window.term != null or ed.buffer.read_only) return null;
    const path = ed.buffer.path orelse return null;
    const abs = try ed.absolutePath(path);
    defer ed.gpa.free(abs);
    return try std.fmt.allocPrint(ed.gpa, "<ide_opened_file>The user opened the file {s} in the IDE (the cursor is on line {d}). This may or may not be related to the current task.</ide_opened_file>", .{ abs, ed.cursorLine() + 1 });
}

/// An edit Claude asks to make, shown in the code window as a diff
/// (`claude_panel.openProposal`) to look at, change, and accept or refuse.
pub const Proposal = struct {
    /// The request it is for (owned).
    ask: []u8,
    buffer: *Buffer,
    /// The file (absolute, owned), as it is on disk (owned), and the
    /// proposal as it was shown (owned), to know if it was changed here.
    path: []u8,
    base: []u8,
    shown: []u8,

    fn deinit(p: Proposal, gpa: std.mem.Allocator) void {
        gpa.free(p.ask);
        gpa.free(p.path);
        gpa.free(p.base);
        gpa.free(p.shown);
    }
};

/// The file a tool waiting for permission would write, and what would be
/// in it (in `a`): Write's content; Edit's replacement made in the file as
/// it is on disk. Null for other tools, or an edit that doesn't fit.
fn editOf(ed: *Editor, a: std.mem.Allocator, ask: Chat.Ask) ?struct { path: []const u8, base: []const u8, contents: []const u8 } {
    const write = std.mem.eql(u8, ask.tool, "Write");
    if (!write and !std.mem.eql(u8, ask.tool, "Edit")) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, ask.input, .{}) catch return null;
    if (v != .object) return null;
    const str = struct {
        fn get(o: std.json.Value, name: []const u8) ?[]const u8 {
            const f = o.object.get(name) orelse return null;
            return if (f == .string) f.string else null;
        }
    }.get;
    const path = str(v, "file_path") orelse return null;
    if (!std.fs.path.isAbsolute(path)) return null;
    const base = Io.Dir.cwd().readFileAlloc(ed.io, path, a, .limited(16 << 20)) catch "";
    if (write) return .{ .path = path, .base = base, .contents = str(v, "content") orelse return null };
    const old = str(v, "old_string") orelse return null;
    const new = str(v, "new_string") orelse return null;
    if (old.len == 0 or std.mem.indexOf(u8, base, old) == null) return null;
    const all = if (v.object.get("replace_all")) |r| r == .bool and r.bool else false;
    const contents = if (all) std.mem.replaceOwned(u8, a, base, old, new) catch return null else blk: {
        const at = std.mem.indexOf(u8, base, old).?;
        break :blk std.mem.concat(a, u8, &.{ base[0..at], new, base[at + old.len ..] }) catch return null;
    };
    return .{ .path = path, .base = base, .contents = contents };
}

/// The proposal that is showing for the tool waiting now, if any.
fn proposal(ed: *Editor) ?*Proposal {
    const p = &(ed.chat_proposal orelse return null);
    const c = ed.chat orelse return null;
    const a = c.asking() orelse return null;
    if (!std.mem.eql(u8, p.ask, a.id) or !state_files.bufferAlive(ed, p.buffer)) return null;
    return p;
}

fn dropProposal(ed: *Editor) void {
    const p = ed.chat_proposal orelse return;
    ed.chat_proposal = null;
    if (state_files.bufferAlive(ed, p.buffer)) @import("claude_panel.zig").closeProposal(ed, p.buffer, p.path);
    p.deinit(ed.gpa);
}

/// Shows the edit the waiting tool would make, as a diff in the code
/// window. False if it isn't an edit that can be shown.
fn showEdit(ed: *Editor, ask: Chat.Ask) !bool {
    var arena: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena.deinit();
    const e = editOf(ed, arena.allocator(), ask) orelse return false;
    dropProposal(ed);
    hide(ed);
    const b = try @import("claude_panel.zig").openProposal(ed, e.path, e.contents);
    var p: Proposal = .{ .ask = &.{}, .buffer = b, .path = &.{}, .base = &.{}, .shown = &.{} };
    errdefer p.deinit(ed.gpa);
    p.ask = try ed.gpa.dupe(u8, ask.id);
    p.path = try ed.gpa.dupe(u8, e.path);
    p.base = try ed.gpa.dupe(u8, e.base);
    p.shown = try ed.gpa.dupe(u8, b.text.slice(0, b.text.len()));
    ed.chat_proposal = p;
    return true;
}

/// `SPC a y` / `SPC a n` on the edit that is showing: allowed (as it is
/// in the editor now, if it was changed there) or refused.
fn finishEdit(ed: *Editor, c: *Chat, accept: bool) !void {
    const p = ed.chat_proposal.?;
    defer dropProposal(ed);
    if (!accept) return c.answer(.refuse);
    const t = &p.buffer.text;
    const now = t.slice(0, t.len());
    if (std.mem.eql(u8, now, p.shown)) return c.answer(.allow);
    // Changed here: the whole file as it should be (an Edit replacing all
    // of what is there; a Write, where there is nothing yet).
    const text = try std.mem.concat(ed.gpa, u8, &.{ now, if (p.buffer.final_newline and now.len > 0) "\n" else "" });
    defer ed.gpa.free(text);
    const input = if (p.base.len > 0 and std.mem.eql(u8, c.asking().?.tool, "Edit"))
        try std.json.Stringify.valueAlloc(ed.gpa, .{ .file_path = p.path, .old_string = p.base, .new_string = text }, .{})
    else if (std.mem.eql(u8, c.asking().?.tool, "Write"))
        try std.json.Stringify.valueAlloc(ed.gpa, .{ .file_path = p.path, .content = text }, .{})
    else
        return c.answer(.allow);
    defer ed.gpa.free(input);
    try c.answerWith(input);
}

/// Puts the panel on screen. The code keeps the keyboard unless `focus`.
pub fn show(ed: *Editor, focus: bool) !void {
    _ = try awake(ed);
    // One panel along the bottom at a time.
    @import("pads.zig").hide(ed);
    ed.chat_panel.shown = true;
    if (focus) ed.chat_panel.focus = true;
}

/// Takes the panel off the screen (the conversation goes on).
pub fn hide(ed: *Editor) void {
    side_float.close(ed);
    ed.chat_panel.shown = false;
    ed.chat_panel.focus = false;
}

/// `SPC a a`: shows the conversation and goes into it; from it, hides it.
pub fn toggle(ed: *Editor) !void {
    if (ed.chat_panel.shown and ed.chat_panel.focus) return hide(ed);
    try show(ed, true);
    if (ed.chat.?.entries.items.len == 0) ed.setMessage(.info, "SPC a i: tell Claude something (it answers here)", .{});
}

/// Says `text` to Claude; the conversation is shown, the keyboard stays.
/// `about`: the lines it was said about, if any were selected.
pub fn tell(ed: *Editor, text: []const u8, about: ?About) !void {
    const c = try chat(ed);
    const told = context(ed, about) catch null;
    defer if (told) |t| ed.gpa.free(t);
    try show(ed, false);
    // What is said, and the answer to it, are what to look at.
    ed.chat_panel.follow = true;
    c.send(text, told) catch |err| switch (err) {
        error.NoApiKey => return ed.setMessage(.err, "{s} needs {s} in the environment zile starts in (SPC a d: who answers)", .{ c.backend.title(), fill.keyName(c.backend.service().?) }),
        else => return err,
    };
    tick(ed);
}

/// `SPC a y` / `SPC a n` while Claude is waiting for an answer (a tool
/// wants permission, or it has a question of its own). It is answered in
/// the panel, where what is asked is to be read: `SPC a y` allows what the
/// panel shows, and brings the panel up first when it doesn't (or when the
/// answer is one of several: a question). `SPC a n` refuses at once. An
/// edit is looked at in the code window first. False if nothing is waiting.
pub fn answer(ed: *Editor, yes: bool) bool {
    const c = ed.chat orelse return false;
    const a = c.asking() orelse return false;
    const p = &ed.chat_panel;
    // An edit: the first `SPC a y` shows it in the code window (to change
    // it there if need be), the second accepts it; the panel comes back.
    if (proposal(ed) != null) {
        const back = p.back;
        finishEdit(ed, c, yes) catch {};
        tick(ed);
        if (back != .no) show(ed, back == .focused) catch {};
        return true;
    }
    if (!yes) {
        reply(ed, .refuse);
        return true;
    }
    const was: @TypeOf(p.back) = if (p.shown) (if (p.focus) .focused else .shown) else .no;
    if (showEdit(ed, a) catch false) {
        p.back = was;
        return true;
    }
    if (a.question or !p.shown) face(ed, a) else reply(ed, .allow);
    return true;
}

/// Into the panel, on the row of what is asked, to answer it there.
fn face(ed: *Editor, a: Chat.Ask) void {
    show(ed, true) catch return;
    const c = ed.chat orelse return;
    for (c.entries.items, 0..) |*e, i| if (std.mem.eql(u8, e.id, a.id)) select(ed, i);
    if (a.question)
        ed.setMessage(.info, "Claude's question: the number of an answer picks it", .{})
    else
        ed.setMessage(.info, "Claude asks to use {s}: y allows, n refuses", .{a.tool});
}

fn reply(ed: *Editor, r: Chat.Reply) void {
    const c = ed.chat orelse return;
    c.answer(r) catch {};
    tick(ed);
}

/// The panel's keys while Claude waits: `y` allows, `a` allows from now on
/// (what the CLI suggests), `n` refuses; a question's answers are picked
/// by their numbers. False for any other key.
fn answerKey(ed: *Editor, cp: u21) bool {
    const c = ed.chat orelse return false;
    const a = c.asking() orelse return false;
    if (a.question) {
        if (cp < '1' or cp > '9') return false;
        var arena: std.heap.ArenaAllocator = .init(ed.gpa);
        defer arena.deinit();
        const q = c.question(arena.allocator()) orelse return false;
        if (cp - '1' >= q.options.len) return true;
        _ = c.choose(q.options[cp - '1'].label) catch {};
        tick(ed);
        return true;
    }
    switch (cp) {
        // (An edit is in the panel's text as a diff; Enter has it in the
        // code window, to change before it is accepted.)
        'y' => reply(ed, .allow),
        'a' => if (a.suggestions != null) reply(ed, .always) else ed.setMessage(.info, "nothing to allow from now on here: y allows it this once", .{}),
        'n' => reply(ed, .refuse),
        else => return false,
    }
    return true;
}

/// What `SPC a /`, `SPC a m` and `SPC a p` pick from.
pub const Menu = enum { commands, models, modes, efforts, usage, sessions };

/// `SPC a /` (`/` in the panel, or first in the box): Claude's slash
/// commands; the one taken starts the box (`/review `). `SPC a m` (`m`):
/// the models to choose from. `SPC a p` (`p`): how much Claude may do
/// without asking. The lists are the CLI's own.
pub fn menu(ed: *Editor, which: Menu) !void {
    const c = try awake(ed);
    c.poll();
    // (The limits as they are now, for the next look.)
    if (which == .usage) c.refresh();
    if (which == .modes) c.loadModes();
    if (which == .sessions) {
        c.listSessions();
        if (c.listed.len == 0) return ed.setMessage(.info, "no conversations with Claude in this project yet", .{});
    }
    const empty = switch (which) {
        .commands => c.commands.len == 0,
        .models => c.models.len == 0,
        .modes => c.modes.len == 0,
        .efforts => c.efforts().len == 0,
        .usage => !c.usage.known,
        .sessions => false,
    };
    if (empty) return ed.setMessage(.info, "Claude is starting: its {s} here in a moment", .{switch (which) {
        .commands => "commands are",
        .models => "models are",
        .modes => "permission modes are",
        .efforts => "effort levels are",
        .usage => "usage is",
        .sessions => "conversations are",
    }});
    try ed.openPicker(switch (which) {
        .commands => .claude_commands,
        .models => .claude_models,
        .modes => .claude_modes,
        .efforts => .claude_efforts,
        .usage => .claude_usage,
        .sessions => .claude_sessions,
    }, "");
}

/// A row of one of those pickers was taken.
pub fn menuPick(ed: *Editor, which: Menu, row: usize) !void {
    const c = ed.chat orelse return;
    switch (which) {
        .commands => {
            if (row >= c.commands.len) return;
            var buf: [256]u8 = undefined;
            const start = std.fmt.bufPrint(&buf, "/{s} ", .{c.commands[row].name}) catch return;
            try @import("claude_panel.zig").claudeAskWith(ed, start);
        },
        .models => {
            if (row >= c.models.len) return;
            const m = c.models[row];
            try c.setModel(m.name);
            ed.setMessage(.info, "Claude answers with {s} from now on", .{if (m.title.len > 0) m.title else m.name});
        },
        .modes => {
            if (row >= c.modes.len) return;
            try c.setMode(c.modes[row]);
            ed.setMessage(.info, "Claude's permission mode is {s} from now on", .{c.modes[row]});
        },
        .efforts => {
            const levels = c.efforts();
            if (row >= levels.len) return;
            try c.setEffort(levels[row]);
            ed.setMessage(.info, "Claude's effort is {s} from now on", .{levels[row]});
        },
        // Only to look at.
        .usage => {},
        .sessions => {
            if (row >= c.listed.len) return;
            try c.resumeSession(c.listed[row].id, c.listed[row].path);
            ed.chat_panel.follow = true;
            try show(ed, true);
            tick(ed);
            ed.setMessage(.info, "back in that conversation: what you say next carries on with it", .{});
        },
    }
}

/// "3h ago": how long since `at` (seconds since 1970).
pub fn ago(ed: *const Editor, at: i64, buf: []u8) []const u8 {
    const since = @max(Io.Timestamp.now(ed.io, .real).toSeconds() - at, 0);
    return (if (since >= 2 * 86400)
        std.fmt.bufPrint(buf, "{d} days ago", .{@divFloor(since, 86400)})
    else if (since >= 3600)
        std.fmt.bufPrint(buf, "{d}h ago", .{@divFloor(since, 3600)})
    else if (since >= 60)
        std.fmt.bufPrint(buf, "{d}m ago", .{@divFloor(since, 60)})
    else
        std.fmt.bufPrint(buf, "just now", .{})) catch "";
}

/// "in 2h 14m" until `at` (seconds since 1970), from now.
pub fn until(ed: *const Editor, at: i64, buf: []u8) []const u8 {
    if (at == 0) return "";
    const left = at - Io.Timestamp.now(ed.io, .real).toSeconds();
    if (left <= 0) return "starts over now";
    const days = @divFloor(left, 86400);
    const hours = @divFloor(@mod(left, 86400), 3600);
    const minutes = @divFloor(@mod(left, 3600), 60);
    return (if (days > 0)
        std.fmt.bufPrint(buf, "starts over in {d}d {d}h", .{ days, hours })
    else if (hours > 0)
        std.fmt.bufPrint(buf, "starts over in {d}h {d}m", .{ hours, minutes })
    else
        std.fmt.bufPrint(buf, "starts over in {d}m", .{@max(minutes, 1)})) catch "";
}

/// `SPC a x`: stops what Claude is doing.
pub fn stop(ed: *Editor) void {
    const c = ed.chat orelse return ed.setMessage(.info, "Claude isn't doing anything", .{});
    if (c.state == .idle) return ed.setMessage(.info, "Claude isn't doing anything", .{});
    c.interrupt();
    ed.setMessage(.info, "stopping Claude", .{});
}

/// `SPC a c`: a new conversation (the old one's rows stay, above a note).
pub fn startOver(ed: *Editor) !void {
    const c = try chat(ed);
    c.reset();
    try show(ed, false);
    tick(ed);
    ed.setMessage(.info, "a new conversation with Claude", .{});
}

/// Takes what Claude has said since the last frame. While the last row is
/// the selected one the panel follows: new rows are selected as they come,
/// and the end of what is being written is what shows.
pub fn tick(ed: *Editor) void {
    const c = ed.chat orelse return;
    c.poll();
    const p = &ed.chat_panel;
    const before = p.state;
    p.state = c.state;
    // Its turn is over: a notification says so (you may be elsewhere), with
    // the start of what it said last, or what went wrong.
    if (before != .idle and c.state == .idle and !p.focus) {
        const where: []const u8 = if (p.shown) "" else " (SPC a a)";
        const last: ?*const Chat.Entry = if (c.entries.items.len > 0) &c.entries.items[c.entries.items.len - 1] else null;
        if (last) |e| switch (e.kind) {
            .note => notifications.notify(ed, .err, "Claude: {s}{s}", .{ Chat.rowLine(e), where }),
            .claude => notifications.notify(ed, .info, "Claude is done: {s}{s}", .{ cut(Chat.rowLine(e), 70), where }),
            else => notifications.notify(ed, .info, "Claude is done{s}", .{where}),
        } else notifications.notify(ed, .info, "Claude is done{s}", .{where});
    }
    if (p.version != c.version) {
        p.version = c.version;
        if (p.follow and c.entries.items.len > 0) {
            p.sel = c.entries.items.len - 1;
            p.tail = true;
        }
        ed.wake_fn();
    }
    // An edit that was showing, and isn't asked about any more.
    if (ed.chat_proposal != null and proposal(ed) == null) dropProposal(ed);
    // A notification for as long as Claude waits for an answer.
    const waiting: u64 = if (c.asking()) |a| std.hash.Wyhash.hash(0, a.id) | 1 else 0;
    if (waiting != ed.chat_asked) {
        ed.chat_asked = waiting;
        if (c.asking()) |a| {
            if (a.question)
                notifications.progress(ed, ask_toast, true, "Claude has a question: SPC a y to answer", .{})
            else if (std.mem.eql(u8, a.tool, "Edit") or std.mem.eql(u8, a.tool, "Write"))
                notifications.progress(ed, ask_toast, true, "Claude asks to change a file: SPC a y shows it (SPC a n refuses)", .{})
            else
                notifications.progress(ed, ask_toast, true, "Claude asks to use {s}: SPC a y to answer (SPC a n refuses)", .{a.tool});
        } else notifications.progress(ed, ask_toast, false, "Claude has its answer", .{});
    }
}

/// At most `max` bytes of `s`, cut between characters.
fn cut(s: []const u8, max: usize) []const u8 {
    if (s.len <= max) return s;
    var end = max;
    while (end > 0 and (s[end] & 0xc0) == 0x80) end -= 1;
    return s[0..end];
}

/// The selected row, if there is one.
pub fn selected(ed: *const Editor) ?*const Chat.Entry {
    const c = ed.chat orelse return null;
    if (ed.chat_panel.sel >= c.entries.items.len) return null;
    return &c.entries.items[ed.chat_panel.sel];
}

fn select(ed: *Editor, row: usize) void {
    const c = ed.chat orelse return;
    const n = c.entries.items.len;
    if (n == 0) return;
    const p = &ed.chat_panel;
    p.sel = @min(row, n - 1);
    p.follow = p.sel == n - 1;
    // A row gone to is read from its top.
    p.tail = false;
    p.scroll = 0;
}

fn scrollText(ed: *Editor, delta: isize) void {
    const p = &ed.chat_panel;
    const last = p.lines -| p.page;
    const from: isize = @intCast(if (p.tail) last else @min(p.scroll, last));
    p.scroll = @intCast(std.math.clamp(from + delta, 0, @as(isize, @intCast(last))));
    p.tail = false;
}

/// The wheel over the panel: over the rows it goes through them, over the
/// text it scrolls that (the copy opened by Tab, while it is open). True
/// when the pointer was over the panel.
pub fn wheel(ed: *Editor, x: f32, y: f32, lines: isize) bool {
    const p = &ed.chat_panel;
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

/// Tab on a row: into its text, where it shows, with vim's keys (a
/// read-only copy; Tab or Esc comes back to the rows).
fn intoText(ed: *Editor) !void {
    const e = selected(ed) orelse return;
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try b.text.insert(ed.gpa, 0, e.text.items);
    b.syntax = Syntax.forPath("claude.md");
    b.label = try ed.gpa.dupe(u8, "Claude");
    b.read_only = true;
    try side_float.open(ed, b, true);
}

/// `o` / Enter on a row: its text in a buffer of its own (read-only), in
/// the code window, to yank part of it or search it with vim's keys.
fn openRow(ed: *Editor) !void {
    const e = selected(ed) orelse return;
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try b.text.insert(ed.gpa, 0, e.text.items);
    b.syntax = Syntax.forPath("claude.md");
    const line = Chat.rowLine(e);
    b.label = try std.fmt.allocPrint(ed.gpa, "Claude: {s}", .{line[0..@min(line.len, 40)]});
    b.read_only = true;
    try ed.buffers.append(ed.gpa, b);
    ed.chat_panel.focus = false;
    ed.switchTo(b);
    ed.setMessage(.info, "read-only: y copies; SPC a a is the conversation again", .{});
}

/// The panel's keys, while it has the keyboard. True when the key was the
/// panel's (all are, but SPC: the leader menu is the code's). While it is
/// only shown (the code has the keyboard), Esc in normal mode hides it, and
/// does what Esc does besides.
pub fn key(ed: *Editor, ev: Editor.KeyEvent) bool {
    const p = &ed.chat_panel;
    if (!p.shown or side_float.focused(ed)) return false;
    if (ed.picker != null or ed.cmd_float != null or ed.search_prompt != null or ed.popup != null) return false;
    if (!p.focus) {
        const esc = ev.key == .special and ev.key.special == .escape and !ev.mods.any();
        if (esc and ed.mode == .normal and ed.isIdle() and ed.cursors.items.len == 0 and ed.window.term == null) hide(ed);
        return false;
    }
    const c = ed.chat orelse return false;
    const n = c.entries.items.len;
    const half: isize = @intCast(@max(p.page / 2, 1));
    const was_g = p.pending_g;
    p.pending_g = false;
    switch (ev.key) {
        .special => |sp| switch (sp) {
            .escape => hide(ed),
            .tab => intoText(ed) catch {},
            .enter => if (!answer(ed, true)) openRow(ed) catch {},
            .down => select(ed, p.sel + 1),
            .up => select(ed, p.sel -| 1),
            .page_down => scrollText(ed, half * 2),
            .page_up => scrollText(ed, -half * 2),
            else => {},
        },
        .codepoint => |cp| if (ev.mods.ctrl) switch (cp) {
            'w' => p.focus = false,
            'c' => stop(ed),
            'd' => scrollText(ed, half),
            'u' => scrollText(ed, -half),
            'n' => select(ed, p.sel + 1),
            'p' => select(ed, p.sel -| 1),
            else => {},
        } else if (answerKey(ed, cp)) {} else switch (cp) {
            'j' => select(ed, p.sel + 1),
            'k' => select(ed, p.sel -| 1),
            'J' => scrollText(ed, 1),
            'K' => scrollText(ed, -1),
            'G' => select(ed, n -| 1),
            'g' => if (was_g) select(ed, 0) else {
                p.pending_g = true;
            },
            'y' => if (selected(ed)) |e| {
                ed.registers.store(null, .yank, e.text.items, false) catch {};
                ed.setMessage(.info, "yanked the row ({d} lines); o opens it to yank part of it", .{std.mem.count(u8, e.text.items, "\n") + 1});
            },
            'o' => openRow(ed) catch {},
            'i', 'a' => @import("claude_panel.zig").claudeAskPrompt(ed) catch {},
            'q' => hide(ed),
            '/' => menu(ed, .commands) catch {},
            'm' => menu(ed, .models) catch {},
            'p' => menu(ed, .modes) catch {},
            'e' => menu(ed, .efforts) catch {},
            'u' => menu(ed, .usage) catch {},
            'r' => menu(ed, .sessions) catch {},
            ' ' => {
                p.focus = false;
                return false;
            },
            else => {},
        },
    }
    return true;
}
