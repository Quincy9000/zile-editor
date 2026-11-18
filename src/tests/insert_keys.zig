//! Insert mode's keys as Vim has them (`editor/insert_keys.zig`).

const std = @import("std");
const testing = std.testing;
const Editor = @import("../Editor.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const expectCursor = support.expectCursor;

fn indicator(ed: *const Editor) []const u8 {
    const S = struct {
        var buf: [16]u8 = undefined;
    };
    return Editor.insert_keys.indicator(ed, &S.buf);
}

test "insert Ctrl-h: the character before the cursor, as Backspace" {
    var ed = try testEditor("abc\nd");
    defer ed.deinit();
    try ed.feed("A<C-h>");
    try expectText(&ed, "ab\nd");
    // At the start of a line: it joins the one before.
    try ed.feed("<Esc>jI<C-h>");
    try expectText(&ed, "abd");
    // A character of several bytes goes whole.
    try ed.feed("é<C-h>");
    try expectText(&ed, "abd");
}

test "insert Ctrl-w: blanks, then one run of word characters or of others; joins at the start of a line" {
    var ed = try testEditor("foo bar.baz  ");
    defer ed.deinit();
    try ed.feed("A<C-w>");
    try expectText(&ed, "foo bar.");
    try ed.feed("<C-w>");
    try expectText(&ed, "foo bar");
    try ed.feed("<C-w>");
    try expectText(&ed, "foo ");
    try ed.feed("<C-w>");
    try expectText(&ed, "");
    try ed.feed("<C-w>"); // nothing left: nothing happens
    try expectText(&ed, "");
    try testing.expectEqual(Editor.Mode.insert, ed.mode);
}

test "insert Ctrl-w: start of a line, an empty line, only indentation before, letters with accents" {
    var ed = try testEditor("a\nb");
    defer ed.deinit();
    try ed.feed("jI<C-w>");
    try expectText(&ed, "ab");
    try expectCursor(&ed, 0, 1);

    var empty = try testEditor("a\n\nb");
    defer empty.deinit();
    try empty.feed("ji<C-w>");
    try expectText(&empty, "a\nb");

    var indent = try testEditor("    x");
    defer indent.deinit();
    try indent.feed("I<C-w>"); // not past the start of the line
    try expectText(&indent, "x");

    var accents = try testEditor("héllo wörld");
    defer accents.deinit();
    try accents.feed("A<C-w>");
    try expectText(&accents, "héllo ");

    var tabs = try testEditor("a\tb\t");
    defer tabs.deinit();
    try tabs.feed("A<C-w>");
    try expectText(&tabs, "a\t");
}

test "insert Ctrl-u: back to the line's first character, then to its start" {
    var ed = try testEditor("    foo bar");
    defer ed.deinit();
    try ed.feed("A<C-u>");
    try expectText(&ed, "    ");
    try ed.feed("<C-u>"); // at the first character already: to column 0
    try expectText(&ed, "");
    try ed.feed("<C-u>"); // an empty line: nothing
    try expectText(&ed, "");

    // Inside the indentation: to column 0, what is after the cursor stays.
    var inside = try testEditor("    foo");
    defer inside.deinit();
    try inside.feed("lli<C-u>");
    try expectText(&inside, "  foo");

    // A tab is indentation too; in the middle of a line the rest stays.
    var tabs = try testEditor("\tfoo bar");
    defer tabs.deinit();
    try tabs.feed("$i<C-u>");
    try expectText(&tabs, "\tr");

    var accents = try testEditor("  é ü");
    defer accents.deinit();
    try accents.feed("A<C-u>");
    try expectText(&accents, "  ");
}

test "insert Ctrl-w and Ctrl-u are undo steps of their own" {
    var ed = try testEditor("one");
    defer ed.deinit();
    try ed.feed("A two three<C-w><Esc>");
    try expectText(&ed, "one two ");
    try ed.feed("u"); // the deletion, not the whole insert
    try expectText(&ed, "one two three");
    try ed.feed("u");
    try expectText(&ed, "one");

    var line = try testEditor("    x");
    defer line.deinit();
    try line.feed("A yz<C-u>q<Esc>");
    try expectText(&line, "    q");
    try line.feed("u"); // what was typed after it
    try expectText(&line, "    ");
    try line.feed("u"); // the deletion
    try expectText(&line, "    x yz");
    try line.feed("u");
    try expectText(&line, "    x");
}

test "insert Ctrl-a: what the insert before typed, again" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("i<C-a>"); // nothing typed before
    try expectText(&ed, "");
    try ed.feed("abx<BS>c<Esc>"); // (what was deleted again isn't part of it)
    try expectText(&ed, "abc");
    try ed.feed("o<C-a><Esc>");
    try expectText(&ed, "abc\nabc");
    // That insert typed it too: it is still what Ctrl-a has.
    try ed.feed("o-<C-a>-<Esc>");
    try expectText(&ed, "abc\nabc\n-abc-");
    // Several bytes to a character, and more than one line.
    try ed.feed("oé<CR>ü<Esc>Go<C-a><Esc>");
    try expectText(&ed, "abc\nabc\n-abc-\né\nü\né\nü");
}

