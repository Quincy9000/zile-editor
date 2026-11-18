//! A conversation with Claude Code that zile draws itself: the `claude` CLI
//! runs without its terminal interface (`-p` with stream-json both ways),
//! and what it says arrives as JSON events, one a line. They are turned
//! into the conversation's rows here (`entries`), which the editor shows:
//! what you said, each thing Claude says (growing as it is written), each
//! tool it uses with what that gave back, each thing it asks. Tools that need permission ask through the same stream
//! (`--permission-prompt-tool stdio`); the editor answers.
//!
//! A reader thread queues the CLI's lines; the main thread takes them in
//! `poll`. The CLI is started by the first message and started again
//! (resuming the session) if it has gone.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Chat = @This();

pub const State = enum { idle, working, asking };

/// A row of the conversation.
pub const Entry = struct {
    kind: Kind,
    /// The row's line when it isn't the text's first: a tool and what it
    /// is doing, what is asked (owned).
    title: []u8 = &.{},
    /// The whole of it: what was said; a tool's input, then what it gave
    /// back; what a question offers.
    text: std.ArrayList(u8) = .empty,
    /// The tool use or the request this row is (owned), for its result or
    /// its answer to find it.
    id: []u8 = &.{},

    pub const Kind = enum { you, claude, tool, ask, note };
};

/// Something the CLI says it has: a slash command, a model (in `info`).
pub const Named = struct {
    /// What is sent to pick it: `/name`, the model's value.
    name: []const u8,
    /// What it is called (a model's), and what it is.
    title: []const u8 = "",
    description: []const u8 = "",
    /// A model's effort levels, the lowest first.
    efforts: []const []const u8 = &.{},
};

/// How much of what there is has been used, as the CLI last said.
pub const Usage = struct {
    known: bool = false,
    /// Percent of the 5-hour and the weekly limit used (null: no such
    /// limit), and when each starts over (seconds since 1970; 0: not said).
    five_hour: ?f64 = null,
    five_hour_resets: i64 = 0,
    week: ?f64 = null,
    week_resets: i64 = 0,
    /// The conversation: tokens in its context, of how many.
    context_tokens: u64 = 0,
    context_max: u64 = 0,
};

/// A tool waiting for permission.
pub const Ask = struct {
    /// The request's id (owned).
    id: []u8,
    /// The tool (owned), and its input as JSON (owned), given back on allow.
    tool: []u8,
    input: []u8,
    /// How not to be asked again, as the CLI suggests it (JSON, owned).
    suggestions: ?[]u8 = null,
    /// One of Claude's own questions (the AskUserQuestion tool): its
    /// `input` holds them, each with the options to pick from.
    question: bool = false,
};

/// How a tool waiting for permission is answered.
pub const Reply = enum { allow, always, refuse };

/// One of Claude's questions, and what can be picked (in `arena`).
pub const Question = struct {
    text: []const u8,
    options: []const Option,
    pub const Option = struct { label: []const u8, description: []const u8 };
};

gpa: Allocator,
io: Io,
wake: *const fn () void,
/// The folder Claude works in (owned).
root: []u8,

child: ?std.process.Child = null,
reader: ?std.Thread = null,
mutex: Io.Mutex = .init,
/// Lines from the CLI (owned), guarded by `mutex`.
inbox: std.ArrayList([]u8) = .empty,
/// The CLI's output ended. Guarded by `mutex`.
closed: bool = false,

/// The conversation, oldest first: a row each.
entries: std.ArrayList(Entry) = .empty,
/// Goes up whenever a row is added or changes (the view follows).
version: usize = 0,
state: State = .idle,
/// Tools waiting for an answer, the oldest first.
asks: std.ArrayList(Ask) = .empty,
/// The session, to resume it when the CLI is started again (owned).
session: ?[]u8 = null,
/// What the conversation has cost so far, in dollars.
cost: f64 = 0,
/// Claude's text is being written (a text block is open).
writing: bool = false,
/// Answers given so far to the questions of the first of `asks` (the
/// inside of a JSON object, owned), and how many that is.
answers: std.ArrayList(u8) = .empty,
answered: usize = 0,
/// What the CLI said it has when it started (in `info`): its slash
/// commands, the models to choose from.
info: std.heap.ArenaAllocator,
commands: []const Named = &.{},
models: []const Named = &.{},
/// How much Claude may do without asking: the permission modes the CLI
/// takes, as its own help lists them (`claude --help`, `--permission-mode`;
/// nothing in the stream says). Owned; read when first wanted.
modes: [][]u8 = &.{},
/// The model answering and the permission mode, as the CLI last said
/// (owned; empty until it has).
model: []u8 = &.{},
mode: []u8 = &.{},
effort: []u8 = &.{},
usage: Usage = .{},
want_effort: ?[]u8 = null,
/// A model or mode chosen while no CLI was running: it starts with them
/// (owned).
want_model: ?[]u8 = null,
want_mode: ?[]u8 = null,
/// The conversations of before, as last listed (in `listing`).
listing: std.heap.ArenaAllocator,
listed: []const Session = &.{},
/// An MCP server for the CLI to connect to when it starts (zile's own:
/// the diagnostics of the files that are open), as `--mcp-config` takes it
/// (JSON, owned), and the tools of it that need no asking.
mcp_config: ?[]u8 = null,
mcp_allowed: []const u8 = "",
/// The last thing written to the CLI (owned): for the tests.
last_sent: std.ArrayList(u8) = .empty,
next_request: usize = 1,
/// No CLI is ever started (the tests: nothing is said to a real Claude).
offline: bool = false,

pub fn create(gpa: Allocator, io: Io, root: []const u8, wake: *const fn () void) !*Chat {
    const c = try gpa.create(Chat);
    errdefer gpa.destroy(c);
    c.* = .{ .gpa = gpa, .io = io, .wake = wake, .root = try gpa.dupe(u8, root), .info = .init(gpa), .listing = .init(gpa) };
    return c;
}

pub fn destroy(c: *Chat) void {
    c.stopProcess();
    for (c.entries.items) |*e| c.freeEntry(e);
    c.entries.deinit(c.gpa);
    c.clearAsks();
    c.asks.deinit(c.gpa);
    if (c.session) |s| c.gpa.free(s);
    c.last_sent.deinit(c.gpa);
    c.answers.deinit(c.gpa);
    if (c.mcp_config) |m| c.gpa.free(m);
    c.info.deinit();
    c.listing.deinit();
    c.freeModes();
    c.gpa.free(c.model);
    c.gpa.free(c.mode);
    c.gpa.free(c.effort);
    if (c.want_effort) |m| c.gpa.free(m);
    if (c.want_model) |m| c.gpa.free(m);
    if (c.want_mode) |m| c.gpa.free(m);
    c.gpa.free(c.root);
    c.gpa.destroy(c);
}

fn freeEntry(c: *Chat, e: *Entry) void {
    c.gpa.free(e.title);
    e.text.deinit(c.gpa);
    c.gpa.free(e.id);
}

/// A new row at the end.
fn add(c: *Chat, kind: Entry.Kind, title: []const u8, text: []const u8, id: []const u8) !*Entry {
    var e: Entry = .{ .kind = kind };
    errdefer c.freeEntry(&e);
    e.title = try c.gpa.dupe(u8, title);
    e.id = try c.gpa.dupe(u8, id);
    try e.text.appendSlice(c.gpa, text);
    try c.entries.append(c.gpa, e);
    c.version += 1;
    return &c.entries.items[c.entries.items.len - 1];
}

/// The newest row with this id.
fn find(c: *Chat, id: []const u8) ?*Entry {
    if (id.len == 0) return null;
    var i = c.entries.items.len;
    while (i > 0) {
        i -= 1;
        if (std.mem.eql(u8, c.entries.items[i].id, id)) return &c.entries.items[i];
    }
    return null;
}

