//! Normalized key events and vim-style key notation ("<C-w>v", "gg", "<Esc>").
//!
//! Normalization rules (applied by the platform layer and by the notation parser,
//! so bindings and live input compare equal):
//! - Plain text input carries its final codepoint, shift folded in: `A`, not `S-a`.
//! - With ctrl/alt/super held, letters are lowercase and shift is an explicit mod.
//! - Space is the codepoint ' ', not a special key.

const std = @import("std");

pub const Mods = packed struct(u8) {
    shift: bool = false,
    ctrl: bool = false,
    alt: bool = false,
    super: bool = false,
    _pad: u4 = 0,

    pub fn any(m: Mods) bool {
        return m.shift or m.ctrl or m.alt or m.super;
    }

    /// True when the modifiers would prevent the key from producing plain text.
    pub fn blocksText(m: Mods) bool {
        return m.ctrl or m.alt or m.super;
    }
};

pub const Special = enum(u8) {
    escape,
    enter,
    tab,
    backspace,
    delete,
    insert,
    up,
    down,
    left,
    right,
    home,
    end,
    page_up,
    page_down,
    f1,
    f2,
    f3,
    f4,
    f5,
    f6,
    f7,
    f8,
    f9,
    f10,
    f11,
    f12,
};

pub const Key = union(enum) {
    codepoint: u21,
    special: Special,
};

pub const KeyEvent = struct {
    key: Key,
    mods: Mods = .{},

    pub fn char(cp: u21) KeyEvent {
        return .{ .key = .{ .codepoint = cp } };
    }

    pub fn special(s: Special) KeyEvent {
        return .{ .key = .{ .special = s } };
    }

    pub fn eql(a: KeyEvent, b: KeyEvent) bool {
        if (@as(u8, @bitCast(a.mods)) != @as(u8, @bitCast(b.mods))) return false;
        return switch (a.key) {
            .codepoint => |cp| b.key == .codepoint and b.key.codepoint == cp,
            .special => |s| b.key == .special and b.key.special == s,
        };
    }

    /// The text this event inserts in insert mode, if any.
    pub fn text(ev: KeyEvent) ?u21 {
        if (ev.mods.blocksText()) return null;
        return switch (ev.key) {
            .codepoint => |cp| cp,
            .special => null,
        };
    }

    /// Writes vim notation, e.g. `a`, `<C-w>`, `<S-Tab>`, `<Space>`, `<lt>`.
    pub fn format(ev: KeyEvent, w: *std.Io.Writer) std.Io.Writer.Error!void {
        const plain = !ev.mods.any();
        if (plain and ev.key == .codepoint) {
            const cp = ev.key.codepoint;
            switch (cp) {
                ' ' => return w.writeAll("<Space>"),
                '<' => return w.writeAll("<lt>"),
                else => return writeCodepoint(w, cp),
            }
        }
        try w.writeByte('<');
        if (ev.mods.ctrl) try w.writeAll("C-");
        if (ev.mods.alt) try w.writeAll("A-");
        if (ev.mods.super) try w.writeAll("D-");
        if (ev.mods.shift) try w.writeAll("S-");
        switch (ev.key) {
            .codepoint => |cp| switch (cp) {
                ' ' => try w.writeAll("Space"),
                '<' => try w.writeAll("lt"),
                else => try writeCodepoint(w, cp),
            },
            .special => |s| try w.writeAll(specialName(s)),
        }
        try w.writeByte('>');
    }
};

/// Emacs-style display for menus and the status line: `SPC`, `C-x`, `M-x`, `RET`.
pub fn formatDisplay(ev: KeyEvent, w: *std.Io.Writer) std.Io.Writer.Error!void {
    if (ev.mods.ctrl) try w.writeAll("C-");
    if (ev.mods.alt) try w.writeAll("M-");
    if (ev.mods.super) try w.writeAll("s-");
    if (ev.mods.shift) try w.writeAll("S-");
    switch (ev.key) {
        .codepoint => |cp| if (cp == ' ') try w.writeAll("SPC") else try writeCodepoint(w, cp),
        .special => |s| try w.writeAll(switch (s) {
            .escape => "ESC",
            .enter => "RET",
            .tab => "TAB",
            .backspace => "BS",
            .delete => "DEL",
            .insert => "INS",
            .page_up => "PgUp",
            .page_down => "PgDn",
            inline else => |tag| comptime displayName(tag),
        }),
    }
}

