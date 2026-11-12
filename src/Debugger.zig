//! Debugging with gdb, through its Debug Adapter Protocol mode (`gdb -i dap`).
//!
//! The program runs on the run popup's terminal (gdb's `inferior-tty`), so
//! its output, colours and input work as in a plain run, while gdb's own
//! stdin/stdout carry the protocol. When the program stops (a breakpoint, a
//! step, a crash) the stack is fetched, then each frame's arguments and
//! locals, and what is inside them (structs, slices, what pointers point
//! at) a few levels down, for the frames you look at.
//!
//! gdb doesn't know Zig: `gdb_setup.py` (sent to it at the start) teaches it
//! slices, optionals, error unions and tagged unions.
//!
//! `plan` works out, from a runner command (`zig build run`, `cargo run`,
//! `./app args`, `make && ./app`), what to build first and which program
//! to start under gdb.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Client = @import("lsp/Client.zig");

const Debugger = @This();

gpa: Allocator,
io: Io,
client: *Client,
seq: i64 = 1,
state: State = .starting,
/// Why it stopped ("breakpoint", "step", "signal SIGSEGV"). Owned.
reason: []u8 = &.{},
thread: i64 = 1,
/// The stack while stopped, innermost first.
frames: std.ArrayList(Frame) = .empty,
/// Requests waiting for their answer, by sequence number.
waiting: std.AutoHashMapUnmanaged(i64, Waiting) = .empty,
/// Bumped on every stop and resume: answers about an older stop are dropped.
gen: u32 = 0,
exit_code: ?i64 = null,
/// The program's process id, once it has started.
pid: ?i64 = null,
/// gdb's word on something that failed (owned), for the editor to show.
note: ?[]u8 = null,
/// The last `Var.id` given out.
var_id: u32 = 0,

pub const State = enum { starting, running, stopped, exited };

const max_frames = 64;
/// Frames whose variables are fetched on a stop (the ones you'd look at).
pub const max_var_frames = 16;
const max_value = 240;
/// A value with its insides listed under it is cut to this.
const max_parent_value = 60;
/// How far into a value its insides are listed.
const max_depth = 3;
/// Of one value's insides (a slice's items, a struct's fields).
const max_children = 32;
/// Of one frame.
const max_vars = 400;

/// `python exec(...)` of `gdb_setup.py`, as one gdb command (so no file has
/// to be written for gdb to `source`).
const printers_command = blk: {
    const script = @embedFile("gdb_setup.py");
    @setEvalBranchQuota(script.len * 20);
    break :blk "python exec(bytes.fromhex('" ++ std.fmt.bytesToHex(script[0..script.len].*, .lower) ++ "').decode())";
};

/// An argument or a local, or something inside one.
pub const Var = struct {
    name: []u8,
    value: []u8,
    /// 0: of the frame itself.
    depth: u8,
    id: u32,
    /// gdb's handle for what is inside it; 0: nothing.
    ref: i64,
    /// Its insides were asked for.
    asked: bool = false,
};

pub const Frame = struct {
    name: []u8,
    /// The source file (absolute), if gdb knows it.
    path: ?[]u8,
    /// 0-based.
    line: u32,
    id: i64,
    /// The arguments, then the locals, each followed by what is inside it.
    vars: std.ArrayList(Var) = .empty,
    /// Answers still to come for `vars`.
    vars_left: u32 = 0,
    /// What is inside its variables is fetched too (`expand`).
    expanded: bool = false,

    fn deinit(f: *Frame, gpa: Allocator) void {
        gpa.free(f.name);
        if (f.path) |p| gpa.free(p);
        for (f.vars.items) |v| {
            gpa.free(v.name);
            gpa.free(v.value);
        }
        f.vars.deinit(gpa);
    }

    /// `name = value` lines, what is inside a value indented under it.
    pub fn writeVars(f: *const Frame, gpa: Allocator, out: *std.ArrayList(u8)) !void {
        for (f.vars.items, 0..) |v, i| {
            try out.appendNTimes(gpa, ' ', @as(usize, v.depth) * 2);
            try out.appendSlice(gpa, v.name);
            const parent = i + 1 < f.vars.items.len and f.vars.items[i + 1].depth > v.depth;
            // A struct's own value is its fields again, on one line.
            if (v.value.len > 0 and !(parent and v.value[0] == '{')) {
                try out.appendSlice(gpa, " = ");
                const end = if (parent) cut(v.value, max_parent_value) else v.value.len;
                try out.appendSlice(gpa, v.value[0..end]);
                if (end < v.value.len) try out.appendSlice(gpa, "…");
            }
            try out.append(gpa, '\n');
        }
    }
};

/// At most `max` bytes of `value`, not through the middle of a character.
fn cut(value: []const u8, max: usize) usize {
    var end = @min(value.len, max);
    while (end < value.len and end > 0 and value[end] & 0xC0 == 0x80) end -= 1;
    return end;
}

const Waiting = union(enum) {
    stack: u32,
    scopes: struct { gen: u32, frame: u32 },
    /// `parent`: the variable these are inside (its id); null: the frame's.
    variables: struct { gen: u32, frame: u32, parent: ?u32 = null },
    launch,
    other,
    /// Nothing is said when it fails.
    quiet,
};

/// What changed in a `poll`, for the editor to show.
pub const Update = struct {
    /// Stopped, and the stack is in `frames`.
    stopped: bool = false,
    /// More of the frames' variables arrived.
    vars: bool = false,
    /// The program (or gdb) is gone.
    ended: bool = false,
    /// `note` is new.
    note: bool = false,
};

pub const Options = struct {
    program: []const u8,
    args: []const []const u8,
    cwd: []const u8,
    /// The terminal the program gets (its stdin, stdout and stderr).
    tty: ?[]const u8 = null,
    breakpoints: []const Breakpoints = &.{},
    /// gdb's stderr goes here.
    log: ?[]const u8 = null,
    wake: *const fn () void,
};

/// A file's breakpoints, 0-based lines.
pub const Breakpoints = struct { path: []const u8, lines: []const u32 };

pub const Step = enum {
    next,
    step_in,
    step_out,
    cont,

    fn command(s: Step) []const u8 {
        return switch (s) {
            .next => "next",
            .step_in => "stepIn",
            .step_out => "stepOut",
            .cont => "continue",
        };
    }
};