/// The row's title becomes `mark` and what it was (`✓ Allow Bash…`).
fn mark(c: *Chat, id: []const u8, sign: []const u8, note: []const u8) !void {
    const e = c.find(id) orelse return;
    const title = try std.fmt.allocPrint(c.gpa, "{s} {s}", .{ sign, e.title });
    c.gpa.free(e.title);
    e.title = title;
    try e.text.print(c.gpa, "\n\n{s}", .{note});
    c.version += 1;
}

fn clearAsks(c: *Chat) void {
    for (c.asks.items) |a| freeAsk(c.gpa, a);
    c.asks.clearRetainingCapacity();
    c.answers.clearRetainingCapacity();
    c.answered = 0;
}

fn freeAsk(gpa: Allocator, a: Ask) void {
    gpa.free(a.id);
    gpa.free(a.tool);
    gpa.free(a.input);
    if (a.suggestions) |s| gpa.free(s);
}

fn stopProcess(c: *Chat) void {
    // Killing the CLI ends its output, which ends the reader thread.
    if (c.child) |*ch| ch.kill(c.io);
    if (c.reader) |t| t.join();
    c.child = null;
    c.reader = null;
    for (c.inbox.items) |m| c.gpa.free(m);
    c.inbox.clearAndFree(c.gpa);
    c.closed = false;
}

/// A conversation of before, as the CLI keeps it.
pub const Session = struct {
    /// What `--resume` takes, and its file (in the list's arena).
    id: []const u8,
    path: []const u8,
    /// What was said first, on one line.
    first: []const u8,
    /// When it was last added to (seconds since 1970).
    modified: i64,
};

/// Where the CLI keeps the conversations had in `root`
/// (`<its folder>/projects/<root, every other character a ->/`). Caller frees.
pub fn sessionsDir(gpa: Allocator, root: []const u8) ?[]u8 {
    const slug = gpa.dupe(u8, root) catch return null;
    defer gpa.free(slug);
    for (slug) |*b| if (!std.ascii.isAlphanumeric(b.*)) {
        b.* = '-';
    };
    if (std.c.getenv("CLAUDE_CONFIG_DIR")) |d| if (std.mem.span(d).len > 0) return std.fs.path.join(gpa, &.{ std.mem.span(d), "projects", slug }) catch null;
    const home = std.mem.span(std.c.getenv("HOME") orelse return null);
    return std.fs.path.join(gpa, &.{ home, ".claude", "projects", slug }) catch null;
}

/// The conversations had in `root`, the latest first (in `a`): those of
/// the CLI's own interface too.
pub fn sessions(a: Allocator, io: Io, root: []const u8) ![]Session {
    const max = 100;
    var list: std.ArrayList(Session) = .empty;
    const dir_path = sessionsDir(a, root) orelse return list.items;
    var dir = Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return list.items;
    defer dir.close(io);
    var it = dir.iterate();
    while (it.next(io) catch null) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".jsonl")) continue;
        const st = dir.statFile(io, entry.name, .{}) catch continue;
        try list.append(a, .{
            .id = try a.dupe(u8, entry.name[0 .. entry.name.len - ".jsonl".len]),
            .path = try std.fs.path.join(a, &.{ dir_path, entry.name }),
            .first = "",
            .modified = st.mtime.toSeconds(),
        });
    }
    std.mem.sort(Session, list.items, {}, struct {
        fn later(_: void, x: Session, y: Session) bool {
            return x.modified > y.modified;
        }
    }.later);
    if (list.items.len > max) list.items.len = max;
    // What each began with: in the start of its file.
    var kept: usize = 0;
    for (list.items) |sn| {
        var file = Io.Dir.cwd().openFile(io, sn.path, .{}) catch continue;
        defer file.close(io);
        const head = try a.alloc(u8, 256 * 1024);
        const n = file.readPositionalAll(io, head, 0) catch continue;
        var one = sn;
        one.first = try firstSaid(a, head[0..n]) orelse continue; // (nothing said: not a conversation)
        list.items[kept] = one;
        kept += 1;
    }
    return list.items[0..kept];
}

/// What the user said in a line of a session's file (in `a`): the text of
/// a `user` line that isn't a tool's result, a subagent's, or something the
/// CLI or the editor put there (`<ide_selection>…`, `<command-name>…`).
fn saidIn(a: Allocator, v: std.json.Value) ?[]const u8 {
    if (!std.mem.eql(u8, string(v, "type") orelse return null, "user")) return null;
    if (member(v, "isSidechain")) |sc| if (sc == .bool and sc.bool) return null;
    if (member(v, "isMeta")) |meta| if (meta == .bool and meta.bool) return null;
    const content = member(member(v, "message") orelse return null, "content") orelse return null;
    var out: std.ArrayList(u8) = .empty;
    switch (content) {
        .string => |text| out.appendSlice(a, text) catch return null,
        .array => |parts| for (parts.items) |part| {
            if (!std.mem.eql(u8, string(part, "type") orelse "", "text")) continue;
            const text = std.mem.trim(u8, string(part, "text") orelse "", " \t\r\n");
            if (text.len == 0 or text[0] == '<') continue;
            if (out.items.len > 0) out.append(a, '\n') catch return null;
            out.appendSlice(a, text) catch return null;
        },
        else => return null,
    }
    const said = std.mem.trim(u8, out.items, " \t\r\n");
    return if (said.len == 0 or said[0] == '<') null else said;
}

fn firstSaid(a: Allocator, head: []const u8) !?[]const u8 {
    var lines = std.mem.splitScalar(u8, head, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch continue;
        if (saidIn(a, v)) |said| return try a.dupe(u8, oneLine(said));
    }
    return null;
}

/// Looks again for the conversations had in this folder (`listed`).
pub fn listSessions(c: *Chat) void {
    c.listed = &.{};
    _ = c.listing.reset(.free_all);
    c.listed = sessions(c.listing.allocator(), c.io, c.root) catch &.{};
}

/// Goes back to a conversation of before: its rows are shown again (from
/// its file) and the next message carries on with it.
pub fn resumeSession(c: *Chat, id: []const u8, path: []const u8) !void {
    c.reset();
    for (c.entries.items) |*e| c.freeEntry(e);
    c.entries.clearRetainingCapacity();
    c.session = try c.gpa.dupe(u8, id);
    const text = Io.Dir.cwd().readFileAlloc(c.io, path, c.gpa, .limited(64 << 20)) catch return;
    defer c.gpa.free(text);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| if (line.len > 0) c.replay(line) catch {};
    c.version += 1;
}

/// A line of a session's file, as a row: what was said, what Claude said,
/// the tools it used and what they gave back.
fn replay(c: *Chat, line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const a = arena.allocator();
    const v = std.json.parseFromSliceLeaky(std.json.Value, a, line, .{}) catch return;
    const kind = string(v, "type") orelse return;
    if (member(v, "isSidechain")) |sc| if (sc == .bool and sc.bool) return;
    const content = member(member(v, "message") orelse return, "content") orelse return;
    if (std.mem.eql(u8, kind, "user")) {
        if (saidIn(a, v)) |said| _ = try c.add(.you, "", said, "");
        if (content == .array) for (content.array.items) |part| {
            if (!std.mem.eql(u8, string(part, "type") orelse "", "tool_result")) continue;
            const failed = if (member(part, "is_error")) |e| e == .bool and e.bool else false;
            try c.toolResult(string(part, "tool_use_id") orelse "", member(part, "content") orelse .null, failed);
        };
    } else if (std.mem.eql(u8, kind, "assistant")) {
        if (content != .array) return;
        for (content.array.items) |part| {
            const what = string(part, "type") orelse "";
            if (std.mem.eql(u8, what, "text")) {
                const text = std.mem.trim(u8, string(part, "text") orelse "", " \t\r\n");
                if (text.len > 0) _ = try c.add(.claude, "", text, "");
            } else if (std.mem.eql(u8, what, "tool_use")) {
                try c.toolRow(a, string(part, "name") orelse "tool", member(part, "input") orelse .null, string(part, "id") orelse "");
            }
        }
    }
}

