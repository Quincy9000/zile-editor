//! The editor's side of debugging (`SPC d`, and Ctrl-Enter in the runner):
//! what to debug, the session's place in the run popup, where it stopped,
//! and the breakpoints. gdb itself is Debugger.zig (its DAP mode).
//!
//! A runner command becomes a build and a program (`Debugger.plan`). The
//! program runs on the run popup's terminal; when it stops, the stop's line
//! is shown and the Debug picker opens with the stack.

const std = @import("std");
const syntax_objects = @import("syntax/objects.zig");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Editor = @import("Editor.zig");
const Buffer = @import("core/Buffer.zig");
const Debugger = @import("Debugger.zig");
const RunMemory = @import("terminal/RunMemory.zig");
const sources = @import("picker/sources.zig");
const config = @import("config/config.zig");
const formatting = @import("editor/formatting.zig");
const notifications = @import("editor/notifications.zig");
const project_ops = @import("editor/project_ops.zig");
const picker_ops = @import("editor/picker_ops.zig");
const picker_query = @import("editor/picker_query.zig");
const run_popup = @import("editor/run_popup.zig");

/// A breakpoint: an absolute path and a 0-based line.
pub const Breakpoint = struct { path: []u8, line: u32 };

pub const Marks = struct { breakpoint: bool = false, here: bool = false };

/// What a runner command (`from`, in `project`) debugs as, this session.
pub const Command = struct {
    project: []u8,
    from: []u8,
    cmd: []u8,

    fn deinit(d: Command, gpa: Allocator) void {
        gpa.free(d.project);
        gpa.free(d.from);
        gpa.free(d.cmd);
    }
};

/// The program a project's build command debugs (`text`: its absolute
/// path).
pub const Program = struct {
    project: []u8,
    text: []u8,

    fn deinit(d: Program, gpa: Allocator) void {
        gpa.free(d.project);
        gpa.free(d.text);
    }
};

/// Frames whose variables are fetched at a stop.
pub const frames_with_variables = Debugger.max_var_frames;

/// What a row of the Debug picker is, kept in its item's id.
pub const Row = union(enum(u8)) {
    /// A stack frame (an index in the session's).
    frame: u32,
    /// A breakpoint (an index in `State.breakpoints`).
    breakpoint: u32,
    /// A program found, when asking which one a build made.
    program: u32,
    /// The command the debugger runs.
    command,

    const Bits = packed struct(u32) { index: u24, kind: u8 };

    pub fn id(r: Row) u32 {
        const index: u32 = switch (r) {
            .frame, .breakpoint, .program => |i| i,
            .command => 0,
        };
        return @bitCast(Bits{ .index = @intCast(index), .kind = @intFromEnum(r) });
    }

    pub fn of(item_id: u32) Row {
        const bits: Bits = @bitCast(item_id);
        const kind = std.enums.fromInt(std.meta.Tag(Row), bits.kind) orelse return .command;
        return switch (kind) {
            .frame => .{ .frame = bits.index },
            .breakpoint => .{ .breakpoint = bits.index },
            .program => .{ .program = bits.index },
            .command => .command,
        };
    }
};

/// What the editor keeps for debugging (`Editor.dbg`).
/// How the last debugged program ended.
pub const Outcome = union(enum) {
    exited: i64,
    /// No exit code: killed by a signal, or gdb itself went away.
    ended,
    /// By `x`.
    stopped,
};

pub const State = struct {
    /// The debugging session (`SPC d`), while there is one.
    session: ?*Debugger = null,
    /// How the session whose output the run popup shows ended; null while
    /// it runs. (The popup's own process is a stand-in that is hung up on,
    /// so its exit code says nothing.)
    outcome: ?Outcome = null,
    /// The command being debugged (owned), for `r` to debug it again.
    command: ?[]u8 = null,
    /// `command` is a program typed in the Debug picker ("zig-out/bin/app
    /// args"), not a runner command.
    by_program: bool = false,
    /// The programs debugged this session, oldest first: what `zig build run`
    /// debugs in a project (not kept across sessions).
    programs: std.ArrayList(Program) = .empty,
    /// The Debug picker is asking which program a build made (it lists only
    /// the programs).
    asking: bool = false,
    /// A build's program is being looked for (off the main thread).
    search: ?*Debugger.Search = null,
    /// While looking and asking: the plan waiting for its program. While
    /// asking: the programs found (the picker's rows) and the folder they
    /// are in. All owned.
    ask: ?Debugger.Plan = null,
    found: [][]u8 = &.{},
    ask_root: ?[]u8 = null,
    /// The folder the debugged command runs in (owned): its build, its
    /// program's relative paths, the program itself. Set when a debug starts.
    root: ?[]u8 = null,
    /// A command to debug once its build (running in the popup) succeeds.
    plan: ?Debugger.Plan = null,
    /// The stack frame shown (its line is marked): an index in the debugger's.
    frame: usize = 0,
    /// Breakpoints: absolute paths, 0-based lines. They stay across sessions.
    breakpoints: std.ArrayList(Breakpoint) = .empty,
    /// Off (`t` in the Debug picker): kept and shown, but runs run normally and
    /// gdb doesn't stop at them.
    breakpoints_on: bool = true,
    /// The breakpoints before each change, newest last (`u` in the Debug picker).
    undo: std.ArrayList([]Breakpoint) = .empty,
    /// The commands the debugger runs, this session: a runner command (`from`,
    /// per project) as you edited it the first time it was debugged.
    commands: std.ArrayList(Command) = .empty,
};

