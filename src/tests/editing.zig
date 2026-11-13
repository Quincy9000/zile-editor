//! Editor tests: editing.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const indenting = @import("../editor/indenting.zig");
const Editor = @import("../Editor.zig");
const Mode = Editor.Mode;
const support = @import("support.zig");
const testEditor = support.testEditor;
const testEditorAs = support.testEditorAs;
const expectText = support.expectText;
const expectCursor = support.expectCursor;

test "insert mode typing and escape" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ihello<Esc>");
    try expectText(&ed, "hello");
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(4, ed.view.cursor); // Esc steps back onto 'o'
}

test "open line keeps indentation" {
    var ed = try testEditor("    foo");
    defer ed.deinit();
    try ed.feed("obar<Esc>");
    try expectText(&ed, "    foo\n    bar");
    try ed.feed("Obaz<Esc>");
    try expectText(&ed, "    foo\n    baz\n    bar");
}

test "x, X and dd with counts" {
    var ed = try testEditor("abcdef\nline2\nline3\nline4");
    defer ed.deinit();
    try ed.feed("2x");
    try expectText(&ed, "cdef\nline2\nline3\nline4");
    try ed.feed("$X");
    try expectText(&ed, "cdf\nline2\nline3\nline4");
    try ed.feed("j2dd");
    try expectText(&ed, "cdf\nline4");
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("dd");
    try expectText(&ed, "cdf");
    try ed.feed("dd");
    try expectText(&ed, "");
}

test "insert mode backspace joins lines and <C-w> deletes a word" {
    var ed = try testEditor("foo\nbar baz");
    defer ed.deinit();
    try ed.feed("jI<BS><Esc>");
    try expectText(&ed, "foobar baz");
    try ed.feed("A<C-w><Esc>");
    try expectText(&ed, "foobar ");
}

test "counts multiply and dd/yy/p are linewise" {
    var ed = try testEditor("a b c d e f g\nl2\nl3\nl4");
    defer ed.deinit();
    try ed.feed("2d2w");
    try expectText(&ed, "e f g\nl2\nl3\nl4");
    try ed.feed("j2yyGp");
    try expectText(&ed, "e f g\nl2\nl3\nl4\nl2\nl3");
    // On the last pasted line.
    try expectCursor(&ed, 5, 0);
    try ed.feed("ggddP");
    try expectText(&ed, "e f g\nl2\nl3\nl4\nl2\nl3");
    try ed.feed("3dd");
    try expectText(&ed, "l4\nl2\nl3");
}

test "pastes in a row stack in order: the cursor ends on the last pasted line" {
    var ed = try testEditor("a\nb\nend");
    defer ed.deinit();
    try ed.feed("2yyjpp");
    try expectText(&ed, "a\nb\na\nb\na\nb\nend");
    try expectCursor(&ed, 5, 0);
    try ed.feed("u");
    try expectText(&ed, "a\nb\na\nb\nend");
    // P with a count: on the first pasted line (so another P goes above).
    try ed.feed("G2P");
    try expectText(&ed, "a\nb\na\nb\na\nb\na\nb\nend");
    try expectCursor(&ed, 4, 0);
}

test "P in a row stacks in order too: the cursor ends on the first pasted line" {
    var ed = try testEditor("a\nb\nend");
    defer ed.deinit();
    try ed.feed("2yyGPP");
    try expectText(&ed, "a\nb\na\nb\na\nb\nend");
    try expectCursor(&ed, 2, 0);
    // Characters: `P` `P` gives abab, not aabb.
    var ed2 = try testEditor("abX");
    defer ed2.deinit();
    try ed2.feed("y2l$PP");
    try expectText(&ed2, "abababX");
    try expectCursor(&ed2, 0, 2);
}

test "yanking leaves the cursor where it is" {
    var ed = try testEditor("one\n    foo(bar, baz)\nthree\n\nfour");
    defer ed.deinit();
    try ed.feed("j$h"); // on the last `z`
    try ed.feed("yil");
    try expectCursor(&ed, 1, 15);
    try ed.feed("yib");
    try expectCursor(&ed, 1, 15);
    try ed.feed("yip");
    try expectCursor(&ed, 1, 15);
    try ed.feed("yb");
    try expectCursor(&ed, 1, 15);
    // Visual: back to where `v` was pressed, even from the other end.
    try ed.feed("Vjy");
    try expectCursor(&ed, 1, 15);
    try ed.feed("vipy");
    try expectCursor(&ed, 1, 15);
    try testing.expectEqualStrings("one\n    foo(bar, baz)\nthree\n", ed.registers.get(null).?.text);
}

