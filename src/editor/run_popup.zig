//! The terminal popup (`SPC r t`) and running commands (`SPC r`).

const std = @import("std");
const Io = std.Io;
const Buffer = @import("../core/Buffer.zig");
const motions = @import("../core/motions.zig");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const sources = @import("../picker/sources.zig");
const sql = @import("../sql.zig");
const Windows = @import("../Windows.zig");
const Project = @import("../core/Project.zig");
const Terminal = @import("../terminal/Terminal.zig");
const Pty = @import("../terminal/Pty.zig");
const RunMemory = @import("../terminal/RunMemory.zig");
const Debugger = @import("../Debugger.zig");
const debugging = @import("../debugging.zig");
const run_errors_mod = @import("../terminal/errors.zig");
const formatting = @import("formatting.zig");
const window_ops = @import("window_ops.zig");
const project_ops = @import("project_ops.zig");
const inlay = @import("inlay.zig");
const quickfix_list = @import("quickfix_list.zig");
const Editor = @import("../Editor.zig");
const code_motion = @import("code_motion.zig");
const prompts = @import("prompts.zig");
const git_ops = @import("git_ops.zig");
const after_typing = @import("after_typing.zig");
const sql_ops = @import("sql_ops.zig");
const lsp_ops = @import("lsp_ops.zig");
const CommandPurpose = Editor.CommandPurpose;
const PromptKind = Editor.PromptKind;

/// Starts `argv` in a terminal, in the current project's root.
/// Build files that mark the folder a command should run in.
pub const run_markers = Project.markers ++ [_][]const u8{ "makefile", "GNUmakefile" };

/// Where commands (the runner, shells) start: the folder of the code you
/// are in. From the current file's folder up to its project's root, the
/// nearest folder with a build file (build.zig, Makefile, Cargo.toml, ...),
/// else the project root. A file in no project: its own folder (not some
/// other project you were in earlier). No file: the project root. The
/// caller frees it.
pub fn commandFolder(ed: *Editor) ![]u8 {
    const b = ed.buffer;
    const path = b.path orelse return ed.gpa.dupe(u8, project_ops.projectRoot(ed));
    const abs = try ed.absolutePath(path);
    defer ed.gpa.free(abs);
    const dir = std.fs.path.dirname(abs) orelse return ed.gpa.dupe(u8, project_ops.projectRoot(ed));
    const root = (b.project orelse return ed.gpa.dupe(u8, dir)).root;
    const inside = dir.len >= root.len and std.mem.startsWith(u8, dir, root) and (dir.len == root.len or dir[root.len] == '/');
    if (!inside) return ed.gpa.dupe(u8, dir);
    var d: []const u8 = dir;
    while (true) {
        for (run_markers) |m| {
            const candidate = try std.fs.path.join(ed.gpa, &.{ d, m });
            defer ed.gpa.free(candidate);
            if (formatting.fileExists(ed, candidate)) return ed.gpa.dupe(u8, d);
        }
        if (d.len <= root.len) break;
        d = std.fs.path.dirname(d) orelse break;
    }
    return ed.gpa.dupe(u8, root);
}

pub fn spawnTerminal(ed: *Editor, argv: []const []const u8) !*Terminal {
    const folder = try commandFolder(ed);
    defer ed.gpa.free(folder);
    return spawnTerminalIn(ed, argv, folder);
}

pub fn spawnTerminalIn(ed: *Editor, argv: []const []const u8, cwd: []const u8) !*Terminal {
    const sz = ed.term_size;
    return Terminal.create(ed.gpa, ed.io, .{
        .argv = argv,
        .cwd = cwd,
        .cols = sz.cols,
        .rows = sz.rows,
        .cell_w = sz.cell_w,
        .cell_h = sz.cell_h,
        .fg = ed.term_fg,
        .bg = ed.term_bg,
        .wake = ed.wake_fn,
    });
}

/// The terminal the popup shows.
pub fn popupTerminal(ed: *Editor) ?*Terminal {
    return switch (ed.popup orelse return null) {
        .shell => ed.shell,
        .run => ed.run,
    };
}

