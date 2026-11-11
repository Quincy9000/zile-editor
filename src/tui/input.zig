//! Terminal input bytes -> key events (and pastes, mouse). Understands the
//! kitty keyboard protocol's `CSI code ; mods u` (asked for at startup, so
//! <Esc>, <C-i> vs <Tab> and <C-S-v> stay distinct), xterm sequences for
//! special keys, control bytes, `ESC` + key as Alt, UTF-8, bracketed paste
//! and SGR mouse reports.

const std = @import("std");
const keys = @import("../input/keys.zig");
const KeyEvent = keys.KeyEvent;
const Mods = keys.Mods;

pub const Mouse = struct {
    kind: enum { press, release, drag, wheel_up, wheel_down },
    /// 0-based cell.
    col: u16,
    row: u16,
};

pub const Event = union(enum) {
    key: KeyEvent,
    /// Bracketed paste: the text (a slice of the input).
    paste: []const u8,
    mouse: Mouse,
    /// The terminal gained (true) or lost focus (mode 1004).
    focus: bool,
};

pub const Result = union(enum) {
    /// An event, from the first `len` bytes.
    event: struct { ev: Event, len: usize },
    /// Bytes that mean nothing to us (unknown sequences).
    skip: usize,
    /// A sequence has started but not all of it has arrived.
    incomplete,
};

/// Decodes the event at the start of `bytes`. `final`: no more bytes are
/// coming soon, so a lone ESC is the Escape key.
pub fn decode(bytes: []const u8, final: bool) Result {
    if (bytes.len == 0) return .incomplete;
    const b = bytes[0];
    if (b == 0x1b) return escape(bytes, final);
    if (b < 0x20 or b == 0x7f) return key(control(b), 1);
    // UTF-8 text.
    const n = std.unicode.utf8ByteSequenceLength(b) catch return .{ .skip = 1 };
    if (bytes.len < n) return .incomplete;
    const cp = std.unicode.utf8Decode(bytes[0..n]) catch return .{ .skip = n };
    return key(KeyEvent.char(cp), n);
}

fn key(ev: KeyEvent, len: usize) Result {
    return .{ .event = .{ .ev = .{ .key = ev }, .len = len } };
}

/// A control byte: Enter, Tab, Backspace, or Ctrl+key.
fn control(b: u8) KeyEvent {
    return switch (b) {
        0x0d, 0x0a => KeyEvent.special(.enter),
        0x09 => KeyEvent.special(.tab),
        0x7f, 0x08 => KeyEvent.special(.backspace),
        0x00 => withMods(KeyEvent.char(' '), .{ .ctrl = true }),
        0x01...0x07, 0x0b, 0x0c, 0x0e...0x1a => withMods(KeyEvent.char('a' + b - 1), .{ .ctrl = true }),
        0x1c => withMods(KeyEvent.char('\\'), .{ .ctrl = true }),
        0x1d => withMods(KeyEvent.char(']'), .{ .ctrl = true }),
        0x1e => withMods(KeyEvent.char('^'), .{ .ctrl = true }),
        0x1f => withMods(KeyEvent.char('_'), .{ .ctrl = true }),
        else => KeyEvent.special(.escape),
    };
}

fn withMods(ev: KeyEvent, m: Mods) KeyEvent {
    var e = ev;
    e.mods = m;
    return e;
}

fn escape(bytes: []const u8, final: bool) Result {
    if (bytes.len == 1) return if (final) key(KeyEvent.special(.escape), 1) else .incomplete;
    switch (bytes[1]) {
        '[' => return csi(bytes, final),
        'O' => {
            if (bytes.len < 3) return if (final) key(withMods(KeyEvent.char('O'), .{ .alt = true }), 2) else .incomplete;
            const ev: ?KeyEvent = switch (bytes[2]) {
                'A' => KeyEvent.special(.up),
                'B' => KeyEvent.special(.down),
                'C' => KeyEvent.special(.right),
                'D' => KeyEvent.special(.left),
                'H' => KeyEvent.special(.home),
                'F' => KeyEvent.special(.end),
                'P' => KeyEvent.special(.f1),
                'Q' => KeyEvent.special(.f2),
                'R' => KeyEvent.special(.f3),
                'S' => KeyEvent.special(.f4),
                else => null,
            };
            return if (ev) |e| key(e, 3) else .{ .skip = 3 };
        },
        0x1b => return key(KeyEvent.special(.escape), 1),
        else => {
            // ESC + key: Alt+key.
            switch (decode(bytes[1..], final)) {
                .event => |e| switch (e.ev) {
                    .key => |k| {
                        var m = k.mods;
                        m.alt = true;
                        var k2 = k;
                        // With a modifier held, letters are lowercase and shift is explicit.
                        if (k2.key == .codepoint and k2.key.codepoint >= 'A' and k2.key.codepoint <= 'Z') {
                            k2.key.codepoint += 'a' - 'A';
                            m.shift = true;
                        }
                        k2.mods = m;
                        return key(k2, 1 + e.len);
                    },
                    else => return key(KeyEvent.special(.escape), 1),
                },
                .incomplete => return if (final) key(KeyEvent.special(.escape), 1) else .incomplete,
                .skip => return key(KeyEvent.special(.escape), 1),
            }
        },
    }
}