/// A new conversation: the CLI is stopped, and the next message starts one
/// that remembers nothing.
pub fn reset(c: *Chat) void {
    if (c.entries.items.len > 0) _ = c.add(.note, "a new conversation", "", "") catch {};
    c.stopProcess();
    c.clearAsks();
    if (c.session) |s| c.gpa.free(s);
    c.session = null;
    c.state = .idle;
    c.writing = false;
    c.cost = 0;
}

fn startProcess(c: *Chat) !void {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(c.gpa);
    try argv.appendSlice(c.gpa, &.{
        "claude",                    "-p",    "--input-format", "stream-json", "--output-format", "stream-json", "--verbose",
        "--include-partial-messages", "--permission-prompt-tool", "stdio",
    });
    if (c.session) |s| try argv.appendSlice(c.gpa, &.{ "--resume", s });
    if (c.want_model) |m| try argv.appendSlice(c.gpa, &.{ "--model", m });
    if (c.want_mode) |m| try argv.appendSlice(c.gpa, &.{ "--permission-mode", m });
    if (c.want_effort) |m| try argv.appendSlice(c.gpa, &.{ "--effort", m });
    if (c.mcp_config) |m| {
        try argv.appendSlice(c.gpa, &.{ "--mcp-config", m });
        if (c.mcp_allowed.len > 0) try argv.appendSlice(c.gpa, &.{ "--allowedTools", c.mcp_allowed });
    }
    c.child = try std.process.spawn(c.io, .{ .argv = argv.items, .cwd = .{ .path = c.root }, .stdin = .pipe, .stdout = .pipe, .stderr = .ignore });
    errdefer {
        c.child.?.kill(c.io);
        c.child = null;
    }
    c.closed = false;
    c.reader = try std.Thread.spawn(.{}, readLoop, .{c});
    // What it has: its slash commands, its models (it answers at once,
    // before anything is said).
    c.write("{\"type\":\"control_request\",\"request_id\":\"zile-init\",\"request\":{\"subtype\":\"initialize\"}}");
    c.refresh();
}

/// Asks the CLI again for what changes as it goes: the model and effort in
/// use, the limits used, the size of the context.
pub fn refresh(c: *Chat) void {
    inline for (.{ "get_settings", "get_usage", "get_context_usage" }) |subtype| {
        var buf: [128]u8 = undefined;
        const json = std.fmt.bufPrint(&buf, "{{\"type\":\"control_request\",\"request_id\":\"zile-{d}\",\"request\":{{\"subtype\":\"" ++ subtype ++ "\"}}}}", .{c.next_request}) catch unreachable;
        c.next_request += 1;
        c.write(json);
    }
}

/// Changes how hard Claude thinks, from now on (one of the model's levels).
pub fn setEffort(c: *Chat, level: []const u8) !void {
    const mine = try c.gpa.dupe(u8, level);
    if (c.want_effort) |old| c.gpa.free(old);
    c.want_effort = mine;
    const v = try std.json.Stringify.valueAlloc(c.gpa, level, .{});
    defer c.gpa.free(v);
    const json = try std.fmt.allocPrint(c.gpa, "{{\"type\":\"control_request\",\"request_id\":\"zile-{d}\",\"request\":{{\"subtype\":\"apply_flag_settings\",\"settings\":{{\"effortLevel\":{s}}}}}}}", .{ c.next_request, v });
    defer c.gpa.free(json);
    c.next_request += 1;
    c.write(json);
    // What it is on now.
    c.keep(&c.effort, level);
    c.refresh();
}

/// The effort levels of the model in use (those of the default one until
/// it is known which that is).
pub fn efforts(c: *const Chat) []const []const u8 {
    const want = c.want_model orelse "default";
    for (c.models) |m| if (std.mem.eql(u8, m.name, want) and m.efforts.len > 0) return m.efforts;
    for (c.models) |m| if (m.efforts.len > 0) return m.efforts;
    return &.{};
}

/// `2026-11-16T21:30:00…` (UTC) as seconds since 1970; 0 if it isn't one.
fn isoSeconds(s: []const u8) i64 {
    if (s.len < 19 or s[4] != '-' or s[7] != '-' or s[10] != 'T') return 0;
    const y = std.fmt.parseInt(i64, s[0..4], 10) catch return 0;
    const mo = std.fmt.parseInt(i64, s[5..7], 10) catch return 0;
    const d = std.fmt.parseInt(i64, s[8..10], 10) catch return 0;
    const h = std.fmt.parseInt(i64, s[11..13], 10) catch return 0;
    const mi = std.fmt.parseInt(i64, s[14..16], 10) catch return 0;
    const sec = std.fmt.parseInt(i64, s[17..19], 10) catch return 0;
    // Days from the civil date (Howard Hinnant's algorithm).
    const yy = if (mo <= 2) y - 1 else y;
    const era = @divFloor(yy, 400);
    const yoe = yy - era * 400;
    const doy = @divFloor(153 * (if (mo > 2) mo - 3 else mo + 9) + 2, 5) + d - 1;
    const doe = yoe * 365 + @divFloor(yoe, 4) - @divFloor(yoe, 100) + doy;
    return (era * 146097 + doe - 719468) * 86400 + h * 3600 + mi * 60 + sec;
}

fn number(v: std.json.Value, name: []const u8) ?f64 {
    return switch (member(v, name) orelse return null) {
        .float => |f| f,
        .integer => |i| @floatFromInt(i),
        else => null,
    };
}

/// Starts the CLI if it isn't running (nothing is said to Claude yet): its
/// commands and models are known a moment later.
pub fn wake_up(c: *Chat) void {
    if (c.child == null and !c.offline) c.startProcess() catch {};
}

/// Changes the model that answers, from now on.
pub fn setModel(c: *Chat, value: []const u8) !void {
    const mine = try c.gpa.dupe(u8, value);
    if (c.want_model) |old| c.gpa.free(old);
    c.want_model = mine;
    try c.control("set_model", "model", value);
}

fn freeModes(c: *Chat) void {
    for (c.modes) |m| c.gpa.free(m);
    c.gpa.free(c.modes);
    c.modes = &.{};
}

/// Asks the CLI for its permission modes, once (its help: quick).
pub fn loadModes(c: *Chat) void {
    if (c.modes.len > 0 or c.offline) return;
    const r = std.process.run(c.gpa, c.io, .{ .argv = &.{ "claude", "--help" }, .stdout_limit = .limited(1 << 20) }) catch return;
    defer c.gpa.free(r.stdout);
    defer c.gpa.free(r.stderr);
    c.readModes(r.stdout) catch {};
}

/// Takes the modes from the CLI's help: the quoted choices of
/// `--permission-mode`.
pub fn readModes(c: *Chat, help: []const u8) !void {
    const flag = std.mem.indexOf(u8, help, "--permission-mode") orelse return;
    const open = std.mem.indexOfPos(u8, help, flag, "(choices:") orelse return;
    const close = std.mem.indexOfScalarPos(u8, help, open, ')') orelse return;
    var list: std.ArrayList([]u8) = .empty;
    errdefer {
        for (list.items) |m| c.gpa.free(m);
        list.deinit(c.gpa);
    }
    var it = std.mem.splitScalar(u8, help[open..close], '"');
    _ = it.next();
    // Every other piece is inside quotes.
    while (it.next()) |name| : (_ = it.next()) {
        if (name.len == 0) continue;
        const mine = try c.gpa.dupe(u8, name);
        errdefer c.gpa.free(mine);
        try list.append(c.gpa, mine);
    }
    if (list.items.len == 0) return list.deinit(c.gpa);
    c.freeModes();
    c.modes = try list.toOwnedSlice(c.gpa);
}

/// Whether `name` is the mode in use. (The CLI calls the one that asks
/// first `manual` in its help and `default` when it says which it is on.)
pub fn modeInUse(c: *const Chat, name: []const u8) bool {
    if (std.mem.eql(u8, c.mode, name)) return true;
    return std.mem.eql(u8, c.mode, "default") and std.mem.eql(u8, name, "manual");
}