/// Starts gdb and the program in it; it runs once the breakpoints are set.
pub fn start(gpa: Allocator, io: Io, opts: Options) !*Debugger {
    // In a session of its own: gdb on zile's terminal (terminal mode) takes
    // it over for job control, and the program never starts.
    const client = try Client.start(gpa, io, &.{ "setsid", "gdb", "-q", "-nx", "-i", "dap" }, opts.wake, opts.log, null);
    errdefer stopGdb(client);
    const d = try gpa.create(Debugger);
    errdefer gpa.destroy(d);
    d.* = .{ .gpa = gpa, .io = io, .client = client };
    errdefer d.waiting.deinit(gpa);
    try d.send("initialize", .{
        .clientID = "zile",
        .adapterID = "gdb",
        .linesStartAt1 = true,
        .columnsStartAt1 = true,
        .pathFormat = "path",
    }, .other);
    try d.send("evaluate", .{ .expression = printers_command, .context = "repl" }, .quiet);
    if (opts.tty) |tty| {
        const cmd = try std.fmt.allocPrint(gpa, "set inferior-tty {s}", .{tty});
        defer gpa.free(cmd);
        try d.send("evaluate", .{ .expression = cmd, .context = "repl" }, .other);
    }
    try d.send("launch", .{ .program = opts.program, .args = opts.args, .cwd = opts.cwd }, .launch);
    for (opts.breakpoints) |b| try d.setBreakpoints(b.path, b.lines);
    // `.{}` would be written as `[]`; DAP wants an object.
    try d.send("configurationDone", struct {}{}, .other);
    return d;
}

/// Ends the session: the program is killed, then gdb.
pub fn deinit(d: *Debugger) void {
    if (d.state != .exited) d.send("disconnect", .{ .terminateDebuggee = true }, .other) catch {};
    // gdb going away may leave the program running, detached: make sure.
    if (d.state != .exited) if (d.pid) |pid| if (std.math.cast(c_int, pid)) |p| {
        _ = killProcess(p, 9);
    };
    stopGdb(d.client);
    d.clearFrames();
    d.frames.deinit(d.gpa);
    d.waiting.deinit(d.gpa);
    d.gpa.free(d.reason);
    if (d.note) |n| d.gpa.free(n);
    d.gpa.destroy(d);
}

/// gdb ignores SIGTERM, which is what the client's cleanup sends before
/// waiting for it: that wait would never end (the editor would hang).
fn stopGdb(client: *Client) void {
    if (client.child.id) |pid| _ = killProcess(pid, 9);
    client.deinit();
}

const killProcess = @extern(*const fn (c_int, c_int) callconv(.c) c_int, .{ .name = "kill" });

/// Replaces the breakpoints in `path`.
pub fn setBreakpoints(d: *Debugger, path: []const u8, lines: []const u32) !void {
    const Line = struct { line: u32 };
    const list = try d.gpa.alloc(Line, lines.len);
    defer d.gpa.free(list);
    for (lines, list) |l, *out| out.* = .{ .line = l + 1 };
    try d.send("setBreakpoints", .{ .source = .{ .path = path }, .breakpoints = list }, .other);
}

/// `n` / `s` / `f` / `c`: on from a stop.
pub fn step(d: *Debugger, how: Step) !void {
    if (d.state != .stopped) return;
    try d.send(how.command(), .{ .threadId = d.thread }, .other);
    d.resumed();
}

/// Stops the running program where it is.
pub fn pause(d: *Debugger) !void {
    if (d.state != .running) return;
    try d.send("pause", .{ .threadId = d.thread }, .other);
}

fn resumed(d: *Debugger) void {
    d.state = .running;
    d.gen += 1;
    d.clearFrames();
}

fn clearFrames(d: *Debugger) void {
    for (d.frames.items) |*f| f.deinit(d.gpa);
    d.frames.clearRetainingCapacity();
}

fn send(d: *Debugger, command: []const u8, arguments: anytype, why: Waiting) !void {
    const seq = d.seq;
    d.seq += 1;
    try d.waiting.put(d.gpa, seq, why);
    errdefer _ = d.waiting.remove(seq);
    try d.client.send(.{ .seq = seq, .type = "request", .command = command, .arguments = arguments });
}

/// Handles what gdb sent since the last call.
pub fn poll(d: *Debugger) Update {
    var msgs: std.ArrayList([]u8) = .empty;
    defer msgs.deinit(d.gpa);
    const alive = d.client.takeMessages(&msgs);
    var up: Update = .{};
    for (msgs.items) |body| {
        defer d.gpa.free(body);
        var parsed = std.json.parseFromSlice(std.json.Value, d.gpa, body, .{}) catch continue;
        defer parsed.deinit();
        d.handle(parsed.value, &up) catch {};
    }
    if (!alive and d.state != .exited) {
        d.state = .exited;
        up.ended = true;
    }
    return up;
}

fn handle(d: *Debugger, msg: std.json.Value, up: *Update) !void {
    const kind = str(field(msg, "type")) orelse return;
    if (std.mem.eql(u8, kind, "response")) return d.onResponse(msg, up);
    if (!std.mem.eql(u8, kind, "event")) return;
    const event = str(field(msg, "event")) orelse return;
    const body = field(msg, "body");
    if (std.mem.eql(u8, event, "stopped")) {
        d.clearFrames();
        d.gen += 1;
        d.state = .stopped;
        const reason = str(field(body, "reason")) orelse "stopped";
        const desc = str(field(body, "description")) orelse str(field(body, "text"));
        d.gpa.free(d.reason);
        d.reason = &.{};
        d.reason = if (desc) |x| (if (!std.mem.eql(u8, x, reason)) try std.fmt.allocPrint(d.gpa, "{s}: {s}", .{ reason, x }) else try d.gpa.dupe(u8, reason)) else try d.gpa.dupe(u8, reason);
        if (int(field(body, "threadId"))) |t| d.thread = t;
        try d.send("stackTrace", .{ .threadId = d.thread, .startFrame = 0, .levels = max_frames }, .{ .stack = d.gen });
    } else if (std.mem.eql(u8, event, "continued")) {
        if (d.state == .stopped) d.resumed();
    } else if (std.mem.eql(u8, event, "process")) {
        d.pid = int(field(body, "systemProcessId"));
    } else if (std.mem.eql(u8, event, "exited")) {
        d.exit_code = int(field(body, "exitCode"));
        // Its process id may be another's from here on.
        d.pid = null;
    } else if (std.mem.eql(u8, event, "terminated")) {
        d.state = .exited;
        up.ended = true;
    } else if (std.mem.eql(u8, event, "output")) {
        // gdb's own chatter is "stdout"/"console"; the program has its terminal.
        const category = str(field(body, "category")) orelse return;
        if (!std.mem.eql(u8, category, "important")) return;
        try d.setNote(std.mem.trim(u8, str(field(body, "output")) orelse return, " \r\n"));
        up.note = true;
    }
}