test "insert Ctrl-v: the next key as it is; u and hex digits: a codepoint" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("i<C-v>");
    try testing.expectEqualStrings("^V", indicator(&ed));
    try ed.feed("<Tab>"); // a real tab, though tabs are written as spaces
    try expectText(&ed, "\t");
    try testing.expectEqualStrings("", indicator(&ed));
    try ed.feed("<C-v>("); // no closing bracket with it
    try expectText(&ed, "\t(");
    try ed.feed("<C-v><C-a>"); // a control character
    try expectText(&ed, "\t(\x01");

    var hex = try testEditor("");
    defer hex.deinit();
    try hex.feed("ix<C-v>u");
    try testing.expectEqualStrings("^Vu", indicator(&hex));
    try hex.feed("00e");
    try testing.expectEqualStrings("^Vu00e", indicator(&hex));
    try hex.feed("9"); // the fourth digit ends it
    try expectText(&hex, "xé");
    try hex.feed("<C-v>u41 "); // a key that isn't a digit ends it, and is typed
    try expectText(&hex, "xéA ");
    try hex.feed("<C-v>u2192!");
    try expectText(&hex, "xéA →!");
    try hex.feed("<C-v>uz"); // no digits: only the key
    try expectText(&hex, "xéA →!z");
}

test "insert Ctrl-v and Ctrl-k: Esc gives them up, and insert mode goes on" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("i<C-v><Esc>");
    try testing.expectEqual(Editor.Mode.insert, ed.mode);
    try testing.expectEqualStrings("", indicator(&ed));
    try ed.feed("a<C-v>u4<Esc>b<C-k><Esc>c<C-k>e<Esc>d");
    try expectText(&ed, "abcd");
    try testing.expectEqual(Editor.Mode.insert, ed.mode);
    try ed.feed("<Esc>");
    try testing.expectEqual(Editor.Mode.normal, ed.mode);
}

test "insert Ctrl-k: a digraph from two keys" {
    var ed = try testEditor("");
    defer ed.deinit();
    try ed.feed("i<C-k>");
    try testing.expectEqualStrings("^K", indicator(&ed));
    try ed.feed("e");
    try testing.expectEqualStrings("^Ke", indicator(&ed));
    try ed.feed("'");
    try expectText(&ed, "é");
    try testing.expectEqualStrings("", indicator(&ed));
    try ed.feed("<C-k>a:<C-k>-><C-k>ss<C-k>Eu");
    try expectText(&ed, "éä→ß€");
    try ed.feed("<C-k>:a"); // the other way round
    try expectText(&ed, "éä→ß€ä");
    try ed.feed("<C-k>qj"); // no such pair: the second key
    try expectText(&ed, "éä→ß€äj");
}

test "insert Ctrl-y / Ctrl-e: the character above / below, by the column on screen" {
    var ed = try testEditor("abc\n\nxyz");
    defer ed.deinit();
    try ed.feed("ji<C-y><C-y>");
    try expectText(&ed, "abc\nab\nxyz");
    try ed.feed("<C-e>"); // column 2 of the line below
    try expectText(&ed, "abc\nabz\nxyz");
    try ed.feed("<C-y><C-e>"); // both lines end before column 3
    try expectText(&ed, "abc\nabz\nxyz");

    // The first line has nothing above, the last nothing below.
    var edges = try testEditor("ab");
    defer edges.deinit();
    try edges.feed("i<C-y><C-e>");
    try expectText(&edges, "ab");

    // A line shorter than the cursor's column.
    var short = try testEditor("ab\nwxyz\nc");
    defer short.deinit();
    try short.feed("jA<C-y><C-e>");
    try expectText(&short, "ab\nwxyz\nc");
    try short.feed("<Esc>0lli<C-y><C-e>"); // column 2: neither line reaches it
    try expectText(&short, "ab\nwxyz\nc");
    try short.feed("<Esc>0li<C-y>"); // column 1: `b` above
    try expectText(&short, "ab\nwbxyz\nc");

    // Characters of several bytes are one column each, and come whole.
    var accents = try testEditor("héy\n");
    defer accents.deinit();
    try accents.feed("ji<C-y><C-y><C-y><C-y>");
    try expectText(&accents, "héy\nhéy");

    // A tab above: at its first column it is the tab; past it (the tab is
    // four columns here), what comes after.
    var tabs = try testEditor("\tx\n");
    defer tabs.deinit();
    tabs.options.tab_width = 4;
    try tabs.feed("ji<C-y>");
    try expectText(&tabs, "\tx\n\t");
    try tabs.feed("<C-y>"); // the cursor is at column 4 now: the x
    try expectText(&tabs, "\tx\n\tx");
    // Spaces under a tab: column 4 is still the x.
    var spaces = try testEditor("\tx\n    ");
    defer spaces.deinit();
    spaces.options.tab_width = 4;
    try spaces.feed("jA<C-y>");
    try expectText(&spaces, "\tx\n    x");
}

