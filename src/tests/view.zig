//! Editor tests: view.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Folds = @import("../core/Folds.zig");
const notifications = @import("../editor/notifications.zig");
const smooth_scrolling = @import("../editor/smooth_scrolling.zig");
const row_model = @import("../editor/row_model.zig");
const folding = @import("../editor/folding.zig");
const code_motion = @import("../editor/code_motion.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const Seg = Editor.Seg;
const max_segments = Editor.max_segments;
const indent_guide_delay_ms = Editor.indent_guide_delay_ms;
const indent_guide_step_ms = Editor.indent_guide_step_ms;
const support = @import("support.zig");
const testEditor = support.testEditor;
const testEditorAs = support.testEditorAs;
const expectText = support.expectText;

test "scrolling keeps the cursor in view" {
    var ed = try testEditor("0\n1\n2\n3\n4\n5\n6\n7\n8\n9\n10\n11\n12\n13\n14\n15\n16\n17\n18\n19");
    defer ed.deinit();
    ed.setViewSize(10, 80);
    try ed.feed("15j");
    try testing.expectEqual(15, ed.cursorLine());
    try testing.expect(ed.view.top <= 15 and 15 < ed.view.top + 10);
    ed.scrollLines(-100);
    try testing.expectEqual(0, ed.view.top);
    try testing.expect(ed.cursorLine() < 10);
}

test "mouse: drag selects and copies on release; double-click a word, triple a line" {
    var ed = try testEditor("hello world\nsecond line");
    defer ed.deinit();
    ed.setViewSize(10, 40);
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
    row_model.mousePress(&ed, 0, 0, 1);
    row_model.mouseDrag(&ed, 0, 4);
    try testing.expectEqual(Mode.visual, ed.mode);
    row_model.mouseRelease(&ed);
    try testing.expectEqualStrings("hello", Fake.copied());
    try testing.expectEqual(Mode.visual, ed.mode); // still selected, as in nvim
    row_model.mousePress(&ed, 0, 7, 2);
    row_model.mouseRelease(&ed);
    try testing.expectEqualStrings("world", Fake.copied());
    row_model.mousePress(&ed, 1, 2, 3);
    row_model.mouseRelease(&ed);
    try testing.expectEqualStrings("second line", std.mem.trimEnd(u8, Fake.copied(), "\n"));
    row_model.mousePress(&ed, 0, 3, 1); // a plain click: no selection, nothing copied
    row_model.mouseRelease(&ed);
    try testing.expectEqual(Mode.normal, ed.mode);
    try testing.expectEqual(3, ed.view.cursor);
}

test "wrap: long lines break at words, keep their indent; j/k go by screen row" {
    var ed = try testEditor("  alpha beta gamma delta epsilon\nshort");
    defer ed.deinit();
    ed.setViewSize(10, 16);
    var buf: [max_segments]Seg = undefined;
    const segs = row_model.segments(&ed, 0, &buf);
    try testing.expectEqual(3, segs.len);
    try testing.expectEqual(13, segs[1].start); // after "  alpha beta "
    try testing.expectEqual(2, segs[1].indent); // under the indentation
    try testing.expectEqual(3, row_model.subRows(&ed, 0));
    try testing.expectEqual(1, row_model.subRows(&ed, 1));
    try ed.feed("j"); // a screen row down: still line 0
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(1, row_model.cursorRow(&ed).sub);
    try ed.feed("jj");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("k");
    try testing.expectEqual(2, row_model.cursorRow(&ed).sub);
    try ed.feed("gg2j"); // a count: whole lines
    try testing.expectEqual(1, ed.cursorLine());
    // A click on a later row lands in that piece.
    row_model.clickCell(&ed, 1, 4);
    try testing.expectEqual(0, ed.cursorLine());
    try testing.expectEqual(15, ed.view.cursor); // col 13 + (4 - indent 2)
    ed.options.wrap = false;
    try testing.expectEqual(1, row_model.segments(&ed, 0, &buf).len);
}

test "sticky context: the headers of the scopes the top line is in" {
    var ed = try testEditorAs("a.zig", "fn f() void {\n    if (x) {\n        a();\n        b();\n        c();\n        d();\n    }\n}");
    defer ed.deinit();
    var buf: [3]usize = undefined;
    // At the top of the file, nothing.
    try testing.expectEqual(0, code_motion.contextLines(&ed, &buf).len);
    ed.view.top = 3;
    ed.view.cursor = ed.text().lineStart(5);
    try testing.expectEqualSlices(usize, &.{ 0, 1 }, code_motion.contextLines(&ed, &buf));
    // Not over the cursor: with it on the top line, none.
    ed.view.cursor = ed.text().lineStart(3);
    try testing.expectEqual(0, code_motion.contextLines(&ed, &buf).len);
    ed.options.sticky_context = false;
    ed.view.cursor = ed.text().lineStart(5);
    try testing.expectEqual(0, code_motion.contextLines(&ed, &buf).len);
}

test "zz / zt / zb place the cursor line in the view" {
    var lines: std.ArrayList(u8) = .empty;
    defer lines.deinit(testing.allocator);
    for (0..100) |i| try lines.print(testing.allocator, "line {d}\n", .{i});
    var ed = try testEditor(lines.items[0 .. lines.items.len - 1]);
    defer ed.deinit();
    ed.setViewSize(21, 80);
    try ed.feed("50G");
    try ed.feed("zt");
    try testing.expectEqual(49 - ed.effectiveScrolloff(), ed.view.top);
    try ed.feed("zb");
    try testing.expectEqual(49 + ed.effectiveScrolloff() + 1 - 21, ed.view.top);
    try ed.feed("zz");
    try testing.expectEqual(49 - 10, ed.view.top);
    try ed.feed("80zz"); // count: center line 80
    try testing.expectEqual(79, ed.cursorLine());
    try testing.expectEqual(79 - 10, ed.view.top);
    try ed.feed("gg");
    try ed.feed("zz"); // can't scroll above the first line
    try testing.expectEqual(0, ed.view.top);
}

test "folds: zc/zo/za, j/k skip closed folds, dd deletes a fold, zf makes one" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-folds.zig");
    try ed.insertAt(0, "fn a() void {\n    x();\n    y();\n}\nfn b() void {}\nconst z = 1;");
    try ed.buffer.history.commit(ed.gpa);

    try ed.feed("jzc"); // inside a's body: closes the function (lines 0-3)
    try testing.expectEqual(Folds.Lines{ .first = 0, .last = 3 }, folding.foldAt(&ed, 1).?);
    try testing.expectEqual(0, ed.cursorLine()); // moved to the fold's first line
    try ed.feed("j");
    try testing.expectEqual(4, ed.cursorLine()); // skipped the hidden lines
    try ed.feed("k");
    try testing.expectEqual(0, ed.cursorLine());
    try ed.feed("za");
    try testing.expectEqual(null, folding.foldAt(&ed, 1));
    try ed.feed("za");
    try ed.feed("dd"); // deletes the whole closed fold
    try expectText(&ed, "fn b() void {}\nconst z = 1;");
    try ed.feed("u");
    try ed.feed("zR");
    try testing.expectEqual(null, folding.foldAt(&ed, 1));

    try ed.feed("Gzfk"); // manual fold over the last two lines
    try testing.expectEqual(Folds.Lines{ .first = 4, .last = 5 }, folding.foldAt(&ed, 5).?);
    try ed.feed("/z = <CR>"); // a search into a fold opens it
    try testing.expectEqual(null, folding.foldAt(&ed, 5));
    try testing.expectEqual(5, ed.cursorLine());
}

