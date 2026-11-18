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
    try ed.feed("A<C-v>!<Esc>");
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
