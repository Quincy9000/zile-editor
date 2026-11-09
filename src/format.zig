//! Formatting without a language server (or one that doesn't format): the
//! language's usual formatter, fed the buffer on stdin.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const formatters = [_]struct { lang: []const u8, argv: []const []const u8 }{
    .{ .lang = "zig", .argv = &.{ "zig", "fmt", "--stdin" } },
    .{ .lang = "rust", .argv = &.{ "rustfmt", "--emit", "stdout" } },
    .{ .lang = "c", .argv = &.{"clang-format"} },
    .{ .lang = "python", .argv = &.{ "ruff", "format", "-" } },
    .{ .lang = "json", .argv = &.{ "jq", "." } },
};

pub const Result = union(enum) {
    /// The formatted text (owned).
    ok: []u8,
    /// No formatter for this language, or it isn't installed.
    none,
    /// It ran and refused (e.g. a syntax error): the first line it printed (owned).
    failed: []u8,
};

/// The formatter's name for messages ("zig fmt"), if the language has one.
pub fn name(lang: []const u8) ?[]const u8 {
    for (formatters) |f| if (std.mem.eql(u8, f.lang, lang)) return f.argv[0];
    return null;
}

/// Formats `text` (in language `lang`), running in `cwd` so project config
/// files (.clang-format, rustfmt.toml) apply.
pub fn run(gpa: Allocator, io: Io, lang: []const u8, text: []const u8, cwd: []const u8) !Result {
    const f = for (formatters) |f| {
        if (std.mem.eql(u8, f.lang, lang)) break f;
    } else return .none;
    var child = std.process.spawn(io, .{
        .argv = f.argv,
        .cwd = .{ .path = cwd },
        .stdin = .pipe,
        .stdout = .pipe,
        .stderr = .pipe,
    }) catch return .none; // not installed
    // Formatters read all their input before writing, so this can't deadlock.
    child.stdin.?.writeStreamingAll(io, text) catch {};
    child.stdin.?.close(io);
    child.stdin = null;
    const out = try readAll(gpa, io, child.stdout.?);
    errdefer gpa.free(out);
    const err_text = try readAll(gpa, io, child.stderr.?);
    defer gpa.free(err_text);
    const term = child.wait(io) catch return .none;
    if (term == .exited and term.exited == 0) return .{ .ok = out };
    gpa.free(out);
    const first = std.mem.trim(u8, std.mem.sliceTo(err_text, '\n'), " \t\r");
    return .{ .failed = try gpa.dupe(u8, if (first.len > 0) first else "failed") };
}

fn readAll(gpa: Allocator, io: Io, file: Io.File) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var chunk: [64 * 1024]u8 = undefined;
    while (true) {
        const n = file.readStreaming(io, &.{&chunk}) catch break;
        if (n == 0) break;
        try out.appendSlice(gpa, chunk[0..n]);
    }
    return out.toOwnedSlice(gpa);
}

test "zig fmt formats, and reports syntax errors" {
    const gpa = std.testing.allocator;
    const io = std.testing.io;
    switch (try run(gpa, io, "zig", "const  x=1;\n", "/")) {
        .ok => |out| {
            defer gpa.free(out);
            try std.testing.expectEqualStrings("const x = 1;\n", out);
        },
        .none => return error.SkipZigTest,
        .failed => |m| {
            gpa.free(m);
            return error.TestUnexpectedResult;
        },
    }
    switch (try run(gpa, io, "zig", "const x = ;\n", "/")) {
        .failed => |m| gpa.free(m),
        .ok => |out| {
            gpa.free(out);
            return error.TestUnexpectedResult;
        },
        .none => {},
    }
    try std.testing.expectEqual(Result.none, try run(gpa, io, "cobol", "x", "/"));
}
