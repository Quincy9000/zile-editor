//! Editor tests: debug.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const sources = @import("../picker/sources.zig");
const Debugger = @import("../Debugger.zig");
const debugging = @import("../debugging.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const settlePicker = support.settlePicker;
const testStoppedVars = support.testStoppedVars;
const expectVars = support.expectVars;

test "debugging: a breakpoint stops the program there, stepping, locals, the exit" {
    const gpa = testing.allocator;
    if (!sources.onPath(testing.io, "gdb") or !sources.onPath(testing.io, "cc")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.c", .data =
        \\#include <stdio.h>
        \\int add(int a, int b) {
        \\  int c = a + b;
        \\  return c;
        \\}
        \\int main(void) {
        \\  int x = add(2, 3);
        \\  printf("x=%d\n", x);
        \\  return 7;
        \\}
        \\
    });
    const src = try std.fs.path.join(gpa, &.{ dir, "t.c" });
    defer gpa.free(src);
    const out = try std.fs.path.join(gpa, &.{ dir, "t" });
    defer gpa.free(out);
    const cc = try std.process.run(gpa, testing.io, .{ .argv = &.{ "cc", "-g", "-O0", "-o", out, src } });
    gpa.free(cc.stdout);
    gpa.free(cc.stderr);

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(src);
    try ed.feed("3G"); // `int c = a + b;`
    try debugging.toggleBreakpoint(&ed);
    try testing.expectEqual(1, ed.dbg.breakpoints.items.len);
    const S = struct {
        /// Ticks until `done`, or about ten seconds.
        fn until(e: *Editor, comptime done: fn (*Editor) bool) !void {
            for (0..2000) |_| {
                e.tick();
                if (done(e)) return;
                testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
            }
            return error.Timeout;
        }
        fn varsIn(e: *Editor) bool {
            const d = e.dbg.session orelse return false;
            return d.state == .stopped and d.frames.items.len > 0 and d.frames.items[0].vars_left == 0 and d.frames.items[0].vars.items.len > 0;
        }
        fn ended(e: *Editor) bool {
            return e.dbg.session == null;
        }
    };
    try debugging.start(&ed, out);
    try S.until(&ed, S.varsIn);
    const d = ed.dbg.session.?;
    try testing.expectEqualStrings("add", d.frames.items[0].name);
    try testing.expectEqual(2, d.frames.items[0].line);
    try testing.expectEqualStrings("main", d.frames.items[1].name);
    // Arguments, then locals.
    var vars: std.ArrayList(u8) = .empty;
    defer vars.deinit(gpa);
    try d.frames.items[0].writeVars(gpa, &vars);
    try testing.expect(std.mem.startsWith(u8, vars.items, "a = 2\nb = 3\nc = "));
    // The values a line uses, for its end: the function's lines down to the
    // stop, not below it.
    var vbuf: [256]u8 = undefined;
    try testing.expectEqualStrings("a = 2, b = 3", debugging.inlineValues(&ed, src, 1, &vbuf).?);
    try testing.expect(std.mem.startsWith(u8, debugging.inlineValues(&ed, src, 2, &vbuf).?, "a = 2, b = 3, c = "));
    try testing.expect(debugging.inlineValues(&ed, src, 3, &vbuf) == null);
    try testing.expect(debugging.inlineValues(&ed, src, 0, &vbuf) == null);
    // J / K scroll the variables in the preview.
    ed.picker.?.updatePreview();
    try ed.feed("J");
    try testing.expectEqual(3, ed.picker.?.previewScroll());
    try ed.feed("K");
    try testing.expectEqual(0, ed.picker.?.previewScroll());
    // The editor is on the stop, marked, with the Debug picker open.
    try testing.expectEqual(2, ed.cursorLine());
    try testing.expect(debugging.marks(&ed, src, 2).here and debugging.marks(&ed, src, 2).breakpoint);
    try testing.expect(ed.picker != null and ed.picker.?.kind == .debug);

    // `n`: on to `return c;`, where c is 5.
    try ed.feed("n");
    try S.until(&ed, S.varsIn);
    try testing.expectEqual(3, ed.dbg.session.?.frames.items[0].line);
    vars.clearRetainingCapacity();
    try ed.dbg.session.?.frames.items[0].writeVars(gpa, &vars);
    try testing.expect(std.mem.indexOf(u8, vars.items, "c = 5") != null);
    try testing.expectEqual(3, ed.cursorLine());

    // `c`: runs to the end; the exit is reported in its output.
    try ed.feed("c");
    try S.until(&ed, S.ended);
    try testing.expect(ed.popup == .run);
    // The popup's title goes by the program's exit, not its stand-in's.
    try testing.expectEqual(7, ed.dbg.outcome.?.exited);
    try testing.expect(ed.run_debug);
    const shown = try ed.run.?.screenText(gpa);
    defer gpa.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "x=5") != null);
    try testing.expect(std.mem.indexOf(u8, shown, "exited 7") != null);
    // The terminal had no process of its own: it ends with the program, its
    // code the program's.
    for (0..400) |_| {
        if (!ed.run.?.isRunning()) break;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    try testing.expect(!ed.run.?.isRunning());
    try testing.expectEqual(7, ed.run.?.exit_code);
}