fn onResponse(d: *Debugger, msg: std.json.Value, up: *Update) !void {
    const rseq = int(field(msg, "request_seq")) orelse return;
    const why = (d.waiting.fetchRemove(rseq) orelse return).value;
    const ok = if (field(msg, "success")) |s| s == .bool and s.bool else false;
    const body = field(msg, "body");
    if (!ok) {
        // An answer that won't come still counts as one.
        switch (why) {
            .scopes => |s| d.varsAnswered(s.gen, s.frame, up),
            .variables => |v| {
                d.varsAnswered(v.gen, v.frame, up);
                // Inside a value there's often nothing to read (a dangling pointer).
                if (v.parent != null) return;
            },
            .quiet => return,
            else => {},
        }
        const command = str(field(msg, "command")) orelse "";
        const text = try std.fmt.allocPrint(d.gpa, "{s}: {s}", .{ command, str(field(msg, "message")) orelse "failed" });
        defer d.gpa.free(text);
        try d.setNote(text);
        up.note = true;
        if (why == .launch) {
            d.state = .exited;
            up.ended = true;
        }
        return;
    }
    switch (why) {
        .launch => if (d.state == .starting) {
            d.state = .running;
        },
        .stack => |gen| {
            if (gen != d.gen) return;
            const list = field(body, "stackFrames") orelse return;
            if (list != .array) return;
            for (list.array.items) |f| {
                const name = try d.gpa.dupe(u8, str(field(f, "name")) orelse "??");
                errdefer d.gpa.free(name);
                const path: ?[]u8 = if (str(field(field(f, "source"), "path"))) |p| try d.gpa.dupe(u8, p) else null;
                errdefer if (path) |p| d.gpa.free(p);
                const line: u32 = @intCast(std.math.clamp(int(field(f, "line")) orelse 1, 1, std.math.maxInt(u32)) - 1);
                try d.frames.append(d.gpa, .{ .name = name, .path = path, .line = line, .id = int(field(f, "id")) orelse 0 });
            }
            for (d.frames.items[0..@min(d.frames.items.len, max_var_frames)], 0..) |*f, i| {
                // Where it stopped is looked at first; the others when shown.
                f.expanded = i == 0;
                f.vars_left = 1;
                try d.send("scopes", .{ .frameId = f.id }, .{ .scopes = .{ .gen = d.gen, .frame = @intCast(i) } });
            }
            up.stopped = true;
        },
        .scopes => |s| {
            if (s.gen != d.gen or s.frame >= d.frames.items.len) return;
            const f = &d.frames.items[s.frame];
            f.vars_left -|= 1;
            const list = field(body, "scopes") orelse return;
            if (list == .array) for (list.array.items) |scope| {
                // Arguments and locals; not the registers.
                const hint = str(field(scope, "presentationHint")) orelse str(field(scope, "name")) orelse continue;
                if (!std.ascii.eqlIgnoreCase(hint, "arguments") and !std.ascii.eqlIgnoreCase(hint, "locals")) continue;
                const ref = int(field(scope, "variablesReference")) orelse continue;
                if (ref <= 0) continue;
                f.vars_left += 1;
                try d.send("variables", .{ .variablesReference = ref }, .{ .variables = .{ .gen = d.gen, .frame = s.frame } });
            };
            if (f.vars_left == 0) up.vars = true;
        },
        .variables => |v| {
            if (v.gen != d.gen or v.frame >= d.frames.items.len) return;
            const f = &d.frames.items[v.frame];
            f.vars_left -|= 1;
            up.vars = true;
            // After the variable they're inside (and what's inside it so far).
            var at = f.vars.items.len;
            var depth: u8 = 0;
            if (v.parent) |id| {
                const p = for (f.vars.items, 0..) |x, i| {
                    if (x.id == id) break i;
                } else return;
                depth = f.vars.items[p].depth + 1;
                at = p + 1;
                while (at < f.vars.items.len and f.vars.items[at].depth >= depth) at += 1;
            }
            const list = field(body, "variables") orelse return;
            if (list != .array) return;
            // gdb puts what a pointer points at in a `value` of its own:
            // a level that says nothing, so its insides go under the pointer.
            const pointee = v.parent != null and list.array.items.len == 1 and
                std.mem.eql(u8, str(field(list.array.items[0], "name")) orelse "", "value");
            if (pointee) if (int(field(list.array.items[0], "variablesReference"))) |ref| if (ref > 0) {
                f.vars_left += 1;
                return d.send("variables", .{ .variablesReference = ref }, .{ .variables = v });
            };
            for (list.array.items, 0..) |x, n| {
                if (n == max_children or f.vars.items.len >= max_vars) {
                    const name = try std.fmt.allocPrint(d.gpa, "… {d} more", .{list.array.items.len - n});
                    errdefer d.gpa.free(name);
                    try d.addVar(f, at, .{ .name = name, .value = &.{}, .depth = depth, .id = 0, .ref = 0 });
                    break;
                }
                const value = str(field(x, "value")) orelse "";
                const name = try d.gpa.dupe(u8, if (pointee) "*" else str(field(x, "name")) orelse continue);
                errdefer d.gpa.free(name);
                // One line each, cut short when long.
                const end = cut(value, max_value);
                const shown = try std.mem.concat(d.gpa, u8, &.{ value[0..end], if (end < value.len) "…" else "" });
                errdefer d.gpa.free(shown);
                for (shown) |*b| if (b.* == '\n' or b.* == '\r') {
                    b.* = ' ';
                };
                try d.addVar(f, at, .{ .name = name, .value = shown, .depth = depth, .id = 0, .ref = int(field(x, "variablesReference")) orelse 0 });
                at += 1;
            }
            if (f.expanded) try d.askInside(v.frame);
        },
        .other, .quiet => {},
    }
}

fn varsAnswered(d: *Debugger, gen: u32, frame: u32, up: *Update) void {
    if (gen != d.gen or frame >= d.frames.items.len) return;
    d.frames.items[frame].vars_left -|= 1;
    up.vars = true;
}

fn addVar(d: *Debugger, f: *Frame, at: usize, v: Var) !void {
    var x = v;
    d.var_id += 1;
    x.id = d.var_id;
    try f.vars.insert(d.gpa, at, x);
}

/// What is inside frame `index`'s variables is fetched too (it's being
/// looked at). Again is fine.
pub fn expand(d: *Debugger, index: usize) !void {
    if (d.state != .stopped or index >= d.frames.items.len or index >= max_var_frames) return;
    d.frames.items[index].expanded = true;
    try d.askInside(@intCast(index));
}

fn askInside(d: *Debugger, index: u32) !void {
    const f = &d.frames.items[index];
    for (f.vars.items) |*v| {
        if (v.asked or v.ref <= 0 or v.depth >= max_depth) continue;
        if (f.vars.items.len + f.vars_left >= max_vars) break;
        v.asked = true;
        // Text is all there already; a null pointer points at nothing.
        if (v.value.len > 0 and v.value[0] == '"') continue;
        if (std.mem.eql(u8, v.value, "0x0")) continue;
        f.vars_left += 1;
        try d.send("variables", .{ .variablesReference = v.ref }, .{ .variables = .{ .gen = d.gen, .frame = index, .parent = v.id } });
    }
}

fn setNote(d: *Debugger, text: []const u8) !void {
    if (d.note) |n| d.gpa.free(n);
    d.note = null;
    d.note = try d.gpa.dupe(u8, text);
}

