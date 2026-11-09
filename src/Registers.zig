//! Vim registers.
//!
//!   ""        unnamed: points at the last written register
//!   "0        last yank
//!   "1-"9     deletes containing a line break (shifted, newest in "1)
//!   "-        small (within-line) deletes
//!   "a-"z     named; "A-"Z append
//!   "_        black hole
//!   "+ "*     system clipboard
//!
//! The unnamed register is synced with the system clipboard (like neovim's
//! `clipboard=unnamedplus`): yanks and deletes land on the clipboard, and `p`
//! pastes whatever is on it. Our own text read back keeps its linewise flag.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Registers = @This();

pub const Value = struct {
    text: []const u8,
    linewise: bool,
};

/// Platform clipboard access (main thread only). Absent in tests.
pub const Clipboard = struct {
    /// Returns an owned copy of the clipboard text, or null.
    get: *const fn (gpa: Allocator) ?[]u8,
    set: *const fn (gpa: Allocator, text: []const u8) void,
};

pub const Kind = enum { yank, delete };

const Slot = struct {
    text: std.ArrayList(u8) = .empty,
    linewise: bool = false,
};

// Slots: 0-9 digits, 10-35 letters, then the small-delete and scratch slots.
const small_delete = 36;
/// Holds clipboard text read for a paste.
const scratch = 37;
const slot_count = 38;

gpa: Allocator,
slots: [slot_count]Slot = @splat(.{}),
unnamed: usize = 0,
clipboard: ?Clipboard = null,
/// The text we last put on the clipboard, to recognize it when reading back.
clip_last: std.ArrayList(u8) = .empty,
clip_linewise: bool = false,

pub fn init(gpa: Allocator) Registers {
    return .{ .gpa = gpa };
}

pub fn deinit(r: *Registers) void {
    for (&r.slots) |*s| s.text.deinit(r.gpa);
    r.clip_last.deinit(r.gpa);
    r.* = undefined;
}

pub fn isValidName(c: u21) bool {
    return switch (c) {
        '"', '0'...'9', 'a'...'z', 'A'...'Z', '-', '_', '+', '*' => true,
        else => false,
    };
}

fn slotOf(name: u8) ?usize {
    return switch (name) {
        '0'...'9' => name - '0',
        'a'...'z' => 10 + name - 'a',
        'A'...'Z' => 10 + name - 'A',
        '-' => small_delete,
        else => null,
    };
}

fn set(r: *Registers, slot: usize, text: []const u8, linewise: bool) Allocator.Error!void {
    const s = &r.slots[slot];
    s.text.clearRetainingCapacity();
    try s.text.appendSlice(r.gpa, text);
    s.linewise = linewise;
}

/// Stores the text of a yank or delete. `name` is the register from a `"x`
/// prefix, or null for the default.
pub fn store(r: *Registers, name: ?u8, kind: Kind, text: []const u8, linewise: bool) Allocator.Error!void {
    const n = name orelse '"';
    switch (n) {
        '_' => return,
        '+', '*' => return r.setClipboard(text, linewise),
        'a'...'z' => {
            try r.set(slotOf(n).?, text, linewise);
            r.unnamed = slotOf(n).?;
        },
        'A'...'Z' => {
            // Append. Appending lines to a charwise register makes it linewise.
            const s = &r.slots[slotOf(n).?];
            if (linewise and !s.linewise and s.text.items.len > 0) try s.text.append(r.gpa, '\n');
            try s.text.appendSlice(r.gpa, text);
            s.linewise = s.linewise or linewise;
            r.unnamed = slotOf(n).?;
        },
        else => {
            switch (kind) {
                .yank => {
                    try r.set(0, text, linewise);
                    r.unnamed = 0;
                },
                .delete => if (linewise or std.mem.indexOfScalar(u8, text, '\n') != null) {
                    // Shift "1.."8 into "2.."9.
                    var i: usize = 9;
                    while (i > 1) : (i -= 1) std.mem.swap(Slot, &r.slots[i], &r.slots[i - 1]);
                    try r.set(1, text, linewise);
                    r.unnamed = 1;
                } else {
                    try r.set(small_delete, text, linewise);
                    r.unnamed = small_delete;
                },
            }
            r.setClipboard(text, linewise);
        },
    }
}

/// Writes a register directly (macro recording). Does not touch the unnamed
/// register or the clipboard.
pub fn setNamed(r: *Registers, name: u8, text: []const u8) Allocator.Error!void {
    const slot = slotOf(name) orelse return;
    try r.set(slot, text, false);
}

/// Reads a register for pasting. Valid until the next register write.
pub fn get(r: *Registers, name: ?u8) ?Value {
    const n = name orelse '"';
    const slot: usize = switch (n) {
        '"' => r.readClipboard() orelse r.unnamed,
        '+', '*' => r.readClipboard() orelse return null,
        else => slotOf(n) orelse return null,
    };
    const s = &r.slots[slot];
    if (s.text.items.len == 0) return null;
    return .{ .text = s.text.items, .linewise = s.linewise };
}

fn setClipboard(r: *Registers, text: []const u8, linewise: bool) void {
    const cb = r.clipboard orelse return;
    cb.set(r.gpa, text);
    r.clip_last.clearRetainingCapacity();
    r.clip_last.appendSlice(r.gpa, text) catch {};
    r.clip_linewise = linewise;
}

/// The slot holding the clipboard's text, or null to fall back to our own
/// registers (no clipboard, empty, or it still holds what we put there).
fn readClipboard(r: *Registers) ?usize {
    const cb = r.clipboard orelse return null;
    const text = cb.get(r.gpa) orelse return null;
    defer r.gpa.free(text);
    if (text.len == 0) return null;
    if (std.mem.eql(u8, text, r.clip_last.items) and r.slots[r.unnamed].text.items.len > 0 and
        std.mem.eql(u8, text, r.slots[r.unnamed].text.items))
    {
        return null;
    }
    const linewise = if (std.mem.eql(u8, text, r.clip_last.items)) r.clip_linewise else text[text.len - 1] == '\n';
    r.set(scratch, text, linewise) catch return null;
    return scratch;
}

const testing = std.testing;

test "yank, delete and named registers" {
    var r: Registers = .init(testing.allocator);
    defer r.deinit();
    try r.store(null, .yank, "word", false);
    try r.store(null, .delete, "line\n", true);
    try r.store(null, .delete, "x", false);
    try testing.expectEqualStrings("x", r.get(null).?.text); // unnamed = last write
    try testing.expectEqualStrings("word", r.get('0').?.text);
    try testing.expectEqualStrings("line\n", r.get('1').?.text);
    try testing.expectEqualStrings("x", r.get('-').?.text);

    try r.store(null, .delete, "second\n", true);
    try testing.expectEqualStrings("line\n", r.get('2').?.text); // shifted

    try r.store('a', .yank, "foo", false);
    try r.store('A', .yank, "bar", false);
    try testing.expectEqualStrings("foobar", r.get('a').?.text);
    try r.store('_', .delete, "gone", false);
    try testing.expectEqualStrings("foobar", r.get(null).?.text);
}