test "breakpoints: on/off keeps them, clearing and undo, runs choose gdb" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.c", .data = "int main(void) {\n  return 0;\n}\n" });
    const src = try std.fs.path.join(gpa, &.{ dir, "a.c" });
    defer gpa.free(src);
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(src);
    try debugging.toggleBreakpoint(&ed);
    try ed.feed("j");
    try debugging.toggleBreakpoint(&ed);
    try testing.expectEqual(2, ed.dbg.breakpoints.items.len);
    try testing.expect(debugging.hasBreakpoints(&ed));
    // Off: kept, but runs run normally.
    try debugging.toggleBreakpointsOn(&ed);
    try testing.expectEqual(2, ed.dbg.breakpoints.items.len);
    try testing.expect(!debugging.hasBreakpoints(&ed));
    try debugging.toggleBreakpointsOn(&ed);
    // Removing all, then undo brings them back; undo again: before the second.
    try debugging.clearBreakpoints(&ed);
    try testing.expectEqual(0, ed.dbg.breakpoints.items.len);
    try debugging.undoBreakpoints(&ed);
    try testing.expectEqual(2, ed.dbg.breakpoints.items.len);
    try debugging.undoBreakpoints(&ed);
    try testing.expectEqual(1, ed.dbg.breakpoints.items.len);
    try testing.expectEqual(0, ed.dbg.breakpoints.items[0].line);
    // Toggling a line off and undoing it.
    try ed.feed("k");
    try debugging.toggleBreakpoint(&ed);
    try testing.expectEqual(0, ed.dbg.breakpoints.items.len);
    try debugging.undoBreakpoints(&ed);
    try testing.expectEqual(1, ed.dbg.breakpoints.items.len);
}

test "debugging Zig: slices, optionals, unions and what is inside structs can be read" {
    const gpa = testing.allocator;
    const vars = try testStoppedVars(gpa, "t.zig",
        \\const P = struct { x: i32, name: []const u8, next: ?*const P };
        \\const U = union(enum) { a: i32, b: []const u8, none };
        \\fn work(s: []const u8, nums: []u32, p: *const P, o: ?i32, u: U, eu: anyerror!u8) usize {
        \\    const none: ?i32 = null;
        \\    const total = s.len + nums.len;
        \\    keep(.{ p, o, u, eu, none });
        \\    return total;
        \\}
        \\fn keep(x: anytype) void {
        \\    _ = x;
        \\}
        \\pub fn main() void {
        \\    var nums = [_]u32{ 1, 2, 3, 4 };
        \\    const a: P = .{ .x = 1, .name = "inner", .next = null };
        \\    const b: P = .{ .x = 7, .name = "outer", .next = &a };
        \\    _ = work("some text", &nums, &b, 42, .{ .b = "ub" }, error.Oops);
        \\}
        \\
    , &.{ "zig", "build-exe", "--cache-dir", "cache" }, "-femit-bin=", "6");
    defer gpa.free(vars);
    try expectVars(vars, &.{
        "s = \"some text\"\n", // a slice of bytes is its text
        "nums = len 4\n  [0] = 1\n  [1] = 2\n", // a slice's items, under it
        "o = 42\n", // an optional is what it holds
        "none = null\n",
        "eu = error.Oops\n",
        "u = .b\n  b = \"ub\"\n", // a union's field in use
        "\n  x = 7\n  name = \"outer\"\n", // through the pointer, into the struct
        "\n    x = 1\n    name = \"inner\"\n    next = null\n", // and on through its optional pointer
    });
}

