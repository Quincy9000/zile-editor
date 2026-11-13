//! What the editor tests share: editors made from text, and waiting helpers.

const std = @import("std");
const testing = std.testing;
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Text = @import("../core/Text.zig");
const sources = @import("../picker/sources.zig");
const Syntax = @import("../syntax/Syntax.zig");
const debugging = @import("../debugging.zig");
const git_ops = @import("../editor/git_ops.zig");
const Editor = @import("../Editor.zig");
const deinit = Editor.deinit;

pub fn testEditor(content: []const u8) !Editor {
    var ed = try Editor.init(testing.allocator, testing.io);
    errdefer ed.deinit();
    try ed.text().insert(ed.gpa, 0, content);
    return ed;
}

/// A test editor whose buffer is a (never written) file named `path`, so it
/// gets that language's syntax tree and settings.
pub fn testEditorAs(path: []const u8, content: []const u8) !Editor {
    var ed = try testEditor(content);
    errdefer ed.deinit();
    ed.buffer.path = try ed.gpa.dupe(u8, path);
    ed.buffer.syntax = Syntax.forPath(path);
    return ed;
}

pub fn expectText(ed: *Editor, expected: []const u8) !void {
    try testing.expectEqualStrings(expected, ed.text().slice(0, ed.text().len()));
}

pub fn expectCursor(ed: *Editor, line: usize, col: usize) !void {
    try testing.expectEqual(line, ed.cursorLine());
    try testing.expectEqual(col, ed.cursorCol());
}

/// An editor whose buffer is diffed against `head` (as if from git).
pub fn ghostEditor(head: []const u8, current: []const u8) !Editor {
    var ed = try testEditor(current);
    errdefer ed.deinit();
    ed.buffer.git = .{ .base = try Text.init(ed.gpa, head) };
    ed.buffer.edit_version += 1;
    git_ops.updateGit(&ed);
    return ed;
}

pub fn waitForRun(ed: *Editor) void {
    while (ed.run.?.isRunning()) std.Thread.yield() catch {};
    ed.tick();
}

/// Lets the picker catch up (results, then a frame for the preview).
pub fn settlePicker(ed: *Editor) void {
    if (ed.picker) |p| p.sync();
    ed.tick();
}

/// A minimal Claude Code CLI for tests: a WebSocket client speaking JSON-RPC.
pub const FakeCli = struct {
    fd: c_int,
    buf: std.ArrayList(u8) = .empty,

    const socketFn = @extern(*const fn (c_uint, c_uint, c_uint) callconv(.c) c_int, .{ .name = "socket" });
    const SockaddrIn = extern struct { family: u16 = 2, port: u16, addr: u32, zero: [8]u8 = @splat(0) };

    pub fn connect(port: u16, token: []const u8) !FakeCli {
        const fd = socketFn(2, 1, 0);
        var addr: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
        if (std.c.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) != 0) return error.Connect;
        var req: [512]u8 = undefined;
        const r = try std.fmt.bufPrint(&req, "GET / HTTP/1.1\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\nSec-WebSocket-Protocol: mcp\r\nX-Claude-Code-Ide-Authorization: {s}\r\n\r\n", .{token});
        _ = std.c.write(fd, r.ptr, r.len);
        var resp: [512]u8 = undefined;
        const n = std.c.read(fd, &resp, resp.len);
        if (n <= 0 or !std.mem.startsWith(u8, resp[0..@intCast(n)], "HTTP/1.1 101")) return error.Handshake;
        return .{ .fd = fd };
    }

    pub fn deinit(f: *FakeCli) void {
        _ = std.c.close(f.fd);
        f.buf.deinit(testing.allocator);
    }

    pub fn send(f: *FakeCli, msg: []const u8) void {
        var frame: std.ArrayList(u8) = .empty;
        defer frame.deinit(testing.allocator);
        frame.append(testing.allocator, 0x81) catch return;
        if (msg.len < 126) {
            frame.append(testing.allocator, 0x80 | @as(u8, @intCast(msg.len))) catch return;
        } else {
            frame.appendSlice(testing.allocator, &.{ 0x80 | 126, @intCast(msg.len >> 8), @intCast(msg.len & 0xff) }) catch return;
        }
        frame.appendSlice(testing.allocator, &.{ 0, 0, 0, 0 }) catch return; // a zero mask
        frame.appendSlice(testing.allocator, msg) catch return;
        _ = std.c.write(f.fd, frame.items.ptr, frame.items.len);
    }

    /// The next message containing `needle`, running the editor's frames
    /// until it arrives (caller frees).
    pub fn expect(f: *FakeCli, ed: *Editor, needle: []const u8) ![]u8 {
        for (0..400) |_| {
            ed.tick();
            while (f.nextFrame()) |msg| {
                if (std.mem.indexOf(u8, msg, needle) != null) return msg;
                testing.allocator.free(msg);
            }
            var fds = [_]std.c.pollfd{.{ .fd = f.fd, .events = std.c.POLL.IN, .revents = 0 }};
            if (std.c.poll(&fds, 1, 10) > 0) {
                var chunk: [64 * 1024]u8 = undefined;
                const n = std.c.read(f.fd, &chunk, chunk.len);
                if (n > 0) try f.buf.appendSlice(testing.allocator, chunk[0..@intCast(n)]);
            }
        }
        return error.Timeout;
    }

    pub fn nextFrame(f: *FakeCli) ?[]u8 {
        const b = f.buf.items;
        if (b.len < 2) return null;
        var len: usize = b[1] & 0x7f;
        var at: usize = 2;
        if (len == 126) {
            if (b.len < 4) return null;
            len = std.mem.readInt(u16, b[2..4], .big);
            at = 4;
        } else if (len == 127) {
            if (b.len < 10) return null;
            len = @intCast(std.mem.readInt(u64, b[2..10], .big));
            at = 10;
        }
        if (b.len < at + len) return null;
        const msg = testing.allocator.dupe(u8, b[at .. at + len]) catch return null;
        f.buf.replaceRangeAssumeCapacity(0, at + len, &.{});
        return msg;
    }
};