/// `SPC r t` / <C-\>: shows or hides the shell (started on first use).
pub fn toggleShell(ed: *Editor) !void {
    if (ed.popup == .shell) {
        ed.popup = null;
        return;
    }
    if (ed.shell == null) ed.shell = try spawnTerminal(ed, &.{Pty.userShell()});
    ed.popup = .shell;
}

/// `SPC r o`: shows the last run's output again.
pub fn showRunOutput(ed: *Editor) void {
    if (ed.run == null) return ed.setMessage(.info, "nothing has been run yet (SPC r r)", .{});
    ed.popup = .run;
}

/// Esc in a terminal: the first goes to the program at once (Claude's
/// interrupt, vim); a second within a third of a second means "leave",
/// and isn't sent. True for that second Esc.
pub fn doubleEsc(ed: *Editor, t: *Terminal, ev: KeyEvent) bool {
    if (ev.key != .special or ev.key.special != .escape or ev.mods.any()) return false;
    const now = Io.Timestamp.now(ed.io, .awake);
    const since = ed.last_term_esc.durationTo(now).nanoseconds;
    if (ed.last_term_esc.nanoseconds != 0 and since < 350 * std.time.ns_per_ms) {
        ed.last_term_esc = .zero;
        return true;
    }
    ed.last_term_esc = now;
    _ = t;
    return false;
}

/// A key in a terminal window's normal mode; false lets the keymap have it.
pub fn termNormalKey(ed: *Editor, t: *Terminal, ev: KeyEvent) bool {
    const half: isize = @intCast(@max(1, t.rows / 2));
    switch (ev.key) {
        .codepoint => |cp| if (ev.mods.ctrl) switch (cp) {
            'd' => t.scroll(half),
            'u' => t.scroll(-half),
            else => {},
        } else switch (cp) {
            ' ' => return false,
            'i', 'a', 'I', 'A' => ed.window.term_normal = false,
            'j' => t.scroll(1),
            'k' => t.scroll(-1),
            else => {},
        },
        .special => |sp| switch (sp) {
            .enter => ed.window.term_normal = false,
            .down => t.scroll(1),
            .up => t.scroll(-1),
            else => {},
        },
    }
    return true;
}

pub fn isCtrlBackslash(ev: KeyEvent) bool {
    return ev.mods.ctrl and ev.key == .codepoint and ev.key.codepoint == '\\';
}