test "debugging C: what is inside structs, through pointers, and arrays" {
    const gpa = testing.allocator;
    const vars = try testStoppedVars(gpa, "t.c",
        \\struct P { int x; const char *name; struct P *next; int arr[2]; };
        \\int work(struct P *p, struct P byval) {
        \\  int total = p->x + byval.x;
        \\  return total;
        \\}
        \\int main(void) {
        \\  struct P a = {1, "inner", 0, {1, 2}};
        \\  struct P b = {7, "outer", &a, {4, 5}};
        \\  return work(&b, a);
        \\}
        \\
    , &.{ "cc", "-g", "-O0" }, "-o", "4");
    defer gpa.free(vars);
    try expectVars(vars, &.{
        "\n  x = 7\n  name = ", // under `p`, through the pointer
        "\"outer\"",
        "\n    x = 1\n", // and through `next`
        "byval\n  x = 1\n", // a struct has no value of its own
        "  arr\n    0 = 1\n    1 = 2\n",
        "  next = 0x0\n",
    });
}

test "debugging Rust: the toolchain's printers are loaded; enums read as their variant" {
    const gpa = testing.allocator;
    const vars = try testStoppedVars(gpa, "t.rs",
        \\struct P { x: i32, name: String }
        \\enum U { A(i32), Named { a: u8, b: u8 }, Empty }
        \\fn work(s: &str, p: &P, o: Option<i32>, u: U, r: Result<u8, String>) -> usize {
        \\    let v: Vec<u32> = vec![1, 2, 3];
        \\    let none: Option<i32> = None;
        \\    let e = [U::A(3), U::Empty];
        \\    keep(&(p.x, &o, &u, &r, &none, &e));
        \\    s.len() + v.len()
        \\}
        \\#[inline(never)]
        \\fn keep<T>(_x: &T) {}
        \\fn main() {
        \\    let b = P { x: 7, name: "outer".into() };
        \\    work("some text", &b, Some(42), U::Named { a: 1, b: 2 }, Err("bad".into()));
        \\}
        \\
    , &.{ "rustc", "-g" }, "-o", "7");
    defer gpa.free(vars);
    try expectVars(vars, &.{
        "s = \"some text\"\n",
        "\n  x = 7\n  name = \"outer\"\n", // a String, by the toolchain's printer
        "o = Some(42)\n",
        "none = None\n",
        "r = Err(\"bad\")\n",
        "u = Named\n  a = 1\n  b = 2\n",
        "v = Vec(size=3)\n  [0] = 1\n",
        "A(3)",
        "Empty",
    });
}

