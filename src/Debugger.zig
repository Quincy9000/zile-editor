//! Debugging with gdb, through its Debug Adapter Protocol mode (`gdb -i dap`).
//!
//! The program runs on the run popup's terminal (gdb's `inferior-tty`), so
//! its output, colours and input work as in a plain run, while gdb's own
//! stdin/stdout carry the protocol. When the program stops (a breakpoint, a
//! step, a crash) the stack is fetched, then each frame's arguments and
//! locals.
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

pub const State = enum { starting, running, stopped, exited };

const max_frames = 64;
/// Frames whose variables are fetched on a stop (the ones you'd look at).
pub const max_var_frames = 16;
const max_value = 240;

pub const Frame = struct {
    name: []u8,
    /// The source file (absolute), if gdb knows it.
    path: ?[]u8,
    /// 0-based.
    line: u32,
    id: i64,
    /// `name = value` lines: the arguments, then the locals.
    vars: std.ArrayList(u8) = .empty,
    /// Answers still to come for `vars`.
    vars_left: u32 = 0,

    fn deinit(f: *Frame, gpa: Allocator) void {
        gpa.free(f.name);
        if (f.path) |p| gpa.free(p);
        f.vars.deinit(gpa);
    }
};

const Waiting = union(enum) {
    stack: u32,
    scopes: struct { gen: u32, frame: u32 },
    variables: struct { gen: u32, frame: u32 },
    launch,
    other,
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
    const client = try Client.start(gpa, io, &.{ "setsid", "gdb", "-q", "-nx", "-i", "dap" }, opts.wake, opts.log);
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
            const list = field(body, "variables") orelse return;
            if (list == .array) for (list.array.items) |x| {
                const name = str(field(x, "name")) orelse continue;
                const value = str(field(x, "value")) orelse "";
                try f.vars.print(d.gpa, "{s} = ", .{name});
                // One line each, cut short when long.
                var end = @min(value.len, max_value);
                // Not through the middle of a character.
                while (end < value.len and end > 0 and value[end] & 0xC0 == 0x80) end -= 1;
                for (value[0..end]) |b| try f.vars.append(d.gpa, if (b == '\n' or b == '\r') ' ' else b);
                if (end < value.len) try f.vars.appendSlice(d.gpa, "…");
                try f.vars.append(d.gpa, '\n');
            };
            up.vars = true;
        },
        .other => {},
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
    /// The command asks for an optimized build (`--release`, `-O`): such a
    /// program loses variables and its lines jump about under a debugger.
    release: bool = false,
    args: [][]u8,

    pub fn deinit(p: Plan, gpa: Allocator) void {
        if (p.build) |b| gpa.free(b);
        gpa.free(p.program);
        for (p.args) |a| gpa.free(a);
        gpa.free(p.args);
    }

    pub fn clone(p: Plan, gpa: Allocator) !Plan {
        const build: ?[]u8 = if (p.build) |b| try gpa.dupe(u8, b) else null;
        errdefer if (build) |b| gpa.free(b);
        const program = try gpa.dupe(u8, p.program);
        errdefer gpa.free(program);
        return .{ .build = build, .program = program, .newest_in = p.newest_in, .release = p.release, .args = try dupeAll(gpa, p.args) };
    }
};

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
        const run = for (head[2..], 2..) |x, i| {
            if (std.mem.eql(u8, x, "run")) break i;
        } else return .{ .unsupported = "`zig build` without `run`: which program does it start?" };
        var build: std.ArrayList(u8) = .empty;
        errdefer build.deinit(gpa);
        try build.appendSlice(gpa, "zig build");
        var release = false;
        for (head[2..], 2..) |x, i| {
            if (i == run) continue;
            if (std.mem.eql(u8, x, "--release") or std.mem.startsWith(u8, x, "--release=") or (std.mem.startsWith(u8, x, "-Doptimize=") and !std.mem.endsWith(u8, x, "=Debug"))) release = true;
            try appendWord(gpa, &build, x);
        }
        return .{ .plan = .{
            .build = try build.toOwnedSlice(gpa),
            .program = try gpa.dupe(u8, "zig-out/bin"),
            .newest_in = true,
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
        return .{ .plan = .{ .build = try build.toOwnedSlice(gpa), .program = program, .newest_in = bin == null, .release = release, .args = try dupeAll(gpa, tail) } };
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
    stop: std.atomic.Value(bool) = .init(false),
    done: std.atomic.Value(bool) = .init(false),
    /// Once `done`: the folder the programs are in (`out_dir` or `folder`)
    /// and their paths in it, newest first.
    dir: []const u8 = "",
    found: [][]u8 = &.{},

    pub fn start(gpa: Allocator, io: Io, out_dir: []const u8, folder: []const u8, wake: *const fn () void) !*Search {
        const s = try gpa.create(Search);
        errdefer gpa.destroy(s);
        const o = try gpa.dupe(u8, out_dir);
        errdefer gpa.free(o);
        const f = try gpa.dupe(u8, folder);
        errdefer gpa.free(f);
        s.* = .{ .gpa = gpa, .io = io, .wake = wake, .out_dir = o, .folder = f };
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
        s.gpa.destroy(s);
    }

    pub fn isDone(s: *const Search) bool {
        return s.done.load(.acquire);
    }

    fn run(s: *Search) void {
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
        .{ .cmd = "cargo run --release --bin srv -- -p 80", .build = "cargo build --release --bin srv", .program = "target/release/srv", .release = true, .args = &.{ "-p", "80" } },
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
}
