//! Finds compiler errors in a run's output: `path:line:col: message` (Zig,
//! C/C++, Go, TypeScript...), Rust's `--> path:line:col` (message on the
//! line above), and Python's `File "path", line N`. Escape sequences are
//! stripped first; only paths that exist count (so `http://x:80` doesn't).

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Severity = enum { err, warning, note };

pub const Error = struct {
    /// Owned.
    path: []u8,
    /// 1-based, as compilers print them (column 1 when absent).
    line: u32,
    col: u32,
    /// Owned.
    message: []u8,
    severity: Severity,

    pub fn deinit(e: Error, gpa: Allocator) void {
        gpa.free(e.path);
        gpa.free(e.message);
    }
};

/// Appends the errors in `output` to `out`. `exists` decides whether a path
/// is a real file (relative paths are relative to where the command ran).
pub fn parse(gpa: Allocator, output: []const u8, ctx: anytype, comptime exists: fn (@TypeOf(ctx), []const u8) bool, out: *std.ArrayList(Error)) !void {
    const plain = try stripEscapes(gpa, output);
    defer gpa.free(plain);
    var prev: []const u8 = "";
    var lines = std.mem.splitScalar(u8, plain, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trimEnd(u8, raw, " \t");
        defer prev = line;
        if (try parseLine(gpa, line, prev, ctx, exists)) |e| {
            // The same place twice (e.g. error and its note) keeps the first.
            const dup = for (out.items) |o| {
                if (o.line == e.line and o.col == e.col and std.mem.eql(u8, o.path, e.path)) break true;
            } else false;
            if (dup) e.deinit(gpa) else try out.append(gpa, e);
        }
    }
}

fn parseLine(gpa: Allocator, line: []const u8, prev: []const u8, ctx: anytype, comptime exists: anytype) !?Error {
    const trimmed = std.mem.trimStart(u8, line, " \t");
    // Rust: "  --> src/main.rs:3:5", the message is the line before.
    if (std.mem.startsWith(u8, trimmed, "--> ")) {
        const loc = location(trimmed[4..]) orelse return null;
        if (!exists(ctx, loc.path)) return null;
        const msg = std.mem.trim(u8, prev, " \t");
        return try make(gpa, loc.path, loc.line, loc.col, msg);
    }
    // Python: '  File "app.py", line 3, in main'
    if (std.mem.startsWith(u8, trimmed, "File \"")) {
        const rest = trimmed[6..];
        const q = std.mem.indexOfScalar(u8, rest, '"') orelse return null;
        const path = rest[0..q];
        const after = rest[q + 1 ..];
        const key = ", line ";
        if (!std.mem.startsWith(u8, after, key)) return null;
        const n = digits(after[key.len..]);
        if (n.len == 0 or !exists(ctx, path)) return null;
        const num = std.fmt.parseInt(u32, n, 10) catch return null;
        return try make(gpa, path, num, 1, trimmed);
    }
    // "path:line:col: message" / "path:line: message" anywhere on the line
    // (after a prefix like "error: " some tools print first).
    var start: usize = 0;
    while (start < trimmed.len) {
        const loc = location(trimmed[start..]) orelse {
            // Try after the next space.
            const sp = std.mem.indexOfScalarPos(u8, trimmed, start, ' ') orelse return null;
            start = sp + 1;
            continue;
        };
        if (!exists(ctx, loc.path)) {
            const sp = std.mem.indexOfScalarPos(u8, trimmed, start, ' ') orelse return null;
            start = sp + 1;
            continue;
        }
        const msg = std.mem.trim(u8, std.mem.trimStart(u8, trimmed[start + loc.len ..], ":"), " \t");
        return try make(gpa, loc.path, loc.line, loc.col, if (msg.len > 0) msg else trimmed);
    }
    return null;
}

const Loc = struct { path: []const u8, line: u32, col: u32, len: usize };

/// "path:line[:col]" at the start of `s`.
fn location(s: []const u8) ?Loc {
    // The path runs to the first ":<digit>" (paths may contain ':' rarely;
    // drive letters don't occur on Linux).
    var i: usize = 0;
    while (i + 1 < s.len) : (i += 1) {
        if (s[i] == ' ' or s[i] == '\t' or s[i] == '(' or s[i] == '\'' or s[i] == '"') return null;
        if (s[i] == ':' and std.ascii.isDigit(s[i + 1])) break;
    } else return null;
    if (i == 0) return null;
    const path = s[0..i];
    var rest = s[i + 1 ..];
    const ln = digits(rest);
    const line = std.fmt.parseInt(u32, ln, 10) catch return null;
    rest = rest[ln.len..];
    var len = i + 1 + ln.len;
    var col: u32 = 1;
    if (rest.len > 1 and rest[0] == ':' and std.ascii.isDigit(rest[1])) {
        const cn = digits(rest[1..]);
        col = std.fmt.parseInt(u32, cn, 10) catch 1;
        len += 1 + cn.len;
    }
    if (line == 0) return null;
    return .{ .path = path, .line = line, .col = @max(col, 1), .len = len };
}

