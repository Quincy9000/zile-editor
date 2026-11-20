//! Editor tests: run.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Terminal = @import("../terminal/Terminal.zig");
const window_ops = @import("../editor/window_ops.zig");
const quickfix_list = @import("../editor/quickfix_list.zig");
const run_popup = @import("../editor/run_popup.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const QuickfixItem = Editor.QuickfixItem;
const PromptKind = Editor.PromptKind;
const noWake = Editor.noWake;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const waitForRun = support.waitForRun;
const settlePicker = support.settlePicker;
const io_sleep = support.io_sleep;

test "run: SPC r c shows output and how it ended; SPC r remembers its command" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });

    try ed.feed("<cmd:run_command>echo hi; exit 4<Esc><CR>");
    try testing.expectEqual(.run, ed.popup.?);
    waitForRun(&ed);
    try testing.expectEqual(4, ed.run.?.exit_code);
    try testing.expectEqual(.err, ed.message.kind);
    const out = try ed.run.?.screenText(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "hi\n"));
    try testing.expect(std.mem.indexOf(u8, out, "exited 4") != null);
    try ed.feed("y"); // no errors in it: the whole output, without our status line
    try testing.expectEqualStrings("hi", std.mem.trimEnd(u8, ed.registers.get(null).?.text, "\n"));
    try ed.feed("q");
    try testing.expectEqual(null, ed.popup);

    // The runner: a picker of the commands run here. Empty the first time;
    // typing one runs it; then it is first in the list.
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(.runner, ed.picker.?.kind);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try testing.expectEqual(Mode.picker, ed.mode); // none yet: typing one
    try ed.feed("<Esc><CR>"); // Enter with nothing to run: typing one again
    try testing.expectEqual(Mode.picker, ed.mode);
    try ed.feed("echo runner<CR>");
    waitForRun(&ed);
    try testing.expectEqual(0, ed.run.?.exit_code);
    try ed.feed("q<cmd:run_runner>iecho second<CR>"); // (on the list now: i types)
    waitForRun(&ed);
    try ed.feed("q<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo second", ed.picker.?.itemAt(0).?.text); // newest first
    try testing.expectEqualStrings("echo runner", ed.picker.?.itemAt(1).?.text);
    // Typing filters the history; the typed text itself stays the first row.
    try ed.feed("irun");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.createRow().?);
    try testing.expectEqualStrings("echo runner", ed.picker.?.itemAt(1).?.text);
    try ed.feed("<C-n><CR>"); // down to the old command: run that
    try testing.expectEqualStrings("echo runner", ed.run_command.?);
    waitForRun(&ed);
    // It is the newest now; x forgets one.
    try ed.feed("q<cmd:run_runner>"); // on the list (normal mode) when it has commands
    settlePicker(&ed);
    try testing.expectEqual(Mode.picker_normal, ed.mode);
    try testing.expectEqualStrings("echo runner", ed.picker.?.itemAt(0).?.text);
    try ed.feed("jx");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try ed.feed("<CR>"); // Enter on the list: the last command again
    try testing.expectEqualStrings("echo runner", ed.run_command.?);
    waitForRun(&ed);
    try ed.feed("r"); // `r` in a finished run: once more
    waitForRun(&ed);
    try testing.expectEqual(0, ed.run.?.exit_code);
    try ed.feed("q<cmd:run_output>"); // the output comes back
    try testing.expectEqual(.run, ed.popup.?);
    // SPC r r: the runner, on the last command, and r runs it.
    try ed.feed("q");
    const before = ed.run.?;
    try ed.feed("<Space>rr");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.run.? != before); // a new run
    try testing.expectEqualStrings("echo runner", ed.run_command.?);
    waitForRun(&ed);
    // SPC r .: the last command, whatever row is selected.
    try ed.feed("q<cmd:run_runner>iecho other<CR>");
    waitForRun(&ed);
    try ed.feed("q<Space>r");
    settlePicker(&ed);
    try ed.feed("j."); // on the older row, still the last command
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqualStrings("echo other", ed.run_command.?);
    waitForRun(&ed);
}