/// Ends the session and frees everything.
pub fn deinit(ed: *Editor) void {
    if (ed.dbg.session) |d| d.deinit();
    if (ed.dbg.plan) |pl| pl.deinit(ed.gpa);
    if (ed.dbg.command) |c| ed.gpa.free(c);
    for (ed.dbg.programs.items) |dp| dp.deinit(ed.gpa);
    ed.dbg.programs.deinit(ed.gpa);
    for (ed.dbg.commands.items) |dc| dc.deinit(ed.gpa);
    ed.dbg.commands.deinit(ed.gpa);
    if (ed.dbg.search) |sr| sr.destroy();
    if (ed.dbg.ask) |a| a.deinit(ed.gpa);
    setFound(ed, &.{});
    if (ed.dbg.ask_root) |r| ed.gpa.free(r);
    if (ed.dbg.root) |r| ed.gpa.free(r);
    freeBreakpoints(ed.gpa, ed.dbg.breakpoints.items);
    ed.dbg.breakpoints.deinit(ed.gpa);
    for (ed.dbg.undo.items) |list| {
        freeBreakpoints(ed.gpa, list);
        ed.gpa.free(list);
    }
    ed.dbg.undo.deinit(ed.gpa);
}

/// Breakpoints (switched on) in the project the runner's commands are for.
pub fn hasBreakpoints(ed: *Editor) bool {
    if (!ed.dbg.breakpoints_on or ed.dbg.breakpoints.items.len == 0) return false;
    const key = run_popup.runKey(ed) catch return false;
    defer ed.gpa.free(key);
    for (ed.dbg.breakpoints.items) |b| {
        if (std.mem.startsWith(u8, b.path, key) and b.path.len > key.len and b.path[key.len] == '/') return true;
    }
    return false;
}

/// `R` in the Debug picker: the runner's command under gdb (the runner
/// opens if there is none yet).
pub fn again(ed: *Editor) !void {
    const cmd = run_popup.loadRunnerCommand(ed) orelse return run_popup.runPrompt(ed, true);
    defer ed.gpa.free(cmd);
    try debug(ed, cmd);
}

/// Ctrl-Enter in the runner: `command` under gdb (remembered like a run).
pub fn fromRunner(ed: *Editor, command: []const u8) !void {
    const cmd = std.mem.trim(u8, command, " \t");
    if (cmd.len == 0) return;
    if (run_popup.runMemoryPath(ed)) |path| {
        const key = try run_popup.runKey(ed);
        defer ed.gpa.free(key);
        RunMemory.save(ed.gpa, ed.io, path, key, cmd);
    }
    try debug(ed, cmd);
}

/// Debugs runner command `cmd`. The first time this session it comes up in
/// the command editor, to change for the debugger (a debug build, other
/// arguments, `zig build && ./zig-out/bin/app` to name the program); Enter
/// there debugs it, and it's what `cmd` debugs as from then on.
pub fn debug(ed: *Editor, cmd: []const u8) !void {
    if (try commandFor(ed, cmd)) |mine| {
        defer ed.gpa.free(mine);
        return start(ed, mine);
    }
    if (!sources.onPath(ed.io, "gdb")) return ed.setMessage(.err, "gdb isn't installed", .{});
    try run_popup.editCommand(ed, cmd, .debug, cmd);
    const release = switch (try Debugger.plan(ed.gpa, cmd)) {
        .plan => |p| blk: {
            defer p.deinit(ed.gpa);
            break :blk p.release;
        },
        .unsupported => false,
    };
    if (release) {
        ed.setMessage(.info, "the debugger's command: release flags lose variables under gdb (take them out here?)", .{});
    } else ed.setMessage(.info, "the debugger's command for this session: change it or just Enter", .{});
}

/// What runner command `from` debugs as, if it was debugged this session.
/// Caller frees.
fn commandFor(ed: *Editor, from: []const u8) !?[]u8 {
    const key = try run_popup.runKey(ed);
    defer ed.gpa.free(key);
    for (ed.dbg.commands.items) |d| {
        if (std.mem.eql(u8, d.project, key) and std.mem.eql(u8, d.from, from)) return try ed.gpa.dupe(u8, d.cmd);
    }
    return null;
}

/// Enter in the command editor: `cmd` is what `from` debugs as; debug it.
/// Which program it starts is asked again if need be.
pub fn edited(ed: *Editor, from: []const u8, cmd: []const u8) !void {
    const key = try run_popup.runKey(ed);
    var key_owned = true;
    defer if (key_owned) ed.gpa.free(key);
    var i: usize = 0;
    while (i < ed.dbg.commands.items.len) {
        const d = ed.dbg.commands.items[i];
        if (std.mem.eql(u8, d.project, key) and std.mem.eql(u8, d.from, from)) {
            d.deinit(ed.gpa);
            _ = ed.dbg.commands.orderedRemove(i);
        } else i += 1;
    }
    forgetProgram(ed);
    const f = try ed.gpa.dupe(u8, from);
    errdefer ed.gpa.free(f);
    const c = try ed.gpa.dupe(u8, cmd);
    errdefer ed.gpa.free(c);
    try ed.dbg.commands.append(ed.gpa, .{ .project = key, .from = f, .cmd = c });
    key_owned = false;
    try start(ed, cmd);
}

/// The Debug picker's command row: the command last debugged here this
/// session (`edited`), else the runner's. Caller frees `cmd` and `from`.
pub const CommandRow = struct { cmd: []u8, from: []u8, edited: bool };