/// Takes `note` (caller frees).
pub fn takeNote(d: *Debugger) ?[]u8 {
    defer d.note = null;
    return d.note;
}

fn field(v: ?std.json.Value, name: []const u8) ?std.json.Value {
    const val = v orelse return null;
    if (val != .object) return null;
    return val.object.get(name);
}

fn str(v: ?std.json.Value) ?[]const u8 {
    const val = v orelse return null;
    return if (val == .string) val.string else null;
}

fn int(v: ?std.json.Value) ?i64 {
    const val = v orelse return null;
    return if (val == .integer) val.integer else null;
}

// ---------------------------------------------------------------------------
// From a runner command to a program

/// What to do to debug a command: build (through the shell) first, then
/// start `program` with `args` under gdb.
pub const Plan = struct {
    build: ?[]u8 = null,
    /// A path (relative to where the command runs, or absolute), or a name
    /// to find on PATH; with `newest_in`, the folder the build system puts
    /// programs in: which one it is, it doesn't say (it's looked for there
    /// once the build is done).
    program: []u8,
    newest_in: bool = false,
    /// With `newest_in`: how to ask the build system which program the
    /// build made, once it is done (`Search` asks first, and only looks in
    /// the folder when that gives no answer).
    query: ?Query = null,
    /// The command asks for an optimized build (`--release`, `-O`): such a
    /// program loses variables and its lines jump about under a debugger.
    release: bool = false,
    args: [][]u8,

    pub fn deinit(p: Plan, gpa: Allocator) void {
        if (p.build) |b| gpa.free(b);
        if (p.query) |q| q.deinit(gpa);
        gpa.free(p.program);
        for (p.args) |a| gpa.free(a);
        gpa.free(p.args);
    }

    pub fn clone(p: Plan, gpa: Allocator) !Plan {
        const build: ?[]u8 = if (p.build) |b| try gpa.dupe(u8, b) else null;
        errdefer if (build) |b| gpa.free(b);
        const program = try gpa.dupe(u8, p.program);
        errdefer gpa.free(program);
        const query: ?Query = if (p.query) |q| try q.clone(gpa) else null;
        errdefer if (query) |q| q.deinit(gpa);
        return .{ .build = build, .program = program, .newest_in = p.newest_in, .query = query, .release = p.release, .args = try dupeAll(gpa, p.args) };
    }
};

/// A build system's own answer to "which program did that build?".
pub const Query = struct {
    tool: enum {
        /// `zig build --print-configuration`: the step's run step, the
        /// artifact it runs, and where that is installed.
        zig,
        /// `cargo build --message-format=json`: each artifact, with its
        /// path (`executable`).
        cargo,
    },
    argv: [][]u8,
    /// zig: the step that runs the program (`run`).
    step: []u8 = &.{},
    /// zig: where it installs programs (`-p`, `--prefix-exe-dir`).
    bin_dir: []u8 = &.{},

    pub fn deinit(q: Query, gpa: Allocator) void {
        for (q.argv) |a| gpa.free(a);
        gpa.free(q.argv);
        gpa.free(q.step);
        gpa.free(q.bin_dir);
    }

    pub fn clone(q: Query, gpa: Allocator) !Query {
        const argv = try dupeAll(gpa, q.argv);
        errdefer {
            for (argv) |a| gpa.free(a);
            gpa.free(argv);
        }
        const step_name = try gpa.dupe(u8, q.step);
        errdefer gpa.free(step_name);
        return .{ .tool = q.tool, .argv = argv, .step = step_name, .bin_dir = try gpa.dupe(u8, q.bin_dir) };
    }

    /// Runs it in `folder`: the programs (absolute paths) the build made.
    /// Empty when it can't say. Caller frees.
    fn programs(q: Query, gpa: Allocator, io: Io, folder: []const u8) ![][]u8 {
        var arena_state: std.heap.ArenaAllocator = .init(gpa);
        defer arena_state.deinit();
        const arena = arena_state.allocator();
        const r = std.process.run(arena, io, .{ .argv = q.argv, .cwd = .{ .path = folder }, .stdout_limit = .limited(64 << 20) }) catch return &.{};
        if (r.term != .exited or r.term.exited != 0) return &.{};
        var out: std.ArrayList([]u8) = .empty;
        errdefer {
            for (out.items) |x| gpa.free(x);
            out.deinit(gpa);
        }
        switch (q.tool) {
            .zig => if (try zigProgram(arena, r.stdout, q.step)) |name| {
                try out.append(gpa, try std.fs.path.resolve(gpa, &.{ folder, q.bin_dir, name }));
            },
            .cargo => for (try cargoPrograms(arena, r.stdout)) |path| {
                try out.append(gpa, try std.fs.path.resolve(gpa, &.{ folder, path }));
            },
        }
        // Only what is there (a build that failed half-way).
        var i: usize = 0;
        while (i < out.items.len) {
            if (Io.Dir.cwd().statFile(io, out.items[i], .{})) |_| {
                i += 1;
            } else |_| gpa.free(out.orderedRemove(i));
        }
        return out.toOwnedSlice(gpa);
    }
};

/// `zig build` options whose value is the next word.
fn isValuedOption(x: []const u8) bool {
    for ([_][]const u8{ "-p", "--prefix", "--prefix-exe-dir", "--prefix-lib-dir", "--prefix-include-dir", "--build-file", "--cache-dir", "--global-cache-dir", "--zig-lib-dir", "--sysroot", "--search-prefix", "--libc", "--maxrss" }) |o| {
        if (std.mem.eql(u8, x, o)) return true;
    }
    return false;
}