fn digits(s: []const u8) []const u8 {
    var n: usize = 0;
    while (n < s.len and std.ascii.isDigit(s[n])) n += 1;
    return s[0..n];
}

fn make(gpa: Allocator, path: []const u8, line: u32, col: u32, msg: []const u8) !Error {
    const lower_has = struct {
        fn f(s: []const u8, word: []const u8) bool {
            return std.ascii.findIgnoreCase(s, word) != null;
        }
    }.f;
    const severity: Severity = if (lower_has(msg, "error")) .err else if (lower_has(msg, "warning")) .warning else if (lower_has(msg, "note")) .note else .err;
    const p = try gpa.dupe(u8, path);
    errdefer gpa.free(p);
    return .{ .path = p, .line = line, .col = col, .message = try gpa.dupe(u8, msg), .severity = severity };
}

/// Output as plain text: escape sequences removed, "\r\n" as "\n", and a
/// lone "\r" (progress bars redrawing a line) restarting the line.
pub fn stripEscapes(gpa: Allocator, s: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = try .initCapacity(gpa, s.len);
    errdefer out.deinit(gpa);
    var line_start: usize = 0;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const b = s[i];
        switch (b) {
            0x1b => {
                if (i + 1 >= s.len) break;
                const kind = s[i + 1];
                i += 1;
                if (kind == '[') {
                    // CSI: parameters, then a final byte 0x40-0x7e.
                    while (i + 1 < s.len) {
                        i += 1;
                        if (s[i] >= 0x40 and s[i] <= 0x7e) break;
                    }
                } else if (kind == ']' or kind == 'P' or kind == '_') {
                    // OSC/DCS/APC: until BEL or ESC \.
                    while (i + 1 < s.len) {
                        i += 1;
                        if (s[i] == 0x07) break;
                        if (s[i] == 0x1b and i + 1 < s.len and s[i + 1] == '\\') {
                            i += 1;
                            break;
                        }
                    }
                }
            },
            '\r' => {
                if (i + 1 < s.len and s[i + 1] == '\n') continue;
                out.items.len = line_start;
            },
            '\n' => {
                out.appendAssumeCapacity('\n');
                line_start = out.items.len;
            },
            else => if (b >= 0x20 or b == '\t') out.appendAssumeCapacity(b),
        }
    }
    return out.toOwnedSlice(gpa);
}

const testing = std.testing;

fn fakeExists(_: void, path: []const u8) bool {
    return !std.mem.startsWith(u8, path, "http");
}

fn testParse(output: []const u8) !std.ArrayList(Error) {
    var out: std.ArrayList(Error) = .empty;
    try parse(testing.allocator, output, {}, fakeExists, &out);
    return out;
}

fn freeAll(list: *std.ArrayList(Error)) void {
    for (list.items) |e| e.deinit(testing.allocator);
    list.deinit(testing.allocator);
}

test "zig, gcc and go style errors" {
    var errs = try testParse(
        "install\n+- compile exe zile Debug native 1 errors\n" ++
            "\x1b[1msrc/main.zig:12:5: \x1b[31merror:\x1b[0m use of undeclared identifier 'x'\r\n" ++
            "    x += 1;\n    ^\n" ++
            "src/main.zig:3:1: note: declared here\n" ++
            "foo.c:7: warning: unused variable\n" ++
            "see http://example.com:80/x for help\n",
    );
    defer freeAll(&errs);
    try testing.expectEqual(3, errs.items.len);
    try testing.expectEqualStrings("src/main.zig", errs.items[0].path);
    try testing.expectEqual(12, errs.items[0].line);
    try testing.expectEqual(5, errs.items[0].col);
    try testing.expectEqualStrings("error: use of undeclared identifier 'x'", errs.items[0].message);
    try testing.expectEqual(.err, errs.items[0].severity);
    try testing.expectEqual(.note, errs.items[1].severity);
    try testing.expectEqual(1, errs.items[2].col);
    try testing.expectEqual(.warning, errs.items[2].severity);
}

test "rust and python" {
    var errs = try testParse(
        "error[E0425]: cannot find value `y` in this scope\n" ++
            "  --> src/main.rs:4:13\n" ++
            "Traceback (most recent call last):\n" ++
            "  File \"app.py\", line 9, in <module>\n",
    );
    defer freeAll(&errs);
    try testing.expectEqual(2, errs.items.len);
    try testing.expectEqualStrings("src/main.rs", errs.items[0].path);
    try testing.expectEqual(13, errs.items[0].col);
    try testing.expectEqualStrings("error[E0425]: cannot find value `y` in this scope", errs.items[0].message);
    try testing.expectEqualStrings("app.py", errs.items[1].path);
    try testing.expectEqual(9, errs.items[1].line);
}

test "progress lines redrawn with \\r are dropped" {
    const plain = try stripEscapes(testing.allocator, "[1/3] a\r[2/3] b\r[3/3] c\ndone\r\n");
    defer testing.allocator.free(plain);
    try testing.expectEqualStrings("[3/3] c\ndone\n", plain);
}