/// `up`, `home`, `F5`, ... derived from the enum tag at compile time.
fn displayName(comptime s: Special) []const u8 {
    const name = @tagName(s);
    if (name[0] == 'f' and name.len > 1 and std.ascii.isDigit(name[1])) return "F" ++ name[1..];
    return name;
}

/// A whole sequence, space-separated: `SPC f s`.
pub fn formatSequenceDisplay(seq: []const KeyEvent, w: *std.Io.Writer) std.Io.Writer.Error!void {
    for (seq, 0..) |ev, i| {
        if (i > 0) try w.writeByte(' ');
        try formatDisplay(ev, w);
    }
}

fn writeCodepoint(w: *std.Io.Writer, cp: u21) std.Io.Writer.Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch return w.writeAll("\u{FFFD}");
    try w.writeAll(buf[0..n]);
}

const special_names = [_]struct { []const u8, Special }{
    .{ "Esc", .escape },
    .{ "CR", .enter },
    .{ "Enter", .enter },
    .{ "Return", .enter },
    .{ "Tab", .tab },
    .{ "BS", .backspace },
    .{ "Backspace", .backspace },
    .{ "Del", .delete },
    .{ "Delete", .delete },
    .{ "Insert", .insert },
    .{ "Up", .up },
    .{ "Down", .down },
    .{ "Left", .left },
    .{ "Right", .right },
    .{ "Home", .home },
    .{ "End", .end },
    .{ "PageUp", .page_up },
    .{ "PageDown", .page_down },
    .{ "F1", .f1 },
    .{ "F2", .f2 },
    .{ "F3", .f3 },
    .{ "F4", .f4 },
    .{ "F5", .f5 },
    .{ "F6", .f6 },
    .{ "F7", .f7 },
    .{ "F8", .f8 },
    .{ "F9", .f9 },
    .{ "F10", .f10 },
    .{ "F11", .f11 },
    .{ "F12", .f12 },
};

fn specialName(s: Special) []const u8 {
    // First entry wins, so canonical names come first in the table.
    for (special_names) |entry| {
        if (entry[1] == s) return entry[0];
    }
    unreachable;
}

pub const ParseError = error{ InvalidNotation, SequenceTooLong };

/// Parses vim key notation into `out`. Returns the filled prefix of `out`.
pub fn parseSequence(notation: []const u8, out: []KeyEvent) ParseError![]KeyEvent {
    var n: usize = 0;
    var i: usize = 0;
    while (i < notation.len) {
        if (n == out.len) return error.SequenceTooLong;
        if (notation[i] == '<') {
            if (std.mem.indexOfScalarPos(u8, notation, i + 1, '>')) |close| {
                // "<>" or a lone '<' followed later by '>' with junk is rejected below.
                out[n] = try parseBracketed(notation[i + 1 .. close]);
                n += 1;
                i = close + 1;
                continue;
            }
            return error.InvalidNotation;
        }
        const len = std.unicode.utf8ByteSequenceLength(notation[i]) catch return error.InvalidNotation;
        if (i + len > notation.len) return error.InvalidNotation;
        const cp = std.unicode.utf8Decode(notation[i .. i + len]) catch return error.InvalidNotation;
        out[n] = KeyEvent.char(cp);
        n += 1;
        i += len;
    }
    return out[0..n];
}

fn parseBracketed(inner: []const u8) ParseError!KeyEvent {
    if (inner.len == 0) return error.InvalidNotation;
    var mods: Mods = .{};
    var rest = inner;
    // Modifier prefixes: C- A- M- D- S- (any order). A single trailing char like
    // in "<C-->" is the key itself, so stop when only one char would remain.
    while (rest.len > 2 and rest[1] == '-') {
        switch (rest[0]) {
            'C', 'c' => mods.ctrl = true,
            'A', 'a', 'M', 'm' => mods.alt = true,
            'D', 'd' => mods.super = true,
            'S', 's' => mods.shift = true,
            else => return error.InvalidNotation,
        }
        rest = rest[2..];
    }

    var ev: KeyEvent = undefined;
    if (std.ascii.eqlIgnoreCase(rest, "Space")) {
        ev = KeyEvent.char(' ');
    } else if (std.ascii.eqlIgnoreCase(rest, "lt")) {
        ev = KeyEvent.char('<');
    } else if (lookupSpecial(rest)) |s| {
        ev = KeyEvent.special(s);
    } else {
        const len = std.unicode.utf8ByteSequenceLength(rest[0]) catch return error.InvalidNotation;
        if (len != rest.len) return error.InvalidNotation;
        const cp = std.unicode.utf8Decode(rest) catch return error.InvalidNotation;
        ev = KeyEvent.char(cp);
    }

    // Normalize letters under modifiers: lowercase + explicit shift. Vim treats
    // <C-W> and <C-w> as the same key, so a bare-ctrl uppercase letter drops shift.
    if (ev.key == .codepoint and mods.blocksText()) {
        const cp = ev.key.codepoint;
        if (cp >= 'A' and cp <= 'Z') {
            ev.key.codepoint = cp + ('a' - 'A');
            const ctrl_only = mods.ctrl and !mods.alt and !mods.super;
            if (!ctrl_only) mods.shift = true;
        }
    }
    // <S-a> without other mods is just "A".
    if (ev.key == .codepoint and mods.shift and !mods.blocksText()) {
        const cp = ev.key.codepoint;
        if (cp >= 'a' and cp <= 'z') {
            ev.key.codepoint = cp - ('a' - 'A');
            mods.shift = false;
        }
    }
    ev.mods = mods;
    return ev;
}