test "gp / gP paste a yanked line inline, inside brackets" {
    var ed = try testEditor("    a + b\nfoo();\nbar();");
    defer ed.deinit();
    try ed.feed("yyjf(gp");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar();");
    // On the last pasted character, like p.
    try expectCursor(&ed, 1, 8);
    try ed.feed("jf)gP");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar(a + b);");
    // p still puts the line below.
    try ed.feed("p");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar(a + b);\n    a + b");
    // Charwise text goes in unchanged.
    try ed.feed("ggyiwG$gp");
    try expectText(&ed, "    a + b\nfoo(a + b);\nbar(a + b);\n    a + ba");
}

test "change: cw, ciw, cc, C keep vim's semantics" {
    var ed = try testEditor("    foo bar baz");
    defer ed.deinit();
    try ed.feed("wcwX<Esc>"); // cw stops at the end of the word
    try expectText(&ed, "    X bar baz");
    try ed.feed("wciwY<Esc>");
    try expectText(&ed, "    X Y baz");
    try ed.feed("ccnew<Esc>"); // cc keeps the indent
    try expectText(&ed, "    new");
    try ed.feed("0wCz<Esc>");
    try expectText(&ed, "    z");
}

test "dot repeats changes, including inserts" {
    var ed = try testEditor("a1 a2 a3 a4");
    defer ed.deinit();
    try ed.feed("dw..");
    try expectText(&ed, "a4");
    try ed.feed("A!<Esc>.");
    try expectText(&ed, "a4!!");

    var ed2 = try testEditor("x\nx\nx");
    defer ed2.deinit();
    try ed2.feed("ciwyes<Esc>j.j.");
    try expectText(&ed2, "yes\nyes\nyes");
}

test "undo groups whole commands; redo; [+] clears at the saved state" {
    var ed = try testEditor("abc");
    defer ed.deinit();
    try ed.feed("Adef<Esc>");
    try testing.expect(ed.buffer.modified);
    try ed.feed("x");
    try expectText(&ed, "abcde");
    try ed.feed("u");
    try expectText(&ed, "abcdef");
    try ed.feed("u");
    try expectText(&ed, "abc");
    try testing.expect(!ed.buffer.modified);
    try ed.feed("<C-r><C-r>");
    try expectText(&ed, "abcde");
}

test "visual mode operators" {
    var ed = try testEditor("hello world\nsecond line\nthird");
    defer ed.deinit();
    try ed.feed("wvlld");
    try expectText(&ed, "hello ld\nsecond line\nthird");
    try ed.feed("jVy");
    try ed.feed("Gp");
    try expectText(&ed, "hello ld\nsecond line\nthird\nsecond line");
    try ed.feed("ggVjd");
    try expectText(&ed, "third\nsecond line");
    try ed.feed("viwU");
    try expectText(&ed, "THIRD\nsecond line");
}

test "v again switches to line mode over all the selected lines" {
    var ed = try testEditor("hello world\nsecond line\nthird");
    defer ed.deinit();
    try ed.feed("wvvd");
    try expectText(&ed, "second line\nthird");
    try ed.feed("vjvd"); // moved: still line mode, both lines
    try expectText(&ed, "");
}

test "autopairs: an opener right before its own closer adds no pair" {
    var ed = try testEditor("}");
    defer ed.deinit();
    try ed.feed("i{<Esc>");
    try expectText(&ed, "{}");
    try ed.feed("A[<Esc>");
    try expectText(&ed, "{}[]"); // another kind still pairs
    try ed.feed("0a{<Esc>");
    try expectText(&ed, "{{}}[]"); // an opener before: it nests
}

test "yanking flashes the range; a delete does not" {
    var ed = try testEditor("one two\nthree");
    defer ed.deinit();
    try ed.feed("yiw");
    try testing.expectEqual(0, ed.yank_flash.?.start);
    try testing.expectEqual(3, ed.yank_flash.?.end);
    ed.yank_flash = null;
    try ed.feed("dw");
    try testing.expect(ed.yank_flash == null);
    try ed.feed("yy");
    try testing.expect(ed.yank_flash.?.linewise);
}