pub fn io_sleep(ms: i64) void {
    testing.io.sleep(.fromMilliseconds(ms), .awake) catch {};
}

/// What the debugger shows of the frame a program stops in: `source` is
/// written as `name`, built by `build` (then `src` and, after `out_flag`,
/// the program to make), and stopped on line `stop` (as `G` counts).
pub fn testStoppedVars(gpa: Allocator, name: []const u8, source: []const u8, build: []const []const u8, out_flag: []const u8, stop: []const u8) ![]u8 {
    if (!sources.onPath(testing.io, "gdb") or !sources.onPath(testing.io, build[0])) return error.SkipZigTest;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(testing.io, &dir_buf)];
    try tmp.dir.writeFile(testing.io, .{ .sub_path = name, .data = source });
    const src = try std.fs.path.join(gpa, &.{ dir, name });
    defer gpa.free(src);
    const out = try std.fs.path.join(gpa, &.{ dir, "t" });
    defer gpa.free(out);
    const emit = try std.mem.concat(gpa, u8, &.{ out_flag, out });
    defer gpa.free(emit);
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(gpa);
    try argv.appendSlice(gpa, build);
    try argv.appendSlice(gpa, &.{ src, emit });
    const built = try std.process.run(gpa, testing.io, .{ .argv = argv.items, .cwd = .{ .path = dir } });
    gpa.free(built.stdout);
    gpa.free(built.stderr);
    if (built.term != .exited or built.term.exited != 0) return error.SkipZigTest;

    var ed = try testEditor("");
    defer ed.deinit();
    try ed.openFile(src);
    try ed.feed(stop);
    try ed.feed("G");
    try debugging.toggleBreakpoint(&ed);
    try debugging.start(&ed, out);
    defer debugging.stop(&ed);
    for (0..2000) |_| {
        ed.tick();
        if (ed.dbg.session) |d| if (d.state == .stopped and d.frames.items.len > 0 and d.frames.items[0].vars_left == 0 and d.frames.items[0].vars.items.len > 0) break;
        testing.io.sleep(.fromMilliseconds(5), .awake) catch {};
    } else return error.Timeout;
    var vars: std.ArrayList(u8) = .empty;
    errdefer vars.deinit(gpa);
    try ed.dbg.session.?.frames.items[0].writeVars(gpa, &vars);
    return vars.toOwnedSlice(gpa);
}

pub fn expectVars(vars: []const u8, wanted: []const []const u8) !void {
    errdefer std.debug.print("{s}\n", .{vars});
    for (wanted) |want| try testing.expect(std.mem.indexOf(u8, vars, want) != null);
}