fn lookupSpecial(name: []const u8) ?Special {
    for (special_names) |entry| {
        if (std.ascii.eqlIgnoreCase(entry[0], name)) return entry[1];
    }
    return null;
}

const testing = std.testing;

test "parse plain and bracketed notation" {
    var buf: [8]KeyEvent = undefined;
    const seq = try parseSequence("g<C-w><Esc><Space><lt>", &buf);
    try testing.expectEqual(5, seq.len);
    try testing.expect(seq[0].eql(KeyEvent.char('g')));
    try testing.expect(seq[1].eql(.{ .key = .{ .codepoint = 'w' }, .mods = .{ .ctrl = true } }));
    try testing.expect(seq[2].eql(KeyEvent.special(.escape)));
    try testing.expect(seq[3].eql(KeyEvent.char(' ')));
    try testing.expect(seq[4].eql(KeyEvent.char('<')));
}

test "modifier normalization" {
    var buf: [4]KeyEvent = undefined;
    // <C-W> == <C-w> (vim compat)
    const a = try parseSequence("<C-W>", &buf);
    try testing.expect(a[0].eql(.{ .key = .{ .codepoint = 'w' }, .mods = .{ .ctrl = true } }));
    // <A-W> keeps the shift
    const b = try parseSequence("<A-W>", &buf);
    try testing.expect(b[0].eql(.{ .key = .{ .codepoint = 'w' }, .mods = .{ .alt = true, .shift = true } }));
    // <S-a> is just "A"
    const c = try parseSequence("<S-a>", &buf);
    try testing.expect(c[0].eql(KeyEvent.char('A')));
    // <S-Tab> stays a shifted special
    const d = try parseSequence("<S-Tab>", &buf);
    try testing.expect(d[0].eql(.{ .key = .{ .special = .tab }, .mods = .{ .shift = true } }));
    // "<C-->" is ctrl + minus
    const e = try parseSequence("<C-->", &buf);
    try testing.expect(e[0].eql(.{ .key = .{ .codepoint = '-' }, .mods = .{ .ctrl = true } }));
}

test "format round trip" {
    const cases = [_][]const u8{ "a", "<C-w>", "<Esc>", "<Space>", "<lt>", "<S-Tab>", "<C-A-S-x>", "é" };
    for (cases) |notation| {
        var buf: [4]KeyEvent = undefined;
        const seq = try parseSequence(notation, &buf);
        var out: [32]u8 = undefined;
        var w: std.Io.Writer = .fixed(&out);
        try seq[0].format(&w);
        try testing.expectEqualStrings(notation, w.buffered());
    }
}

test "invalid notation" {
    var buf: [4]KeyEvent = undefined;
    try testing.expectError(error.InvalidNotation, parseSequence("<Bogus>", &buf));
    try testing.expectError(error.InvalidNotation, parseSequence("<C-w", &buf));
    try testing.expectError(error.SequenceTooLong, parseSequence("abcde", &buf));
}

test "emacs-style display" {
    var buf: [8]KeyEvent = undefined;
    var out: [64]u8 = undefined;
    var w: std.Io.Writer = .fixed(&out);
    try formatSequenceDisplay(try parseSequence("<Space>fs<C-x><A-x><CR><F5><PageDown>", &buf), &w);
    try testing.expectEqualStrings("SPC f s C-x M-x RET F5 PgDn", w.buffered());
}