test "comments: <!-- --> in HTML, /* */ in CSS, {/* */} among JSX children" {
    {
        var ed = try testEditorAs("x.html", "<div>\n  <p>hi</p>\n</div>");
        defer ed.deinit();
        try ed.feed("jgcc");
        try expectText(&ed, "<div>\n  <!-- <p>hi</p> -->\n</div>");
        try ed.feed("gcc");
        try expectText(&ed, "<div>\n  <p>hi</p>\n</div>");
    }
    {
        var ed = try testEditorAs("x.css", "a {\n  color: red;\n}");
        defer ed.deinit();
        try ed.feed("jgcc");
        try expectText(&ed, "a {\n  /* color: red; */\n}");
    }
    {
        const src = "const A = () => (\n  <div>\n    <p>hi</p>\n  </div>\n);\nconst b = 1;";
        var ed = try testEditorAs("x.tsx", src);
        defer ed.deinit();
        try ed.feed("jjgcc"); // a child of the <div>
        try expectText(&ed, "const A = () => (\n  <div>\n    {/* <p>hi</p> */}\n  </div>\n);\nconst b = 1;");
        try ed.feed("gcc");
        try expectText(&ed, src);
        try ed.feed("Ggcc"); // plain code
        try expectText(&ed, "const A = () => (\n  <div>\n    <p>hi</p>\n  </div>\n);\n// const b = 1;");
    }
}

test "U redoes; <C-;> ends the line with ;, the cursor staying" {
    var ed = try testEditor("foo(1)");
    defer ed.deinit();
    try ed.feed("xu");
    try expectText(&ed, "foo(1)");
    try ed.feed("U");
    try expectText(&ed, "oo(1)");
    try ed.feed("$i<C-;>");
    try expectText(&ed, "oo(1);");
    try testing.expectEqual(4, ed.view.cursor); // still before the `)`
    try ed.feed("<C-;><Esc>"); // already ends in `;`
    try expectText(&ed, "oo(1);");
}

test "gV selects the last change, or the last yank" {
    var ed = try testEditor("one two three\nfour");
    defer ed.deinit();
    try ed.feed("wcwTWO<Esc>gV");
    try testing.expectEqual(Mode.visual, ed.mode);
    try ed.feed("y");
    try testing.expectEqualStrings("TWO", ed.registers.get(null).?.text);
    try ed.feed("jyygV"); // a linewise yank: the line, linewise
    try testing.expect(ed.visual_line);
    try testing.expectEqual(1, ed.cursorLine());
}

test "go: a new file indents with tabs" {
    var ed = try testEditorAs("main.go", "func main() {");
    defer ed.deinit();
    try testing.expect(indenting.usesTabs(&ed));
    try ed.feed("A<CR>x<Esc>");
    try testing.expectEqualStrings("\tx", ed.text().lineSlice(1));
}

test "registers: named, append, black hole" {
    var ed = try testEditor("alpha beta");
    defer ed.deinit();
    try ed.feed("\"ayiww\"Ayiw");
    try testing.expectEqualStrings("alphabeta", ed.registers.get('a').?.text);
    try ed.feed("\"_dw"); // black hole: the unnamed register still points at "a
    try testing.expectEqualStrings("alphabeta", ed.registers.get(null).?.text);
    try ed.feed("$\"ap");
    try expectText(&ed, "alpha alphabeta");
}

test "macros" {
    var ed = try testEditor("1\n2\n3\n4");
    defer ed.deinit();
    try ed.feed("QaA.<Esc>jQ");
    try testing.expectEqual(null, ed.macro_register);
    try ed.feed("2@a");
    try expectText(&ed, "1.\n2.\n3.\n4");
    try ed.feed("@@");
    try expectText(&ed, "1.\n2.\n3.\n4.");
}

test "dit / dat / cit on tags" {
    var ed = try testEditor("<ul><li>one</li><li>two</li></ul>");
    defer ed.deinit();
    try ed.feed("fndit");
    try expectText(&ed, "<ul><li></li><li>two</li></ul>");
    try ed.feed("fwcitTWO<Esc>");
    try expectText(&ed, "<ul><li></li><li>TWO</li></ul>");
    try ed.feed("0fOdat");
    try expectText(&ed, "<ul><li></li></ul>");
    try ed.feed("04ld2it"); // on <li>: li is level 1, ul level 2
    try expectText(&ed, "<ul></ul>");
}