/// Changes how much Claude may do without asking (one of `modes`).
pub fn setMode(c: *Chat, value: []const u8) !void {
    const mine = try c.gpa.dupe(u8, value);
    if (c.want_mode) |old| c.gpa.free(old);
    c.want_mode = mine;
    const changed = !c.modeInUse(value);
    try c.control("set_permission_mode", "mode", value);
    // The CLI takes the mode for what comes next, and never looks again at
    // what was already waiting for an answer: Claude would sit there under
    // a mode that no longer asks. What waits is handed back to be done
    // again, so the new mode's own rules decide (a question of Claude's is
    // still yours to answer).
    if (!changed) return;
    while (c.asks.items.len > 0 and !c.asks.items[0].question) {
        const body = try std.fmt.allocPrint(c.gpa, "{{\"behavior\":\"deny\",\"message\":\"Not refused: the permission mode changed to {s} while this was waiting for an answer. Make the same tool call again.\"}}", .{value});
        defer c.gpa.free(body);
        try c.mark(c.asks.items[0].id, "↻", "asked again, the mode changed");
        try c.respond(body);
    }
}

fn control(c: *Chat, subtype: []const u8, key: []const u8, value: []const u8) !void {
    const v = try std.json.Stringify.valueAlloc(c.gpa, value, .{});
    defer c.gpa.free(v);
    const json = try std.fmt.allocPrint(c.gpa, "{{\"type\":\"control_request\",\"request_id\":\"zile-{d}\",\"request\":{{\"subtype\":\"{s}\",\"{s}\":{s}}}}}", .{ c.next_request, subtype, key, v });
    defer c.gpa.free(json);
    c.next_request += 1;
    c.write(json);
}

fn keep(c: *Chat, slot: *[]u8, value: []const u8) void {
    const mine = c.gpa.dupe(u8, value) catch return;
    c.gpa.free(slot.*);
    slot.* = mine;
    c.version += 1;
}

/// The CLI's answer to a request of ours: what it has (to `initialize`),
/// the model or the mode it is now on.
fn controlResponse(c: *Chat, v: std.json.Value) !void {
    const r = member(member(v, "response") orelse return, "response") orelse return;
    // `get_settings`: what is in use.
    if (member(r, "applied")) |applied| {
        if (string(applied, "model")) |m| c.keep(&c.model, m);
        if (string(applied, "effort")) |e| c.keep(&c.effort, e);
    }
    // `get_usage`: the limits.
    if (member(r, "rate_limits")) |limits| {
        c.usage.known = true;
        c.usage.five_hour = null;
        c.usage.week = null;
        if (member(limits, "five_hour")) |w| if (w == .object) {
            c.usage.five_hour = number(w, "utilization");
            c.usage.five_hour_resets = isoSeconds(string(w, "resets_at") orelse "");
        };
        if (member(limits, "seven_day")) |w| if (w == .object) {
            c.usage.week = number(w, "utilization");
            c.usage.week_resets = isoSeconds(string(w, "resets_at") orelse "");
        };
        if (member(r, "session")) |session| if (number(session, "total_cost_usd")) |cost| {
            if (cost > c.cost) c.cost = cost;
        };
        c.version += 1;
    }
    // `get_context_usage`.
    if (number(r, "totalTokens")) |tokens| {
        c.usage.context_tokens = @intFromFloat(@max(tokens, 0));
        c.usage.context_max = @intFromFloat(@max(number(r, "maxTokens") orelse 0, 0));
        c.version += 1;
    }
    if (string(r, "model")) |m| c.keep(&c.model, m);
    if (string(r, "mode")) |m| c.keep(&c.mode, m);
    if (string(r, "current_permission_mode")) |m| c.keep(&c.mode, m);
    const cmds = member(r, "commands") orelse return;
    _ = c.info.reset(.free_all);
    const a = c.info.allocator();
    c.commands = &.{};
    c.models = &.{};
    if (cmds == .array) {
        var list: std.ArrayList(Named) = .empty;
        for (cmds.array.items) |cmd| try list.append(a, .{
            .name = try a.dupe(u8, string(cmd, "name") orelse continue),
            .description = try a.dupe(u8, oneLine(string(cmd, "description") orelse "")),
        });
        c.commands = list.items;
    }
    if (member(r, "models")) |ms| if (ms == .array) {
        var list: std.ArrayList(Named) = .empty;
        for (ms.array.items) |m| {
            var levels: std.ArrayList([]const u8) = .empty;
            if (member(m, "supportedEffortLevels")) |ls| if (ls == .array) for (ls.array.items) |l| {
                if (l == .string) try levels.append(a, try a.dupe(u8, l.string));
            };
            try list.append(a, .{
                .name = try a.dupe(u8, string(m, "value") orelse continue),
                .title = try a.dupe(u8, string(m, "displayName") orelse ""),
                .description = try a.dupe(u8, oneLine(string(m, "description") orelse "")),
                .efforts = levels.items,
            });
        }
        c.models = list.items;
    };
    c.version += 1;
}

fn readLoop(c: *Chat) void {
    defer {
        c.mutex.lockUncancelable(c.io);
        c.closed = true;
        c.mutex.unlock(c.io);
        c.wake();
    }
    const stdout = c.child.?.stdout orelse return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(c.gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = stdout.readStreaming(c.io, &.{&chunk}) catch return;
        buf.appendSlice(c.gpa, chunk[0..n]) catch return;
        var from: usize = 0;
        var any = false;
        while (std.mem.indexOfScalarPos(u8, buf.items, from, '\n')) |end| {
            defer from = end + 1;
            if (end == from) continue;
            const line = c.gpa.dupe(u8, buf.items[from..end]) catch return;
            c.mutex.lockUncancelable(c.io);
            c.inbox.append(c.gpa, line) catch c.gpa.free(line);
            c.mutex.unlock(c.io);
            any = true;
        }
        buf.replaceRangeAssumeCapacity(0, from, &.{});
        if (any) c.wake();
    }
}

fn write(c: *Chat, line: []const u8) void {
    c.last_sent.clearRetainingCapacity();
    c.last_sent.appendSlice(c.gpa, line) catch {};
    const ch = c.child orelse return;
    const stdin = ch.stdin orelse return;
    stdin.writeStreamingAll(c.io, line) catch return;
    stdin.writeStreamingAll(c.io, "\n") catch {};
}

/// Says `text` to Claude (starting the CLI if it isn't running). It may be
/// said while Claude is working: it is taken up when the turn allows.
pub fn send(c: *Chat, text: []const u8, context: ?[]const u8) !void {
    if (c.child == null and !c.offline) try c.startProcess();
    try c.say(text, context);
}

/// `send`, without the CLI (the tests). `context`: what the editor adds
/// for Claude to know (the file that is open, the selection); it goes
/// before `text` and isn't in the row.
pub fn say(c: *Chat, text: []const u8, context: ?[]const u8) !void {
    c.endText();
    _ = try c.add(.you, "", std.mem.trim(u8, text, " \t\r\n"), "");
    const Part = struct { type: []const u8 = "text", text: []const u8 };
    const parts = [_]Part{ .{ .text = context orelse "" }, .{ .text = text } };
    const json = try std.json.Stringify.valueAlloc(c.gpa, .{
        .type = "user",
        .message = .{ .role = "user", .content = parts[@intFromBool(context == null)..] },
    }, .{});
    defer c.gpa.free(json);
    c.state = .working;
    c.write(json);
}

/// Stops what Claude is doing (its turn ends; the conversation stays).
pub fn interrupt(c: *Chat) void {
    if (c.state == .idle) return;
    var buf: [128]u8 = undefined;
    const json = std.fmt.bufPrint(&buf, "{{\"type\":\"control_request\",\"request_id\":\"zile-{d}\",\"request\":{{\"subtype\":\"interrupt\"}}}}", .{c.next_request}) catch return;
    c.next_request += 1;
    c.write(json);
}

/// The tool that is waiting for an answer, if any.
pub fn asking(c: *const Chat) ?Ask {
    return if (c.asks.items.len > 0) c.asks.items[0] else null;
}