/// From `zig build --print-configuration` (ZON): the name of the program
/// that `step` runs, if the build installs it among its programs.
pub fn zigProgram(arena: Allocator, zon: []const u8, step_name: []const u8) !?[]const u8 {
    const source = try arena.dupeSentinel(u8, zon, 0);
    const tree = try std.zig.Ast.parse(arena, source, .{ .mode = .zon });
    if (tree.errors.len > 0) return null;
    const zoir = try std.zig.ZonGen.generate(arena, tree, .{});
    if (zoir.hasCompileErrors()) return null;
    const Z = struct {
        zoir: *const std.zig.Zoir,
        fn get(z: @This(), node: ?std.zig.Zoir.Node.Index, name: []const u8) ?std.zig.Zoir.Node.Index {
            const n = node orelse return null;
            const st = switch (n.get(z.zoir)) {
                .struct_literal => |x| x,
                else => return null,
            };
            for (st.names, 0..) |nm, i| if (std.mem.eql(u8, nm.get(z.zoir), name)) return st.vals.at(@intCast(i));
            return null;
        }
        fn int(z: @This(), node: ?std.zig.Zoir.Node.Index) ?u32 {
            return switch ((node orelse return null).get(z.zoir)) {
                .int_literal => |v| switch (v) {
                    .small => |x| std.math.cast(u32, x),
                    .big => null,
                },
                else => null,
            };
        }
        fn enumName(z: @This(), node: ?std.zig.Zoir.Node.Index) ?[]const u8 {
            return switch ((node orelse return null).get(z.zoir)) {
                .enum_literal => |x| x.get(z.zoir),
                else => null,
            };
        }
        fn str(z: @This(), node: ?std.zig.Zoir.Node.Index) ?[]const u8 {
            return switch ((node orelse return null).get(z.zoir)) {
                .string_literal => |x| x,
                else => null,
            };
        }
        fn list(z: @This(), node: ?std.zig.Zoir.Node.Index) ?std.zig.Zoir.Node.Index.Range {
            return switch ((node orelse return null).get(z.zoir)) {
                .array_literal => |r| r,
                .empty_literal => .{ .start = .root, .len = 0 },
                else => null,
            };
        }
        fn tag(z: @This(), s: std.zig.Zoir.Node.Index) ?[]const u8 {
            return z.enumName(z.get(z.get(z.get(s, "extended"), "flags"), "tag"));
        }
    };
    const z: Z = .{ .zoir = &zoir };
    const root: std.zig.Zoir.Node.Index = .root;
    const steps = z.list(z.get(root, "steps")) orelse return null;
    const top = z.int(z.get(z.get(root, "top_level_steps"), step_name)) orelse return null;
    // Down from the step to the run step under it.
    var seen = try arena.alloc(bool, steps.len);
    @memset(seen, false);
    var todo: std.ArrayList(u32) = .empty;
    try todo.append(arena, top);
    const producer = while (todo.pop()) |i| {
        if (i >= steps.len or seen[i]) continue;
        seen[i] = true;
        const st = steps.at(i);
        if (std.mem.eql(u8, z.tag(st) orelse "", "run")) {
            if (z.int(z.get(z.get(st, "extended"), "producer"))) |p| break p;
        }
        const deps = z.list(z.get(st, "deps")) orelse continue;
        for (0..deps.len) |d| if (z.int(deps.at(@intCast(d)))) |x| try todo.append(arena, x);
    } else return null;
    if (producer >= steps.len) return null;
    const name = z.str(z.get(z.get(steps.at(producer), "extended"), "root_name")) orelse return null;
    // Installed among the programs (`bin_dir = .bin`, under its own name)?
    for (0..steps.len) |i| {
        const st = steps.at(@intCast(i));
        if (!std.mem.eql(u8, z.tag(st) orelse "", "install_artifact")) continue;
        const deps = z.list(z.get(st, "deps")) orelse continue;
        const on_it = for (0..deps.len) |d| {
            if (z.int(deps.at(@intCast(d))) == producer) break true;
        } else false;
        if (!on_it) continue;
        const ext = z.get(st, "extended");
        if (!std.mem.eql(u8, z.enumName(z.get(ext, "bin_dir")) orelse "", "bin")) continue;
        if (z.get(ext, "bin_sub_path")) |sub| if (sub.get(&zoir) != .null) continue;
        return name;
    }
    return null;
}

/// From `cargo build --message-format=json`: the programs it built (bins
/// and examples), as cargo says where.
pub fn cargoPrograms(arena: Allocator, out: []const u8) ![]const []const u8 {
    var list: std.ArrayList([]const u8) = .empty;
    var lines = std.mem.splitScalar(u8, out, '\n');
    while (lines.next()) |line| {
        if (line.len == 0 or line[0] != '{') continue;
        const v = std.json.parseFromSliceLeaky(std.json.Value, arena, line, .{}) catch continue;
        if (!std.mem.eql(u8, str(field(v, "reason")) orelse "", "compiler-artifact")) continue;
        const exe = str(field(v, "executable")) orelse continue;
        const kinds = field(field(v, "target"), "kind") orelse continue;
        if (kinds != .array) continue;
        const runnable = for (kinds.array.items) |k| {
            const name = if (k == .string) k.string else continue;
            if (std.mem.eql(u8, name, "bin") or std.mem.eql(u8, name, "example")) break true;
        } else false;
        if (!runnable) continue;
        for (list.items) |x| {
            if (std.mem.eql(u8, x, exe)) break;
        } else try list.append(arena, exe);
    }
    return list.items;
}

pub const PlanResult = union(enum) {
    plan: Plan,
    /// Why it can't be debugged.
    unsupported: []const u8,
};

