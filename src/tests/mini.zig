//! Editor tests: mini.

const std = @import("std");
const testing = std.testing;
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const expectCursor = support.expectCursor;
const settlePicker = support.settlePicker;

test "mini.move: <A-j>/<A-k>/<A-h>/<A-l>" {
    var ed = try testEditor("one\ntwo\nthree");
    defer ed.deinit();
    try ed.feed("<A-j>");
    try expectText(&ed, "two\none\nthree");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("<A-j><A-j>"); // second is a no-op at the end
    try expectText(&ed, "two\nthree\none");
    try ed.feed("<A-k>");
    try expectText(&ed, "two\none\nthree");
    try ed.feed("<A-l>");
    try expectText(&ed, "two\n    one\nthree");
    try ed.feed("<A-h>");
    try expectText(&ed, "two\none\nthree");
    // Charwise selection moves along the line; linewise selection moves lines.
    try ed.feed("ggvl<A-l>");
    try expectText(&ed, "otw\none\nthree");
    try ed.feed("<A-h><Esc>Vj<A-j>");
    try expectText(&ed, "three\ntwo\none");
    try ed.feed("<Esc>u");
    try expectText(&ed, "two\none\nthree");
}

test "mini.comment: gcc, gc{motion}, visual gc, the gc object" {
    var ed = try testEditor("one\n  two\n\n  three");
    defer ed.deinit();
    try ed.feed("gcc");
    try expectText(&ed, "# one\n  two\n\n  three");
    try ed.feed("gcc");
    try expectText(&ed, "one\n  two\n\n  three");
    // The prefix goes at the block's smallest indentation; blank lines stay.
    try ed.feed("jgcG");
    try expectText(&ed, "one\n  # two\n\n  # three");
    try ed.feed("dgc"); // the comment block at the cursor (one line)
    try expectText(&ed, "one\n\n  # three");
    try ed.feed("GVgc");
    try expectText(&ed, "one\n\n  three");
    try ed.feed("ggVGgc");
    try expectText(&ed, "# one\n\n#   three");
    try ed.feed("gcgc"); // uncomments only the block under the cursor
    try expectText(&ed, "one\n\n#   three");
}

test "mini.operators: gr replaces, gx exchanges, gs sorts, gm duplicates" {
    var ed = try testEditor("foo bar\nc, a, b\nz\ny");
    defer ed.deinit();
    try ed.feed("yiwwgriw");
    try expectText(&ed, "foo foo\nc, a, b\nz\ny");
    try testing.expectEqualStrings("foo", ed.registers.get(null).?.text); // kept
    try ed.feed("u0gxiwwgxiw");
    try expectText(&ed, "bar foo\nc, a, b\nz\ny");
    try ed.feed("j0gs$");
    try expectText(&ed, "bar foo\na, b, c\nz\ny");
    try ed.feed("jgsj");
    try expectText(&ed, "bar foo\na, b, c\ny\nz");
    try ed.feed("gmm");
    try expectText(&ed, "bar foo\na, b, c\ny\ny\nz");
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("grr");
    try expectText(&ed, "bar foo\na, b, c\ny\nfoo\nz");
    try ed.feed("gmiw");
    try expectText(&ed, "bar foo\na, b, c\ny\nfoofoo\nz");
    // A mark is dropped by <Esc>; `dr` is not `dd`.
    try ed.feed("gxiw<Esc>ggdr");
    try testing.expect(ed.exchange_mark == null);
    try expectText(&ed, "bar foo\na, b, c\ny\nfoofoo\nz");
}

test "mini.align: ga{motion}{char}; mini.splitjoin: gS" {
    var ed = try testEditor("a = 1\nbbb = 2\ncc += 3");
    defer ed.deinit();
    try ed.feed("gaip=");
    try expectText(&ed, "a   = 1\nbbb = 2\ncc  += 3");
    try ed.feed("u");
    try expectText(&ed, "a = 1\nbbb = 2\ncc += 3");

    var ed2 = try testEditor("x: 1,\nlonger: 2,");
    defer ed2.deinit();
    try ed2.feed("Vjga:");
    try expectText(&ed2, "x:      1,\nlonger: 2,");

    var ed3 = try testEditor("  f(a, g(b, c), d);");
    defer ed3.deinit();
    try ed3.feed("gS");
    try expectText(&ed3, "  f(\n      a,\n      g(b, c),\n      d\n  );");
    try ed3.feed("gS");
    try expectText(&ed3, "  f(a, g(b, c), d);");
}