/// Answers the tool that is waiting: allowed, allowed and not asked about
/// again (what the CLI suggested: this kind of edit for the session, say),
/// or refused.
pub fn answer(c: *Chat, reply: Reply) !void {
    if (c.asks.items.len == 0) return;
    const a = c.asks.items[0];
    const always = reply == .always and a.suggestions != null;
    const body = switch (reply) {
        .refuse => try c.gpa.dupe(u8, "{\"behavior\":\"deny\",\"message\":\"The user refused this in the editor.\"}"),
        else => if (always)
            try std.fmt.allocPrint(c.gpa, "{{\"behavior\":\"allow\",\"updatedInput\":{s},\"updatedPermissions\":{s}}}", .{ a.input, a.suggestions.? })
        else
            try std.fmt.allocPrint(c.gpa, "{{\"behavior\":\"allow\",\"updatedInput\":{s}}}", .{a.input}),
    };
    defer c.gpa.free(body);
    switch (reply) {
        .refuse => try c.mark(a.id, "✗", "refused"),
        else => try c.mark(a.id, "✓", if (always) "allowed, from now on" else "allowed"),
    }
    try c.respond(body);
}

/// Allows the tool that is waiting, with `input` (JSON) instead of what it
/// asked to do (an edit changed in the editor before it was accepted).
pub fn answerWith(c: *Chat, input: []const u8) !void {
    if (c.asks.items.len == 0) return;
    const body = try std.fmt.allocPrint(c.gpa, "{{\"behavior\":\"allow\",\"updatedInput\":{s}}}", .{input});
    defer c.gpa.free(body);
    try c.mark(c.asks.items[0].id, "✓", "allowed, as changed in the editor");
    try c.respond(body);
}

/// The question of Claude's that is waiting for an answer (in `arena`).
pub fn question(c: *const Chat, arena: Allocator) ?Question {
    const a = c.asking() orelse return null;
    if (!a.question) return null;
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena, a.input, .{}) catch return null;
    const all = member(v, "questions") orelse return null;
    if (all != .array or c.answered >= all.array.items.len) return null;
    const q = all.array.items[c.answered];
    var options: std.ArrayList(Question.Option) = .empty;
    if (member(q, "options")) |opts| if (opts == .array) for (opts.array.items) |o| {
        options.append(arena, .{ .label = string(o, "label") orelse continue, .description = string(o, "description") orelse "" }) catch return null;
    };
    return .{ .text = string(q, "question") orelse "", .options = options.items };
}

/// `label` is the answer to the question that is waiting. When that was
/// the last one the answers go to Claude; true while more are waiting.
pub fn choose(c: *Chat, label: []const u8) !bool {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const q = c.question(arena.allocator()) orelse return false;
    const key = try std.json.Stringify.valueAlloc(arena.allocator(), q.text, .{});
    const value = try std.json.Stringify.valueAlloc(arena.allocator(), label, .{});
    if (c.answers.items.len > 0) try c.answers.append(c.gpa, ',');
    try c.answers.print(c.gpa, "{s}:{s}", .{ key, value });
    if (c.find(c.asks.items[0].id)) |e| {
        try e.text.print(c.gpa, "\n→ {s}: {s}", .{ oneLine(q.text), oneLine(label) });
        c.version += 1;
    }
    c.answered += 1;
    if (c.question(arena.allocator()) != null) return true;
    // All answered: the tool is allowed, its input with the answers in it.
    const input = c.asks.items[0].input;
    const open = std.mem.lastIndexOfScalar(u8, input, '}') orelse return false;
    const body = try std.fmt.allocPrint(c.gpa, "{{\"behavior\":\"allow\",\"updatedInput\":{s},\"answers\":{{{s}}}}}}}", .{ input[0..open], c.answers.items });
    defer c.gpa.free(body);
    try c.mark(c.asks.items[0].id, "✓", "answered");
    try c.respond(body);
    return false;
}

/// Sends the answer to the first of `asks`, which is done with.
fn respond(c: *Chat, body: []const u8) !void {
    const a = c.asks.orderedRemove(0);
    defer freeAsk(c.gpa, a);
    c.answers.clearRetainingCapacity();
    c.answered = 0;
    const id = try std.json.Stringify.valueAlloc(c.gpa, a.id, .{});
    defer c.gpa.free(id);
    const json = try std.fmt.allocPrint(c.gpa, "{{\"type\":\"control_response\",\"response\":{{\"subtype\":\"success\",\"request_id\":{s},\"response\":{s}}}}}", .{ id, body });
    defer c.gpa.free(json);
    c.state = if (c.asks.items.len > 0) .asking else .working;
    c.write(json);
}

/// Takes what the CLI has said since the last call into `entries`.
pub fn poll(c: *Chat) void {
    var lines: std.ArrayList([]u8) = .empty;
    defer lines.deinit(c.gpa);
    c.mutex.lockUncancelable(c.io);
    lines.appendSlice(c.gpa, c.inbox.items) catch {};
    if (lines.items.len == c.inbox.items.len) c.inbox.clearRetainingCapacity();
    const closed = c.closed and c.inbox.items.len == 0;
    c.mutex.unlock(c.io);
    for (lines.items) |line| {
        defer c.gpa.free(line);
        c.event(line) catch {};
    }
    if (closed and c.child != null) {
        // It has gone (it crashed, or was killed): the next message starts
        // it again, with the session.
        c.stopProcess();
        c.endText();
        if (c.state != .idle) _ = c.add(.note, "Claude Code stopped; your next message starts it again", "", "") catch {};
        c.clearAsks();
        c.state = .idle;
        // What that used.
        c.refresh();
    }
}

/// What Claude was writing is whole: the next text is a row of its own.
fn endText(c: *Chat) void {
    c.writing = false;
}

fn member(v: std.json.Value, name: []const u8) ?std.json.Value {
    return if (v == .object) v.object.get(name) else null;
}

fn string(v: std.json.Value, name: []const u8) ?[]const u8 {
    const f = member(v, name) orelse return null;
    return if (f == .string) f.string else null;
}

