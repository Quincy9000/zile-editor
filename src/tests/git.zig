//! Editor tests: git.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const project_ops = @import("../editor/project_ops.zig");
const row_model = @import("../editor/row_model.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const ghostEditor = support.ghostEditor;

test "ghost lines: j/k walk onto them, yy yanks, edits are refused, SPC g r restores" {
    var ed = try ghostEditor("a\nold b\nc\ngone\nd", "a\nnew b\nc\nd");
    defer ed.deinit();
    // Rows: a, new b, [old b], c, [gone], d
    try ed.feed("jj");
    try testing.expect(ed.ghost != null);
    try testing.expectEqualStrings("old b", row_model.ghostText(&ed, ed.ghost.?.line, ed.ghost.?.k));
    try ed.feed("yy");
    try testing.expectEqualStrings("old b\n", ed.registers.get(null).?.text);
    try ed.feed("x"); // read-only
    try expectText(&ed, "a\nnew b\nc\nd");
    try testing.expectEqual(.err, ed.message.kind);
    try ed.feed("jj");
    try testing.expectEqualStrings("gone", row_model.ghostText(&ed, ed.ghost.?.line, ed.ghost.?.k));
    try ed.feed("j");
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(3, ed.cursorLine()); // "d"

    // Restore the changed line, then the deleted one.
    try ed.feed("gg<cmd:git_next_hunk><cmd:git_restore_hunk>");
    try expectText(&ed, "a\nold b\nc\nd");
    try ed.feed("<cmd:git_next_hunk><cmd:git_restore_hunk>");
    try expectText(&ed, "a\nold b\nc\ngone\nd");
    try ed.feed("u");
    try expectText(&ed, "a\nold b\nc\nd");

    try ed.feed("<cmd:toggle_ghost_lines>"); // ghost lines off: j skips them
    try ed.feed("ggjj");
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(2, ed.cursorLine());
}

test "ghost lines: the mouse selects and copies them" {
    var ed = try ghostEditor("x\nold1\nold2\nold3\ny", "x\ny");
    defer ed.deinit();
    const Fake = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        fn get(_: Allocator) ?[]u8 {
            return null;
        }
        fn set(_: Allocator, data: []const u8) void {
            len = @min(data.len, buf.len);
            @memcpy(buf[0..len], data[0..len]);
        }
        fn copied() []const u8 {
            return buf[0..len];
        }
    };
    ed.registers.clipboard = .{ .get = Fake.get, .set = Fake.set };
    // Rows: x, [old1], [old2], [old3], y. Drag from old1 to old3.
    row_model.mousePress(&ed, 1, 0, 1);
    try testing.expect(ed.ghost != null);
    row_model.mouseDrag(&ed, 3, 2);
    try testing.expectEqual(Mode.visual, ed.mode);
    row_model.mouseDrag(&ed, 4, 0); // past the hunk: stays on its last old line
    row_model.mouseRelease(&ed);
    try testing.expectEqualStrings("old1\nold2\nold3\n", Fake.copied());
    // A double click: that one line.
    try ed.feed("<Esc>");
    row_model.mousePress(&ed, 2, 1, 2);
    row_model.mouseRelease(&ed);
    try testing.expectEqualStrings("old2\n", Fake.copied());
}

test "ghost lines: V selects several, y yanks them" {
    var ed = try ghostEditor("x\nold1\nold2\nold3\ny", "x\ny");
    defer ed.deinit();
    try ed.feed("jVjjy");
    try testing.expectEqualStrings("old1\nold2\nold3\n", ed.registers.get(null).?.text);
    try testing.expectEqual(.normal, ed.mode);
}

test "ghost lines: w / e / b move word by word through them" {
    var ed = try ghostEditor("a\nold one two\nc", "a\nnew\nc");
    defer ed.deinit();
    // Rows: a, new, [old one two], c
    try ed.feed("jw"); // from "new": into the ghost line's first word
    try testing.expect(ed.ghost != null);
    try testing.expectEqual(0, ed.ghost.?.col);
    try ed.feed("w");
    try testing.expectEqual(4, ed.ghost.?.col); // "one"
    try ed.feed("e");
    try testing.expectEqual(6, ed.ghost.?.col); // end of "one"
    try ed.feed("w");
    try testing.expectEqual(8, ed.ghost.?.col); // "two"
    try ed.feed("w"); // past the end: on to the text line "c"
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("b"); // back into the ghost line's last word
    try testing.expectEqual(8, ed.ghost.?.col);
    try ed.feed("bb");
    try testing.expectEqual(0, ed.ghost.?.col);
    try ed.feed("b"); // back out to "new"
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(1, ed.cursorLine());
    // With an operator, w stays on text.
    try ed.feed("ggdw");
    try expectText(&ed, "\nnew\nc");
}