/// `ESC [ params final`.
fn csi(bytes: []const u8, final: bool) Result {
    var i: usize = 2;
    while (i < bytes.len and !(bytes[i] >= 0x40 and bytes[i] <= 0x7e)) i += 1;
    if (i >= bytes.len) return if (final and bytes.len == 2) key(withMods(KeyEvent.char('['), .{ .alt = true }), 2) else .incomplete;
    const params = bytes[2..i];
    const fin = bytes[i];
    const len = i + 1;

    // Bracketed paste: everything up to ESC[201~.
    if (fin == '~' and std.mem.eql(u8, params, "200")) {
        const end_marker = "\x1b[201~";
        const end = std.mem.indexOf(u8, bytes[len..], end_marker) orelse return .incomplete;
        return .{ .event = .{ .ev = .{ .paste = bytes[len .. len + end] }, .len = len + end + end_marker.len } };
    }
    // Focus reports: ESC[I in, ESC[O out.
    if (params.len == 0 and (fin == 'I' or fin == 'O')) return .{ .event = .{ .ev = .{ .focus = fin == 'I' }, .len = len } };
    // SGR mouse: ESC[<b;x;yM (press) / m (release).
    if (params.len > 0 and params[0] == '<' and (fin == 'M' or fin == 'm')) {
        var it = std.mem.splitScalar(u8, params[1..], ';');
        const btn = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .skip = len };
        const x = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .skip = len };
        const y = std.fmt.parseInt(u16, it.next() orelse "", 10) catch return .{ .skip = len };
        const kind: @FieldType(Mouse, "kind") = if (btn & 64 != 0)
            (if (btn & 1 == 0) .wheel_up else .wheel_down)
        else if (btn & 32 != 0) .drag else if (fin == 'm') .release else .press;
        return .{ .event = .{ .ev = .{ .mouse = .{ .kind = kind, .col = x -| 1, .row = y -| 1 } }, .len = len } };
    }

    // "a;b" -> first number and modifiers (1 + bits: shift 1, alt 2, ctrl 4, super 8).
    var it = std.mem.splitScalar(u8, params, ';');
    const first_field = it.next() orelse "";
    const first = std.fmt.parseInt(u32, std.mem.sliceTo(first_field, ':'), 10) catch 1;
    const mod_field = it.next() orelse "1";
    const mod_num = std.fmt.parseInt(u32, std.mem.sliceTo(mod_field, ':'), 10) catch 1;
    const bits = mod_num -| 1;
    const mods: Mods = .{ .shift = bits & 1 != 0, .alt = bits & 2 != 0, .ctrl = bits & 4 != 0, .super = bits & 8 != 0 };
    // Key releases (kitty event type 3) are not wanted.
    if (std.mem.indexOfScalar(u8, mod_field, ':')) |c| if (std.mem.eql(u8, mod_field[c + 1 ..], "3")) return .{ .skip = len };

    const ev: ?KeyEvent = switch (fin) {
        'u' => switch (first) {
            27 => KeyEvent.special(.escape),
            13 => KeyEvent.special(.enter),
            9 => KeyEvent.special(.tab),
            127, 8 => KeyEvent.special(.backspace),
            else => if (first < 0x110000 and first >= 0x20) blk: {
                var cp: u21 = @intCast(first);
                // Plain text arriving as CSI u: fold shift into the character.
                if (!mods.ctrl and !mods.alt and !mods.super) {
                    if (mods.shift and cp >= 'a' and cp <= 'z') cp -= 'a' - 'A';
                    break :blk KeyEvent.char(cp);
                }
                break :blk KeyEvent.char(cp);
            } else null,
        },
        'A' => KeyEvent.special(.up),
        'B' => KeyEvent.special(.down),
        'C' => KeyEvent.special(.right),
        'D' => KeyEvent.special(.left),
        'H' => KeyEvent.special(.home),
        'F' => KeyEvent.special(.end),
        'P' => KeyEvent.special(.f1),
        'Q' => KeyEvent.special(.f2),
        'R' => KeyEvent.special(.f3),
        'S' => KeyEvent.special(.f4),
        'Z' => withMods(KeyEvent.special(.tab), .{ .shift = true }),
        '~' => switch (first) {
            1, 7 => KeyEvent.special(.home),
            2 => KeyEvent.special(.insert),
            3 => KeyEvent.special(.delete),
            4, 8 => KeyEvent.special(.end),
            5 => KeyEvent.special(.page_up),
            6 => KeyEvent.special(.page_down),
            15 => KeyEvent.special(.f5),
            17 => KeyEvent.special(.f6),
            18 => KeyEvent.special(.f7),
            19 => KeyEvent.special(.f8),
            20 => KeyEvent.special(.f9),
            21 => KeyEvent.special(.f10),
            23 => KeyEvent.special(.f11),
            24 => KeyEvent.special(.f12),
            else => null,
        },
        else => null,
    };
    var e = ev orelse return .{ .skip = len };
    // Plain text keeps its folded character; everything else gets the mods.
    if (!(fin == 'u' and e.key == .codepoint and !mods.ctrl and !mods.alt and !mods.super)) {
        if (fin != 'Z') e.mods = mods;
    }
    return key(e, len);
}