/// One line from the CLI.
pub fn event(c: *Chat, line: []const u8) !void {
    var arena: std.heap.ArenaAllocator = .init(c.gpa);
    defer arena.deinit();
    const v = std.json.parseFromSliceLeaky(std.json.Value, arena.allocator(), line, .{}) catch return;
    const kind = string(v, "type") orelse return;
    // What a subagent says and does stays inside its tool.
    if (member(v, "parent_tool_use_id")) |p| if (p == .string) return;
    if (std.mem.eql(u8, kind, "control_response")) {
        try c.controlResponse(v);
    } else if (std.mem.eql(u8, kind, "system")) {
        if (std.mem.eql(u8, string(v, "subtype") orelse "", "init")) if (string(v, "session_id")) |id| {
            if (c.session) |s| c.gpa.free(s);
            c.session = try c.gpa.dupe(u8, id);
        };
        // (`init` says the model, `status` the mode when it changes.)
        if (string(v, "model")) |m| c.keep(&c.model, m);
        if (string(v, "permissionMode")) |m| c.keep(&c.mode, m);
    } else if (std.mem.eql(u8, kind, "stream_event")) {
        const ev = member(v, "event") orelse return;
        const what = string(ev, "type") orelse return;
        if (std.mem.eql(u8, what, "content_block_delta")) {
            const delta = member(ev, "delta") orelse return;
            if (!std.mem.eql(u8, string(delta, "type") orelse "", "text_delta")) return;
            const text = string(delta, "text") orelse return;
            if (!c.writing) _ = try c.add(.claude, "", "", "");
            c.writing = true;
            try c.entries.items[c.entries.items.len - 1].text.appendSlice(c.gpa, text);
            c.version += 1;
        } else if (std.mem.eql(u8, what, "content_block_stop")) c.endText();
    } else if (std.mem.eql(u8, kind, "assistant")) {
        // Its text came as it was written; the tools it uses are here whole.
        const content = member(member(v, "message") orelse return, "content") orelse return;
        if (content != .array) return;
        for (content.array.items) |part| {
            if (!std.mem.eql(u8, string(part, "type") orelse "", "tool_use")) continue;
            c.endText();
            try c.toolRow(arena.allocator(), string(part, "name") orelse "tool", member(part, "input") orelse .null, string(part, "id") orelse "");
        }
    } else if (std.mem.eql(u8, kind, "user")) {
        const content = member(member(v, "message") orelse return, "content") orelse return;
        if (content != .array) return;
        for (content.array.items) |part| {
            if (!std.mem.eql(u8, string(part, "type") orelse "", "tool_result")) continue;
            const failed = if (member(part, "is_error")) |e| e == .bool and e.bool else false;
            try c.toolResult(string(part, "tool_use_id") orelse "", member(part, "content") orelse .null, failed);
        }
    } else if (std.mem.eql(u8, kind, "control_request")) {
        const req = member(v, "request") orelse return;
        if (!std.mem.eql(u8, string(req, "subtype") orelse "", "can_use_tool")) return;
        const id = string(v, "request_id") orelse return;
        const tool = string(req, "tool_name") orelse "tool";
        const input = member(req, "input") orelse std.json.Value{ .string = "" };
        const is_question = std.mem.eql(u8, tool, "AskUserQuestion");
        c.endText();
        if (is_question) try c.questionRow(input, id) else try c.askRow(arena.allocator(), tool, input, id);
        const suggestions: ?[]u8 = if (member(req, "permission_suggestions")) |sg| (if (sg == .array and sg.array.items.len > 0) try std.json.Stringify.valueAlloc(c.gpa, sg, .{}) else null) else null;
        errdefer if (suggestions) |sg| c.gpa.free(sg);
        const input_json = if (input == .object) try std.json.Stringify.valueAlloc(c.gpa, input, .{}) else try c.gpa.dupe(u8, "{}");
        errdefer c.gpa.free(input_json);
        const id_owned = try c.gpa.dupe(u8, id);
        errdefer c.gpa.free(id_owned);
        try c.asks.append(c.gpa, .{ .id = id_owned, .tool = try c.gpa.dupe(u8, tool), .input = input_json, .suggestions = suggestions, .question = is_question });
        c.state = .asking;
    } else if (std.mem.eql(u8, kind, "result")) {
        c.endText();
        if (member(v, "total_cost_usd")) |cost| switch (cost) {
            .float => |f| c.cost = f,
            .integer => |i| c.cost = @floatFromInt(i),
            else => {},
        };
        const failed = if (member(v, "is_error")) |e| e == .bool and e.bool else false;
        if (failed) _ = try c.add(.note, "the turn failed", string(v, "result") orelse string(v, "subtype") orelse "", "");
        c.clearAsks();
        c.state = .idle;
    }
}

/// The part of a tool's input that says what it is doing.
fn subject(a: Allocator, tool: []const u8, input: std.json.Value) []const u8 {
    inline for (.{ "command", "file_path", "pattern", "path", "url", "query", "description", "prompt", "skill" }) |key| {
        if (string(input, key)) |s| return s;
    }
    _ = tool;
    if (input != .object or input.object.count() == 0) return "";
    return std.json.Stringify.valueAlloc(a, input, .{}) catch "";
}

fn oneLine(s: []const u8) []const u8 {
    const t = std.mem.trim(u8, s, " \t\r\n");
    const end = std.mem.indexOfScalar(u8, t, '\n') orelse t.len;
    return t[0..@min(end, 200)];
}

/// A tool being used: `Bash echo hi` is its row, its input the text.
fn toolRow(c: *Chat, a: Allocator, tool: []const u8, input: std.json.Value, id: []const u8) !void {
    const what = subject(a, tool, input);
    const title = try std.fmt.allocPrint(a, "{s} {s}", .{ tool, oneLine(what) });
    _ = try c.add(.tool, std.mem.trimEnd(u8, title, " "), what, id);
}

/// What a tool gave back goes under its input, in its row.
fn toolResult(c: *Chat, id: []const u8, content: std.json.Value, failed: bool) !void {
    const max_bytes = 64 * 1024;
    var text: []const u8 = "";
    switch (content) {
        .string => |s| text = s,
        .array => |parts| for (parts.items) |p| if (string(p, "text")) |s| {
            text = s;
            break;
        },
        else => {},
    }
    text = std.mem.trim(u8, text, " \t\r\n");
    const e = c.find(id) orelse try c.add(.tool, "a tool's result", "", id);
    if (failed) {
        const title = try std.fmt.allocPrint(c.gpa, "✗ {s}", .{e.title});
        c.gpa.free(e.title);
        e.title = title;
    }
    if (text.len > 0) {
        try e.text.appendSlice(c.gpa, "\n\n");
        try e.text.appendSlice(c.gpa, text[0..@min(text.len, max_bytes)]);
        if (text.len > max_bytes) try e.text.appendSlice(c.gpa, "\n… (cut short)");
    }
    c.version += 1;
}

/// A tool asking for permission: what it would do (an edit as a diff).
fn askRow(c: *Chat, a: Allocator, tool: []const u8, input: std.json.Value, id: []const u8) !void {
    const what = subject(a, tool, input);
    const title = try std.fmt.allocPrint(a, "Allow {s}? {s}", .{ tool, oneLine(what) });
    const e = try c.add(.ask, title, what, id);
    const old = string(input, "old_string");
    const new = string(input, "new_string") orelse string(input, "content");
    if (old != null or new != null) {
        try e.text.appendSlice(c.gpa, "\n\n```diff\n");
        if (old) |o| try diffLines(c.gpa, &e.text, '-', o);
        if (new) |n| try diffLines(c.gpa, &e.text, '+', n);
        try e.text.appendSlice(c.gpa, "```");
    }
}

/// Claude's own questions, each with what can be picked.
fn questionRow(c: *Chat, input: std.json.Value, id: []const u8) !void {
    const all = member(input, "questions") orelse return;
    if (all != .array or all.array.items.len == 0) return;
    const first = oneLine(string(all.array.items[0], "question") orelse "Claude has a question");
    const e = try c.add(.ask, first, "", id);
    for (all.array.items, 0..) |q, i| {
        if (i > 0) try e.text.appendSlice(c.gpa, "\n\n");
        try e.text.appendSlice(c.gpa, string(q, "question") orelse "");
        // Numbered: the panel's 1-9 pick one.
        if (member(q, "options")) |opts| if (opts == .array) for (opts.array.items, 1..) |o, n| {
            try e.text.print(c.gpa, "\n{d}. {s}: {s}", .{ n, oneLine(string(o, "label") orelse ""), oneLine(string(o, "description") orelse "") });
        };
    }
}

fn diffLines(gpa: Allocator, out: *std.ArrayList(u8), sign: u8, text: []const u8) !void {
    const max_lines = 200;
    var lines = std.mem.splitScalar(u8, std.mem.trimEnd(u8, text, "\n"), '\n');
    var n: usize = 0;
    while (lines.next()) |l| : (n += 1) {
        if (n == max_lines) {
            try out.print(gpa, "{c} … {d} more lines\n", .{ sign, std.mem.count(u8, lines.rest(), "\n") + 2 });
            return;
        }
        try out.print(gpa, "{c}{s}\n", .{ sign, std.mem.trimEnd(u8, l, "\r") });
    }
}

/// The line a row shows in the list: its title, or the first line of what
/// was said.
pub fn rowLine(e: *const Entry) []const u8 {
    return if (e.title.len > 0) e.title else oneLine(e.text.items);
}

/// A word for the state, for the window's name.
pub fn stateText(c: *const Chat) []const u8 {
    return switch (c.state) {
        .idle => "",
        .working => "working…",
        .asking => "asks: SPC a y answers",
    };
}

fn noWake() void {}