test "autopairs: pair, step over, quotes, split blocks" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ifoo(a<Esc>");
    try expectText(&ed, "foo(a)");
    try ed.feed("cc<Esc>ifoo(a, \"x\")<Esc>"); // `"` pairs, then steps over; `)` steps over
    try expectText(&ed, "foo(a, \"x\")");
    try ed.feed("odon't (x<Esc>"); // no pair inside a word
    try expectText(&ed, "foo(a, \"x\")\ndon't (x)");
    try ed.feed("ofn f() {<CR>body<Esc>");
    try expectText(&ed, "foo(a, \"x\")\ndon't (x)\nfn f() {\n    body\n}");
    try ed.feed("<cmd:toggle_auto_pairs>Go(<Esc>"); // toggled off
    try expectText(&ed, "foo(a, \"x\")\ndon't (x)\nfn f() {\n    body\n}\n(");
}

test "surround: ys, yss, ds, cs, visual S, and dot" {
    var ed = try testEditor("say hello world");
    defer ed.deinit();
    try ed.feed("wysiw)");
    try expectText(&ed, "say (hello) world");
    try ed.feed("cs)]");
    try expectText(&ed, "say [hello] world");
    try ed.feed("cs]{");
    try expectText(&ed, "say { hello } world");
    try ed.feed("ds{");
    try expectText(&ed, "say hello world");
    try ed.feed("0ysiw\"3w."); // the cursor lands on the new opening quote
    try expectText(&ed, "\"say\" \"hello\" world");
    try ed.feed("0ds\"");
    try expectText(&ed, "say \"hello\" world");
    try ed.feed("0ds\""); // seeks the next pair
    try expectText(&ed, "say hello world");
    try ed.feed("yssb");
    try expectText(&ed, "(say hello world)");
    try ed.feed("0wviwS*");
    try expectText(&ed, "(*say* hello world)");
    try ed.feed("0d/hel<CR>");
    try expectText(&ed, "hello world)");
    try ed.feed("VS{");
    try expectText(&ed, "{\nhello world)\n}");
}

test "Ctrl-/ toggles comments in normal, visual and insert mode, cursor on its text" {
    var ed = try testEditor("one\n  two\nthree");
    defer ed.deinit();
    try ed.feed("jw<C-/>"); // on "two"
    try expectText(&ed, "one\n  # two\nthree");
    try expectCursor(&ed, 1, 4);
    try ed.feed("ix<C-/>y<Esc>");
    try expectText(&ed, "one\n  xytwo\nthree");
    try ed.feed("ggVj<C-/>");
    try expectText(&ed, "# one\n#   xytwo\nthree");
    try testing.expectEqual(Mode.normal, ed.mode);
    try ed.feed("gg2<C-/>");
    try expectText(&ed, "one\n  xytwo\nthree");
    try ed.feed("jj<C-_>");
    try expectText(&ed, "one\n  xytwo\n# three");
}

test "r replaces the character under the cursor (with a count, and repeatable)" {
    var ed = try testEditor("abcdef");
    defer ed.deinit();
    try ed.feed("rx");
    try expectText(&ed, "xbcdef");
    try ed.feed("l3ry");
    try expectText(&ed, "xyyyef");
    try ed.feed("0."); // the count goes with the repeat
    try expectText(&ed, "yyyyef");
    try ed.feed("$3rz"); // not enough characters left: nothing happens, as in vim
    try expectText(&ed, "yyyyef");
    try testing.expectEqual(Mode.normal, ed.mode);
}

test "new lines: a level deeper after an opening bracket; a closing bracket lines up with its opener" {
    var ed = try testEditor("fn f() {\n    if (x) {\n    }\n}");
    defer ed.deinit();
    try ed.feed("oa;<Esc>"); // below a line that opens a block
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n    }\n}");
    try ed.feed("jA<CR>b;<Esc>"); // Enter after `{`
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n    }\n}");
    try ed.feed("jOc;<Esc>"); // above the line that closes it
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n        c;\n    }\n}");
    try ed.feed("od;<Esc>"); // an ordinary line: the same indentation
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n        c;\n        d;\n    }\n}");
    // Typing the closer on a fresh line pulls it back to its opener's level.
    try ed.feed("<cmd:toggle_auto_pairs>"); // (auto pairs off: type it by hand)
    try ed.feed("Gowhile (y) {<CR>e;<CR>}<Esc>");
    try expectText(&ed, "fn f() {\n    a;\n    if (x) {\n        b;\n        c;\n        d;\n    }\n}\nwhile (y) {\n    e;\n}");
}