test "ghost lines: /, n, N, f and snipe reach into them" {
    var ed = try ghostEditor("x = 1\nold needle here\ny = 2", "x = 1\ny = 2");
    defer ed.deinit();
    // Rows: "x = 1", [old needle here], "y = 2"
    try ed.feed("/needle<CR>");
    try testing.expect(ed.ghost != null);
    try testing.expectEqual(4, ed.ghost.?.col);
    try ed.feed("fh"); // f within the ghost line
    try testing.expectEqual(11, ed.ghost.?.col);
    try ed.feed("gg/=<CR>"); // the "=" later on the same text line
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(2, ed.cursorCol());
    try ed.feed("gg");
    try ed.feed("/e<CR>"); // first 'e' after line 0's start: the ghost line
    try testing.expect(ed.ghost != null);
    try ed.feed("n");
    try testing.expect(ed.ghost != null); // more e's in the ghost line
    try ed.feed("N");
    try testing.expect(ed.ghost != null);
    try ed.feed("<Esc>gg");
    try ed.feed("th"); // the only 'h' on screen is in the ghost line: jumps
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(11, ed.ghost.?.col);
    try ed.feed("<Esc>gg/zzz<Esc>"); // Esc returns to where we were
    try testing.expectEqual(null, ed.ghost);
    try testing.expectEqual(0, ed.cursorLine());
}

test "git: commit from the editor in a real repository" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const git = struct {
        fn run(d: []const u8, args: []const []const u8) ![]u8 {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(testing.allocator);
            try argv.appendSlice(testing.allocator, &.{ "git", "-C", d });
            try argv.appendSlice(testing.allocator, args);
            const r = try std.process.run(testing.allocator, testing.io, .{ .argv = argv.items });
            testing.allocator.free(r.stderr);
            return r.stdout;
        }
    }.run;
    for ([_][]const []const u8{
        &.{ "init", "-q", "-b", "main" },
        &.{ "config", "user.email", "test@example.com" },
        &.{ "config", "user.name", "Test" },
    }) |args| gpa.free(try git(dir, args));

    var ed = try testEditor("");
    defer ed.deinit();
    const file = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(file);
    try ed.openFile(file);
    try ed.feed("ihello<Esc>");

    try ed.feed("<cmd:git_commit>first commit<CR>");
    try testing.expect(!ed.buffer.modified); // saved before committing
    while (ed.git_job) |job| {
        if (job.done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    ed.tick();
    try testing.expectEqual(.info, ed.message.kind);
    const log = try git(dir, &.{ "log", "--format=%s" });
    defer gpa.free(log);
    try testing.expectEqualStrings("first commit\n", log);
}

test "ghost lines: o and O open a line in the text next to them" {
    // Rows: a, [gone 1], [gone 2], "  b", c
    var ed = try ghostEditor("a\ngone 1\ngone 2\n  b\nc", "a\n  b\nc");
    defer ed.deinit();
    try ed.feed("jj");
    try testing.expectEqualStrings("gone 2", row_model.ghostText(&ed, ed.ghost.?.line, ed.ghost.?.k));
    try ed.feed("ox<Esc>"); // before the line below them, with its indent
    try expectText(&ed, "a\n  x\n  b\nc");
    try testing.expectEqual(null, ed.ghost);
    try ed.feed("u");
    try expectText(&ed, "a\n  b\nc");
    try ed.feed("ggj");
    try testing.expect(ed.ghost != null);
    try ed.feed("Oy<Esc>"); // after the line above them, with its indent
    try expectText(&ed, "a\ny\n  b\nc");
    // Other edits are still refused there.
    try ed.feed("u");
    try ed.feed("ggjdd");
    try expectText(&ed, "a\n  b\nc");
}

test "git init: SPC g i makes the project a repository, and the open file becomes a git file" {
    const gpa = testing.allocator;
    const io = testing.io;
    // Not under the checkout the tests run in (that is a repository already,
    // and a project's git root is the outermost one found).
    const dir = try std.fmt.allocPrint(gpa, "/tmp/zile-test-gitinit-{d}", .{Io.Timestamp.now(io, .real).nanoseconds});
    defer gpa.free(dir);
    try Io.Dir.cwd().createDirPath(io, dir);
    defer Io.Dir.cwd().deleteTree(io, dir) catch {};
    const file = try std.fmt.allocPrint(gpa, "{s}/a.txt", .{dir});
    defer gpa.free(file);
    const build = try std.fmt.allocPrint(gpa, "{s}/build.zig", .{dir});
    defer gpa.free(build);
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = file, .data = "one\n" });
    try Io.Dir.cwd().writeFile(io, .{ .sub_path = build, .data = "" });

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(file);
    try testing.expectEqual(null, project_ops.gitRoot(&ed)); // a build.zig project, no repository yet
    try ed.feed("<cmd:git_init>");
    while (ed.git_job) |job| {
        if (job.done.load(.acquire)) break;
        std.Thread.yield() catch {};
    }
    ed.tick();
    const dot_git = try std.fmt.allocPrint(gpa, "{s}/.git", .{dir});
    defer gpa.free(dot_git);
    Io.Dir.cwd().access(io, dot_git, .{}) catch return error.NoRepository;
    try testing.expectEqualStrings(dir, project_ops.gitRoot(&ed).?);
    try testing.expect(ed.buffer.project.?.git);
    // Again: it says so instead of starting over.
    try ed.feed("<cmd:git_init>");
    try testing.expectEqual(null, ed.git_job);
    try testing.expect(std.mem.startsWith(u8, ed.message.text(), "already in a git repository"));
}