test "the conversation as markdown: text as it is written, tools, what they gave back" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.say("run it", null);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"text\":\"run it\"") != null);
    try std.testing.expectEqual(State.working, c.state);
    const events = [_][]const u8{
        \\{"type":"system","subtype":"init","session_id":"abc-1","model":"m"}
        ,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"I'll run"}},"parent_tool_use_id":null}
        ,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":" it."}},"parent_tool_use_id":null}
        ,
        \\{"type":"stream_event","event":{"type":"content_block_stop","index":0}}
        ,
        \\{"type":"assistant","message":{"content":[{"type":"text","text":"I'll run it."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"echo hi","description":"says hi"}}]}}
        ,
        \\{"type":"user","message":{"role":"user","content":[{"tool_use_id":"t1","type":"tool_result","content":"hi","is_error":false}]}}
        ,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"sub"}},"parent_tool_use_id":"t9"}
        ,
        \\{"type":"stream_event","event":{"type":"content_block_delta","index":0,"delta":{"type":"text_delta","text":"It printed hi."}}}
        ,
        \\{"type":"result","subtype":"success","is_error":false,"total_cost_usd":0.25}
        ,
        "not json",
    };
    for (events) |e| try c.event(e);
    // A row each: what you said, what Claude said, the tool, what it said after.
    try std.testing.expectEqual(4, c.entries.items.len);
    const rows = c.entries.items;
    try std.testing.expectEqual(Entry.Kind.you, rows[0].kind);
    try std.testing.expectEqualStrings("run it", rowLine(&rows[0]));
    try std.testing.expectEqual(Entry.Kind.claude, rows[1].kind);
    try std.testing.expectEqualStrings("I'll run it.", rows[1].text.items);
    try std.testing.expectEqual(Entry.Kind.tool, rows[2].kind);
    try std.testing.expectEqualStrings("Bash echo hi", rowLine(&rows[2]));
    try std.testing.expectEqualStrings("echo hi\n\nhi", rows[2].text.items);
    try std.testing.expectEqualStrings("It printed hi.", rows[3].text.items);
    try std.testing.expectEqualStrings("abc-1", c.session.?);
    try std.testing.expectEqual(State.idle, c.state);
    try std.testing.expectEqual(0.25, c.cost);
}

test "a tool asks: the edit as a diff, allowed with its input or refused" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.event(
        \\{"type":"control_request","request_id":"r-1","request":{"subtype":"can_use_tool","tool_name":"Edit","input":{"file_path":"/p/a.zig","old_string":"a = 1","new_string":"a = 2"}}}
    );
    try c.event(
        \\{"type":"control_request","request_id":"r-2","request":{"subtype":"can_use_tool","tool_name":"Bash","input":{"command":"rm x"}}}
    );
    try std.testing.expectEqual(State.asking, c.state);
    try std.testing.expectEqualStrings("Edit", c.asking().?.tool);
    try std.testing.expectEqualStrings("Allow Edit? /p/a.zig", rowLine(&c.entries.items[0]));
    try std.testing.expectEqualStrings("/p/a.zig\n\n```diff\n-a = 1\n+a = 2\n```", c.entries.items[0].text.items);
    try c.answer(.allow);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"request_id\":\"r-1\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"behavior\":\"allow\",\"updatedInput\":{\"file_path\":\"/p/a.zig\"") != null);
    try std.testing.expectEqualStrings("✓ Allow Edit? /p/a.zig", rowLine(&c.entries.items[0]));
    // The next one is waiting still.
    try std.testing.expectEqual(State.asking, c.state);
    try c.answer(.refuse);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"request_id\":\"r-2\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"behavior\":\"deny\"") != null);
    try std.testing.expectEqual(State.working, c.state);
    try std.testing.expectEqual(null, c.asking());
}

test "Claude's own questions: one picked for each, sent together" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.event(
        \\{"type":"control_request","request_id":"q-1","request":{"subtype":"can_use_tool","tool_name":"AskUserQuestion","input":{"questions":[{"question":"Tea or coffee?","header":"Drink","options":[{"label":"Tea","description":"leaves"},{"label":"Coffee","description":"beans"}],"multiSelect":false},{"question":"Milk?","options":[{"label":"Yes","description":""},{"label":"No","description":""}]}]}}}
    );
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const q = c.question(arena.allocator()).?;
    try std.testing.expectEqualStrings("Tea or coffee?", q.text);
    try std.testing.expectEqualStrings("beans", q.options[1].description);
    try std.testing.expect(try c.choose("Coffee"));
    try std.testing.expectEqualStrings("Milk?", c.question(arena.allocator()).?.text);
    try std.testing.expect(!try c.choose("No"));
    try std.testing.expectEqual(null, c.asking());
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"request_id\":\"q-1\"") != null);
    try std.testing.expect(std.mem.endsWith(u8, c.last_sent.items, "\"answers\":{\"Tea or coffee?\":\"Coffee\",\"Milk?\":\"No\"}}}}}"));
    // Still JSON, with the questions as they were asked.
    const sent = try std.json.parseFromSlice(std.json.Value, gpa, c.last_sent.items, .{});
    defer sent.deinit();
    try std.testing.expect(sent.value.object.get("response").?.object.get("response").?.object.get("updatedInput").?.object.get("questions") != null);
}

test "allowed from now on: what the CLI suggested goes back with the answer" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.event(
        \\{"type":"control_request","request_id":"r-1","request":{"subtype":"can_use_tool","tool_name":"Write","input":{"file_path":"x","content":"hi"},"permission_suggestions":[{"type":"setMode","mode":"acceptEdits","destination":"session"}]}}
    );
    try c.answer(.always);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"updatedPermissions\":[{\"type\":\"setMode\",\"mode\":\"acceptEdits\",\"destination\":\"session\"}]") != null);
}

test "with the real CLI (only when ZILE_CLAUDE_SMOKE is set: it costs a message)" {
    if (std.c.getenv("ZILE_CLAUDE_SMOKE") == null) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const c = try create(gpa, std.testing.io, dir, noWake);
    defer c.destroy();
    try c.send("Reply with just the word: pineapple", null);
    for (0..600) |_| {
        c.poll();
        if (c.state == .idle) break;
        std.testing.io.sleep(.fromMilliseconds(100), .awake) catch {};
    }
    try std.testing.expectEqual(State.idle, c.state);
    // What was said, and an answer with the word in it.
    try std.testing.expect(c.entries.items.len >= 2);
    const answer_text = c.entries.items[c.entries.items.len - 1].text.items;
    try std.testing.expect(std.mem.indexOf(u8, answer_text, "ineapple") != null);
    try std.testing.expect(c.session != null);
    // What it said it has, when it started.
    try std.testing.expect(c.commands.len > 0 and c.models.len > 0);
    try std.testing.expect(c.model.len > 0);
}

test "what the CLI has: its slash commands and models; a model and a mode chosen" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.event(
        \\{"type":"control_response","response":{"subtype":"success","request_id":"zile-init","response":{"commands":[{"name":"review","description":"Review the diff\nat length"},{"name":"init","description":"Make a CLAUDE.md"}],"models":[{"value":"default","displayName":"Default (recommended)","description":"Fable"},{"value":"opus","displayName":"Opus","description":"For complex work"}],"current_permission_mode":"default"}}}
    );
    try std.testing.expectEqual(2, c.commands.len);
    try std.testing.expectEqualStrings("review", c.commands[0].name);
    try std.testing.expectEqualStrings("Review the diff", c.commands[0].description);
    try std.testing.expectEqualStrings("opus", c.models[1].name);
    try std.testing.expectEqualStrings("Opus", c.models[1].title);
    try std.testing.expectEqualStrings("default", c.mode);
    try c.setModel("opus");
    try std.testing.expectEqualStrings("{\"type\":\"control_request\",\"request_id\":\"zile-1\",\"request\":{\"subtype\":\"set_model\",\"model\":\"opus\"}}", c.last_sent.items);
    try c.event("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zile-1\",\"response\":{\"model\":\"claude-opus-5-5\"}}}");
    try std.testing.expectEqualStrings("claude-opus-5-5", c.model);
    try std.testing.expectEqual(2, c.commands.len); // still known
    try c.setMode("plan");
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"subtype\":\"set_permission_mode\",\"mode\":\"plan\"") != null);
    try c.event("{\"type\":\"system\",\"subtype\":\"status\",\"status\":null,\"permissionMode\":\"plan\"}");
    try std.testing.expectEqualStrings("plan", c.mode);
    // A tool that was waiting when the mode changes is handed back to be
    // done again (the CLI never looks at it again by itself); a question
    // of Claude's stays to be answered.
    try c.event("{\"type\":\"control_request\",\"request_id\":\"r-9\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"Bash\",\"input\":{\"command\":\"ls\"}}}");
    try c.event("{\"type\":\"control_request\",\"request_id\":\"q-9\",\"request\":{\"subtype\":\"can_use_tool\",\"tool_name\":\"AskUserQuestion\",\"input\":{\"questions\":[{\"question\":\"Tea?\",\"options\":[]}]}}}");
    try std.testing.expectEqual(.asking, c.state);
    try c.setMode("plan"); // the same mode: nothing is answered
    try std.testing.expectEqual(2, c.asks.items.len);
    try c.setMode("auto");
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"request_id\":\"r-9\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"behavior\":\"deny\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "Make the same tool call again") != null);
    try std.testing.expectEqual(1, c.asks.items.len);
    try std.testing.expect(c.asks.items[0].question);
}