pub fn commandRow(ed: *Editor) !?CommandRow {
    const key = try run_popup.runKey(ed);
    defer ed.gpa.free(key);
    var i = ed.dbg.commands.items.len;
    while (i > 0) {
        i -= 1;
        const d = ed.dbg.commands.items[i];
        if (!std.mem.eql(u8, d.project, key)) continue;
        const c = try ed.gpa.dupe(u8, d.cmd);
        errdefer ed.gpa.free(c);
        return .{ .cmd = c, .from = try ed.gpa.dupe(u8, d.from), .edited = true };
    }
    const cmd = run_popup.loadRunnerCommand(ed) orelse return null;
    errdefer ed.gpa.free(cmd);
    return .{ .cmd = cmd, .from = try ed.gpa.dupe(u8, cmd), .edited = false };
}

/// Enter on the command row: debug it (the first time, after a look).
pub fn acceptCommandRow(ed: *Editor) !void {
    const row = try commandRow(ed) orelse return run_popup.runPrompt(ed, true);
    defer ed.gpa.free(row.cmd);
    defer ed.gpa.free(row.from);
    if (row.edited) return start(ed, row.cmd);
    try debug(ed, row.cmd);
}

/// `e` in the Debug picker: the debugger's command, in the command editor.
pub fn editCommandRow(ed: *Editor) !void {
    const row = try commandRow(ed) orelse return run_popup.runPrompt(ed, true);
    defer ed.gpa.free(row.cmd);
    defer ed.gpa.free(row.from);
    try run_popup.editCommand(ed, row.cmd, .debug, row.from);
}

/// Debugs `cmd`: a build-and-run command (`zig build run`, `cargo run`) is
/// built first, in the popup, and the program it made starts under gdb.
pub fn start(ed: *Editor, cmd: []const u8) !void {
    if (!sources.onPath(ed.io, "gdb")) return ed.setMessage(.err, "gdb isn't installed", .{});
    var p = switch (try Debugger.plan(ed.gpa, cmd)) {
        .unsupported => |why| return ed.setMessage(.err, "can't debug `{s}`: {s}", .{ cmd, why }),
        .plan => |x| x,
    };
    var handed = false;
    defer if (!handed) p.deinit(ed.gpa);
    try setRoot(ed);
    // A build system's run (`zig build run`, `cargo run`) doesn't say which
    // program it starts: the one found (or picked) here this session, else
    // it's looked for once the build is done (`askProgram`).
    if (p.newest_in) if (try rememberedProgram(ed)) |program| {
        ed.gpa.free(p.program);
        p.program = program;
        p.newest_in = false;
    };
    try setCommand(ed, cmd, false);
    handed = true;
    try runPlan(ed, p);
}

fn setCommand(ed: *Editor, cmd: []const u8, by_program: bool) !void {
    const owned = try ed.gpa.dupe(u8, cmd);
    if (ed.dbg.command) |old| ed.gpa.free(old);
    ed.dbg.command = owned;
    ed.dbg.by_program = by_program;
}

/// The debugged command runs where a runner command would, from the file
/// you're in now (not where a stop takes you later).
fn setRoot(ed: *Editor) !void {
    const folder = try run_popup.commandFolder(ed);
    if (ed.dbg.root) |old| ed.gpa.free(old);
    ed.dbg.root = folder;
}

/// Builds (if the plan says so) then starts the program under gdb. Takes
/// the plan, whether it fails or not.
fn runPlan(ed: *Editor, plan: Debugger.Plan) !void {
    var owned = true;
    defer if (owned) plan.deinit(ed.gpa);
    if (plan.build) |build| {
        // startRun drops any plan waiting, so this one goes in after it.
        try run_popup.startRun(ed, build);
        ed.dbg.plan = plan;
        owned = false;
        // `r` in its popup (a build that failed, say) is the debug again.
        ed.run_debug = true;
        return;
    }
    end(ed);
    cancelSearch(ed);
    try launch(ed, plan);
}

/// A program path relative to where the command runs made absolute (a name
/// with no folder stays one to find on PATH, unless that file is there).
fn inProject(ed: *Editor, plan: *Debugger.Plan) !void {
    if (std.fs.path.isAbsolute(plan.program)) return;
    const full = try std.fs.path.resolve(ed.gpa, &.{ ed.dbg.root orelse project_ops.projectRoot(ed), plan.program });
    if (std.mem.indexOfScalar(u8, plan.program, '/') == null and !formatting.fileExists(ed, full)) {
        ed.gpa.free(full);
        return;
    }
    ed.gpa.free(plan.program);
    plan.program = full;
}

/// Enter on a program in the Debug picker. Asked which program a build
/// made: that one starts (the build is done), with the command's arguments
/// unless some are typed after it, and the command debugs it from now on.
/// Typed in `SPC d` otherwise (`./app args`): that program as it is.
pub fn pickProgram(ed: *Editor, row: []const u8) !void {
    const t = std.mem.trim(u8, row, " \t");
    if (t.len == 0) return;
    const asking = ed.dbg.asking;
    ed.dbg.asking = false;
    if (!sources.onPath(ed.io, "gdb")) return ed.setMessage(.err, "gdb isn't installed", .{});
    var chosen = switch (try Debugger.plan(ed.gpa, t)) {
        .unsupported => |why| return ed.setMessage(.err, "can't debug `{s}`: {s}", .{ t, why }),
        .plan => |c| c,
    };
    var handed = false;
    defer if (!handed) chosen.deinit(ed.gpa);
    if (chosen.build != null or chosen.newest_in) {
        return ed.setMessage(.info, "here it's a program and its arguments (zig-out/bin/app args)", .{});
    }
    if (asking) if (ed.dbg.ask) |ask| {
        const abs = try std.fs.path.resolve(ed.gpa, &.{ ed.dbg.ask_root orelse ".", chosen.program });
        ed.gpa.free(chosen.program);
        chosen.program = abs;
        try rememberProgram(ed, abs);
        chosen.release = ask.release;
        if (chosen.args.len == 0 and ask.args.len > 0) {
            const args = try Debugger.dupeArgs(ed.gpa, ask.args);
            ed.gpa.free(chosen.args);
            chosen.args = args;
        }
        end(ed);
        return launch(ed, chosen);
    };
    try setRoot(ed);
    try inProject(ed, &chosen);
    try setCommand(ed, t, true);
    handed = true;
    try runPlan(ed, chosen);
}