test "runner: s / Ctrl-s runs with the shell under the output; Ctrl-\\ swaps the keys; a plain run is alone again" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });

    // Typed, then Ctrl-s: the server runs, the shell under it has the keys.
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try ed.feed("sleep 30; true<C-s>"); // (`; true`: sleep is a child of the shell)
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(.run, ed.popup.?);
    try testing.expectEqualStrings("sleep 30; true", ed.run_command.?);
    try testing.expect(run_popup.splitShown(&ed));
    try testing.expectEqual(ed.shell.?, run_popup.keyTerminal(&ed).?);
    // Both are drawn: the run above, the shell's header between them.
    {
        const render = @import("../ui/render.zig");
        const Grid = @import("../tui/Grid.zig");
        const gfx = @import("../ui/gfx.zig");
        var grid: Grid = .{};
        defer grid.deinit(gpa);
        try grid.resize(gpa, 80, 30);
        gfx.grid = &grid;
        defer gfx.grid = null;
        var font = @import("../ui/Font.zig").cells();
        const theme = @import("../ui/Theme.zig").get(ed.theme_index);
        render.draw(&ed, &font, theme, render.prepare(&ed, &font, 80 * Grid.cell_w, 30 * Grid.cell_h));
        try testing.expect(ed.run.?.rows + ed.shell.?.rows + 1 == ed.term_size.rows);
        var found = false;
        for (0..grid.rows) |r| {
            var line: [80]u8 = undefined;
            for (0..grid.cols) |c| line[c] = std.math.cast(u8, grid.cells[r * grid.cols + c].cp) orelse '?';
            if (std.mem.indexOf(u8, &line, "Terminal") != null and std.mem.indexOf(u8, &line, "the other") != null) found = true;
        }
        try testing.expect(found);
    }
    // Ctrl-\ gives the keys to the run, and back.
    try ed.feed("<C-\\>");
    try testing.expectEqual(ed.run.?, run_popup.keyTerminal(&ed).?);
    try ed.feed("<C-\\>");
    try testing.expectEqual(ed.shell.?, run_popup.keyTerminal(&ed).?);
    // Typing goes to the shell: `exit` leaves it, and that ends the run
    // too, all of it (the sleep under its shell), and closes their popup.
    const shell = ed.shell.?;
    const run = ed.run.?;
    try ed.feed("exit<CR>");
    while (shell.isRunning()) std.Thread.yield() catch {};
    try testing.expect(run.isRunning());
    ed.tick();
    try testing.expectEqual(null, ed.shell);
    try testing.expectEqual(null, ed.popup);
    var waited: usize = 0;
    while (run.isRunning() and waited < 500) : (waited += 1) io_sleep(10);
    try testing.expect(!run.isRunning()); // (not 30 seconds)
    ed.tick();
    try testing.expect(std.mem.indexOf(u8, ed.message.text(), "stopped with its terminal") != null);
    try testing.expectEqual(.info, ed.message.kind);
    // Again: with its terminal again.
    try ed.feed("<cmd:run_again>");
    try testing.expect(run_popup.splitShown(&ed));
    try ed.feed("<C-\\><C-c>"); // (to the run: stopped by hand, the shell stays)
    waited = 0;
    while (ed.run.?.isRunning() and waited < 500) : (waited += 1) io_sleep(10);
    try testing.expect(!ed.run.?.isRunning());
    ed.tick();
    try testing.expect(ed.shell != null);
    try ed.feed("<Esc><Esc>");

    // A plain run from the runner: no shell under it.
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try ed.feed("iecho plain<CR>"); // (on the list: i types a new one)
    try testing.expectEqualStrings("echo plain", ed.run_command.?);
    try testing.expect(!ed.run_split);
}

test "runner: a run with a terminal that fails closes the terminal; the error keeps the popup, r brings both back" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });

    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try ed.feed("sleep 0.2; exit 3<C-s>");
    try testing.expect(run_popup.splitShown(&ed));
    var waited: usize = 0;
    while (ed.run.?.isRunning() and waited < 500) : (waited += 1) io_sleep(10);
    try testing.expect(!ed.run.?.isRunning());
    ed.tick();
    try testing.expectEqual(null, ed.shell);
    try testing.expectEqual(.run, ed.popup.?);
    try testing.expect(!run_popup.splitShown(&ed));
    try testing.expectEqual(ed.run.?, run_popup.keyTerminal(&ed).?);
    try testing.expectEqual(.err, ed.message.kind);
    // Again: with its terminal again.
    try ed.feed("<cmd:run_again>");
    try testing.expect(run_popup.splitShown(&ed));
}