/// How to debug `cmd`, a runner command:
///
///   zig build run [-- args]   `zig build`, then the program it installed
///   zig run main.zig          `zig build-exe main.zig`, then that
///   cargo run [-- args]       `cargo build`, then target/debug's program
///   ./app args, app args      that program
///   build && ./app args       the build, then the program
pub fn plan(gpa: Allocator, cmd: []const u8) !PlanResult {
    const whole = std.mem.trim(u8, cmd, " \t\r\n");
    if (std.mem.lastIndexOf(u8, whole, "&&")) |at| {
        const before = std.mem.trim(u8, whole[0..at], " \t");
        var r = try plan(gpa, whole[at + 2 ..]);
        switch (r) {
            .unsupported => return r,
            .plan => |*p| {
                const b = if (p.build) |inner| try std.fmt.allocPrint(gpa, "{s} && {s}", .{ before, inner }) else try gpa.dupe(u8, before);
                if (p.build) |old| gpa.free(old);
                p.build = b;
                return r;
            },
        }
    }
    var toks = tokenize(gpa, whole) catch |err| switch (err) {
        error.Shell => return .{ .unsupported = "it uses the shell (pipes, $variables, ;): gdb needs one program and its arguments" },
        error.OutOfMemory => return error.OutOfMemory,
    };
    defer {
        for (toks.items) |t| gpa.free(t);
        toks.deinit(gpa);
    }
    const t = toks.items;
    if (t.len == 0) return .{ .unsupported = "there's nothing to run" };
    if (std.mem.indexOfScalar(u8, t[0], '=') != null and std.mem.indexOfScalar(u8, t[0], '/') == null)
        return .{ .unsupported = "it sets environment variables first (not yet supported)" };
    const dash = for (t, 0..) |x, i| {
        if (std.mem.eql(u8, x, "--")) break i;
    } else t.len;
    const head = t[0..dash];
    const tail = if (dash < t.len) t[dash + 1 ..] else t[t.len..];

    if (std.mem.eql(u8, t[0], "zig") and head.len >= 2 and std.mem.eql(u8, head[1], "build")) {
        // A step to run, before anything is put together for it.
        const has_step = for (head[2..], 2..) |x, i| {
            const after_valued = i > 2 and isValuedOption(head[i - 1]);
            if (x.len > 0 and x[0] != '-' and !after_valued) break true;
        } else false;
        if (!has_step) return .{ .unsupported = "`zig build` without a step (`run`): which program does it start?" };
        var build: std.ArrayList(u8) = .empty;
        errdefer build.deinit(gpa);
        try build.appendSlice(gpa, "zig build");
        // The same options, asking for the configuration instead.
        var argv: std.ArrayList([]u8) = .empty;
        errdefer {
            for (argv.items) |a| gpa.free(a);
            argv.deinit(gpa);
        }
        try argv.append(gpa, try gpa.dupe(u8, "zig"));
        try argv.append(gpa, try gpa.dupe(u8, "build"));
        var release = false;
        var first_step: ?[]const u8 = null;
        var prefix: []const u8 = "zig-out";
        var exe_dir: ?[]const u8 = null;
        var i: usize = 2;
        while (i < head.len) : (i += 1) {
            const x = head[i];
            // Options with their value in the next word.
            const valued = isValuedOption(x);
            if (valued and i + 1 < head.len) {
                const val = head[i + 1];
                if (std.mem.eql(u8, x, "-p") or std.mem.eql(u8, x, "--prefix")) prefix = val;
                if (std.mem.eql(u8, x, "--prefix-exe-dir")) exe_dir = val;
                try appendWord(gpa, &build, x);
                try appendWord(gpa, &build, val);
                try argv.append(gpa, try gpa.dupe(u8, x));
                try argv.append(gpa, try gpa.dupe(u8, val));
                i += 1;
                continue;
            }
            if (x.len > 0 and x[0] != '-') {
                // A step: the first is the one that runs the program.
                if (first_step == null) first_step = x;
                continue;
            }
            if (std.mem.eql(u8, x, "--release") or std.mem.startsWith(u8, x, "--release=") or (std.mem.startsWith(u8, x, "-Doptimize=") and !std.mem.endsWith(u8, x, "=Debug"))) release = true;
            try appendWord(gpa, &build, x);
            try argv.append(gpa, try gpa.dupe(u8, x));
        }
        const run_step = first_step orelse return .{ .unsupported = "`zig build` without a step (`run`): which program does it start?" };
        try argv.append(gpa, try gpa.dupe(u8, "--print-configuration"));
        const bin_dir = if (exe_dir) |d| try gpa.dupe(u8, d) else try std.fs.path.join(gpa, &.{ prefix, "bin" });
        errdefer gpa.free(bin_dir);
        const step_owned = try gpa.dupe(u8, run_step);
        errdefer gpa.free(step_owned);
        const program = try gpa.dupe(u8, bin_dir);
        errdefer gpa.free(program);
        const argv_owned = try argv.toOwnedSlice(gpa);
        errdefer {
            for (argv_owned) |a| gpa.free(a);
            gpa.free(argv_owned);
        }
        return .{ .plan = .{
            .build = try build.toOwnedSlice(gpa),
            .program = program,
            .newest_in = true,
            .query = .{ .tool = .zig, .argv = argv_owned, .step = step_owned, .bin_dir = bin_dir },
            .release = release,
            .args = try dupeAll(gpa, tail),
        } };
    }
    if (std.mem.eql(u8, t[0], "zig") and head.len >= 3 and std.mem.eql(u8, head[1], "run")) {
        const source = for (head[2..]) |x| {
            if (std.mem.endsWith(u8, x, ".zig")) break x;
        } else return .{ .unsupported = "`zig run` without a .zig file" };
        const base = std.fs.path.basename(source);
        const out = try std.fmt.allocPrint(gpa, ".zig-cache/zile-debug/{s}", .{base[0 .. base.len - ".zig".len]});
        errdefer gpa.free(out);
        var build: std.ArrayList(u8) = .empty;
        errdefer build.deinit(gpa);
        try build.appendSlice(gpa, "mkdir -p .zig-cache/zile-debug && zig build-exe");
        var release = false;
        for (head[2..]) |x| {
            // `-O ReleaseFast`, `-OReleaseFast`.
            if (std.mem.startsWith(u8, x, "-O")) release = true;
            try appendWord(gpa, &build, x);
        }
        try build.appendSlice(gpa, " -femit-bin=");
        try build.appendSlice(gpa, out);
        return .{ .plan = .{ .build = try build.toOwnedSlice(gpa), .program = out, .release = release, .args = try dupeAll(gpa, tail) } };
    }
    if (std.mem.eql(u8, t[0], "cargo") and head.len >= 2 and std.mem.eql(u8, head[1], "run")) {
        var build: std.ArrayList(u8) = .empty;
        errdefer build.deinit(gpa);
        try build.appendSlice(gpa, "cargo build");
        var release = false;
        var bin: ?[]const u8 = null;
        for (head[2..], 2..) |x, i| {
            if (std.mem.eql(u8, x, "--release") or std.mem.eql(u8, x, "-r")) release = true;
            try appendWord(gpa, &build, x);
            if (std.mem.eql(u8, x, "--bin") and i + 1 < head.len) bin = head[i + 1];
            if (std.mem.startsWith(u8, x, "--bin=")) bin = x["--bin=".len..];
        }
        const dir = if (release) "target/release" else "target/debug";
        const program = if (bin) |b| try std.fmt.allocPrint(gpa, "{s}/{s}", .{ dir, b }) else try gpa.dupe(u8, dir);
        errdefer gpa.free(program);
        // Cargo says where it put them (a target dir of its own, say).
        var argv: std.ArrayList([]u8) = .empty;
        errdefer {
            for (argv.items) |a| gpa.free(a);
            argv.deinit(gpa);
        }
        try argv.append(gpa, try gpa.dupe(u8, "cargo"));
        try argv.append(gpa, try gpa.dupe(u8, "build"));
        for (head[2..]) |x| try argv.append(gpa, try gpa.dupe(u8, x));
        try argv.append(gpa, try gpa.dupe(u8, "--quiet"));
        try argv.append(gpa, try gpa.dupe(u8, "--message-format=json"));
        const argv_owned = try argv.toOwnedSlice(gpa);
        errdefer {
            for (argv_owned) |a| gpa.free(a);
            gpa.free(argv_owned);
        }
        return .{ .plan = .{
            .build = try build.toOwnedSlice(gpa),
            .program = program,
            .newest_in = true,
            .query = .{ .tool = .cargo, .argv = argv_owned, .step = try gpa.dupe(u8, ""), .bin_dir = try gpa.dupe(u8, "") },
            .release = release,
            .args = try dupeAll(gpa, tail),
        } };
    }
    const name = std.fs.path.basename(t[0]);
    for ([_][]const u8{ "go", "gopls" }) |x| if (std.mem.eql(u8, name, x))
        return .{ .unsupported = "gdb doesn't follow Go programs well (delve is Go's debugger)" };
    for ([_][]const u8{ "node", "npm", "npx", "pnpm", "yarn", "bun", "deno", "python", "python3", "ruby", "lua", "luajit", "sh", "bash", "zsh", "fish", "perl", "php" }) |x| if (std.mem.eql(u8, name, x))
        return .{ .unsupported = "it runs a script: gdb debugs compiled programs" };
    for ([_][]const u8{ "make", "cmake", "ninja", "meson", "just" }) |x| if (std.mem.eql(u8, name, x))
        return .{ .unsupported = "which program does it build? Write it as `make && ./program`" };
    return .{ .plan = .{ .program = try gpa.dupe(u8, t[0]), .args = try dupeAll(gpa, t[1..]) } };
}

