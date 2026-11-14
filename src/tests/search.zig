//! Editor tests: search.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const claude_panel = @import("../editor/claude_panel.zig");
const prompts = @import("../editor/prompts.zig");
const project_ops = @import("../editor/project_ops.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const PromptKind = Editor.PromptKind;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;

test "replace across the project: from the grep picker, skipping a line and a file" {
    if (!@import("../picker/sources.zig").haveRg(testing.io)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.zig", .data = "const foo = 1;\nfn f() void {\n    _ = foo + foo;\n}\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "b.zig", .data = "// foo\nconst Foo = 2;\n" });
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "c.zig", .data = "foo\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    ed.next_picker_root = dir;
    try ed.openPicker(.grep, "foo");
    try ed.feed("<C-r>");
    try testing.expectEqual(PromptKind.replace, ed.search_prompt.?.kind);
    const r = ed.replace.?;
    r.wait();
    // Lowercase: any case (smart case), so `Foo` too. Lines: a 1, a 3, b 1, b 2, c 1.
    try testing.expectEqual(5, r.matches().len);
    try testing.expectEqual(6, r.counts().matches);
    // The query is what to find; the replacement is typed.
    try testing.expectEqual(.with, r.field);
    try ed.feed("bar");
    r.wait();
    // Skip `const Foo` (b.zig's second line), then all of c.zig.
    try ed.feed("<Down><Down><Down><C-x><C-f>");
    try testing.expectEqual(4, r.counts().matches);
    try ed.feed("<CR>");
    try testing.expectEqual(null, ed.replace);
    try testing.expectEqual(Mode.normal, ed.mode);

    const a_path = try std.fs.path.join(gpa, &.{ dir, "a.zig" });
    defer gpa.free(a_path);
    const b_path = try std.fs.path.join(gpa, &.{ dir, "b.zig" });
    defer gpa.free(b_path);
    const c_path = try std.fs.path.join(gpa, &.{ dir, "c.zig" });
    defer gpa.free(c_path);
    const a = claude_panel.bufferForPath(&ed, a_path).?;
    try testing.expectEqualStrings("const bar = 1;\nfn f() void {\n    _ = bar + bar;\n}", a.text.slice(0, a.text.len()));
    // Written (autosave, on leaving each file); c.zig untouched.
    const on_disk = try tmp.dir.readFileAlloc(testing.io, "a.zig", gpa, .limited(1024));
    defer gpa.free(on_disk);
    try testing.expectEqualStrings("const bar = 1;\nfn f() void {\n    _ = bar + bar;\n}\n", on_disk);
    const c_disk = try tmp.dir.readFileAlloc(testing.io, "c.zig", gpa, .limited(1024));
    defer gpa.free(c_disk);
    try testing.expectEqualStrings("foo\n", c_disk);
    const b = claude_panel.bufferForPath(&ed, b_path).?;
    try testing.expectEqualStrings("// bar\nconst Foo = 2;", b.text.slice(0, b.text.len()));
    try testing.expect(claude_panel.bufferForPath(&ed, c_path) == null);
    // One undo step per file.
    ed.switchTo(a);
    try ed.feed("u");
    try testing.expectEqualStrings("const foo = 1;\nfn f() void {\n    _ = foo + foo;\n}", a.text.slice(0, a.text.len()));
}

test "replace: Esc goes back to the grep picker with the search" {
    if (!@import("../picker/sources.zig").haveRg(testing.io)) return error.SkipZigTest;
    var ed = try testEditor("");
    defer ed.deinit();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    ed.next_picker_root = buf[0..try tmp.dir.realPath(testing.io, &buf)];
    try ed.openPicker(.grep, "needle");
    try ed.feed("<C-r>");
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.replace);
    try testing.expectEqual(null, ed.search_prompt);
    try testing.expectEqualStrings("needle", ed.picker.?.query.items());
}