test "insert Ctrl-j / Ctrl-m: a new line, as Enter (with its indentation)" {
    var ed = try testEditor("    foo");
    defer ed.deinit();
    try ed.feed("A<C-j>x<C-m>y");
    try expectText(&ed, "    foo\n    x\n    y");
    var enter = try testEditor("    foo");
    defer enter.deinit();
    try enter.feed("A<CR>x<CR>y");
    try expectText(&enter, "    foo\n    x\n    y");
}

test "insert Ctrl-t / Ctrl-d: the line a level in or out; the cursor stays on its character" {
    var ed = try testEditor("foo");
    defer ed.deinit();
    ed.buffer.indent_style = null;
    try ed.feed("a<C-t>"); // the cursor is after the f
    try expectText(&ed, "    foo");
    try ed.feed("X");
    try expectText(&ed, "    fXoo");
    try ed.feed("<C-t><C-d><C-d>Y");
    try expectText(&ed, "fXYoo");
    try ed.feed("<C-d>"); // no indentation left: nothing
    try expectText(&ed, "fXYoo");

    // To the next multiple of the width, either way.
    var round = try testEditor("  foo");
    defer round.deinit();
    round.buffer.indent_style = .{ .tabs = false, .width = 4 };
    try round.feed("A<C-t>");
    try expectText(&round, "    foo");
    try round.feed("<Esc>0i  <Esc>A<C-d>"); // six columns: back to four
    try expectText(&round, "    foo");

    // An empty line, and the cursor inside the indentation.
    var empty = try testEditor("");
    defer empty.deinit();
    empty.buffer.indent_style = null;
    try empty.feed("i<C-t><C-t>");
    try expectText(&empty, "        ");
    try expectCursor(&empty, 0, 8);
    try empty.feed("<C-d>x<Esc>0i<C-t>y");
    try expectText(&empty, "        yx");
}

test "insert Ctrl-t / Ctrl-d: tabs where the file is written with tabs" {
    var ed = try testEditor("foo");
    defer ed.deinit();
    ed.buffer.indent_style = .{ .tabs = true, .width = 4 };
    ed.options.tab_width = 4;
    try ed.feed("A<C-t><C-t>");
    try expectText(&ed, "\t\tfoo");
    try ed.feed("<C-d>!");
    try expectText(&ed, "\tfoo!");
    // Spaces that were there become what the file writes.
    var mixed = try testEditor("  é");
    defer mixed.deinit();
    mixed.buffer.indent_style = .{ .tabs = true, .width = 4 };
    mixed.options.tab_width = 4;
    try mixed.feed("A<C-t>ü");
    try expectText(&mixed, "\téü");
}

test "insert 0 Ctrl-d: all of the indentation, and the 0, when the 0 was typed last" {
    var ed = try testEditor("        foo");
    defer ed.deinit();
    ed.buffer.indent_style = .{ .tabs = false, .width = 4 };
    try ed.feed("A0<C-d>");
    try expectText(&ed, "foo");
    try expectCursor(&ed, 0, 3);

    // Something between them: the 0 stays, one level goes.
    var between = try testEditor("        foo");
    defer between.deinit();
    between.buffer.indent_style = .{ .tabs = false, .width = 4 };
    try between.feed("A0x<BS><C-d>");
    try expectText(&between, "    foo0");

    // A 0 that was there already isn't one that was typed.
    var old = try testEditor("    f0");
    defer old.deinit();
    old.buffer.indent_style = .{ .tabs = false, .width = 4 };
    try old.feed("A<C-d>");
    try expectText(&old, "f0");
}

test "the keys these took: todo tags on normal mode's Ctrl-t, paste on Ctrl-Shift-v" {
    var ed = try testEditor("x");
    defer ed.deinit();
    try ed.feed("<C-t>");
    try testing.expectEqual(.todo_tags, ed.picker.?.kind);
    try ed.feed("<Esc><Esc>");
    ed.paste_text = "PASTED";
    try ed.feed("i<C-S-v><Esc>");
    try expectText(&ed, "PASTEDx");
    try ed.feed("$<C-S-v>"); // normal mode too
    try testing.expect(std.mem.indexOf(u8, ed.text().slice(0, ed.text().len()), "xPASTED") != null);
}