/// The program this project's build command debugs, this session (none or
/// one). Caller frees each and the slice.
pub fn pickedPrograms(ed: *Editor) ![][]u8 {
    const key = try run_popup.runKey(ed);
    defer ed.gpa.free(key);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |x| ed.gpa.free(x);
        out.deinit(ed.gpa);
    }
    for (ed.dbg.programs.items) |d| {
        if (std.mem.eql(u8, d.project, key)) try out.append(ed.gpa, try ed.gpa.dupe(u8, d.text));
    }
    return out.toOwnedSlice(ed.gpa);
}

/// That program, if it is still there (caller frees).
fn rememberedProgram(ed: *Editor) !?[]u8 {
    const key = try run_popup.runKey(ed);
    defer ed.gpa.free(key);
    for (ed.dbg.programs.items) |d| {
        if (!std.mem.eql(u8, d.project, key)) continue;
        if (formatting.fileExists(ed, d.text)) return try ed.gpa.dupe(u8, d.text);
        break;
    }
    forgetProgram(ed);
    return null;
}

/// `abs` is what this project's build command debugs (for this session).
fn rememberProgram(ed: *Editor, abs: []const u8) !void {
    forgetProgram(ed);
    const key = try run_popup.runKey(ed);
    errdefer ed.gpa.free(key);
    const t = try ed.gpa.dupe(u8, abs);
    errdefer ed.gpa.free(t);
    try ed.dbg.programs.append(ed.gpa, .{ .project = key, .text = t });
}

/// Forgets it: the next debug of the build command looks again.
pub fn forgetProgram(ed: *Editor) void {
    const key = run_popup.runKey(ed) catch return;
    defer ed.gpa.free(key);
    var i: usize = 0;
    while (i < ed.dbg.programs.items.len) {
        const d = ed.dbg.programs.items[i];
        if (std.mem.eql(u8, d.project, key)) {
            d.deinit(ed.gpa);
            _ = ed.dbg.programs.orderedRemove(i);
        } else i += 1;
    }
}

/// After a build system's build: the program it made is looked for
/// (`Debugger.Search`, off the main thread: a big folder takes a moment);
/// `tickSearch` goes on from there.
fn askProgram(ed: *Editor, plan: Debugger.Plan, folder: []const u8) anyerror!void {
    cancelSearch(ed);
    const out_dir = try std.fs.path.resolve(ed.gpa, &.{ folder, plan.program });
    defer ed.gpa.free(out_dir);
    const waiting = try plan.clone(ed.gpa);
    if (ed.dbg.ask) |old| old.deinit(ed.gpa);
    ed.dbg.ask = waiting;
    ed.dbg.search = try Debugger.Search.start(ed.gpa, ed.io, out_dir, folder, plan.query, ed.wake_fn);
    ed.setMessage(.info, "looking for the program the build made...", .{});
}

pub fn cancelSearch(ed: *Editor) void {
    if (ed.dbg.search) |s| s.destroy();
    ed.dbg.search = null;
}

/// Takes `list` (and its strings) as the programs to pick from.
fn setFound(ed: *Editor, list: [][]u8) void {
    for (ed.dbg.found) |f| ed.gpa.free(f);
    ed.gpa.free(ed.dbg.found);
    ed.dbg.found = list;
}

/// The search is done: the only program is debugged; with several, the
/// Debug picker lists them to pick from.
pub fn tickSearch(ed: *Editor) void {
    const s = ed.dbg.search orelse return;
    if (!s.isDone()) return;
    ed.dbg.search = null;
    defer s.destroy();
    searchDone(ed, s) catch |err| ed.setMessage(.err, "could not start gdb: {s}", .{@errorName(err)});
}

fn searchDone(ed: *Editor, s: *Debugger.Search) !void {
    const plan = ed.dbg.ask orelse return;
    if (s.found.len == 0) return ed.setMessage(.err, "the build made no program to debug (nothing compiled in {s})", .{s.folder});
    if (s.found.len > 1) {
        const root = try ed.gpa.dupe(u8, s.dir);
        if (ed.dbg.ask_root) |old| ed.gpa.free(old);
        ed.dbg.ask_root = root;
        setFound(ed, s.found);
        s.found = &.{};
        ed.dbg.asking = true;
        // The build's output would take the keys.
        ed.popup = null;
        try ed.openPicker(.debug, "");
        ed.setMessage(.info, "which program? Enter debugs it (and `{s}` debugs it from now on, this session)", .{ed.dbg.command orelse "the build"});
        return;
    }
    // One: that's it.
    var chosen = try plan.clone(ed.gpa);
    defer chosen.deinit(ed.gpa);
    const abs = try std.fs.path.resolve(ed.gpa, &.{ s.dir, s.found[0] });
    ed.gpa.free(chosen.program);
    chosen.program = abs;
    chosen.newest_in = false;
    try rememberProgram(ed, abs);
    try launch(ed, chosen);
}