/// How many processes run exactly `cmdline` (by pgrep).
fn countProcesses(cmdline: []const u8) !usize {
    const gpa = testing.allocator;
    const pattern = try std.fmt.allocPrint(gpa, "^{s}$", .{cmdline});
    defer gpa.free(pattern);
    const r = try std.process.run(gpa, testing.io, .{ .argv = &.{ "pgrep", "-f", pattern } });
    defer gpa.free(r.stdout);
    defer gpa.free(r.stderr);
    return std.mem.count(u8, r.stdout, "\n");
}

test "a rerun ends the old run first, all of it (a server still running would hold its port)" {
    var ed = try testEditor("");
    defer ed.deinit();
    // It says "clash" if it starts while an earlier one is still running
    // (as a server would fail to bind); `; true` keeps sleep the shell's
    // child, as `zig build-exe x.zig && ./x`'s server.
    const cmd = "if pgrep -f '^sleep 77123$' >/dev/null; then echo clash; else echo alone; fi; sleep 77123; true";
    try run_popup.startRun(&ed, cmd);
    var waited: usize = 0;
    while (try countProcesses("sleep 77123") == 0 and waited < 300) : (waited += 1) io_sleep(10);
    try run_popup.rerun(&ed);
    waited = 0;
    while (try countProcesses("sleep 77123") == 0 and waited < 300) : (waited += 1) io_sleep(10);
    const out = try ed.run.?.screenText(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.indexOf(u8, out, "alone") != null);
    try testing.expect(std.mem.indexOf(u8, out, "clash") == null);
    try testing.expectEqual(1, try countProcesses("sleep 77123"));
    ed.popup = null;
}

test "terminal popup: keys go to the shell, Ctrl-\\ hides it and keeps it running" {
    var ed = try testEditor("text");
    defer ed.deinit();
    try ed.feed("<cmd:terminal_toggle>");
    try testing.expectEqual(.shell, ed.popup.?);
    const shell = ed.shell.?;
    try ed.feed("<C-\\>");
    try testing.expectEqual(null, ed.popup);
    try testing.expect(shell.isRunning());
    try ed.feed("dd"); // back in the editor
    try expectText(&ed, "");
    try ed.feed("<C-\\>"); // the same shell again
    try testing.expectEqual(shell, ed.shell.?);
    try ed.feed("exit<CR>");
    while (shell.isRunning()) std.Thread.yield() catch {};
    ed.tick(); // an exited shell closes its popup
    try testing.expectEqual(null, ed.popup);
    try testing.expectEqual(null, ed.shell);
}

test "run errors: a failing run fills the quickfix picker; j/k preview, Enter goes" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    try ed.feed("<cmd:run_command>printf 'src/main.zig:4:7: error: boom\\nsrc/Editor.zig:2:1: error: two\\nnot/a/file.zig:1:1: error: x\\n'; exit 1<Esc><CR>");
    waitForRun(&ed);
    try testing.expectEqual(2, ed.run_errors.items.len); // only real files count
    try testing.expectEqual(2, ed.quickfix.items.len); // and they're the quickfix list
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("e"); // from the finished run's popup
    try testing.expectEqual(.quickfix, ed.picker.?.kind);
    try testing.expectEqual(.picker_normal, ed.mode); // quickfix starts in normal mode
    try testing.expectEqual(null, ed.popup);
    settlePicker(&ed);
    // A picker like any other: each row has its file and line number, the
    // preview shows the place, and the editor stays put until Enter.
    try testing.expectEqualStrings("src/main.zig:4", ed.picker.?.itemAt(0).?.detail);
    try testing.expectEqualStrings("src/Editor.zig:2", ed.picker.?.itemAt(1).?.detail);
    try testing.expectEqual(3, ed.picker.?.preview.focus_line);
    try testing.expectEqual(null, ed.buffer.path);
    try ed.feed("j");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.picker.?.preview.focus_line);
    try testing.expectEqual(null, ed.buffer.path);
    try ed.feed("k");
    settlePicker(&ed);
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.picker);
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expectEqual(3, ed.cursorLine());
    try testing.expectEqual(6, ed.view.cursor - ed.text().lineStart(3));
    try ed.feed("j"); // a normal j again
    try testing.expectEqual(4, ed.cursorLine());
    // ]q / [q without the picker.
    try ed.feed("]q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/Editor.zig"));
    try ed.feed("[q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    // SPC f q reopens at the current entry; i types to filter; q closes.
    try ed.feed("<cmd:quickfix_list>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.selected);
    try ed.feed("itwo");
    settlePicker(&ed);
    try testing.expectEqual(1, ed.picker.?.rowCount());
    try ed.feed("<Esc>q");
    try testing.expectEqual(null, ed.picker);
}

test "quickfix: Ctrl-q sends a picker's results" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    try ed.feed("<cmd:search_buffer>surround");
    ed.picker.?.sync();
    const n = ed.picker.?.snap.len;
    try testing.expect(n > 1);
    try ed.feed("<C-q>");
    try testing.expectEqual(.quickfix, ed.picker.?.kind);
    try testing.expectEqual(n, ed.quickfix.items.len);
    try ed.feed("q");
    try testing.expectEqual(null, ed.picker);
}