test "effort and usage: the model's levels, what is in use, the limits and the context" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.event(
        \\{"type":"control_response","response":{"subtype":"success","request_id":"zile-init","response":{"commands":[],"models":[{"value":"default","displayName":"Default","description":"","supportedEffortLevels":["low","medium","high"]},{"value":"haiku","displayName":"Haiku","description":"","supportedEffortLevels":null}]}}}
    );
    try std.testing.expectEqual(3, c.efforts().len);
    try std.testing.expectEqualStrings("high", c.efforts()[2]);
    try c.event(
        \\{"type":"control_response","response":{"subtype":"success","request_id":"zile-1","response":{"effective":{},"sources":[],"applied":{"model":"claude-opus-5-5","effort":"high"}}}}
    );
    try std.testing.expectEqualStrings("high", c.effort);
    try std.testing.expectEqualStrings("claude-opus-5-5", c.model);
    try c.setEffort("low");
    try std.testing.expectEqualStrings("low", c.effort);
    try std.testing.expectEqualStrings("low", c.want_effort.?);
    try c.event(
        \\{"type":"control_response","response":{"subtype":"success","request_id":"zile-2","response":{"session":{"total_cost_usd":0.5},"rate_limits":{"five_hour":{"utilization":34,"resets_at":"2026-11-16T21:30:00.077984+00:00"},"seven_day":{"utilization":5.5,"resets_at":"1970-01-02T00:00:10Z"},"seven_day_opus":null}}}}
    );
    try std.testing.expect(c.usage.known);
    try std.testing.expectEqual(34, c.usage.five_hour.?);
    try std.testing.expectEqual(5.5, c.usage.week.?);
    try std.testing.expectEqual(86410, c.usage.week_resets);
    try std.testing.expectEqual(1794864600, c.usage.five_hour_resets);
    try std.testing.expectEqual(0.5, c.cost);
    try c.event("{\"type\":\"control_response\",\"response\":{\"subtype\":\"success\",\"request_id\":\"zile-3\",\"response\":{\"categories\":[],\"totalTokens\":14876,\"maxTokens\":1000000,\"percentage\":1}}}");
    try std.testing.expectEqual(14876, c.usage.context_tokens);
    try std.testing.expectEqual(1000000, c.usage.context_max);
}

test "what the editor adds goes before what is said, and not in the row" {
    const gpa = std.testing.allocator;
    const c = try create(gpa, std.testing.io, ".", noWake);
    defer c.destroy();
    try c.say("fix it", "<ide_opened_file>a.zig</ide_opened_file>");
    try std.testing.expectEqualStrings("fix it", c.entries.items[0].text.items);
    try std.testing.expect(std.mem.indexOf(u8, c.last_sent.items, "\"content\":[{\"type\":\"text\",\"text\":\"<ide_opened_file>a.zig</ide_opened_file>\"},{\"type\":\"text\",\"text\":\"fix it\"}]") != null);
}

test "conversations of before: listed by what began them, shown again when resumed" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const cfg = try std.fmt.allocPrintSentinel(gpa, "{s}/cfg", .{base}, 0);
    defer gpa.free(cfg);
    const setenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });
    _ = setenv("CLAUDE_CONFIG_DIR", cfg.ptr, 1);
    const dir = sessionsDir(gpa, "/work/my.proj").?;
    defer gpa.free(dir);
    try std.testing.expect(std.mem.endsWith(u8, dir, "/cfg/projects/-work-my-proj"));
    try Io.Dir.cwd().createDirPath(io, dir);
    const one = try std.fs.path.join(gpa, &.{ dir, "aaaa-1.jsonl" });
    defer gpa.free(one);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = one, .data =
        \\{"type":"session-owner","sessionId":"aaaa-1"}
        \\{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"text","text":"<ide_opened_file>a.zig</ide_opened_file>"},{"type":"text","text":"fix the parser\nplease"}]}}
        \\{"type":"attachment","isSidechain":false}
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"thinking","thinking":""},{"type":"text","text":"Looking."},{"type":"tool_use","id":"t1","name":"Bash","input":{"command":"ls"}}]}}
        \\{"type":"user","isSidechain":false,"message":{"role":"user","content":[{"type":"tool_result","tool_use_id":"t1","content":"a.zig"}]}}
        \\{"type":"assistant","isSidechain":true,"message":{"content":[{"type":"text","text":"a subagent's"}]}}
        \\{"type":"assistant","isSidechain":false,"message":{"content":[{"type":"text","text":"Done."}]}}
        \\
    });
    // (A file with nothing said in it isn't listed.)
    const empty = try std.fs.path.join(gpa, &.{ dir, "bbbb-2.jsonl" });
    defer gpa.free(empty);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = empty, .data = "{\"type\":\"session-owner\"}\n" });

    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const list = try sessions(arena.allocator(), io, "/work/my.proj");
    try std.testing.expectEqual(1, list.len);
    try std.testing.expectEqualStrings("aaaa-1", list[0].id);
    try std.testing.expectEqualStrings("fix the parser", list[0].first);

    const c = try create(gpa, io, "/work/my.proj", noWake);
    defer c.destroy();
    try c.say("something else", null);
    try c.resumeSession(list[0].id, list[0].path);
    try std.testing.expectEqualStrings("aaaa-1", c.session.?);
    try std.testing.expectEqual(4, c.entries.items.len);
    try std.testing.expectEqualStrings("fix the parser\nplease", c.entries.items[0].text.items);
    try std.testing.expectEqualStrings("Looking.", c.entries.items[1].text.items);
    try std.testing.expectEqualStrings("ls\n\na.zig", c.entries.items[2].text.items);
    try std.testing.expectEqualStrings("Done.", c.entries.items[3].text.items);
    try std.testing.expectEqual(State.idle, c.state);
}

test "the permission modes are the CLI's own: the choices in its help" {
    const c = try create(std.testing.allocator, std.testing.io, ".", noWake);
    defer c.destroy();
    c.offline = true;
    try c.readModes(
        \\  --permission-mode <mode>              Permission mode to use for the session
        \\                                        (choices: "acceptEdits", "auto",
        \\                                        "manual", "plan")
        \\  --permission-prompts <target>         Who answers (choices: "x")
    );
    try std.testing.expectEqual(4, c.modes.len);
    try std.testing.expectEqualStrings("acceptEdits", c.modes[0]);
    try std.testing.expectEqualStrings("auto", c.modes[1]);
    try std.testing.expectEqualStrings("plan", c.modes[3]);
    try c.event("{\"type\":\"system\",\"subtype\":\"status\",\"permissionMode\":\"default\"}");
    try std.testing.expect(c.modeInUse("manual") and !c.modeInUse("auto"));
}
