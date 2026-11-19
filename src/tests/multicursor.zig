//! Editor tests: multicursor.

const std = @import("std");
const testing = std.testing;
const Editor = @import("../Editor.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;

test "multicursor: qf in a selection puts cursors on the matches inside it" {
    var ed = try testEditor("a1 a2\nxx a3 a4\na5");
    defer ed.deinit();
    try ed.feed("Vjsa<CR>");
    try testing.expectEqual(3, ed.cursors.items.len); // four matches, not the fifth
    try ed.feed("cZ<Esc>");
    try expectText(&ed, "Z1 Z2\nxx Z3 Z4\na5");
}

test "multicursor: visual I/A types on every line" {
    var ed = try testEditor("a\n  b\nc");
    defer ed.deinit();
    try ed.feed("VjjA,<Esc>");
    try expectText(&ed, "a,\n  b,\nc,");
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("<Esc>"); // removes the extra cursors
    try testing.expectEqual(0, ed.cursors.items.len);
    try ed.feed("ggVjjI- <Esc>");
    try expectText(&ed, "- a,\n  - b,\n- c,");
    // One undo step for the whole multi-cursor change.
    try ed.feed("u");
    try expectText(&ed, "a,\n  b,\nc,");
}

test "multicursor: normal-mode commands run at every cursor" {
    var ed = try testEditor("foo: u32,\nbarbaz: u8,\nx: bool,");
    defer ed.deinit();
    try ed.feed("qjqj"); // three cursors down the column
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("0i.<Esc>f:C = 0,<Esc>");
    try expectText(&ed, ".foo = 0,\n.barbaz = 0,\n.x = 0,");
    try ed.feed("<Esc>dd");
    try testing.expectEqual(0, ed.cursors.items.len);
}

test "multicursor: gzn adds the next match, then ciw changes all" {
    var ed = try testEditor("let a = old; old(old_x); old");
    defer ed.deinit();
    try ed.feed("foqnqn");
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("ciwnew<Esc>");
    try expectText(&ed, "let a = new; new(old_x); new");
    try ed.feed("<Esc>uggfoqa");
    try testing.expectEqual(2, ed.cursors.items.len); // old_x is not the word
    try ed.feed("<Esc>");
}

test "multicursor: s takes a regex, each cursor on its own match" {
    var ed = try testEditor("self.dir = a;\nself.dir = longer;\nself.dirs = 1;\nself.dir = b;");
    defer ed.deinit();
    ed.view.rows = 10;
    try ed.feed("sself\\.dir = .*<CR>");
    try testing.expectEqual(.visual, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("cx<Esc>");
    try expectText(&ed, "x\nx\nself.dirs = 1;\nx");
    // Text that is not a regex is looked for as it is.
    try ed.feed("<Esc>uggsdirs = (<CR>");
    try testing.expectEqual(0, ed.cursors.items.len);
    try testing.expectEqual(.normal, ed.mode);
    try ed.feed("sdir = \\w<CR>d");
    try expectText(&ed, "self.;\nself.onger;\nself.dirs = 1;\nself.;");
}

test "multicursor: qp places cursors that stay put while you move; the first edit uses them all" {
    var ed = try testEditor("alpha one\nbeta two\ngamma three\ndelta four");
    defer ed.deinit();
    ed.view.rows = 10;
    try ed.feed("wqp"); // on `one`
    try testing.expect(ed.cursors_placing);
    try testing.expectEqual(1, ed.cursors.items.len);
    const first = ed.cursors.items[0].pos;
    // Moving is yours alone: the placed cursor stays.
    try ed.feed("jj0w");
    try testing.expectEqual(first, ed.cursors.items[0].pos);
    try ed.feed("qp"); // on `three`
    try ed.feed("ggG0"); // anywhere at all
    try testing.expectEqual(2, ed.cursors.items.len);
    try testing.expectEqual(first, ed.cursors.items[0].pos);
    // The first edit is for all of them, and for where you are (delta).
    try ed.feed("i> <Esc>");
    try testing.expect(!ed.cursors_placing);
    try expectText(&ed, "alpha > one\nbeta two\ngamma > three\n> delta four");
    // From here on they move together, as cursors do.
    try ed.feed("wcwX<Esc>");
    try expectText(&ed, "alpha > X\nbeta two\ngamma > X\n> X four");
    try ed.feed("<Esc>");
    try testing.expectEqual(0, ed.cursors.items.len);

    // qu takes back the one placed last; a place twice is one cursor.
    var again = try testEditor("a b c d");
    defer again.deinit();
    again.view.rows = 10;
    try again.feed("qpqpwqpwqp");
    try testing.expectEqual(3, again.cursors.items.len);
    try again.feed("qu");
    try testing.expectEqual(2, again.cursors.items.len);
    try testing.expect(again.cursors_placing);
    try again.feed("$x"); // an edit that isn't insert mode: all of them too
    try expectText(&again, "  c "); // a, b and (where you were) d
}

test "multicursor: on the matches s selected, i / a / o / O type at each" {
    const text = "let dir = a;\nlet other = 1;\n  let dir = b;";
    var ed = try testEditor(text);
    defer ed.deinit();
    ed.view.rows = 10;
    try ed.feed("sdir<CR>");
    try testing.expectEqual(.visual, ed.mode);
    try testing.expectEqual(1, ed.cursors.items.len);
    try ed.feed("imy_<Esc>"); // before each match
    try expectText(&ed, "let my_dir = a;\nlet other = 1;\n  let my_dir = b;");
    try ed.feed("<Esc>uggsdir<CR>as<Esc>"); // after each
    try expectText(&ed, "let dirs = a;\nlet other = 1;\n  let dirs = b;");
    try ed.feed("<Esc>uggsdir<CR>o// below<Esc>"); // a line under each, indented as it
    try expectText(&ed, "let dir = a;\n// below\nlet other = 1;\n  let dir = b;\n  // below");
    try ed.feed("<Esc>uggsdir<CR>O// above<Esc>");
    try expectText(&ed, "// above\nlet dir = a;\nlet other = 1;\n  // above\n  let dir = b;");
    // One match is the same, with no other cursor.
    try ed.feed("<Esc>uggsother<CR>");
    try testing.expectEqual(0, ed.cursors.items.len);
    try ed.feed("a_one<Esc>");
    try expectText(&ed, "let dir = a;\nlet other_one = 1;\n  let dir = b;");
    // A selection of your own keeps its keys: i begins a text object.
    try ed.feed("<Esc>uggwviwd");
    try expectText(&ed, "let  = a;\nlet other = 1;\n  let dir = b;");
}

test "clipboard: p is the registers' alone, Ctrl+Shift+V pastes the clipboard" {
    var ed = try testEditor("one two\nthree");
    defer ed.deinit();
    const Fake = struct {
        var buf: [64]u8 = undefined;
        var len: usize = 0;
        fn get(gpa: std.mem.Allocator) ?[]u8 {
            return gpa.dupe(u8, buf[0..len]) catch null;
        }
        fn set(_: std.mem.Allocator, data: []const u8) void {
            len = @min(data.len, buf.len);
            @memcpy(buf[0..len], data[0..len]);
        }
    };
    ed.registers.clipboard = .{ .get = Fake.get, .set = Fake.set };
    Fake.set(testing.allocator, "CLIP");
    // A delete leaves the clipboard alone; `p` pastes the delete.
    try ed.feed("dw");
    try testing.expectEqualStrings("CLIP", Fake.buf[0..Fake.len]);
    try ed.feed("$p");
    try expectText(&ed, "twoone \nthree");
    // The clipboard, without touching the register.
    try ed.feed("0<C-S-v>");
    try expectText(&ed, "tCLIPwoone \nthree");
    try ed.feed("j0P");
    try expectText(&ed, "tCLIPwoone \none three");
    // Over a selection, and while typing.
    try ed.feed("ggve<C-S-v>");
    try expectText(&ed, "CLIP \none three");
    try ed.feed("A<C-S-v>!<Esc>"); // (insert mode's Ctrl-v is Vim's literal key)
    try expectText(&ed, "CLIP CLIP!\none three");
    // A yank is copied out.
    try ed.feed("j0yiw");
    try testing.expectEqualStrings("one", Fake.buf[0..Fake.len]);
}

test "multicursor: Tab in the snipe or search prompt makes cursors" {
    var ed = try testEditor("int a; int b;\nfloat c; int d;");
    defer ed.deinit();
    ed.view.rows = 10;
    try ed.feed("sint<Tab>");
    try testing.expectEqual(.visual, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("cuint<Esc>");
    try expectText(&ed, "uint a; uint b;\nfloat c; uint d;");
    try ed.feed("<Esc>gg/uint<Tab><Esc>");
    try testing.expectEqual(.normal, ed.mode);
    try testing.expectEqual(2, ed.cursors.items.len);
    try ed.feed("x"); // each cursor is on its match's last character
    try expectText(&ed, "uin a; uin b;\nfloat c; uin d;");
}
