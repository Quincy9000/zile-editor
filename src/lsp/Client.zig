//! A language server over stdio: JSON-RPC with `Content-Length` framing.
//!
//! A reader thread splits the server's output into messages and queues them;
//! the main thread takes them with `takeMessages` (and is woken via `wake`).
//! Writes happen on the main thread. Messages sent before the server answers
//! `initialize` are held back until it does.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Client = @This();

gpa: Allocator,
io: Io,
child: std.process.Child,
reader: std.Thread,
wake: *const fn () void,

mutex: Io.Mutex = .init,
/// Message bodies from the server (owned), guarded by `mutex`.
inbox: std.ArrayList([]u8) = .empty,
/// The server's output ended (it exited or crashed). Guarded by `mutex`.
closed: bool = false,

next_id: i64 = 1,
/// The server answered `initialize`; until then non-initialize messages wait.
ready: bool = false,
held: std.ArrayList([]u8) = .empty,

pub fn start(gpa: Allocator, io: Io, argv: []const []const u8, wake: *const fn () void) !*Client {
    const c = try gpa.create(Client);
    errdefer gpa.destroy(c);
    c.* = .{
        .gpa = gpa,
        .io = io,
        .wake = wake,
        .reader = undefined,
        .child = try std.process.spawn(io, .{
            .argv = argv,
            .stdin = .pipe,
            .stdout = .pipe,
            .stderr = .ignore,
        }),
    };
    errdefer c.child.kill(io);
    c.reader = try std.Thread.spawn(.{}, readLoop, .{c});
    return c;
}

pub fn deinit(c: *Client) void {
    // Killing the server ends its output, which ends the reader thread.
    c.child.kill(c.io);
    c.reader.join();
    for (c.inbox.items) |m| c.gpa.free(m);
    c.inbox.deinit(c.gpa);
    for (c.held.items) |m| c.gpa.free(m);
    c.held.deinit(c.gpa);
    c.gpa.destroy(c);
}

/// Moves received messages into `out` (caller frees each). Returns false once
/// the server has gone away.
pub fn takeMessages(c: *Client, out: *std.ArrayList([]u8)) bool {
    c.mutex.lockUncancelable(c.io);
    defer c.mutex.unlock(c.io);
    out.appendSlice(c.gpa, c.inbox.items) catch return !c.closed;
    c.inbox.clearRetainingCapacity();
    return !c.closed;
}

fn readLoop(c: *Client) void {
    defer {
        c.mutex.lockUncancelable(c.io);
        c.closed = true;
        c.mutex.unlock(c.io);
        c.wake();
    }
    const stdout = c.child.stdout orelse return;
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(c.gpa);
    var chunk: [16 * 1024]u8 = undefined;
    while (true) {
        const n = stdout.readStreaming(c.io, &.{&chunk}) catch return;
        buf.appendSlice(c.gpa, chunk[0..n]) catch return;
        // Extract every complete message.
        while (true) {
            const header_end = std.mem.indexOf(u8, buf.items, "\r\n\r\n") orelse break;
            const len = contentLength(buf.items[0..header_end]) orelse return;
            const total = header_end + 4 + len;
            if (buf.items.len < total) break;
            const body = c.gpa.dupe(u8, buf.items[header_end + 4 .. total]) catch return;
            buf.replaceRangeAssumeCapacity(0, total, &.{});
            c.mutex.lockUncancelable(c.io);
            c.inbox.append(c.gpa, body) catch c.gpa.free(body);
            c.mutex.unlock(c.io);
            c.wake();
        }
    }
}

fn contentLength(header: []const u8) ?usize {
    var lines = std.mem.splitSequence(u8, header, "\r\n");
    while (lines.next()) |line| {
        const name = "Content-Length:";
        if (std.ascii.startsWithIgnoreCase(line, name)) {
            return std.fmt.parseInt(usize, std.mem.trim(u8, line[name.len..], " "), 10) catch null;
        }
    }
    return null;
}