test "mini.ai: next / previous objects, the indent scope, g[ and g]" {
    var ed = try testEditor("f(a) + g(b) + h(c)");
    defer ed.deinit();
    try ed.feed("fgdin(");
    try expectText(&ed, "f(a) + g() + h(c)");
    try ed.feed("diN(");
    try expectText(&ed, "f() + g() + h(c)");
    try ed.feed("$g[(");
    try expectCursor(&ed, 0, 13);
    try ed.feed("0can\"x<Esc>"); // no quotes anywhere: nothing happens, no insert mode
    try testing.expectEqual(Mode.normal, ed.mode);

    var ed2 = try testEditor("if x:\n    a\n\n    b\nend\n  \"s\" 'q' \"t\"");
    defer ed2.deinit();
    try ed2.feed("j]i");
    try testing.expectEqual(4, ed2.cursorLine());
    try ed2.feed("k[i");
    try testing.expectEqual(0, ed2.cursorLine());
    try ed2.feed("jdii");
    try expectText(&ed2, "if x:\nend\n  \"s\" 'q' \"t\"");
    try ed2.feed("Gfqcinqz<Esc>"); // from inside 'q': the next quoted string
    try expectText(&ed2, "if x:\nend\n  \"s\" 'q' \"z\"");
}

test "mini.jump: f and t reach across lines; ; repeats" {
    var ed = try testEditor("abc\ndef x\nyy x");
    defer ed.deinit();
    try ed.feed("fx");
    try expectCursor(&ed, 1, 4);
    try testing.expect(ed.find_shown);
    try ed.feed(".");
    try expectCursor(&ed, 2, 3);
    try ed.feed("Fa");
    try expectCursor(&ed, 0, 0);
    try ed.feed("l");
    try testing.expect(!ed.find_shown);
    try ed.feed("dtx");
    try expectText(&ed, "ax\nyy x");
}

test "mini.bracketed: conflict markers and comment blocks; trailing whitespace" {
    var ed = try testEditor("x  \n<<<<<<< HEAD\na\t\n=======\nb\n>>>>>>> other\n# note\ny");
    defer ed.deinit();
    try ed.feed("]x");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("]x]x");
    try testing.expectEqual(5, ed.cursorLine());
    try ed.feed("[x");
    try testing.expectEqual(3, ed.cursorLine());
    try ed.feed("]c");
    try testing.expectEqual(6, ed.cursorLine());
    try ed.feed("<cmd:trim_trailing_whitespace>");
    try expectText(&ed, "x\n<<<<<<< HEAD\na\n=======\nb\n>>>>>>> other\n# note\ny");
    try ed.feed("u");
    try testing.expect(std.mem.startsWith(u8, ed.text().slice(0, 3), "x  "));
}

test "todo tags: SPC l t writes a comment tag and leaves you typing; Ctrl-t from insert mode" {
    var ed = try testEditor("x = 1\n    ");
    defer ed.deinit();
    try ed.feed("<cmd:todo_tag>");
    settlePicker(&ed);
    try ed.feed("j<CR>"); // FIXME
    try testing.expectEqual(Mode.insert, ed.mode);
    try ed.feed("later<Esc>");
    try expectText(&ed, "x = 1 # FIXME: later\n    ");
    try ed.feed("jA<C-t>");
    settlePicker(&ed);
    try ed.feed("<CR>now<Esc>"); // TODO, on the blank line, keeping its indent
    try expectText(&ed, "x = 1 # FIXME: later\n    # TODO: now");
    try ed.feed("u");
    try expectText(&ed, "x = 1 # FIXME: later\n    ");
}