const testing = std.testing;

fn expectKey(bytes: []const u8, notation: []const u8) !void {
    var buf: [1]KeyEvent = undefined;
    const want = (try keys.parseSequence(notation, &buf))[0];
    switch (decode(bytes, true)) {
        .event => |e| {
            try testing.expectEqual(bytes.len, e.len);
            try testing.expect(e.ev.key.eql(want));
        },
        else => return error.TestUnexpectedResult,
    }
}

test "text, control bytes, alt" {
    try expectKey("a", "a");
    try expectKey("A", "A");
    try expectKey("é", "é");
    try expectKey("\r", "<CR>");
    try expectKey("\t", "<Tab>");
    try expectKey("\x7f", "<BS>");
    try expectKey("\x17", "<C-w>");
    try expectKey("\x1c", "<C-\\>");
    try expectKey("\x1bx", "<A-x>");
    try expectKey("\x1b", "<Esc>");
    try testing.expectEqual(Result.incomplete, decode("\x1b", false));
}

test "xterm and kitty sequences" {
    try expectKey("\x1b[A", "<Up>");
    try expectKey("\x1b[1;5C", "<C-Right>");
    try expectKey("\x1bOP", "<F1>");
    try expectKey("\x1b[5~", "<PageUp>");
    try expectKey("\x1b[3;2~", "<S-Del>");
    try expectKey("\x1b[27u", "<Esc>");
    try expectKey("\x1b[105;5u", "<C-i>");
    try expectKey("\x1b[118;6u", "<C-S-v>");
    try expectKey("\x1b[Z", "<S-Tab>");
    try testing.expectEqual(Result.incomplete, decode("\x1b[1;5", true));
    try testing.expectEqual(Result{ .skip = 4 }, decode("\x1b[?u", true));
}

test "focus reports" {
    switch (decode("\x1b[O", false)) {
        .event => |e| try testing.expectEqual(false, e.ev.focus),
        else => return error.TestUnexpectedResult,
    }
}

test "paste and mouse" {
    switch (decode("\x1b[200~hi\nthere\x1b[201~x", true)) {
        .event => |e| {
            try testing.expectEqualStrings("hi\nthere", e.ev.paste);
            try testing.expectEqual(20, e.len);
        },
        else => return error.TestUnexpectedResult,
    }
    try testing.expectEqual(Result.incomplete, decode("\x1b[200~partial", true));
    switch (decode("\x1b[<65;10;5M", true)) {
        .event => |e| {
            try testing.expectEqual(.wheel_down, e.ev.mouse.kind);
            try testing.expectEqual(9, e.ev.mouse.col);
            try testing.expectEqual(4, e.ev.mouse.row);
        },
        else => return error.TestUnexpectedResult,
    }
}
