//! Compile-checking a standalone `.zig` file (no `build.zig` above it, so
//! zls has no build to check): on open and on save, in the background,
//!   zig ast-check <file>             (syntax: zls shows those, so stop here)
//!   zig build-exe -fno-emit-bin      when the file has `pub fn main`
//!   zig test -fno-emit-bin           when it has tests
//! (each again with -lc if the compiler says it needs libc). The errors in
//! the file become diagnostics. As the nvim config's `zig_check.lua`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const errors = @import("terminal/errors.zig");
const Lsp = @import("lsp/Lsp.zig");

const ZigCheck = @This();

gpa: Allocator,
io: Io,
/// The file (absolute) and its folder; owned.
path: []u8,
dir: []u8,
has_main: bool,
has_test: bool,
wake: *const fn () void,
thread: std.Thread = undefined,
done: std.atomic.Value(bool) = .init(false),
/// Valid once `done`: the file's errors (owned).
diagnostics: std.ArrayList(Lsp.Diagnostic) = .empty,
/// It needed -lc (the next check starts with it).
needed_libc: bool = false,
joined: bool = false,

/// Whether `path` is a Zig file with no `build.zig` in its folder or above.
pub fn wanted(io: Io, path: []const u8) bool {
    if (!std.mem.endsWith(u8, path, ".zig")) return false;
    var dir: ?[]const u8 = std.fs.path.dirname(path);
    while (dir) |d| : (dir = std.fs.path.dirname(d)) {
        var buf: [Io.Dir.max_path_bytes]u8 = undefined;
        const p = std.fmt.bufPrint(&buf, "{s}/build.zig", .{d}) catch return false;
        Io.Dir.cwd().access(io, p, .{}) catch continue;
        return false;
    }
    return true;
}

/// Starts checking `path`, whose text is `text`.
pub fn start(gpa: Allocator, io: Io, path: []const u8, text: []const u8, libc: bool, wake: *const fn () void) !*ZigCheck {
    const c = try gpa.create(ZigCheck);
    errdefer gpa.destroy(c);
    const owned = try gpa.dupe(u8, path);
    errdefer gpa.free(owned);
    const dir = try gpa.dupe(u8, std.fs.path.dirname(path) orelse "/");
    errdefer gpa.free(dir);
    c.* = .{
        .gpa = gpa,
        .io = io,
        .path = owned,
        .dir = dir,
        .has_main = std.mem.indexOf(u8, text, "pub fn main") != null,
        .has_test = std.mem.indexOf(u8, text, "test \"") != null or std.mem.indexOf(u8, text, "test {") != null,
        .wake = wake,
        .needed_libc = libc,
    };
    c.thread = try std.Thread.spawn(.{}, run, .{c});
    return c;
}

/// Waits for the check to finish (tests).
pub fn wait(c: *ZigCheck) void {
    if (c.joined) return;
    c.thread.join();
    c.joined = true;
}

pub fn destroy(c: *ZigCheck) void {
    c.wait();
    for (c.diagnostics.items) |d| c.gpa.free(d.message);
    c.diagnostics.deinit(c.gpa);
    c.gpa.free(c.path);
    c.gpa.free(c.dir);
    c.gpa.destroy(c);
}

fn run(c: *ZigCheck) void {
    defer {
        c.done.store(true, .release);
        c.wake();
    }
    const name = std.fs.path.basename(c.path);
    const ast = c.exec(&.{ "zig", "ast-check", name }) orelse return;
    defer c.gpa.free(ast.stderr);
    if (!ast.ok) return;
    const Cmd = struct { want: bool, argv: []const []const u8 };
    for ([_]Cmd{
        .{ .want = c.has_main, .argv = &.{ "zig", "build-exe", "-fno-emit-bin", name } },
        .{ .want = c.has_test, .argv = &.{ "zig", "test", "-fno-emit-bin", name } },
    }) |cmd| {
        if (!cmd.want) continue;
        var res = c.compile(cmd.argv, c.needed_libc) orelse continue;
        if (!c.needed_libc and needsLibc(res.stderr)) {
            c.gpa.free(res.stderr);
            c.needed_libc = true;
            res = c.compile(cmd.argv, true) orelse continue;
        }
        defer c.gpa.free(res.stderr);
        c.collect(res.stderr) catch {};
    }
}

