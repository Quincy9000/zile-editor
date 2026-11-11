//! Brackets a file is missing at its end. A language server that can't parse
//! a file (a `}` forgotten somewhere) loses the types of everything after
//! the mistake; for completion it is sent the file with these appended, so
//! it can still tell what `actor.` is. Never written to the buffer.

const std = @import("std");
const Allocator = std.mem.Allocator;

/// The closing brackets, innermost first, that would balance `text`; empty
/// when it already balances or the mismatch is not a missing end (a stray
/// closer: guessing would only make it worse). Skips strings, character
/// literals and `//` comments.
pub fn closers(gpa: Allocator, text: []const u8) Allocator.Error![]u8 {
    const r = try scan(gpa, text);
    return r.closers;
}

pub const Scan = struct {
    /// Owned; empty when nothing is missing.
    closers: []u8,
    /// Byte offset of the innermost bracket left open.
    innermost: usize = 0,
};

pub fn scan(gpa: Allocator, text: []const u8) Allocator.Error!Scan {
    var stack: std.ArrayList(u8) = .empty;
    defer stack.deinit(gpa);
    var opens: std.ArrayList(usize) = .empty;
    defer opens.deinit(gpa);
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        switch (text[i]) {
            '/' => if (i + 1 < text.len and text[i + 1] == '/') {
                while (i < text.len and text[i] != '\n') i += 1;
            },
            '\\' => if (i + 1 < text.len and text[i + 1] == '\\') {
                // Zig's multi-line string: to the end of the line.
                while (i < text.len and text[i] != '\n') i += 1;
            },
            '"' => {
                i += 1;
                while (i < text.len and text[i] != '"' and text[i] != '\n') : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
            },
            '\'' => {
                // 'x' or '\n': a literal (otherwise a lifetime or a stray).
                if (i + 2 < text.len and text[i + 1] != '\\' and text[i + 2] == '\'') {
                    i += 2;
                } else if (i + 3 < text.len and text[i + 1] == '\\') {
                    var j = i + 2;
                    while (j < text.len and j < i + 12 and text[j] != '\'' and text[j] != '\n') j += 1;
                    if (j < text.len and text[j] == '\'') i = j;
                }
            },
            '(' => {
                try stack.append(gpa, ')');
                try opens.append(gpa, i);
            },
            '[' => {
                try stack.append(gpa, ']');
                try opens.append(gpa, i);
            },
            '{' => {
                try stack.append(gpa, '}');
                try opens.append(gpa, i);
            },
            ')', ']', '}' => |c| {
                if (stack.items.len == 0 or stack.items[stack.items.len - 1] != c) return .{ .closers = &.{} };
                _ = stack.pop();
                _ = opens.pop();
            },
            else => {},
        }
    }
    const out = try gpa.alloc(u8, stack.items.len);
    for (out, 0..) |*o, k| o.* = stack.items[stack.items.len - 1 - k];
    return .{ .closers = out, .innermost = if (opens.items.len > 0) opens.items[opens.items.len - 1] else 0 };
}

test "missing closers, innermost first" {
    const gpa = std.testing.allocator;
    const a = try closers(gpa, "fn f() void {\n  for (x) |i| {\n    foo(i);\n  }\n");
    defer gpa.free(a);
    try std.testing.expectEqualStrings("}", a);
    const b = try closers(gpa, "a = [ f(\"}\", '{', // {\n");
    defer gpa.free(b);
    try std.testing.expectEqualStrings(")]", b);
    const c = try closers(gpa, "ok() { }");
    defer gpa.free(c);
    try std.testing.expectEqual(0, c.len);
    const d = try closers(gpa, "stray) {");
    defer gpa.free(d);
    try std.testing.expectEqual(0, d.len);
}