/// Starts gdb on the planned program, its terminal the run popup.
pub fn launch(ed: *Editor, plan: Debugger.Plan) !void {
    const folder = if (ed.dbg.root) |r| try ed.gpa.dupe(u8, r) else try run_popup.commandFolder(ed);
    var folder_owned = true;
    defer if (folder_owned) ed.gpa.free(folder);
    const program = try programPath(ed, plan, folder) orelse {
        if (plan.newest_in) return askProgram(ed, plan, folder);
        return ed.setMessage(.err, "nothing to debug: no program at {s}", .{plan.program});
    };
    defer ed.gpa.free(program);
    // The program's terminal: one with nothing in it until gdb starts the
    // program there (Ctrl-C in the popup pauses it instead).
    const t = try run_popup.spawnTerminalIn(ed, &.{}, folder);
    errdefer t.destroy();
    var tty_buf: [128]u8 = undefined;
    const tty = t.pty.deviceName(&tty_buf);

    var arena_state: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();
    var files: std.ArrayList(Debugger.Breakpoints) = .empty;
    if (ed.dbg.breakpoints_on) for (ed.dbg.breakpoints.items) |b| {
        const known = for (files.items) |f| {
            if (std.mem.eql(u8, f.path, b.path)) break true;
        } else false;
        if (known) continue;
        try files.append(arena, .{ .path = b.path, .lines = try breakpointLines(ed, arena, b.path) });
    };
    const log = config.dir(ed.gpa, .cache, "gdb.log");
    defer if (log) |l| ed.gpa.free(l);
    const args = try arena.alloc([]const u8, plan.args.len);
    for (plan.args, args) |a, *out| out.* = a;
    const d = try Debugger.start(ed.gpa, ed.io, .{
        .program = program,
        .args = args,
        .cwd = folder,
        .tty = tty,
        .breakpoints = files.items,
        .log = if (@import("builtin").is_test) null else log,
        .wake = ed.wake_fn,
    });
    errdefer d.deinit();
    const shown = try ed.gpa.dupe(u8, ed.dbg.command orelse program);

    // Nothing below fails: the session is the editor's from here.
    if (ed.run) |old| old.destroy();
    if (ed.run_command) |old| ed.gpa.free(old);
    if (ed.run_root_owned) |old| ed.gpa.free(old);
    ed.run = t;
    ed.run_command = shown;
    ed.run_root_owned = folder;
    ed.run_root = folder;
    folder_owned = false;
    ed.run_started = Io.Timestamp.now(ed.io, .awake);
    // Its end is reported from the debugger (the waiting process lives on).
    ed.run_reported = true;
    ed.run_debug = true;
    ed.dbg.session = d;
    ed.dbg.outcome = null;
    ed.dbg.frame = 0;
    ed.popup = .run;
    var line_buf: [512]u8 = undefined;
    t.print(std.fmt.bufPrint(&line_buf, "\x1b[2mgdb: {s}   C-c pauses it{s}\x1b[0m\r\n", .{ program, if (plan.release) "\r\na release build: variables may be missing (SPC d, e changes the command)" else "" }) catch "");
    ed.setMessage(.info, "debugging {s}: it stops at breakpoints and crashes", .{std.fs.path.basename(program)});
}

/// The program a plan starts, as an absolute path (caller frees), or null.
fn programPath(ed: *Editor, plan: Debugger.Plan, folder: []const u8) !?[]u8 {
    // Which program a build system runs isn't guessed (`start`).
    if (plan.newest_in) return null;
    if (std.fs.path.isAbsolute(plan.program) or std.mem.indexOfScalar(u8, plan.program, '/') != null) {
        const full = try std.fs.path.resolve(ed.gpa, &.{ folder, plan.program });
        if (formatting.fileExists(ed, full)) return full;
        ed.gpa.free(full);
        return null;
    }
    // A name: found on PATH, as the shell would.
    const path = std.c.getenv("PATH") orelse return null;
    var dirs = std.mem.splitScalar(u8, std.mem.span(path), ':');
    while (dirs.next()) |dir| {
        if (dir.len == 0) continue;
        const full = try std.fs.path.join(ed.gpa, &.{ dir, plan.program });
        if (Io.Dir.accessAbsolute(ed.io, full, .{})) |_| return full else |_| ed.gpa.free(full);
    }
    return null;
}

/// Ends the debugging session, if any (the program is killed).
pub fn end(ed: *Editor) void {
    const d = ed.dbg.session orelse return;
    d.deinit();
    ed.dbg.session = null;
    ed.dbg.frame = 0;
}

/// `x` in the Debug picker: stops the program (and gdb).
pub fn stop(ed: *Editor) void {
    if (ed.dbg.session == null) return ed.setMessage(.info, "not debugging", .{});
    end(ed);
    ed.dbg.outcome = .stopped;
    if (ed.run) |t| if (ed.run_debug) t.print("\r\n\x1b[1;31m✗ stopped\x1b[0;2m   r: debug again   q: close\x1b[0m");
    finishTerminal(ed);
    ed.setMessage(.info, "stopped debugging", .{});
}