fn needsLibc(stderr: []const u8) bool {
    return std.mem.indexOf(u8, stderr, "libc") != null and
        (std.mem.indexOf(u8, stderr, "must be explicitly specified") != null or std.mem.indexOf(u8, stderr, "link libc") != null or std.mem.indexOf(u8, stderr, "libc headers") != null);
}

const Result = struct { ok: bool, stderr: []u8 };

fn compile(c: *ZigCheck, argv: []const []const u8, libc: bool) ?Result {
    if (!libc) return c.exec(argv);
    var with: [8][]const u8 = undefined;
    @memcpy(with[0..argv.len], argv);
    with[argv.len] = "-lc";
    return c.exec(with[0 .. argv.len + 1]);
}

fn exec(c: *ZigCheck, argv: []const []const u8) ?Result {
    const r = std.process.run(c.gpa, c.io, .{ .argv = argv, .cwd = .{ .path = c.dir } }) catch return null;
    c.gpa.free(r.stdout);
    const ok = r.term == .exited and r.term.exited == 0;
    return .{ .ok = ok, .stderr = r.stderr };
}

/// The errors in this file, once each (one reachable from both `main` and
/// a test is reported by both).
fn collect(c: *ZigCheck, stderr: []const u8) !void {
    var found: std.ArrayList(errors.Error) = .empty;
    defer {
        for (found.items) |e| e.deinit(c.gpa);
        found.deinit(c.gpa);
    }
    const Ctx = struct {
        fn any(_: *ZigCheck, _: []const u8) bool {
            return true;
        }
    };
    try errors.parse(c.gpa, stderr, c, Ctx.any, &found);
    const name = std.fs.path.basename(c.path);
    for (found.items) |e| {
        if (e.severity == .note) continue;
        // Paths are as the compiler printed them: relative to the folder.
        const same = std.mem.eql(u8, e.path, name) or std.mem.eql(u8, e.path, c.path) or
            (std.mem.endsWith(u8, c.path, e.path) and c.path.len > e.path.len and c.path[c.path.len - e.path.len - 1] == '/');
        if (!same) continue;
        const line: u32 = e.line -| 1;
        const col: u32 = e.col -| 1;
        const dup = for (c.diagnostics.items) |d| {
            if (d.line == line and d.col == col and std.mem.eql(u8, d.message, e.message)) break true;
        } else false;
        if (dup) continue;
        try c.diagnostics.append(c.gpa, .{
            .line = line,
            .col = col,
            .end_line = line,
            .end_col = col + 1,
            .severity = if (e.severity == .warning) .warning else .err,
            .message = try c.gpa.dupe(u8, e.message),
        });
    }
}

test "standalone files only" {
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    try tmp.dir.createDirPath(std.testing.io, "proj/src");
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "proj/build.zig", .data = "" });
    var p1: [Io.Dir.max_path_bytes]u8 = undefined;
    try std.testing.expect(!wanted(std.testing.io, try std.fmt.bufPrint(&p1, "{s}/proj/src/main.zig", .{dir})));
    // (Test folders sit inside zile's own checkout, under its build.zig.)
    try std.testing.expect(wanted(std.testing.io, "/zile-test-nowhere/loose.zig"));
    try std.testing.expect(!wanted(std.testing.io, try std.fmt.bufPrint(&p1, "{s}/notes.md", .{dir})));
}

test "a type error in a standalone file becomes a diagnostic" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const src = "pub fn main() void {\n    const x: u8 = \"no\";\n    _ = x;\n}\n";
    try tmp.dir.writeFile(std.testing.io, .{ .sub_path = "a.zig", .data = src });
    var buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = buf[0..try tmp.dir.realPath(std.testing.io, &buf)];
    const path = try std.fs.path.join(gpa, &.{ dir, "a.zig" });
    defer gpa.free(path);
    const noop = struct {
        fn wake() void {}
    }.wake;
    const c = try start(gpa, std.testing.io, path, src, false, noop);
    defer c.destroy();
    c.wait();
    // (zig is here: it builds these tests.)
    try std.testing.expectEqual(1, c.diagnostics.items.len);
    try std.testing.expectEqual(1, c.diagnostics.items[0].line);
}