test "replace: SPC c, a regex with a group, whole words, Tab between the fields" {
    if (!@import("../picker/sources.zig").haveRg(testing.io)) return error.SkipZigTest;
    const gpa = testing.allocator;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(testing.io, .{ .sub_path = "a.txt", .data = "get(a, b) + forget(c, d)\ncost $5 (x)\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(testing.io, &buf)];

    var ed = try testEditor("");
    defer ed.deinit();
    try project_ops.workIn(&ed, dir);
    try ed.feed("<Space>c");
    try testing.expectEqual(PromptKind.replace, ed.search_prompt.?.kind);
    const r = ed.replace.?;
    try testing.expectEqual(.find, r.field);

    // Plain text: `(x)` and `$5` mean themselves, on both sides.
    try ed.feed("(x)<CR>");
    try testing.expectEqual(.with, r.field);
    try ed.feed("$1");
    r.wait();
    try testing.expectEqual(1, r.counts().matches);
    try testing.expectEqualStrings("$1", r.matches()[0].subs[0].with);

    // A regex, whole words: `get(a, b)` but not `forget(c, d)`; the groups swapped.
    try ed.feed("<C-u><Tab><C-u><C-r><C-b>get\\((\\w+), (\\w+)\\)<Tab>put($2, $1)");
    try testing.expect(r.options.regex and r.options.word);
    r.wait();
    try testing.expectEqual(1, r.counts().matches);
    try testing.expectEqualStrings("put(b, a)", r.matches()[0].subs[0].with);
    // Half a regex: rg says what is wrong, and nothing is replaced.
    try ed.feed("<Tab>(");
    r.wait();
    try testing.expectEqual(0, r.counts().matches);
    try testing.expect(r.complaintOf() != null);
    try ed.feed("<BS><Tab><CR>");
    try testing.expectEqual(null, ed.replace);
    const path = try std.fs.path.join(gpa, &.{ dir, "a.txt" });
    defer gpa.free(path);
    const a = claude_panel.bufferForPath(&ed, path).?;
    try testing.expectEqualStrings("put(b, a) + forget(c, d)\ncost $5 (x)", a.text.slice(0, a.text.len()));
    // The options are as they were left, the next time.
    try ed.feed("<Space>c");
    try testing.expect(ed.replace.?.options.regex);
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.replace);
    try testing.expectEqual(null, ed.picker);
}

test ". and , continue a snipe too" {
    var ed = try testEditor("foo bar baz\nqux bar");
    defer ed.deinit();
    try ed.feed("tbar<CR>");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed(".");
    try testing.expectEqual(16, ed.view.cursor); // the next "bar"
    try ed.feed(",");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("x.");
    try expectText(&ed, "foo r baz\nqux bar"); // a change: . repeats it
}

test "search: incremental /, n, N, *, Esc restores, d/ as motion" {
    var ed = try testEditor("alpha beta\ngamma beta\nbeta alpha");
    defer ed.deinit();
    try ed.feed("/bet");
    try testing.expectEqual(.search, ed.mode);
    try testing.expectEqual(6, ed.view.cursor); // jumped while typing
    try ed.feed("<Esc>");
    try testing.expectEqual(0, ed.view.cursor); // restored
    try ed.feed("/beta<CR>");
    try testing.expectEqual(6, ed.view.cursor);
    try ed.feed("n");
    try testing.expectEqual(17, ed.view.cursor);
    try ed.feed("nn"); // wraps to the first match
    try testing.expectEqual(6, ed.view.cursor);
    try ed.feed("N");
    try testing.expectEqual(22, ed.view.cursor);
    try ed.feed("?gam<CR>");
    try testing.expectEqual(11, ed.view.cursor);
    try ed.feed("gg*"); // word under cursor: alpha
    try testing.expectEqual(27, ed.view.cursor);
    try ed.feed("ggdn"); // deletes up to the next "alpha"
    try expectText(&ed, "alpha");
}

test "snipe: jumps when one match is left, RET takes the first, n continues" {
    var ed = try testEditor("foo bar baz\nqux bar");
    defer ed.deinit();
    try ed.feed("tba");
    try testing.expectEqual(.search, ed.mode); // three matches: keep typing
    try ed.feed("z");
    try testing.expectEqual(.normal, ed.mode); // only "baz" left: jumped
    try testing.expectEqual(8, ed.view.cursor);

    try ed.feed("ggtbar<CR>");
    try testing.expectEqual(4, ed.view.cursor);
    try ed.feed("n");
    try testing.expectEqual(16, ed.view.cursor);

    try ed.feed("ggtq<Esc>"); // only one 'q': jumps on the first key
    try testing.expectEqual(12, ed.view.cursor);
    try ed.feed("gg");
    try ed.feed("tw<Esc>"); // no 'w' anywhere: Esc puts the cursor back
    try testing.expectEqual(0, ed.view.cursor);
    try testing.expectEqual(.normal, ed.mode);
}

test "snipe goes to the nearest match, before the cursor or after" {
    var ed = try testEditor("bar one\ntwo\nthree\nx bar bar\nfour\nfive bar");
    defer ed.deinit();
    try ed.feed("jjjjtbar"); // on "four": the line above is nearest
    try testing.expectEqual(.search, ed.mode);
    try testing.expectEqual(24, ed.view.cursor); // shown while typing
    try ed.feed("<CR>");
    try testing.expectEqual(24, ed.view.cursor); // the nearer of the line's two
    try ed.feed("n");
    try testing.expectEqual(38, ed.view.cursor); // n still goes on down
    try ed.feed("ggjj/bar<CR>"); // `/` is vim's: the next one down
    try testing.expectEqual(20, ed.view.cursor);
}

test "snipe: keys beside the matches jump to them, nearest first" {
    var ed = try testEditor("foo bar baz\nqux bar");
    defer ed.deinit();
    try ed.feed("tba");
    // `r` and `z` could be the next letter typed, so they are no labels.
    const labels = prompts.snipeLabels(&ed);
    try testing.expectEqual(3, labels.len);
    try testing.expectEqual(4, labels[0].pos);
    try testing.expectEqual('g', labels[0].key);
    try testing.expectEqual('h', labels[1].key);
    try ed.feed("f"); // the third nearest: the one on the next line
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(16, ed.view.cursor);
    try testing.expectEqual(0, prompts.snipeLabels(&ed).len);
    try ed.feed("N"); // n / N go on from there
    try testing.expectEqual(8, ed.view.cursor);
}

test "snipe and / work after an operator" {
    var ed = try testEditor("alpha beta gamma");
    defer ed.deinit();
    // (`ds`/`cs`/`ys` are surround; other operators take the snipe motion.)
    try ed.feed("gUsg");
    try expectText(&ed, "ALPHA BETA gamma");
    try ed.feed("u0d/mm<CR>");
    try expectText(&ed, "mma");
}