pub fn dupeArgs(gpa: Allocator, list: []const []u8) ![][]u8 {
    return dupeAll(gpa, list);
}

/// The compiled programs (ELF executables) under `root`, as paths relative
/// to it, newest first: what a build just made comes first. Hidden folders
/// (`.zig-cache`, `.git`) aren't looked in. Caller frees each and the slice.
/// Setting `stop` ends it early (with what was found so far).
pub fn findPrograms(gpa: Allocator, io: Io, root_path: []const u8, stop: ?*const std.atomic.Value(bool)) ![][]u8 {
    const Found = struct { path: []u8, time: Io.Timestamp };
    var found: std.ArrayList(Found) = .empty;
    defer found.deinit(gpa);
    errdefer for (found.items) |f| gpa.free(f.path);
    var root = Io.Dir.cwd().openDir(io, root_path, .{ .iterate = true }) catch return gpa.alloc([]u8, 0);
    defer root.close(io);
    var w = try root.walkSelectively(gpa);
    defer {
        while (w.stack.items.len > 0) w.leave(io);
        w.deinit();
    }
    while (true) {
        if (stop) |x| if (x.load(.acquire)) break;
        const entry = (w.next(io) catch continue) orelse break;
        switch (entry.kind) {
            .directory => if (entry.basename[0] != '.') w.enter(io, entry) catch {},
            .file => {
                const st = entry.dir.statFile(io, entry.basename, .{}) catch continue;
                if (st.permissions.toMode() & 0o111 == 0) continue;
                var head: [4]u8 = undefined;
                const f = entry.dir.openFile(io, entry.basename, .{}) catch continue;
                defer f.close(io);
                const got = f.readPositionalAll(io, &head, 0) catch continue;
                if (got < 4 or !std.mem.eql(u8, &head, "\x7fELF")) continue;
                const path = try gpa.dupe(u8, entry.path);
                errdefer gpa.free(path);
                try found.append(gpa, .{ .path = path, .time = st.mtime });
            },
            else => {},
        }
    }
    std.mem.sort(Found, found.items, {}, struct {
        fn newer(_: void, a: Found, b: Found) bool {
            return a.time.compare(.gt, b.time);
        }
    }.newer);
    const out = try gpa.alloc([]u8, found.items.len);
    for (found.items, out) |f, *o| o.* = f.path;
    found.clearRetainingCapacity();
    return out;
}

/// Looking for the program a build made, off the main thread: where the
/// build system puts programs (`out_dir`) and, with none there, anywhere in
/// `folder`.
pub const Search = struct {
    gpa: Allocator,
    io: Io,
    wake: *const fn () void,
    thread: std.Thread = undefined,
    out_dir: []u8,
    folder: []u8,
    /// Asked first; the folders are looked in only without an answer.
    query: ?Query = null,
    /// The build system said which (not a guess from the folder).
    answered: bool = false,
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// Once `done`: the folder the programs are in (`out_dir` or `folder`)
    /// and their paths in it, newest first.
    dir: []const u8 = "",
    found: [][]u8 = &.{},

    pub fn start(gpa: Allocator, io: Io, out_dir: []const u8, folder: []const u8, query: ?Query, wake: *const fn () void) !*Search {
        const s = try gpa.create(Search);
        errdefer gpa.destroy(s);
        const o = try gpa.dupe(u8, out_dir);
        errdefer gpa.free(o);
        const f = try gpa.dupe(u8, folder);
        errdefer gpa.free(f);
        const q: ?Query = if (query) |x| try x.clone(gpa) else null;
        errdefer if (q) |x| x.deinit(gpa);
        s.* = .{ .gpa = gpa, .io = io, .wake = wake, .out_dir = o, .folder = f, .query = q };
        s.thread = try std.Thread.spawn(.{}, run, .{s});
        return s;
    }

    /// Stops it if it is still looking.
    pub fn destroy(s: *Search) void {
        s.stop.store(true, .release);
        s.thread.join();
        for (s.found) |f| s.gpa.free(f);
        s.gpa.free(s.found);
        s.gpa.free(s.out_dir);
        s.gpa.free(s.folder);
        if (s.query) |q| q.deinit(s.gpa);
        s.gpa.destroy(s);
    }

    pub fn isDone(s: *const Search) bool {
        return s.done.load(.acquire);
    }

    fn run(s: *Search) void {
        if (s.query) |q| {
            const said: [][]u8 = q.programs(s.gpa, s.io, s.folder) catch &.{};
            if (said.len > 0) {
                s.dir = s.folder;
                s.found = said;
                s.answered = true;
                s.done.store(true, .release);
                s.wake();
                return;
            }
            s.gpa.free(said);
        }
        var dir: []const u8 = s.out_dir;
        var found: [][]u8 = findPrograms(s.gpa, s.io, dir, &s.stop) catch &.{};
        if (found.len == 0 and !s.stop.load(.acquire)) {
            s.gpa.free(found);
            dir = s.folder;
            found = findPrograms(s.gpa, s.io, dir, &s.stop) catch &.{};
        }
        s.dir = dir;
        s.found = found;
        s.done.store(true, .release);
        s.wake();
    }
};

fn dupeAll(gpa: Allocator, list: []const []u8) ![][]u8 {
    const out = try gpa.alloc([]u8, list.len);
    var n: usize = 0;
    errdefer {
        for (out[0..n]) |x| gpa.free(x);
        gpa.free(out);
    }
    for (list) |x| {
        out[n] = try gpa.dupe(u8, x);
        n += 1;
    }
    return out;
}