/// Keys while the popup is open (or <C-\> to open the shell). Returns
/// true when the key was used.
pub fn popupKey(ed: *Editor, ev: KeyEvent) bool {
    if (ed.popup == null) {
        // A terminal window (the Claude panel) has the keyboard.
        if (ed.window.term) |t| {
            // Normal mode: SPC and what follows go to the keymap; i/a type
            // again, j/k and Ctrl-d/u scroll, other keys do nothing.
            if (ed.window.term_normal) return ed.pending_len == 0 and termNormalKey(ed, t, ev);
            // Ctrl-\: back to the code, the panel staying open. Ctrl-C: close
            // the panel (it keeps running; SPC a a brings it back). Claude
            // interrupts with Esc; Ctrl-Shift-C sends it a real Ctrl-C.
            const ctrl_c = ev.mods.ctrl and !ev.mods.alt and ev.key == .codepoint and (ev.key.codepoint == 'c' or ev.key.codepoint == 'C');
            if (isCtrlBackslash(ev) or doubleEsc(ed, t, ev)) {
                ed.window.term_normal = true;
                ed.mode = .normal;
            } else if (ctrl_c and !ev.mods.shift and window_ops.isClaudeTerm(ed, t)) {
                window_ops.closeWindow(ed);
            } else if (ctrl_c and window_ops.isClaudeTerm(ed, t)) {
                t.sendKey(.{ .key = .{ .codepoint = 'c' }, .mods = .{ .ctrl = true } });
            } else termKey(ed, t, ev);
            return true;
        }
        if (isCtrlBackslash(ev) and ed.mode == .normal) {
            // To the terminal window if there is one, else the shell popup.
            for (ed.window_list.items) |w| if (w.term != null) {
                window_ops.focusWindow(ed, w);
                return true;
            };
            toggleShell(ed) catch |err| ed.setMessage(.err, "could not start the shell: {s}", .{@errorName(err)});
            return true;
        }
        return false;
    }
    const t = popupTerminal(ed) orelse {
        ed.popup = null;
        return false;
    };
    if (isCtrlBackslash(ev) or (t.isRunning() and doubleEsc(ed, t, ev))) {
        ed.popup = null;
        return true;
    }
    // Shift+PageUp/PageDown: scroll through the output.
    if (ev.mods.shift and ev.key == .special and (ev.key.special == .page_up or ev.key.special == .page_down)) {
        const page: isize = @intCast(@max(t.rows, 2) - 1);
        t.scroll(if (ev.key.special == .page_up) -page else page);
        return true;
    }
    // Ctrl+Shift+V pastes the clipboard.
    if (ev.mods.ctrl and ev.mods.shift and ev.key == .codepoint and (ev.key.codepoint == 'v' or ev.key.codepoint == 'V')) {
        if (ed.registers.clipboard) |cb| if (cb.get(ed.gpa)) |clip| {
            defer ed.gpa.free(clip);
            t.paste(clip);
        };
        return true;
    }
    if (ed.popup == .run and ed.dbg.session != null and ev.mods.ctrl and !ev.mods.alt and ev.key == .codepoint and ev.key.codepoint == 'c') {
        if (ed.dbg.session) |d| d.pause() catch {};
        return true;
    }
    if (!t.isRunning()) {
        // A finished run: q/<Esc> closes, r runs it again; scrolling still works.
        if (ev.key == .special and ev.key.special == .escape) {
            ed.popup = null;
        } else if (ev.key == .codepoint and !ev.mods.blocksText()) switch (ev.key.codepoint) {
            'q' => ed.popup = null,
            'r' => if (ed.popup == .run) rerun(ed) catch |err| ed.setMessage(.err, "could not run: {s}", .{@errorName(err)}),
            'e' => if (ed.popup == .run) {
                ed.popup = null;
                quickfix_list.showRunErrors(ed) catch |err| ed.setMessage(.err, "{s}", .{@errorName(err)});
            },
            'y' => yankRunOutput(ed, t, false),
            'Y' => yankRunOutput(ed, t, true),
            'k' => t.scroll(-1),
            'j' => t.scroll(1),
            else => {},
        };
        return true;
    }
    t.sendKey(ev);
    return true;
}

/// Keys for a terminal: scrolling and pasting are ours, the rest its.
pub fn termKey(ed: *Editor, t: *Terminal, ev: KeyEvent) void {
    if (ev.mods.shift and ev.key == .special and (ev.key.special == .page_up or ev.key.special == .page_down)) {
        const page: isize = @intCast(@max(t.rows, 2) - 1);
        return t.scroll(if (ev.key.special == .page_up) -page else page);
    }
    if (ev.mods.ctrl and ev.mods.shift and ev.key == .codepoint and (ev.key.codepoint == 'v' or ev.key.codepoint == 'V')) {
        if (ed.registers.clipboard) |cb| if (cb.get(ed.gpa)) |clip| {
            defer ed.gpa.free(clip);
            t.paste(clip);
        };
        return;
    }
    t.sendKey(ev);
}

/// `SPC r c`: opens the command editor, a floating vim buffer for the
/// command (any number of lines). Insert mode first; in normal mode <CR>
/// runs it and <Esc> cancels.
pub fn openCommandEditor(ed: *Editor) !void {
    return editCommand(ed, "", .run, null);
}

/// The command editor on `cmd` (normal mode, to change it with vim's keys;
/// empty: insert mode). Enter does what `purpose` says.
pub fn editCommand(ed: *Editor, cmd: []const u8, purpose: CommandPurpose, from: ?[]const u8) !void {
    if (ed.cmd_float != null) return;
    const from_owned: ?[]u8 = if (from) |f| try ed.gpa.dupe(u8, f) else null;
    errdefer if (from_owned) |f| ed.gpa.free(f);
    const b = try ed.gpa.create(Buffer);
    errdefer ed.gpa.destroy(b);
    b.* = try Buffer.initEmpty(ed.gpa);
    errdefer b.deinit(ed.gpa);
    try b.text.insert(ed.gpa, 0, cmd);
    const w = try ed.gpa.create(Windows.Window);
    w.* = .{ .buffer = b, .view = .{ .rows = ed.view.rows, .cols = ed.view.cols }, .node = undefined };
    ed.cmd_float = w;
    ed.cmd_return = ed.window;
    ed.cmd_purpose = purpose;
    if (ed.cmd_from) |old| ed.gpa.free(old);
    ed.cmd_from = from_owned;
    // Keys are the editor's now, not a finished run's popup's.
    ed.popup = null;
    window_ops.focusWindow(ed, w);
    if (cmd.len == 0) ed.setMode(.insert);
}