test "command editor: multi-line with vim editing; Enter runs, Esc cancels" {
    var ed = try testEditor("main text");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    const main_buffer = ed.buffer;

    try ed.feed("<cmd:run_command>");
    try testing.expect(ed.cmd_float != null);
    try testing.expectEqual(.insert, ed.mode);
    try ed.feed("echo one<CR>echo two<Esc>");
    try ed.feed("ggA; echo three<Esc>"); // plain vim editing
    try expectText(&ed, "echo one; echo three\necho two");
    try ed.feed("<Space>w"); // leader keys wait until it closes
    try testing.expect(ed.cmd_float != null);
    try ed.feed("<CR>"); // normal mode: run it
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqual(main_buffer, ed.buffer);
    try expectText(&ed, "main text");
    waitForRun(&ed);
    const out = try ed.run.?.screenText(testing.allocator);
    defer testing.allocator.free(out);
    try testing.expect(std.mem.startsWith(u8, out, "one\nthree\ntwo\n"));

    try ed.feed("q<cmd:run_command>echo nope<Esc><Esc>"); // Esc in normal mode cancels
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expectEqualStrings("echo one; echo three\necho two", ed.run_command.?);
}

test "terminal window: Esc Esc is normal mode, SPC commands work, i types again" {
    var ed = try testEditor("code");
    defer ed.deinit();
    ed.windows.layout(.{ .w = 100, .h = 50 }, 1, 1);
    const t = try Terminal.create(ed.gpa, ed.io, .{ .argv = &.{ "/bin/sh", "-c", "trap 'echo got-int' INT; echo ready; while :; do sleep 0.05; done" }, .cwd = "/", .cols = 40, .rows = 5, .wake = noWake });
    defer t.destroy();
    const code_window = ed.window;
    try window_ops.splitWindow(&ed, .right);
    ed.window.term = t;
    const term_window = ed.window;
    for (0..200) |_| {
        const out = try t.screenText(testing.allocator);
        defer testing.allocator.free(out);
        if (std.mem.indexOf(u8, out, "ready") != null) break;
        io_sleep(10);
    }
    try ed.feed("<C-S-c>"); // to the program
    try testing.expectEqual(term_window, ed.window);
    try ed.feed("<Esc><Esc>"); // normal mode: keys go to the editor
    try testing.expect(term_window.term_normal);
    try ed.feed("x"); // does nothing
    try expectText(&ed, "code");
    try ed.feed("<cmd:window_left>"); // SPC commands work from here
    try testing.expectEqual(code_window, ed.window);
    try testing.expectEqual(2, ed.window_list.items.len);
    try ed.feed("<C-\\>"); // and to the terminal again, typing
    try testing.expectEqual(term_window, ed.window);
    try testing.expect(!term_window.term_normal);
    try ed.feed("<C-\\>"); // one key back to the code
    try testing.expectEqual(code_window, ed.window);
    try testing.expectEqual(Mode.normal, ed.mode);
    try ed.feed("<C-\\><Esc><Esc>"); // from its normal mode, Esc is the way out too
    try testing.expect(term_window.term_normal);
    try ed.feed("<Esc>");
    try testing.expectEqual(code_window, ed.window);
    // The leader menu over the terminal has the keys while it is open: Esc
    // closes it, and nothing more.
    try ed.feed("<C-\\><Esc><Esc><Space>");
    try testing.expect(ed.picker != null);
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.picker);
    try testing.expectEqual(term_window, ed.window);
    try testing.expect(term_window.term_normal);
    try ed.feed("<Space>");
    try ed.feed("j"); // moves in the menu, not the terminal's scrollback
    try testing.expect(ed.picker != null);
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.picker);
    try ed.feed("<C-w>"); // Ctrl-w: back to the code
    try testing.expectEqual(code_window, ed.window);
    try ed.feed("<C-\\>");
    try testing.expectEqual(term_window, ed.window);
    try testing.expect(!term_window.term_normal);
    var got = false;
    for (0..200) |_| {
        const out = try t.screenText(testing.allocator);
        defer testing.allocator.free(out);
        if (std.mem.indexOf(u8, out, "got-int") != null) {
            got = true;
            break;
        }
        io_sleep(10);
    }
    try testing.expect(got);
    try ed.feed("<C-c>"); // not the Claude panel: Ctrl-C is the program's
    try testing.expectEqual(2, ed.window_list.items.len);
    try testing.expectEqual(term_window, ed.window);
}