test "zc on a struct's first line folds the struct" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile("edit-test-struct-fold.zig");
    try ed.insertAt(0, "const Foo = struct {\n    a: u8,\n    fn f() void {\n        g();\n    }\n};\nconst x = 1;");
    try ed.buffer.history.commit(ed.gpa);
    try ed.feed("zc");
    try testing.expectEqual(Folds.Lines{ .first = 0, .last = 5 }, folding.foldAt(&ed, 1).?);
    try ed.feed("zo3Gzc"); // inside the method: its fold, not the struct's
    try testing.expectEqual(Folds.Lines{ .first = 2, .last = 4 }, folding.foldAt(&ed, 3).?);
    try ed.feed("zc"); // again: the next level out, the struct
    try testing.expectEqual(Folds.Lines{ .first = 0, .last = 5 }, folding.foldAt(&ed, 3).?);
}

test "smooth scrolling: the offset follows a scroll and glides to zero" {
    var buf: [400]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 2 == 0) 'x' else '\n';
    var ed = try testEditor(&buf);
    defer ed.deinit();
    ed.setViewSize(10, 40);
    smooth_scrolling.animate(&ed, 0.016); // sees the buffer
    try ed.feed("<C-d>");
    smooth_scrolling.animate(&ed, 0.016);
    const first = ed.view.scroll_offset;
    try testing.expect(first > 3 and first < 5); // already moving
    try testing.expect(notifications.wantsFrames(&ed));
    // More scrolling while it glides adds on; every frame still moves.
    try ed.feed("<C-e>");
    smooth_scrolling.animate(&ed, 0.016);
    const second = ed.view.scroll_offset;
    try testing.expect(second < first + 1 and second > first * 0.7);
    smooth_scrolling.animate(&ed, 0.016);
    try testing.expect(ed.view.scroll_offset < second);
    for (0..80) |_| smooth_scrolling.animate(&ed, 0.016);
    try testing.expectEqual(0, ed.view.scroll_offset);
    // Another buffer in the window is not a scroll.
    try ed.feed("<cmd:new_buffer>");
    smooth_scrolling.animate(&ed, 0.016);
    try testing.expectEqual(0, ed.view.scroll_offset);
}