test "indentation follows the file: two spaces, or tabs" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    try tmp.dir.writeFile(io, .{ .sub_path = "two.c", .data = "int f() {\n  if (x) {\n    y();\n  }\n}\n" });
    try tmp.dir.writeFile(io, .{ .sub_path = "tabs.c", .data = "int f() {\n\tif (x) {\n\t\ty();\n\t}\n}\n" });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const base = buf[0..try tmp.dir.realPath(io, &buf)];
    const two = try std.fmt.allocPrint(gpa, "{s}/two.c", .{base});
    defer gpa.free(two);
    const tabs = try std.fmt.allocPrint(gpa, "{s}/tabs.c", .{base});
    defer gpa.free(tabs);

    var ed = try testEditor("");
    defer ed.deinit();
    ed.options.format_on_save = false;
    try ed.openFile(two);
    try testing.expectEqual(2, indenting.indentWidth(&ed));
    try ed.feed("joz();<Esc>"); // after `if (x) {`: four spaces, not eight
    try testing.expectEqualStrings("    z();", ed.text().lineSlice(2));
    try ed.feed(">>");
    try testing.expectEqualStrings("      z();", ed.text().lineSlice(2));
    try ed.feed("I<Tab><Esc>"); // a tab key is one level too
    try testing.expectEqualStrings("        z();", ed.text().lineSlice(2));

    try ed.openFile(tabs);
    try testing.expect(indenting.usesTabs(&ed));
    try ed.feed("joz();<Esc>");
    try testing.expectEqualStrings("\t\tz();", ed.text().lineSlice(2));
    try ed.feed("<lt><lt>");
    try testing.expectEqualStrings("\tz();", ed.text().lineSlice(2));
}

test "autopairs: Tab steps over a closing quote and bracket instead of inserting a tab" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("ifoo(\"hi");
    try expectText(&ed, "foo(\"hi\")");
    try ed.feed("<Tab>"); // out of the quote
    try testing.expectEqual(8, ed.view.cursor);
    try ed.feed("<Tab>"); // out of the call
    try testing.expectEqual(9, ed.view.cursor);
    try ed.feed("<Tab>x"); // nothing to step over: a tab as usual
    try expectText(&ed, "foo(\"hi\")   x"); // to the next tab stop
    // An empty pair, and nested ones.
    try ed.feed("<Esc>Sg([\"\"]");
    try expectText(&ed, "g([\"\"])");
    try ed.feed("<Esc>0f\"a<Tab><Tab><Tab>"); // inside the quotes: out of "", ], )
    try testing.expectEqual(7, ed.view.cursor);
    // A quote that opens a string isn't stepped over; nor is a closer at the
    // start of a line (that is indentation).
    try ed.feed("<Esc>S0 = \"abc\"<Esc>0f\"i<Tab>");
    try expectText(&ed, "0 =     \"abc\"");
    try ed.feed("<Esc>S}<Esc>0i<Tab>");
    try expectText(&ed, "    }");
    // Off with autopairs.
    try ed.feed("<Esc><cmd:toggle_auto_pairs>Sf(1)<Esc>i<Tab>"); // (S keeps the line's indentation)
    try expectText(&ed, "    f(1 )");
}

test "o, O and Enter on a blank line indent like the code around it" {
    var ed = try testEditor("fn f() {\n    if (x) {\n\n        y;\n    }\n}");
    defer ed.deinit();
    try ed.feed("ggjjoz<Esc>"); // below the blank line: the block's level, not column 0
    try expectText(&ed, "fn f() {\n    if (x) {\n\n        z\n        y;\n    }\n}");
    try ed.feed("ggjjOw<Esc>"); // above it
    try expectText(&ed, "fn f() {\n    if (x) {\n        w\n\n        z\n        y;\n    }\n}");
    try ed.feed("ggjjjA<CR>v<Esc>"); // Enter on the blank line
    try expectText(&ed, "fn f() {\n    if (x) {\n        w\n\n        v\n        z\n        y;\n    }\n}");
    // After a finished block, the level of the line closing it.
    try ed.feed("Go<Esc>o}<Esc>");
    // Nothing above: the code below it.
    var top = try testEditor("\n\n    a;");
    defer top.deinit();
    try top.feed("ggox<Esc>");
    try expectText(&top, "\n    x\n\n    a;");
}