/// The command editor's text, as one shell script. Caller frees.
pub fn commandEditorText(ed: *Editor) ![]u8 {
    const t = ed.text();
    return ed.gpa.dupe(u8, std.mem.trim(u8, t.slice(0, t.len()), " \t\n"));
}

/// Closes the command editor, back to the window it was opened from.
pub fn closeCommandEditor(ed: *Editor) void {
    const w = ed.cmd_float orelse return;
    if (ed.mode != .normal) ed.setMode(.normal);
    ed.cursors.clearRetainingCapacity();
    const back = ed.cmd_return.?;
    window_ops.focusWindow(ed, back);
    inlay.forgetJumps(ed, w.buffer);
    w.buffer.deinit(ed.gpa);
    ed.gpa.destroy(w.buffer);
    ed.gpa.destroy(w);
    ed.cmd_float = null;
    ed.cmd_return = null;
    ed.cmd_purpose = .run;
}

/// In the command editor's normal mode: <CR> runs, <Esc> cancels.
pub fn cmdFloatKey(ed: *Editor, ev: KeyEvent) bool {
    if (ed.cmd_float == null or ed.window != ed.cmd_float.? or ed.mode != .normal or !ed.isIdle()) return false;
    if (ed.cursors.items.len > 0) return false; // <Esc> first drops extra cursors
    if (ev.mods.any() or ev.key != .special) return false;
    switch (ev.key.special) {
        .escape => closeCommandEditor(ed),
        .enter => {
            const cmd = commandEditorText(ed) catch return true;
            defer ed.gpa.free(cmd);
            const purpose = ed.cmd_purpose;
            const from = ed.cmd_from;
            ed.cmd_from = null;
            defer if (from) |f| ed.gpa.free(f);
            closeCommandEditor(ed);
            if (cmd.len == 0) return true;
            const one_line = std.mem.indexOfScalar(u8, cmd, '\n') == null;
            (switch (purpose) {
                .run => startRun(ed, cmd),
                // The history is a line per command.
                .runner => if (one_line) runFromRunner(ed, cmd) else startRun(ed, cmd),
                .debug => debugging.edited(ed, from orelse cmd, cmd),
            }) catch |err| ed.setMessage(.err, "could not run: {s}", .{@errorName(err)});
        },
        else => return false,
    }
    return true;
}

/// `SPC r r`: the code runner's prompt, prefilled with the last command.
/// `SPC r r`: the runner, a picker of this project's commands, newest
/// first (Enter runs the last one again); typing a new one runs that.
/// `SPC r c`: the multi-line command editor.
pub fn runPrompt(ed: *Editor, runner: bool) !void {
    if (!runner) return openCommandEditor(ed);
    try ed.openPicker(.runner, "");
}

/// This project's runner commands, newest first. The caller frees each
/// and the slice.
pub fn runnerHistory(ed: *Editor) ![][]u8 {
    const path = runMemoryPath(ed) orelse return ed.gpa.alloc([]u8, 0);
    const key = try runKey(ed);
    defer ed.gpa.free(key);
    return RunMemory.history(ed.gpa, ed.io, path, key);
}

/// Runs `cmd` as the runner's command: it goes to the front of the history.
pub fn runFromRunner(ed: *Editor, command: []const u8) !void {
    const cmd = std.mem.trim(u8, command, " \t");
    if (cmd.len == 0) return;
    if (runMemoryPath(ed)) |path| {
        const key = try runKey(ed);
        defer ed.gpa.free(key);
        RunMemory.save(ed.gpa, ed.io, path, key, cmd);
    }
    try runOrDebug(ed, cmd);
}