test "wheel: fractions of a line show at once, settle on a whole line, stop at the ends" {
    var buf: [400]u8 = undefined;
    for (&buf, 0..) |*b, i| b.* = if (i % 2 == 0) 'x' else '\n';
    var ed = try testEditor(&buf);
    defer ed.deinit();
    ed.setViewSize(10, 40);
    smooth_scrolling.animate(&ed, 0.016);
    // At the top, scrolling up does nothing.
    smooth_scrolling.scrollSmooth(&ed, -0.4);
    try testing.expectEqual(0, ed.view.drawOffset());
    // Small steps add up; the text doesn't jump at the moment of input.
    for (0..7) |_| {
        const before = ed.view.drawOffset() - @as(f32, @floatFromInt(ed.view.top));
        smooth_scrolling.scrollSmooth(&ed, 0.4);
        smooth_scrolling.animate(&ed, 0); // sees `top` move, no time passes
        const after = ed.view.drawOffset() - @as(f32, @floatFromInt(ed.view.top));
        try testing.expectApproxEqAbs(before, after, 0.001);
    }
    try testing.expectEqual(2, ed.view.top); // 2.8 rows so far
    try testing.expectApproxEqAbs(0.8, ed.view.scroll_frac, 0.001);
    // The wheel rests: the nearer line (one more), then everything settles.
    for (0..120) |_| smooth_scrolling.animate(&ed, 0.016);
    try testing.expectEqual(3, ed.view.top);
    try testing.expectEqual(0, ed.view.drawOffset());
    try testing.expect(!notifications.wantsFrames(&ed));
}

test "indent guide: appears once the cursor settles in a scope, hides at once on leaving it" {
    var ed = try testEditor("fn a() {\n    x;\n    y;\n}\nfn b() {\n    z;\n}");
    defer ed.deinit();
    try ed.feed("j");
    ed.tick();
    try testing.expectEqual(null, ed.indent_guide); // not yet
    try testing.expect(notifications.wantsFrames(&ed)); // but a frame is due
    ed.now = notifications.timeAfter(&ed, indent_guide_delay_ms + 20);
    notifications.tickIndentGuide(&ed);
    try testing.expectEqual(1, ed.indent_guide.?.scope.first);
    // It grows out from the cursor's line, a row every step.
    try testing.expectEqual(1, ed.indent_guide.?.origin);
    try testing.expectEqual(0, ed.indent_guide.?.reach(ed.now));
    try testing.expect(notifications.wantsFrames(&ed)); // still growing
    ed.now.nanoseconds += 10 * indent_guide_step_ms * std.time.ns_per_ms;
    try testing.expectEqual(10, ed.indent_guide.?.reach(ed.now));
    try testing.expect(!notifications.wantsFrames(&ed)); // done: the block is two rows
    // Within the block it stays; typing a line in it keeps it.
    try ed.feed("j");
    notifications.tickIndentGuide(&ed);
    try testing.expectEqual(1, ed.indent_guide.?.scope.first);
    try ed.feed("ow;<Esc>");
    notifications.tickIndentGuide(&ed);
    try testing.expectEqual(3, ed.indent_guide.?.scope.last);
    // On into the next block: gone straight away, back after the delay.
    try ed.feed("3j");
    notifications.tickIndentGuide(&ed);
    try testing.expectEqual(null, ed.indent_guide);
    ed.now = notifications.timeAfter(&ed, 10 * indent_guide_delay_ms); // well past the wait
    notifications.tickIndentGuide(&ed);
    try testing.expectEqual(6, ed.indent_guide.?.scope.first);
}