/// ` word`, quoted for the shell if it needs it.
fn appendWord(gpa: Allocator, out: *std.ArrayList(u8), word: []const u8) !void {
    try out.append(gpa, ' ');
    const plain = word.len > 0 and for (word) |b| {
        if (!(std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-_./=:+,@%", b) != null)) break false;
    } else true;
    if (plain) return out.appendSlice(gpa, word);
    try out.append(gpa, '\'');
    for (word) |b| if (b == '\'') try out.appendSlice(gpa, "'\\''") else try out.append(gpa, b);
    try out.append(gpa, '\'');
}

/// Splits a command line into words as the shell would, for simple ones:
/// quotes and backslashes are understood; anything more (pipes,
/// redirection, variables, globs) is `error.Shell`.
fn tokenize(gpa: Allocator, line: []const u8) error{ Shell, OutOfMemory }!std.ArrayList([]u8) {
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |t| gpa.free(t);
        out.deinit(gpa);
    }
    var word: std.ArrayList(u8) = .empty;
    defer word.deinit(gpa);
    var in_word = false;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const b = line[i];
        switch (b) {
            ' ', '\t', '\n' => {
                if (in_word) try out.append(gpa, try word.toOwnedSlice(gpa));
                in_word = false;
            },
            '\'' => {
                const end = std.mem.indexOfScalarPos(u8, line, i + 1, '\'') orelse return error.Shell;
                try word.appendSlice(gpa, line[i + 1 .. end]);
                in_word = true;
                i = end;
            },
            '"' => {
                in_word = true;
                i += 1;
                while (i < line.len and line[i] != '"') : (i += 1) {
                    if (line[i] == '$' or line[i] == '`') return error.Shell;
                    if (line[i] == '\\' and i + 1 < line.len) i += 1;
                    try word.append(gpa, line[i]);
                }
                if (i >= line.len) return error.Shell;
            },
            '\\' => {
                if (i + 1 >= line.len) return error.Shell;
                i += 1;
                try word.append(gpa, line[i]);
                in_word = true;
            },
            '|', '&', ';', '<', '>', '$', '`', '(', ')', '*', '?', '[', '#', '~' => {
                // `~` and `#` only matter at a word's start.
                if ((b == '~' or b == '#') and in_word) {
                    try word.append(gpa, b);
                    continue;
                }
                return error.Shell;
            },
            else => {
                try word.append(gpa, b);
                in_word = true;
            },
        }
    }
    if (in_word) try out.append(gpa, try word.toOwnedSlice(gpa));
    return out;
}

test "plan: what to build and which program to debug" {
    const gpa = std.testing.allocator;
    const Case = struct { cmd: []const u8, build: ?[]const u8, program: []const u8, newest: bool = false, release: bool = false, args: []const []const u8 = &.{} };
    for ([_]Case{
        .{ .cmd = "zig build run", .build = "zig build", .program = "zig-out/bin", .newest = true },
        .{ .cmd = "zig build run -Dfoo=bar -- a 'b c'", .build = "zig build -Dfoo=bar", .program = "zig-out/bin", .newest = true, .args = &.{ "a", "b c" } },
        .{ .cmd = "zig run src/main.zig -- x", .build = "mkdir -p .zig-cache/zile-debug && zig build-exe src/main.zig -femit-bin=.zig-cache/zile-debug/main", .program = ".zig-cache/zile-debug/main", .args = &.{"x"} },
        .{ .cmd = "cargo run", .build = "cargo build", .program = "target/debug", .newest = true },
        // The command is built as written; release flags are only noted.
        .{ .cmd = "cargo run --release --bin srv -- -p 80", .build = "cargo build --release --bin srv", .program = "target/release/srv", .newest = true, .release = true, .args = &.{ "-p", "80" } },
        // Another step, another prefix: the programs are where it says.
        .{ .cmd = "zig build demo -p out -Dx=1", .build = "zig build -p out -Dx=1", .program = "out/bin", .newest = true },
        .{ .cmd = "zig build run --release=fast", .build = "zig build --release=fast", .program = "zig-out/bin", .newest = true, .release = true },
        .{ .cmd = "zig run -O ReleaseFast a.zig", .build = "mkdir -p .zig-cache/zile-debug && zig build-exe -O ReleaseFast a.zig -femit-bin=.zig-cache/zile-debug/a", .program = ".zig-cache/zile-debug/a", .release = true },
        .{ .cmd = "./build/app --verbose \"two words\"", .build = null, .program = "./build/app", .args = &.{ "--verbose", "two words" } },
        .{ .cmd = "make && ./app in.txt", .build = "make", .program = "./app", .args = &.{"in.txt"} },
    }) |c| {
        const r = try plan(gpa, c.cmd);
        const p = r.plan;
        defer p.deinit(gpa);
        if (c.build) |b| try std.testing.expectEqualStrings(b, p.build.?) else try std.testing.expect(p.build == null);
        try std.testing.expectEqualStrings(c.program, p.program);
        try std.testing.expectEqual(c.newest, p.newest_in);
        try std.testing.expectEqual(c.release, p.release);
        try std.testing.expectEqual(c.args.len, p.args.len);
        for (c.args, p.args) |want, got| try std.testing.expectEqualStrings(want, got);
    }
    for ([_][]const u8{ "go run .", "npm run dev", "python3 x.py", "./app | less", "make", "zig build", "FOO=1 ./app", "echo $HOME" }) |cmd| {
        const r = try plan(gpa, cmd);
        try std.testing.expect(r == .unsupported);
    }
    // The question each build system is asked afterwards.
    const z = (try plan(gpa, "zig build run -Doptimize=Debug -- x")).plan;
    defer z.deinit(gpa);
    try std.testing.expectEqualStrings("run", z.query.?.step);
    try std.testing.expectEqual(4, z.query.?.argv.len);
    try std.testing.expectEqualStrings("--print-configuration", z.query.?.argv[3]);
    const cg = (try plan(gpa, "cargo run --bin srv")).plan;
    defer cg.deinit(gpa);
    try std.testing.expectEqualStrings("--message-format=json", cg.query.?.argv[cg.query.?.argv.len - 1]);
}

test "zigProgram: the run step's program, installed in bin" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const zon =
        \\.{
        \\    .top_level_steps = .{ .install = 0, .run = 1 },
        \\    .steps = .{
        \\        .{ .name = "install", .deps = .{2}, .extended = .{ .flags = .{ .tag = .top_level } } },
        \\        .{ .name = "run", .deps = .{3}, .extended = .{ .flags = .{ .tag = .top_level } } },
        \\        .{ .name = "install app", .deps = .{4}, .extended = .{ .flags = .{ .tag = .install_artifact }, .bin_dir = .bin, .bin_sub_path = null } },
        \\        .{ .name = "run exe app", .deps = .{4}, .extended = .{ .flags = .{ .tag = .run }, .producer = 4 } },
        \\        .{ .name = "compile exe app", .deps = .{}, .extended = .{ .flags = .{ .tag = .compile }, .root_name = "app" } },
        \\    },
        \\}
    ;
    try std.testing.expectEqualStrings("app", (try zigProgram(arena.allocator(), zon, "run")).?);
    try std.testing.expect(try zigProgram(arena.allocator(), zon, "install") == null);
    try std.testing.expect(try zigProgram(arena.allocator(), zon, "nope") == null);
}

test "cargoPrograms: bins and examples, not libraries or build scripts" {
    var arena: std.heap.ArenaAllocator = .init(std.testing.allocator);
    defer arena.deinit();
    const out =
        \\{"reason":"compiler-artifact","target":{"kind":["custom-build"]},"executable":"/t/build/x/build-script-build"}
        \\{"reason":"compiler-artifact","target":{"kind":["lib"]},"executable":null}
        \\{"reason":"compiler-artifact","target":{"kind":["bin"]},"executable":"/t/debug/srv"}
        \\{"reason":"build-finished","success":true}
    ;
    const got = try cargoPrograms(arena.allocator(), out);
    try std.testing.expectEqual(1, got.len);
    try std.testing.expectEqualStrings("/t/debug/srv", got[0]);
}