test "quickfix: without a run it is the project's live errors; a run's list takes over until cleared" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("src/pairs.zig");
    var live = [_]QuickfixItem{
        .{ .path = @constCast("src/main.zig"), .line = 4, .col = 0, .text = @constCast("elsewhere") },
        .{ .path = @constCast("src/pairs.zig"), .line = 10, .col = 2, .text = @constCast("first here") },
        .{ .path = @constCast("src/pairs.zig"), .line = 30, .col = 0, .text = @constCast("second here") },
    };
    ed.live_errors_override = &live;
    // ]q: by the cursor, this file first, then the others.
    try ed.feed("]q");
    try testing.expectEqual(10, ed.cursorLine());
    try ed.feed("]q");
    try testing.expectEqual(30, ed.cursorLine());
    try ed.feed("[q");
    try testing.expectEqual(10, ed.cursorLine());
    try ed.feed("]q]q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/main.zig"));
    try testing.expectEqual(4, ed.cursorLine());
    // The list is live: a fixed error is gone the next time.
    ed.live_errors_override = live[1..];
    try ed.feed("<cmd:quickfix_list>");
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try testing.expectEqualStrings("src/pairs.zig:11", ed.picker.?.itemAt(0).?.detail);
    try ed.feed("q");
    // A list of your own stays, whatever the errors are, until x in the quickfix picker.
    try quickfix_list.newQuickfix(&ed, "mine");
    try quickfix_list.addQuickfix(&ed, "src/main.zig", 1, 0, "picked");
    try ed.feed("]q");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expectEqual(1, ed.quickfix.items.len);
    try ed.feed("<cmd:quickfix_list>x]q");
    try testing.expect(std.mem.endsWith(u8, ed.buffer.path.?, "src/pairs.zig"));
    try testing.expectEqual(10, ed.cursorLine());
}

test "SPC ; runs a one-off shell command in the vim command editor, leaving the runner alone" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    try ed.feed("<Space>;");
    try testing.expect(ed.cmd_float != null); // the command editor, empty, typing
    try testing.expectEqual(Mode.insert, ed.mode);
    try expectText(&ed, "");
    try ed.feed("echo oncx<BS>e<Esc><CR>"); // vim's keys; Enter in normal mode runs it
    try testing.expectEqual(null, ed.cmd_float);
    waitForRun(&ed);
    try testing.expectEqualStrings("echo once", ed.run_command.?);
    try ed.feed("q");
    // Not one of the runner's commands: its list is still empty.
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("<Esc><Esc>");
}