test "debugging a build's program: the only one is used, several are asked for; remembered this session" {
    const gpa = testing.allocator;
    if (!sources.onPath(testing.io, "gdb") or !sources.onPath(testing.io, "cc")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.createDirPath(testing.io, ".git");
    try tmp.dir.createDirPath(testing.io, "out");
    try tmp.dir.createDirPath(testing.io, ".cache");
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.c", .data = "int main(void) {\n  return 3;\n}\n" });
    const src = try std.fs.path.join(gpa, &.{ dir, "t.c" });
    defer gpa.free(src);
    const S = struct {
        fn compile(d: []const u8, c: []const u8, out: []const u8) !void {
            const path = try std.fs.path.join(testing.allocator, &.{ d, out });
            defer testing.allocator.free(path);
            const r = try std.process.run(testing.allocator, testing.io, .{ .argv = &.{ "cc", "-g", "-o", path, c } });
            testing.allocator.free(r.stdout);
            testing.allocator.free(r.stderr);
        }
        fn untilEnd(e: *Editor) !void {
            for (0..2000) |_| {
                e.tick();
                if (e.dbg.session == null) return;
                testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
            }
            return error.Timeout;
        }
        /// The search for the build's program is over.
        fn untilFound(e: *Editor) !void {
            for (0..2000) |_| {
                e.tick();
                if (e.dbg.search == null) return;
                testing.io.sleep(.fromMilliseconds(1), .awake) catch {};
            }
            return error.Timeout;
        }
    };
    try S.compile(dir, src, "out/t");
    // In a hidden folder: a tool's, not looked in.
    try S.compile(dir, src, ".cache/tool");

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try gpa.dupe(u8, "/nonexistent/run-commands");
    try ed.openFile(src);
    const plan: Debugger.Plan = .{ .program = @constCast("zig-out/bin"), .newest_in = true, .args = &.{} };
    // The build made one program: it's debugged, no question.
    try debugging.launch(&ed, plan);
    try S.untilFound(&ed);
    try testing.expect(ed.dbg.session != null);
    try S.untilEnd(&ed);
    const shown = try ed.run.?.screenText(gpa);
    defer gpa.free(shown);
    try testing.expect(std.mem.indexOf(u8, shown, "exited 3") != null);
    {
        const programs = try debugging.pickedPrograms(&ed);
        defer {
            for (programs) |x| gpa.free(x);
            gpa.free(programs);
        }
        try testing.expect(std.mem.endsWith(u8, programs[0], "/out/t"));
    }

    // Two programs, none picked: the Debug picker lists only them.
    try S.compile(dir, src, "out/u");
    debugging.forgetProgram(&ed);
    try debugging.launch(&ed, plan);
    try S.untilFound(&ed);
    try testing.expect(ed.dbg.session == null);
    try testing.expect(ed.dbg.asking);
    try testing.expectEqualStrings("Debug which program?", ed.picker.?.title());
    settlePicker(&ed);
    try testing.expectEqual(2, ed.picker.?.rowCount());
    try testing.expectEqualStrings("out/u", ed.picker.?.itemAt(0).?.text); // newest
    try testing.expectEqualStrings("out/t", ed.picker.?.itemAt(1).?.text);
    // Enter: that one starts (nothing is built again) and is remembered.
    try ed.feed("<CR>");
    try testing.expect(ed.dbg.session != null and !ed.dbg.asking);
    try S.untilEnd(&ed);
    {
        const programs = try debugging.pickedPrograms(&ed);
        defer {
            for (programs) |x| gpa.free(x);
            gpa.free(programs);
        }
        try testing.expectEqual(1, programs.len);
        try testing.expect(std.mem.endsWith(u8, programs[0], "/out/u"));
    }

    // Where the build system puts programs comes first: one there is the
    // one, whatever else is lying about the project.
    try tmp.dir.createDirPath(testing.io, "zig-out/bin");
    try S.compile(dir, src, "zig-out/bin/app");
    debugging.forgetProgram(&ed);
    try debugging.launch(&ed, plan);
    try S.untilFound(&ed);
    try testing.expect(ed.dbg.session != null and !ed.dbg.asking);
    try S.untilEnd(&ed);
    const programs = try debugging.pickedPrograms(&ed);
    defer {
        for (programs) |x| gpa.free(x);
        gpa.free(programs);
    }
    try testing.expect(std.mem.endsWith(u8, programs[0], "/zig-out/bin/app"));
}

test "SPC d: C-j / C-k move the editor's cursor, the picker staying open; b there" {
    var ed = try testEditor("a\nb\nc\nd");
    defer ed.deinit();
    ed.run_memory_path = try testing.allocator.dupe(u8, "/nonexistent/run-commands");
    ed.buffer.path = try ed.gpa.dupe(u8, "/nonexistent/x.c");
    ed.next_picker_root = "/nonexistent";
    try ed.feed("<Space>d");
    try testing.expectEqual(.debug, ed.picker.?.kind);
    try ed.feed("<C-j><C-j>");
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("<C-k>");
    try testing.expectEqual(1, ed.cursorLine());
    try testing.expect(ed.picker != null);
    try ed.feed("b");
    try testing.expectEqual(1, ed.dbg.breakpoints.items[0].line);
}

test "debugging a runner command: the first time it comes up to change; remembered this session" {
    const gpa = testing.allocator;
    if (!sources.onPath(testing.io, "gdb") or !sources.onPath(testing.io, "cc")) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "t.c", .data = "int main(int n, char **v) {\n  return n;\n}\n" });
    const src = try std.fs.path.join(gpa, &.{ dir, "t.c" });
    defer gpa.free(src);
    const prog = try std.fs.path.join(gpa, &.{ dir, "t" });
    defer gpa.free(prog);
    const cc = try std.process.run(gpa, testing.io, .{ .argv = &.{ "cc", "-g", "-o", prog, src } });
    gpa.free(cc.stdout);
    gpa.free(cc.stderr);
    const S = struct {
        fn untilEnd(e: *Editor) !void {
            for (0..2000) |_| {
                e.tick();
                if (e.dbg.session == null) return;
                testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
            }
            return error.Timeout;
        }
    };

    var ed = try testEditor("");
    defer ed.deinit();
    ed.run_memory_path = try gpa.dupe(u8, "/nonexistent/run-commands");
    const cmd = try std.fmt.allocPrint(gpa, "{s} a", .{prog});
    defer gpa.free(cmd);
    // First time: the command editor, on the command, in normal mode.
    try debugging.debug(&ed, cmd);
    try testing.expect(ed.cmd_float != null and ed.dbg.session == null);
    try testing.expectEqual(Mode.normal, ed.mode);
    try expectText(&ed, cmd);
    try ed.feed("A b<Esc><CR>"); // vim: another argument, then Enter debugs
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expect(ed.dbg.session != null);
    try S.untilEnd(&ed);
    {
        const shown = try ed.run.?.screenText(gpa);
        defer gpa.free(shown);
        try testing.expect(std.mem.indexOf(u8, shown, "exited 3") != null); // t a b
    }
    // Again: no question, the changed command.
    try debugging.debug(&ed, cmd);
    try testing.expectEqual(null, ed.cmd_float);
    try testing.expect(ed.dbg.session != null);
    try testing.expect(std.mem.endsWith(u8, ed.dbg.command.?, " a b"));
    try S.untilEnd(&ed);
    // The Debug picker's row is that command; e changes it again.
    const row = (try debugging.commandRow(&ed)).?;
    defer gpa.free(row.cmd);
    defer gpa.free(row.from);
    try testing.expect(row.edited);
    try testing.expectEqualStrings(cmd, row.from);
    try debugging.editCommandRow(&ed);
    try testing.expect(ed.cmd_float != null);
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.cmd_float);
}

