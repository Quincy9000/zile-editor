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
    try ed.feed("2yypp"); // (the yank leaves the cursor on the last line it took)
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

test "a yank leaves the cursor at the end of what it took" {
    var ed = try testEditor("one\n    foo(bar, baz)\nthree\n\nfour");
    defer ed.deinit();
    try ed.feed("j$h"); // on the last `z`
    try ed.feed("yil"); // the line's text: its last character
    try expectCursor(&ed, 1, 16);
    try ed.feed("yib"); // inside the brackets: the last character there
    try expectCursor(&ed, 1, 15);
    try ed.feed("0yw"); // the indentation, up to the word
    try expectCursor(&ed, 1, 3);
    try ed.feed("wyiw");
    try expectCursor(&ed, 1, 6);
    try ed.feed("yy"); // its own line: it stays
    try expectCursor(&ed, 1, 6);
    try ed.feed("yk"); // the line above and this one: this one is the last
    try testing.expectEqual(1, ed.cursorLine());
    try ed.feed("yj"); // this one and the next: the next
    try testing.expectEqual(2, ed.cursorLine());
    try ed.feed("ggyip"); // a paragraph: its last line
    try testing.expectEqual(2, ed.cursorLine());
    try testing.expectEqualStrings("one\n    foo(bar, baz)\nthree\n", ed.registers.get(null).?.text);
    // Visual: back to where `v` was pressed, even from the other end.
    try ed.feed("ggjw");
    const at = ed.view.cursor;
    try ed.feed("Vjy");
    try testing.expectEqual(at, ed.view.cursor);
    try ed.feed("vipy");
    try testing.expectEqual(at, ed.view.cursor);
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
    try ed.feed("b\"_dw"); // black hole: the unnamed register still points at "a
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

test "yat / dat / cat: an element with its lines to itself is whole lines (p puts it below)" {
    const html = "<ul>\n  <li>\n    one\n  </li>\n  <li>two</li>\n</ul>";
    var ed = try testEditor(html);
    defer ed.deinit();
    // Several lines: yanked from inside it, pasted below it, indented as it was.
    try ed.feed("jjyatp"); // (the yank left the cursor on its last line)
    try expectText(&ed, "<ul>\n  <li>\n    one\n  </li>\n  <li>\n    one\n  </li>\n  <li>two</li>\n</ul>");
    try ed.feed("u");
    // One line: below as well, not in the middle of the cursor's line.
    try ed.feed("gg4j^yatggp");
    try expectText(&ed, "<ul>\n  <li>two</li>\n  <li>\n    one\n  </li>\n  <li>two</li>\n</ul>");
    try ed.feed("u");
    // dat takes the lines with it (no empty one stays); p puts them back.
    try ed.feed("ggjjdat");
    try expectText(&ed, "<ul>\n  <li>two</li>\n</ul>");
    try ed.feed("p");
    try expectText(&ed, "<ul>\n  <li>two</li>\n  <li>\n    one\n  </li>\n</ul>");
    // cat keeps a line to type on, with the indentation.
    try ed.feed("ggj^cat<lt>p/><Esc>");
    try expectText(&ed, "<ul>\n  <p/>\n  <li>\n    one\n  </li>\n</ul>");

    // An element that shares its line is text, as before: p is inline.
    var shared = try testEditor("<b>x</b> and <i>y</i>");
    defer shared.deinit();
    try shared.feed("yat$p");
    try expectText(&shared, "<b>x</b> and <i>y</i><b>x</b>");
    // gp is inline for the whole-line kind too.
    var inl = try testEditor("  <li>two</li>\nhere: ");
    defer inl.deinit();
    try inl.feed("^yatj$gp");
    try expectText(&inl, "  <li>two</li>\nhere: <li>two</li>");
}

test "dw on a line's last word stops at the end of the line; an empty line goes whole" {
    var ed = try testEditor("foo qux  \n  next x");
    defer ed.deinit();
    try ed.feed("wdw"); // the word and the blanks after it, not the line break
    try expectText(&ed, "foo \n  next x");
    try testing.expectEqualStrings("qux  ", ed.registers.get(null).?.text);
    try ed.feed("u0wd2w"); // a count goes on over the break; its last word stops
    try expectText(&ed, "foo x");
    try ed.feed("u0wyw");
    try testing.expectEqualStrings("qux  ", ed.registers.get(null).?.text);

    var lines = try testEditor("foo\n\n  bar baz");
    defer lines.deinit();
    try lines.feed("dw"); // the only word of its line: the line stays, empty
    try expectText(&lines, "\n\n  bar baz");
    try lines.feed("jdw"); // an empty line is taken whole
    try expectText(&lines, "\n  bar baz");
    try lines.feed("jdW"); // (j has nowhere to go: the cursor is on bar)
    try expectText(&lines, "\n  baz");
}

test "an exclusive motion from a line's start to another line's start is whole lines (d}, d{, db)" {
    var ed = try testEditor("one\ntwo\n\nthree\nfour");
    defer ed.deinit();
    try ed.feed("d}"); // the paragraph's lines: one empty line stays, not two
    try expectText(&ed, "\nthree\nfour");
    try testing.expect(ed.registers.get(null).?.linewise);
    try ed.feed("uGd{"); // from the last line's start, back over the paragraph
    try expectText(&ed, "one\ntwo\nfour");
    try ed.feed("uggld}"); // from inside a line: text only, as before
    try expectText(&ed, "o\n\nthree\nfour");
    try ed.feed("uggjdb"); // at a line's start: the line before goes
    try expectText(&ed, "two\n\nthree\nfour");
}

test "f, t, F, T after an operator: on the line only, the exact character" {
    var ed = try testEditor("abc Abc\nxyz x");
    defer ed.deinit();
    try ed.feed("dfx"); // no x on this line: nothing, though the next has one
    try expectText(&ed, "abc Abc\nxyz x");
    try ed.feed("dfA"); // the capital, not the a under the cursor's neighbour
    try expectText(&ed, "bc\nxyz x");
    try ed.feed("u$dFa"); // backward: the small one, past the capital
    try expectText(&ed, "c\nxyz x");
    try ed.feed("uj0dtx"); // t: up to it; the first x on this line is the cursor's own
    try expectText(&ed, "abc Abc\nx");
    try ed.feed("u0ctz!<Esc>");
    try expectText(&ed, "abc Abc\n!z x");
}

test "ciw on an empty line types there" {
    var ed = try testEditor("a\n\nb");
    defer ed.deinit();
    try ed.feed("jciwnew<Esc>");
    try expectText(&ed, "a\nnew\nb");
    try testing.expectEqual(Mode.normal, ed.mode);
    var other = try testEditor("a\n\nb");
    defer other.deinit();
    try other.feed("jdiw"); // nothing to delete: nothing happens
    try expectText(&other, "a\n\nb");
    try testing.expectEqual(Mode.normal, other.mode);
}

test "~, gU, gu and visual U / u change letters with accents, Greek and Cyrillic" {
    var ed = try testEditor("éa Öb ÿ σ я");
    defer ed.deinit();
    try ed.feed("~~");
    try expectText(&ed, "ÉA Öb ÿ σ я");
    try ed.feed("gUU");
    try expectText(&ed, "ÉA ÖB Ÿ Σ Я");
    try ed.feed("guu");
    try expectText(&ed, "éa öb ÿ σ я");
    try ed.feed("0vlU");
    try expectText(&ed, "ÉA öb ÿ σ я");
    try ed.feed("g~~");
    try expectText(&ed, "éa ÖB Ÿ Σ Я");
}

test "ip / ap: a line of only spaces is a blank line" {
    var ed = try testEditor("one\n   \ntwo\n\nthree");
    defer ed.deinit();
    try ed.feed("dip");
    try expectText(&ed, "   \ntwo\n\nthree");
    try ed.feed("udap"); // with the blank line after it
    try expectText(&ed, "two\n\nthree");
    try ed.feed("ujdip"); // on the blank line: the blank lines
    try expectText(&ed, "one\ntwo\n\nthree");
}

test "aw with a count: that many words, each with its whitespace" {
    var ed = try testEditor("foo  bar  baz");
    defer ed.deinit();
    try ed.feed("wd2aw"); // no whitespace after the last: what is before goes
    try expectText(&ed, "foo");
    try ed.feed("u0d2aw");
    try expectText(&ed, "baz");
    try ed.feed("u03ld2aw"); // from the whitespace: it and the word, twice
    try expectText(&ed, "foo");
    var punct = try testEditor("foo bar.baz");
    defer punct.deinit();
    try punct.feed("d2aw");
    try expectText(&punct, ".baz");
    try punct.feed("ud3iw"); // iw counts runs: foo, the space, bar
    try expectText(&punct, ".baz");
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

test "Ctrl-a / Ctrl-x change the number at or after the cursor" {
    var ed = try testEditor("a 9 b -3 c 007");
    defer ed.deinit();
    try ed.feed("<C-a>");
    try expectText(&ed, "a 10 b -3 c 007");
    try ed.feed("5<C-x>");
    try expectText(&ed, "a 5 b -3 c 007");
    try ed.feed("w<C-a>");
    try expectText(&ed, "a 5 b -2 c 007");
    try ed.feed("3<C-a>");
    try expectText(&ed, "a 5 b 1 c 007");
    try ed.feed("$<C-a>");
    try expectText(&ed, "a 5 b 1 c 008");
    try ed.feed("u");
    try expectText(&ed, "a 5 b 1 c 007");
}

test "block visual: delete, yank and paste a rectangle" {
    var ed = try testEditor("abcd\nefgh\nijkl");
    defer ed.deinit();
    try ed.feed("l<C-v>jld");
    try expectText(&ed, "ad\neh\nijkl");
    try ed.feed("$p");
    try expectText(&ed, "adbc\nehfg\nijkl");
    try ed.feed("gg0<C-v>jy");
    try expectText(&ed, "adbc\nehfg\nijkl");
    try ed.feed("G$p");
    try expectText(&ed, "adbc\nehfg\nijkla\n    e");
}

test "block visual: I, A and c type on every line of the block" {
    var ed = try testEditor("abcd\nefgh\nij\nklmn");
    defer ed.deinit();
    try ed.feed("l<C-v>jjIX<Esc>");
    try expectText(&ed, "aXbcd\neXfgh\niXj\nklmn");
    ed.deinit();
    ed = try testEditor("abcd\ne\nijkl");
    try ed.feed("l<C-v>jjlAX<Esc>");
    try expectText(&ed, "abcXd\ne  X\nijkXl");
    ed.deinit();
    ed = try testEditor("abcd\nefgh");
    try ed.feed("l<C-v>jlcZ<Esc>");
    try expectText(&ed, "aZd\neZh");
    try ed.feed("u");
    try expectText(&ed, "abcd\nefgh");
}

test "block visual: case operators and leaving with v / Esc" {
    var ed = try testEditor("abcd\nefgh");
    defer ed.deinit();
    try ed.feed("l<C-v>jlU");
    try expectText(&ed, "aBCd\neFGh");
    try ed.feed("l<C-v><Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try ed.feed("<C-v>jv");
    try testing.expect(!ed.visual_block);
    try testing.expectEqual(.visual, ed.mode);
}

test "block visual: the block keeps its shape through short lines and blank space" {
    var ed = try testEditor("abcdef\nab\nabcdef");
    defer ed.deinit();
    try ed.feed("3l<C-v>jjd");
    try expectText(&ed, "abcef\nab\nabcef");
    ed.deinit();
    ed = try testEditor("abcdef\nab\nabcdef");
    try ed.feed("3l<C-v>jllhd");
    try expectText(&ed, "abcf\nab\nabcdef");
    ed.deinit();
    ed = try testEditor("abcdef\nab\nabcdef");
    try ed.feed("l<C-v>j$d");
    try expectText(&ed, "a\na\nabcdef");
}

test "block visual: o and O change corners, r fills the selection" {
    var ed = try testEditor("abcd\nefgh\nijkl");
    defer ed.deinit();
    try ed.feed("l<C-v>jlOd");
    try expectText(&ed, "ad\neh\nijkl");
    ed.deinit();
    // o keeps the blank-space column with its corner: the block stays cols 1..2 over lines 0..2
    ed = try testEditor("abcdef\nabcdef\nab");
    try ed.feed("l<C-v>jjllod");
    try expectText(&ed, "aef\naef\na");
    ed.deinit();
    ed = try testEditor("abcd\nefgh\nijkl");
    try ed.feed("l<C-v>jlrx");
    try expectText(&ed, "axxd\nexxh\nijkl");
    ed.deinit();
    ed = try testEditor("abcd\nefgh");
    try ed.feed("lvlrx");
    try expectText(&ed, "axxd\nefgh");
}