/// The program is gone: its terminal's waiting process can go too, so the
/// popup is a finished run (q closes it, r debugs again).
fn finishTerminal(ed: *Editor) void {
    if (!ed.run_debug) return;
    const code: u8 = if (ed.dbg.outcome) |o| switch (o) {
        .exited => |c| @truncate(@as(u64, @bitCast(c))),
        .ended, .stopped => 1,
    } else 1;
    if (ed.run) |t| t.finish(code);
}

pub fn tick(ed: *Editor) void {
    const d = ed.dbg.session orelse return;
    const up = d.poll();
    if (up.note) if (d.takeNote()) |n| {
        defer ed.gpa.free(n);
        notifications.notify(ed, .err, "gdb: {s}", .{std.mem.sliceTo(n, '\n')});
    };
    if (up.ended) {
        const code = d.exit_code;
        end(ed);
        ed.dbg.outcome = if (code) |c| .{ .exited = c } else .ended;
        if (ed.picker) |p| if (p.kind == .debug) picker_query.closePicker(ed);
        if (ed.run) |t| if (ed.run_debug) {
            var buf: [160]u8 = undefined;
            const ok = code != null and code.? == 0;
            const line = if (code) |c|
                std.fmt.bufPrint(&buf, "\r\n\x1b[1;{s}m{s} exited {d}\x1b[0;2m   r: debug again   q: close\x1b[0m", .{ if (ok) "32" else "31", if (ok) "✓" else "✗", c }) catch ""
            else
                // No exit code: killed by a signal, or gdb itself went away.
                std.fmt.bufPrint(&buf, "\r\n\x1b[1;31m✗ ended\x1b[0;2m   r: debug again   q: close\x1b[0m", .{}) catch "";
            t.print(line);
        };
        finishTerminal(ed);
        ed.popup = .run;
        if (code) |c| ed.setMessage(if (c == 0) .info else .err, "the program exited {d}", .{c}) else ed.setMessage(.err, "the debugging session ended (no exit code: killed, or gdb stopped)", .{});
        return;
    }
    if (up.stopped) showStop(ed);
    if (up.vars) if (ed.picker) |p| if (p.kind == .debug) {
        p.preview_for = null;
    };
}

/// Where the program stopped: the innermost frame in your own code (a
/// crash stops inside libc or the panic handler), shown in the editor,
/// with the Debug picker over it.
fn showStop(ed: *Editor) void {
    const d = ed.dbg.session orelse return;
    const root = ed.run_root;
    var pick: ?usize = null;
    for (d.frames.items, 0..) |f, i| {
        const path = f.path orelse continue;
        if (!formatting.fileExists(ed, path)) continue;
        if (pick == null) pick = i;
        if (std.mem.startsWith(u8, path, root) and path.len > root.len and path[root.len] == '/') {
            pick = i;
            break;
        }
    }
    ed.dbg.frame = pick orelse 0;
    const where = if (d.frames.items.len > 0) d.frames.items[ed.dbg.frame].name else "?";
    const level: Editor.Message.Kind = if (std.mem.startsWith(u8, d.reason, "signal") or std.mem.startsWith(u8, d.reason, "exception")) .err else .info;
    // In the middle of something else (the command editor, another
    // picker): it isn't taken away; `SPC d` goes to the stop.
    const busy = ed.cmd_float != null or (ed.picker != null and ed.picker.?.kind != .debug);
    if (busy) return ed.setMessage(level, "stopped ({s}) in {s}: SPC d", .{ d.reason, where });
    ed.popup = null;
    if (pick) |i| {
        const f = d.frames.items[i];
        ed.moveTo(f.path.?, f.line, 0) catch {};
        picker_ops.centerCursor(ed);
    }
    ed.setMessage(level, "stopped ({s}) in {s}", .{ d.reason, where });
    if (ed.picker) |p| {
        p.refill() catch {};
        p.selected = ed.dbg.frame;
        return;
    }
    ed.dbg.asking = false;
    ed.openPicker(.debug, "") catch return;
    if (ed.picker) |p| p.selected = ed.dbg.frame;
}

/// `n` / `s` / `f` / `c` in the Debug picker.
pub fn step(ed: *Editor, how: Debugger.Step) !void {
    const d = ed.dbg.session orelse return ed.setMessage(.info, "not debugging: Ctrl-Enter on a command in SPC r", .{});
    if (d.state != .stopped) return ed.setMessage(.info, "it's running (C-c in its output, or p, pauses it)", .{});
    try d.step(how);
    // Continuing shows the program until it stops again.
    if (how == .cont) {
        picker_query.closePicker(ed);
        ed.popup = .run;
    }
}

/// `p` in the Debug picker: pauses the running program.
pub fn pause(ed: *Editor) !void {
    const d = ed.dbg.session orelse return;
    try d.pause();
}

/// The Debug picker: in a session, the stack; else (or after it) the
/// breakpoints. `SPC d`.
pub fn open(ed: *Editor) !void {
    ed.dbg.asking = false;
    try ed.openPicker(.debug, "");
    if (ed.picker) |p| if (ed.dbg.session) |d| if (d.state == .stopped) {
        p.selected = ed.dbg.frame;
    };
}

/// Shows stack frame `i`: its line in the editor (and marked).
pub fn showFrame(ed: *Editor, i: usize) !void {
    const d = ed.dbg.session orelse return;
    if (i >= d.frames.items.len) return;
    ed.dbg.frame = i;
    const f = d.frames.items[i];
    const path = f.path orelse return ed.setMessage(.info, "{s}: no source (a library without debug info)", .{f.name});
    try ed.jumpTo(path, f.line, 0);
    picker_ops.centerCursor(ed);
}