/// Sends a request; returns its id.
pub fn request(c: *Client, method: []const u8, params: anytype) !i64 {
    const id = c.next_id;
    c.next_id += 1;
    try c.write(.{ .jsonrpc = "2.0", .id = id, .method = method, .params = params }, std.mem.eql(u8, method, "initialize"));
    return id;
}

pub fn notify(c: *Client, method: []const u8, params: anytype) !void {
    try c.write(.{ .jsonrpc = "2.0", .method = method, .params = params }, false);
}

/// Sends a notification immediately, even before `markReady`.
pub fn notifyNow(c: *Client, method: []const u8, params: anytype) !void {
    try c.write(.{ .jsonrpc = "2.0", .method = method, .params = params }, true);
}

/// Answers a request from the server.
pub fn respond(c: *Client, id: std.json.Value, result: anytype) !void {
    try c.write(.{ .jsonrpc = "2.0", .id = id, .result = result }, true);
}

/// Marks the server initialized and sends everything held back.
pub fn markReady(c: *Client) !void {
    c.ready = true;
    for (c.held.items) |m| {
        defer c.gpa.free(m);
        try c.sendRaw(m);
    }
    c.held.clearRetainingCapacity();
}

fn write(c: *Client, msg: anytype, always: bool) !void {
    const body = try std.json.Stringify.valueAlloc(c.gpa, msg, .{ .emit_null_optional_fields = false });
    if (!c.ready and !always) return c.held.append(c.gpa, body);
    defer c.gpa.free(body);
    try c.sendRaw(body);
}

fn sendRaw(c: *Client, body: []const u8) !void {
    const stdin = c.child.stdin orelse return error.ServerGone;
    var header: [64]u8 = undefined;
    try stdin.writeStreamingAll(c.io, try std.fmt.bufPrint(&header, "Content-Length: {d}\r\n\r\n", .{body.len}));
    try stdin.writeStreamingAll(c.io, body);
}

// ---------------------------------------------------------------------------
// URIs

/// `file://` URI for an absolute path, percent-encoding unsafe bytes.
pub fn uriFromPath(gpa: Allocator, abs_path: []const u8) Allocator.Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, "file://");
    for (abs_path) |b| {
        if (std.ascii.isAlphanumeric(b) or std.mem.indexOfScalar(u8, "-._~/", b) != null) {
            try out.append(gpa, b);
        } else {
            try out.print(gpa, "%{X:0>2}", .{b});
        }
    }
    return out.toOwnedSlice(gpa);
}

/// The path of a `file://` URI, or null for other schemes.
pub fn pathFromUri(gpa: Allocator, uri: []const u8) Allocator.Error!?[]u8 {
    const prefix = "file://";
    if (!std.mem.startsWith(u8, uri, prefix)) return null;
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var i: usize = prefix.len;
    while (i < uri.len) : (i += 1) {
        if (uri[i] == '%' and i + 2 < uri.len) {
            if (std.fmt.parseInt(u8, uri[i + 1 .. i + 3], 16)) |b| {
                try out.append(gpa, b);
                i += 2;
                continue;
            } else |_| {}
        }
        try out.append(gpa, uri[i]);
    }
    return try out.toOwnedSlice(gpa);
}

test "uri round trip" {
    const gpa = std.testing.allocator;
    const uri = try uriFromPath(gpa, "/home/me/my code/a+b.zig");
    defer gpa.free(uri);
    try std.testing.expectEqualStrings("file:///home/me/my%20code/a%2Bb.zig", uri);
    const path = (try pathFromUri(gpa, uri)).?;
    defer gpa.free(path);
    try std.testing.expectEqualStrings("/home/me/my code/a+b.zig", path);
}

test "framing" {
    try std.testing.expectEqual(42, contentLength("Content-Length: 42\r\nContent-Type: x"));
    try std.testing.expectEqual(null, contentLength("X: 1"));
}
