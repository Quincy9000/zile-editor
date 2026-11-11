//! The hex view of a binary file, as `xxd` writes it:
//!
//!   00000000: 7f45 4c46 0201 0100 0000 0000 0000 0000  .ELF............
//!
//! A buffer shows a binary file this way; you edit the hex digits, and saving
//! reads them back into bytes, top to bottom (the offsets and the text column
//! are only for reading: bytes can be added or removed).

const std = @import("std");
const Allocator = std.mem.Allocator;

const per_line = 16;

/// Binary: a NUL byte near the start (as git and grep decide).
pub fn isBinary(data: []const u8) bool {
    return std.mem.indexOfScalar(u8, data[0..@min(data.len, 8192)], 0) != null;
}

/// The dump of `bytes`, one line per 16 (no newline after the last). Caller
/// frees.
pub fn dump(gpa: Allocator, bytes: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.ensureTotalCapacity(gpa, (bytes.len / per_line + 1) * 68);
    var at: usize = 0;
    while (at < bytes.len) : (at += per_line) {
        if (at > 0) try out.append(gpa, '\n');
        const row = bytes[at..@min(at + per_line, bytes.len)];
        try out.print(gpa, "{x:0>8}:", .{at});
        for (0..per_line) |i| {
            if (i % 2 == 0) try out.append(gpa, ' ');
            if (i < row.len) try out.print(gpa, "{x:0>2}", .{row[i]}) else try out.appendSlice(gpa, "  ");
        }
        try out.appendSlice(gpa, "  ");
        for (row) |b| try out.append(gpa, if (b >= 0x20 and b < 0x7f) b else '.');
    }
    return out.toOwnedSlice(gpa);
}

/// The bytes a dump stands for: the hex digits of every line, between its
/// `:` and the two spaces before its text. Caller frees.
pub fn parse(gpa: Allocator, text: []const u8) error{ InvalidHex, OutOfMemory }![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, "\r");
        if (std.mem.trim(u8, line, " \t").len == 0) continue;
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse return error.InvalidHex;
        var rest = line[colon + 1 ..];
        // The hex ends at the two spaces before the text column.
        if (std.mem.indexOf(u8, std.mem.trimStart(u8, rest, " "), "  ")) |end| {
            const lead = rest.len - std.mem.trimStart(u8, rest, " ").len;
            rest = rest[0 .. lead + end];
        }
        var digit: ?u8 = null;
        for (rest) |c| {
            if (c == ' ' or c == '\t') continue;
            const v = std.fmt.charToDigit(c, 16) catch return error.InvalidHex;
            if (digit) |hi| {
                try out.append(gpa, hi * 16 + v);
                digit = null;
            } else digit = v;
        }
        if (digit != null) return error.InvalidHex; // half a byte
    }
    return out.toOwnedSlice(gpa);
}

test "dump and parse round-trip, partial last line, edits" {
    const gpa = std.testing.allocator;
    const bytes = "\x7fELF\x02\x01\x01\x00hello, world!\x00\xff";
    const d = try dump(gpa, bytes);
    defer gpa.free(d);
    try std.testing.expect(std.mem.startsWith(u8, d, "00000000: 7f45 4c46 0201 0100 6865 6c6c 6f2c 2077  .ELF....hello, w\n00000010: 6f72 6c64 2100 ff"));
    const back = try parse(gpa, d);
    defer gpa.free(back);
    try std.testing.expectEqualSlices(u8, bytes, back);
    // An edited byte, an added one, the text column ignored.
    const edited = try parse(gpa, "00000000: 41 42 43  whatever\n00000003: 4400");
    defer gpa.free(edited);
    try std.testing.expectEqualSlices(u8, "ABCD\x00", edited);
    try std.testing.expectError(error.InvalidHex, parse(gpa, "00000000: 4g"));
    try std.testing.expectError(error.InvalidHex, parse(gpa, "00000000: 414"));
    try std.testing.expect(isBinary("a\x00b"));
    try std.testing.expect(!isBinary("plain text"));
}