test "commands run in the folder of the code you are in" {
    const gpa = testing.allocator;
    const io = testing.io;
    const base = try std.fmt.allocPrint(gpa, "/tmp/zile-test-runfolder-{d}", .{Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(base);
    const cwd = Io.Dir.cwd();
    defer cwd.deleteTree(io, base) catch {};
    for ([_][]const u8{ "repo/.git", "repo/app/src", "repo/docs", "loose" }) |sub| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, sub });
        defer gpa.free(p);
        try cwd.createDirPath(io, p);
    }
    const files = [_][2][]const u8{
        .{ "repo/app/Makefile", "" },     .{ "repo/app/src/main.c", "int x;\n" },
        .{ "repo/docs/notes.txt", "n\n" }, .{ "loose/x.txt", "x\n" },
    };
    for (files) |f| {
        const p = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ base, f[0] });
        defer gpa.free(p);
        try cwd.writeFile(io, .{ .sub_path = p, .data = f[1] });
    }
    const at = struct {
        fn path(g: std.mem.Allocator, b: []const u8, rel: []const u8) ![]u8 {
            return std.fmt.allocPrint(g, "{s}/{s}", .{ b, rel });
        }
    }.path;

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try gpa.dupe(u8, "/nonexistent/run-commands");
    // Inside the app: its Makefile's folder, not the repository's root.
    const main_c = try at(gpa, base, "repo/app/src/main.c");
    defer gpa.free(main_c);
    try ed.openFile(main_c);
    const folder = try run_popup.commandFolder(&ed);
    defer gpa.free(folder);
    const want_app = try at(gpa, base, "repo/app");
    defer gpa.free(want_app);
    try testing.expectEqualStrings(want_app, folder);
    // No build file on the way up: the project root.
    const notes = try at(gpa, base, "repo/docs/notes.txt");
    defer gpa.free(notes);
    try ed.openFile(notes);
    const root = try run_popup.commandFolder(&ed);
    defer gpa.free(root);
    const want_root = try at(gpa, base, "repo");
    defer gpa.free(want_root);
    try testing.expectEqualStrings(want_root, root);
    // A file in no project: its own folder, whatever project came before it.
    const loose = try at(gpa, base, "loose/x.txt");
    defer gpa.free(loose);
    try ed.openFile(loose);
    const own = try run_popup.commandFolder(&ed);
    defer gpa.free(own);
    const want_loose = try at(gpa, base, "loose");
    defer gpa.free(want_loose);
    try testing.expectEqualStrings(want_loose, own);
    // Its runner history is its own too, not the project's from before.
    const memory = try at(gpa, base, "run-commands");
    defer gpa.free(memory);
    gpa.free(ed.run_memory_path.?);
    ed.run_memory_path = try gpa.dupe(u8, memory);
    try ed.openFile(main_c);
    try ed.feed("<cmd:run_runner>make app<CR>");
    waitForRun(&ed);
    try ed.feed("q");
    try ed.openFile(loose);
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqual(0, ed.picker.?.rowCount());
    try ed.feed("<Esc><Esc>");
    try ed.openFile(main_c);
    try ed.feed("<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("make app", ed.picker.?.itemAt(0).?.text);
    try ed.feed("<Esc><Esc>");
    try ed.openFile(loose);
    // And that is where the command really runs.
    try ed.feed("<Space>;pwd<Esc><CR>");
    waitForRun(&ed);
    const out = try ed.run.?.screenText(gpa);
    defer gpa.free(out);
    try testing.expect(std.mem.startsWith(u8, out, want_loose));
    try testing.expectEqualStrings(want_loose, ed.run_root);
    try ed.feed("q");
}

test "runner: e / Ctrl-e edits the command in the vim command editor (the one selected, or the one typed)" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try std.fs.path.join(gpa, &.{ dir, "run-commands" });
    try ed.feed("<cmd:run_runner>echo hello<CR>");
    waitForRun(&ed);
    try ed.feed("q<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo hello", ed.picker.?.itemAt(0).?.text);
    try ed.feed("e"); // from the list: in the vim editor, normal mode
    try testing.expectEqual(null, ed.picker);
    try testing.expect(ed.cmd_float != null);
    try testing.expectEqual(Mode.normal, ed.mode);
    try expectText(&ed, "echo hello");
    try ed.feed("A world<Esc><CR>"); // appended; Enter runs it
    waitForRun(&ed);
    try testing.expectEqualStrings("echo hello world", ed.run_command.?);
    // Remembered: newest first now.
    try ed.feed("q<cmd:run_runner>");
    settlePicker(&ed);
    try testing.expectEqualStrings("echo hello world", ed.picker.?.itemAt(0).?.text);
    // Ctrl-e while typing a new one: what's typed so far goes there.
    try ed.feed("iecho ty<C-e>");
    try expectText(&ed, "echo ty");
    try ed.feed("Aped<Esc><CR>");
    waitForRun(&ed);
    try testing.expectEqualStrings("echo typed", ed.run_command.?);
}

test "the command editor: vim keys change the command; Enter runs it" {
    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    try run_popup.editCommand(&ed, "echo one two", .runner, null);
    try ed.feed("$ciwthree<Esc><CR>");
    waitForRun(&ed);
    try testing.expectEqualStrings("echo one three", ed.run_command.?);
}