/// Runs `cmd`, under gdb when this project has breakpoints (and they're on)
/// and gdb can run it; else as usual.
pub fn runOrDebug(ed: *Editor, cmd: []const u8) !void {
    if (!debugging.hasBreakpoints(ed) or !sources.onPath(ed.io, "gdb")) return startRun(ed, cmd);
    switch (try Debugger.plan(ed.gpa, cmd)) {
        .plan => |p| p.deinit(ed.gpa),
        .unsupported => |why| {
            try startRun(ed, cmd);
            ed.setMessage(.info, "ran without gdb ({s})", .{why});
            return;
        },
    }
    try debugging.debug(ed, cmd);
}

/// <Tab> in the runner: the selected command goes into the query line, to
/// add to or cut down (typing, <BS>, <C-w>) before Enter runs the result.
pub fn runnerEdit(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .runner) return;
    p.sync();
    // The "Run <typed>" row has nothing of its own to copy.
    const item = p.itemAt(p.selected) orelse return;
    try p.query.set(ed.gpa, item.text);
    ed.mode = .picker;
    try p.queryChanged();
}

/// `x` / `dd` in the runner: forgets the selected command.
pub fn pickerForgetCommand(ed: *Editor) !void {
    const p = ed.picker orelse return;
    if (p.kind != .runner) return;
    p.sync();
    const item = p.itemAt(p.selected) orelse return;
    const path = runMemoryPath(ed) orelse return;
    const key = try runKey(ed);
    defer ed.gpa.free(key);
    RunMemory.forget(ed.gpa, ed.io, path, key, item.text);
    try p.restart(null);
    ed.mode = .picker_normal;
}

/// `SPC ;`: a one-off shell command. The prompt starts empty and what runs
/// isn't remembered as the project's runner command (`SPC r r`).
pub fn shellPrompt(ed: *Editor) void {
    prompts.startSearch(ed, true, .run_command);
}

pub fn runMemoryPath(ed: *Editor) ?[]const u8 {
    if (ed.run_memory_path == null) ed.run_memory_path = RunMemory.defaultPath(ed.gpa);
    return ed.run_memory_path;
}

/// What the runner's history is kept under: the current file's project,
/// else (a file in no project) its folder, so a file elsewhere doesn't
/// borrow the commands of whatever project you were in before. No file: the
/// current project. The caller frees it.
pub fn runKey(ed: *Editor) ![]u8 {
    const b = ed.buffer;
    if (b.project) |p| return ed.gpa.dupe(u8, p.root);
    if (b.path) |path| {
        const abs = try ed.absolutePath(path);
        defer ed.gpa.free(abs);
        return ed.gpa.dupe(u8, std.fs.path.dirname(abs) orelse abs);
    }
    return ed.gpa.dupe(u8, project_ops.projectRoot(ed));
}

/// The remembered runner command for here. Caller frees.
pub fn loadRunnerCommand(ed: *Editor) ?[]u8 {
    const path = runMemoryPath(ed) orelse return null;
    const key = runKey(ed) catch return null;
    defer ed.gpa.free(key);
    return RunMemory.load(ed.gpa, ed.io, path, key);
}

pub fn finishRunPrompt(ed: *Editor, kind: PromptKind) !void {
    const raw = try git_ops.takePromptText(ed) orelse return;
    defer ed.gpa.free(raw);
    const cmd = std.mem.trim(u8, raw, " \t");
    if (cmd.len == 0) return;
    _ = kind;
    try startRun(ed, cmd);
}

pub const libcSetenv = @extern(*const fn ([*:0]const u8, [*:0]const u8, c_int) callconv(.c) c_int, .{ .name = "setenv" });