/// `b`: a breakpoint on the cursor's line, or off if there is one.
pub fn toggleBreakpoint(ed: *Editor) !void {
    const rel = ed.buffer.path orelse return ed.setMessage(.info, "breakpoints are for files", .{});
    const path = try ed.absolutePath(rel);
    var path_owned = true;
    defer if (path_owned) ed.gpa.free(path);
    const line: u32 = @intCast(ed.text().lineOf(ed.view.cursor));
    try saveBreakpoints(ed);
    for (ed.dbg.breakpoints.items, 0..) |b, i| if (b.line == line and std.mem.eql(u8, b.path, path)) {
        ed.gpa.free(b.path);
        _ = ed.dbg.breakpoints.orderedRemove(i);
        ed.setMessage(.info, "breakpoint removed: line {d}", .{line + 1});
        return sendBreakpoints(ed, path);
    };
    try ed.dbg.breakpoints.append(ed.gpa, .{ .path = path, .line = line });
    path_owned = false;
    if (ed.dbg.breakpoints_on) {
        ed.setMessage(.info, "breakpoint: line {d} (runs go through gdb now)", .{line + 1});
    } else ed.setMessage(.info, "breakpoint: line {d} (breakpoints are off: t in SPC d)", .{line + 1});
    try sendBreakpoints(ed, path);
}

/// Removes breakpoint `i` (the Debug picker's row).
pub fn removeBreakpoint(ed: *Editor, i: usize) !void {
    if (i >= ed.dbg.breakpoints.items.len) return;
    try saveBreakpoints(ed);
    const b = ed.dbg.breakpoints.orderedRemove(i);
    defer ed.gpa.free(b.path);
    try sendBreakpoints(ed, b.path);
}

/// `B`: removes every breakpoint (`u` brings them back).
pub fn clearBreakpoints(ed: *Editor) !void {
    if (ed.dbg.breakpoints.items.len == 0) return ed.setMessage(.info, "no breakpoints", .{});
    try saveBreakpoints(ed);
    const old = try ed.dbg.breakpoints.toOwnedSlice(ed.gpa);
    defer {
        freeBreakpoints(ed.gpa, old);
        ed.gpa.free(old);
    }
    try sendAllBreakpoints(ed, old);
    ed.setMessage(.info, "removed {d} breakpoint{s} (u brings them back)", .{ old.len, if (old.len == 1) "" else "s" });
}

/// `t`: all breakpoints on or off. Off, they're kept (and shown hollow),
/// but runs run normally and gdb doesn't stop at them.
pub fn toggleBreakpointsOn(ed: *Editor) !void {
    ed.dbg.breakpoints_on = !ed.dbg.breakpoints_on;
    try sendAllBreakpoints(ed, &.{});
    if (ed.dbg.breakpoints_on) {
        ed.setMessage(.info, "breakpoints on: runs go through gdb", .{});
    } else ed.setMessage(.info, "breakpoints off (kept): runs run normally", .{});
}

/// `u`: the breakpoints as they were before the last change.
pub fn undoBreakpoints(ed: *Editor) !void {
    const before = ed.dbg.undo.pop() orelse return ed.setMessage(.info, "no breakpoint changes to undo", .{});
    defer ed.gpa.free(before);
    const now = try ed.dbg.breakpoints.toOwnedSlice(ed.gpa);
    defer {
        freeBreakpoints(ed.gpa, now);
        ed.gpa.free(now);
    }
    try ed.dbg.breakpoints.appendSlice(ed.gpa, before);
    // Files that had some then and have none now are told too.
    try sendAllBreakpoints(ed, now);
    ed.setMessage(.info, "breakpoints back as they were ({d})", .{before.len});
}

/// Remembers the breakpoints before a change, for `u`.
fn saveBreakpoints(ed: *Editor) !void {
    const copy = try ed.gpa.alloc(Breakpoint, ed.dbg.breakpoints.items.len);
    var n: usize = 0;
    errdefer {
        freeBreakpoints(ed.gpa, copy[0..n]);
        ed.gpa.free(copy);
    }
    for (ed.dbg.breakpoints.items) |b| {
        copy[n] = .{ .path = try ed.gpa.dupe(u8, b.path), .line = b.line };
        n += 1;
    }
    try ed.dbg.undo.append(ed.gpa, copy);
    if (ed.dbg.undo.items.len > 100) {
        const oldest = ed.dbg.undo.orderedRemove(0);
        freeBreakpoints(ed.gpa, oldest);
        ed.gpa.free(oldest);
    }
}

fn freeBreakpoints(gpa: Allocator, list: []const Breakpoint) void {
    for (list) |b| gpa.free(b.path);
}

/// Tells gdb every file's breakpoints, and those of `also` (files that may
/// have none left).
fn sendAllBreakpoints(ed: *Editor, also: []const Breakpoint) !void {
    if (ed.dbg.session == null) return;
    var arena_state: std.heap.ArenaAllocator = .init(ed.gpa);
    defer arena_state.deinit();
    var paths: std.StringArrayHashMapUnmanaged(void) = .empty;
    for (ed.dbg.breakpoints.items) |b| try paths.put(arena_state.allocator(), b.path, {});
    for (also) |b| try paths.put(arena_state.allocator(), b.path, {});
    for (paths.keys()) |p| try sendBreakpoints(ed, p);
}