test "breakpoints follow their lines through edits and undo" {
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.c", .data = "one\ntwo\nthree\nfour\n" });
    const src = try std.fs.path.join(gpa, &.{ dir, "a.c" });
    defer gpa.free(src);
    var ed = try testEditor("");
    defer ed.deinit();
    ed.options.format_on_save = false;
    try ed.openFile(src);
    try ed.feed("3G"); // "three"
    try debugging.toggleBreakpoint(&ed);
    try ed.feed("4G");
    try debugging.toggleBreakpoint(&ed);
    const bps = &ed.dbg.breakpoints;
    try testing.expectEqual(2, bps.items[0].line);
    // A line added above (O on the breakpoint's own line too) moves it down.
    try ed.feed("ggOzero<Esc>");
    try testing.expectEqual(3, bps.items[0].line);
    try ed.feed("4GOnew<Esc>"); // above "three"
    try testing.expectEqual(4, bps.items[0].line);
    try testing.expectEqual(5, bps.items[1].line);
    // A line added below it doesn't.
    try ed.feed("5Gobelow<Esc>");
    try testing.expectEqual(4, bps.items[0].line);
    try testing.expectEqual(6, bps.items[1].line);
    // Lines deleted above move it up; undo puts it back.
    try ed.feed("ggdd");
    try testing.expectEqual(3, bps.items[0].line);
    try ed.feed("u");
    try testing.expectEqual(4, bps.items[0].line);
    // Its own line deleted with the next one's: both are one, on what's there now.
    try ed.feed("5Gdj"); // "three" and "below"
    try testing.expectEqual(4, bps.items[0].line);
    try ed.feed("dd"); // "four", the other breakpoint's line
    try testing.expectEqual(1, bps.items.len);
}