/// Ctrl-Enter in a SQL file: the statement's rows in the results picker.
/// With `whole` (the command picker's "Run the whole SQL file") the file
/// as a script. SQL against the project's database,
/// the results in the run popup: the statement at the cursor, the selected
/// lines in visual mode, or the whole file.
pub fn runSql(ed: *Editor, whole: bool) !void {
    const lang = if (ed.buffer.syntax) |syn| syn.lang.name else "";
    if (!std.mem.eql(u8, lang, "sql")) return ed.setMessage(.info, "not a SQL file", .{});
    const t = ed.text();
    const all = t.slice(0, t.len());
    const statement: []const u8 = if (ed.mode == .visual) blk: {
        const first = t.lineOf(@min(ed.view.anchor, ed.view.cursor));
        const last = t.lineOf(@max(ed.view.anchor, ed.view.cursor));
        code_motion.exitVisual(ed);
        break :blk t.slice(t.lineStart(first), t.lineEnd(last));
    } else if (whole) all else blk: {
        const here = sql.statementAt(all, ed.view.cursor);
        if (std.mem.trim(u8, here, " \t\r\n;").len > 0) break :blk here;
        // Just after a statement's `;` (it was typed a moment ago, or the
        // cursor is at its line's end): that statement.
        var p = ed.view.cursor;
        while (p > 0 and std.ascii.isWhitespace(all[p - 1])) p -= 1;
        break :blk if (p > 0 and all[p - 1] == ';') sql.statementAt(all, p - 1) else here;
    };
    if (std.mem.trim(u8, statement, " \t\r\n;").len == 0) return ed.setMessage(.info, "no statement here", .{});
    const folder = try after_typing.fileFolder(ed);
    defer ed.gpa.free(folder);
    const found = sql.findUrl(ed.gpa, ed.io, folder, ed.cwd) orelse
        return ed.setMessage(.err, "no database: set DATABASE_URL (environment, or a .env above the file)", .{});
    defer ed.gpa.free(found.url);
    defer ed.gpa.free(found.from);
    const shown = try sql.redact(ed.gpa, found.url);
    defer ed.gpa.free(shown);
    const client = sql.clientFor(found.url) orelse
        return ed.setMessage(.err, "can't run SQL on {s} (postgres:// or sqlite: URLs)", .{shown});
    // A statement: in the background, its rows in the results picker. (The
    // whole file is a script: its output scrolls by in the run popup.)
    if (!whole) return startSqlStatement(ed, found.url, statement, shown);
    // The database by the environment, so a password stays out of the
    // command line (and out of messages).
    const target = try ed.gpa.dupeSentinel(u8, client.target, 0);
    defer ed.gpa.free(target);
    _ = libcSetenv("ZILE_DB", target, 1);
    const cmd = try sql.command(ed.gpa, client.client, statement);
    defer ed.gpa.free(cmd);
    try startRun(ed, cmd);
    // Tables may change: completion reloads them once it has run.
    for ([_][]const u8{ "create", "alter", "drop", "rename" }) |w| {
        if (motions.indexOfFold(statement, 0, w) != null) {
            ed.sql_reload = true;
            ed.sql_fresh = false;
        }
    }
    ed.setMessage(.info, "{s} on {s} (from {s})", .{ @tagName(client.client), shown, found.from });
}

pub fn startSqlStatement(ed: *Editor, url: []const u8, statement: []const u8, shown: []const u8) !void {
    if (ed.sql_results) |old| {
        if (!old.done.load(.acquire)) return ed.setMessage(.info, "the last statement is still running", .{});
        // It looks at these rows.
        sql_ops.closeGrid(ed);
        old.destroy(ed.gpa);
        ed.sql_results = null;
    }
    ed.sql_results = try sql.Results.start(ed.gpa, ed.io, url, statement, ed.wake_fn);
    ed.sql_results_seen = false;
    ed.setMessage(.info, "running on {s}...", .{shown});
}

/// `SPC r .`: the runner's command again, without asking.
pub fn runAgain(ed: *Editor) !void {
    const cmd = loadRunnerCommand(ed) orelse return runPrompt(ed, true);
    defer ed.gpa.free(cmd);
    try runOrDebug(ed, cmd);
}

pub fn rerun(ed: *Editor) !void {
    // A debug run (or its build, which may have failed) again: all of it.
    if (ed.run_debug) if (ed.dbg.command) |dc| {
        const cmd = try ed.gpa.dupe(u8, dc);
        defer ed.gpa.free(cmd);
        return if (ed.dbg.by_program) debugging.pickProgram(ed, cmd) else debugging.start(ed, cmd);
    };
    const cmd = try ed.gpa.dupe(u8, ed.run_command orelse return);
    defer ed.gpa.free(cmd);
    try startRun(ed, cmd);
}