/// Lines were added or removed in `b`: its breakpoints stay on their lines
/// (one whose line is deleted moves to the line it was joined into), in
/// the undo history too. gdb isn't told: what it runs was built from the
/// file as it was; the next debug sends them where they are now.
pub fn breakpointLinesChanged(ctx: *anyopaque, b: *const Buffer, edit: Buffer.LineEdit) void {
    const ed: *Editor = @ptrCast(@alignCast(ctx));
    if (ed.dbg.breakpoints.items.len == 0 and ed.dbg.undo.items.len == 0) return;
    var buf: [std.fs.max_path_bytes]u8 = undefined;
    var fba: std.heap.FixedBufferAllocator = .init(&buf);
    const path = std.fs.path.resolve(fba.allocator(), &.{ ed.cwd, b.path orelse return }) catch return;
    for (ed.dbg.undo.items) |list| for (list) |*bp| {
        if (std.mem.eql(u8, bp.path, path)) bp.line = edit.apply(bp.line);
    };
    for (ed.dbg.breakpoints.items) |*bp| {
        if (std.mem.eql(u8, bp.path, path)) bp.line = edit.apply(bp.line);
    }
    // Two that ended up on one line are one.
    var i: usize = 0;
    while (i < ed.dbg.breakpoints.items.len) : (i += 1) {
        const a = ed.dbg.breakpoints.items[i];
        var j = i + 1;
        while (j < ed.dbg.breakpoints.items.len) {
            const o = ed.dbg.breakpoints.items[j];
            if (o.line == a.line and std.mem.eql(u8, o.path, a.path)) {
                ed.gpa.free(o.path);
                _ = ed.dbg.breakpoints.orderedRemove(j);
            } else j += 1;
        }
    }
}

/// The breakpoint lines in `path` (absolute), sorted.
fn breakpointLines(ed: *Editor, gpa: Allocator, path: []const u8) ![]u32 {
    var out: std.ArrayList(u32) = .empty;
    for (ed.dbg.breakpoints.items) |b| if (std.mem.eql(u8, b.path, path)) try out.append(gpa, b.line);
    std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
    return out.toOwnedSlice(gpa);
}

/// Tells gdb `path`'s breakpoints now, in a session.
fn sendBreakpoints(ed: *Editor, path: []const u8) !void {
    const d = ed.dbg.session orelse return;
    if (!ed.dbg.breakpoints_on) return d.setBreakpoints(path, &.{});
    const lines = try breakpointLines(ed, ed.gpa, path);
    defer ed.gpa.free(lines);
    try d.setBreakpoints(path, lines);
}

/// For drawing `b`'s gutter: whether `line` has a breakpoint, and whether
/// it's where the program is stopped (the shown frame).
/// While stopped: the values of the shown frame's variables that line
/// `line` of the file at `abs` uses, as `name = value, ...` for the end of
/// the line. Only the function's lines down to where it stopped (below it
/// nothing has run yet). In `buf`; null for none.
pub fn inlineValues(ed: *Editor, abs: []const u8, line: usize, buf: []u8) ?[]const u8 {
    const d = ed.dbg.session orelse return null;
    if (d.state != .stopped or ed.dbg.frame >= d.frames.items.len) return null;
    const f = &d.frames.items[ed.dbg.frame];
    const path = f.path orelse return null;
    if (line > f.line or !std.mem.eql(u8, path, abs)) return null;
    // Its function's first line (else a screenful above the stop).
    const first = if (ed.buffer.syntax) |*sx| syntax_objects.enclosingFunctionLine(sx, ed.text(), f.line) orelse f.line -| 30 else f.line -| 30;
    if (line < first) return null;
    const text = ed.text().lineSlice(line);
    var w: std.Io.Writer = .fixed(buf);
    var any = false;
    for (f.vars.items) |v| {
        if (v.depth != 0 or v.value.len == 0) continue;
        if (!usesName(text, v.name)) continue;
        if (any) w.writeAll(", ") catch break;
        any = true;
        w.print("{s} = ", .{v.name}) catch break;
        // One short line: a struct shows its start.
        var n: usize = 0;
        var it = std.unicode.Utf8View.initUnchecked(v.value).iterator();
        while (it.nextCodepointSlice()) |cs| : (n += 1) {
            if (n == max_inline_value) {
                w.writeAll("…") catch {};
                break;
            }
            w.writeAll(if (cs[0] == '\n' or cs[0] == '\t') " " else cs) catch break;
        }
    }
    return if (any) w.buffered() else null;
}

/// Of one value at a line's end.
const max_inline_value = 40;

/// `name` as a whole word in `line` (not inside a longer name, a string's
/// text aside).
fn usesName(line: []const u8, name: []const u8) bool {
    if (name.len == 0) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, line, from, name)) |at| {
        from = at + 1;
        const before_ok = at == 0 or !isNameByte(line[at - 1]);
        const name_end = at + name.len;
        const after_ok = name_end >= line.len or !isNameByte(line[name_end]);
        // `.name` is a field of something else, not this variable.
        const field = at > 0 and line[at - 1] == '.';
        if (before_ok and after_ok and !field) return true;
    }
    return false;
}

fn isNameByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_';
}

pub fn marks(ed: *const Editor, abs: []const u8, line: usize) Marks {
    var out: Marks = .{};
    for (ed.dbg.breakpoints.items) |bp| if (bp.line == line and std.mem.eql(u8, bp.path, abs)) {
        out.breakpoint = true;
        break;
    };
    if (ed.dbg.session) |d| if (d.state == .stopped and ed.dbg.frame < d.frames.items.len) {
        const f = d.frames.items[ed.dbg.frame];
        if (f.line == line) if (f.path) |p| {
            out.here = std.mem.eql(u8, p, abs);
        };
    };
    return out;
}