/// Saves open files, then runs `cmd` through the user's shell in the popup
/// (replacing the previous run, stopping it if it is still going).
pub fn startRun(ed: *Editor, cmd: []const u8) !void {
    // A run replaces the debugging session (its terminal is the popup's).
    debugging.end(ed);
    debugging.cancelSearch(ed);
    if (ed.dbg.plan) |pl| pl.deinit(ed.gpa);
    ed.dbg.plan = null;
    for (ed.buffers.items) |b| if (b.modified and b.path != null) {
        _ = b.save(ed.gpa, ed.io) catch {};
        if (lsp_ops.lspFor(ed, b)) |l| l.didSave(b);
    };
    const owned = try ed.gpa.dupe(u8, cmd);
    errdefer ed.gpa.free(owned);
    const folder = try commandFolder(ed);
    errdefer ed.gpa.free(folder);
    const t = try spawnTerminalIn(ed, &.{ Pty.userShell(), "-c", cmd }, folder);
    if (ed.run) |old| old.destroy();
    if (ed.run_command) |old| ed.gpa.free(old);
    if (ed.run_root_owned) |old| ed.gpa.free(old);
    ed.run = t;
    ed.run_command = owned;
    // Paths in its output (errors) are relative to here.
    ed.run_root_owned = folder;
    ed.run_root = folder;
    ed.run_started = Io.Timestamp.now(ed.io, .awake);
    ed.run_reported = false;
    ed.run_debug = false;
    ed.dbg.outcome = null;
    ed.popup = .run;
}

/// `y` / `Y` in a finished run: its errors (from the first `error:` line
/// on) or, with `all` or when there are none, the whole output, to the
/// clipboard.
pub fn yankRunOutput(ed: *Editor, t: *Terminal, all: bool) void {
    const out = t.copyOutput(ed.gpa) catch return;
    defer ed.gpa.free(out);
    var body: []const u8 = std.mem.trimEnd(u8, out, " \t\r\n");
    // Our own "exited" line at the end is not part of the output.
    if (std.mem.lastIndexOfScalar(u8, body, '\n')) |nl| {
        if (std.mem.indexOf(u8, body[nl..], "exited ") != null) body = std.mem.trimEnd(u8, body[0..nl], " \t\r\n");
    }
    var errors_only = false;
    // Zig/C/TS write `error:`, Rust `error[E0425]:`.
    const first_error: ?usize = blk: {
        const a = std.mem.indexOf(u8, body, "error:");
        const b = std.mem.indexOf(u8, body, "error[");
        if (a != null and b != null) break :blk @min(a.?, b.?);
        break :blk a orelse b;
    };
    if (!all) if (first_error) |at| {
        const line = if (std.mem.lastIndexOfScalar(u8, body[0..at], '\n')) |nl| nl + 1 else 0;
        body = body[line..];
        errors_only = true;
    };
    if (body.len == 0) return ed.setMessage(.info, "no output to yank", .{});
    ed.registers.store(null, .yank, body, false) catch return;
    ed.setMessage(.info, "yanked the run's {s} ({d} lines)", .{
        if (errors_only) "errors" else "output",
        std.mem.count(u8, body, "\n") + 1,
    });
}

/// Finds `path:line:col` errors in the finished run's output.
pub fn collectRunErrors(ed: *Editor, t: *Terminal) void {
    for (ed.run_errors.items) |e| e.deinit(ed.gpa);
    ed.run_errors.clearRetainingCapacity();
    const out = t.copyOutput(ed.gpa) catch return;
    defer ed.gpa.free(out);
    // Paths in the output are relative to where the command ran.
    const S = struct {
        fn exists(e: *Editor, path: []const u8) bool {
            if (std.fs.path.isAbsolute(path)) return formatting.fileExists(e, path);
            var buf: [Io.Dir.max_path_bytes]u8 = undefined;
            const full = std.fmt.bufPrint(&buf, "{s}/{s}", .{ e.run_root, path }) catch return false;
            return formatting.fileExists(e, full);
        }
    };
    run_errors_mod.parse(ed.gpa, out, ed, S.exists, &ed.run_errors) catch {};
    for (ed.run_errors.items) |*e| if (!std.fs.path.isAbsolute(e.path)) {
        const full = std.fs.path.join(ed.gpa, &.{ ed.run_root, e.path }) catch continue;
        ed.gpa.free(e.path);
        e.path = full;
    };
}
