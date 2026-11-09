//! A small WebSocket server on 127.0.0.1 for Claude Code's IDE connection:
//! the CLI connects with an auth token (`X-Claude-Code-Ide-Authorization`)
//! and speaks JSON-RPC (MCP), one message per text frame.
//!
//! A server thread accepts connections, checks the upgrade request, decodes
//! frames (answering ping and close itself) and queues each text message;
//! the main thread takes them with `poll` and answers with `send`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const WsServer = @This();

pub const Message = struct {
    conn: u32,
    /// The JSON text (owned).
    text: []u8,
};

const Conn = struct {
    id: u32,
    fd: c_int,
    /// Upgraded to WebSocket (before: reading the HTTP request).
    open: bool = false,
    in: std.ArrayList(u8) = .empty,
    /// A message being reassembled from fragments.
    partial: std.ArrayList(u8) = .empty,
};

gpa: Allocator,
io: Io,
wake: *const fn () void,
token: []const u8,
listen_fd: c_int,
port: u16,
thread: std.Thread = undefined,
mutex: Io.Mutex = .init,
// Guarded by `mutex`.
conns: std.ArrayList(*Conn) = .empty,
inbox: std.ArrayList(Message) = .empty,
/// Connections that closed since the last `poll` (their ids).
closed: std.ArrayList(u32) = .empty,
stop: std.atomic.Value(bool) = .init(false),
next_id: u32 = 1,

extern "c" fn socket(domain: c_uint, sock_type: c_uint, protocol: c_uint) c_int;
const AF_INET = 2;
const SOCK_STREAM = 1;
const SOL_SOCKET = 1;
const SO_REUSEADDR = 2;
const MSG_NOSIGNAL = 0x4000;

const SockaddrIn = extern struct {
    family: u16 = AF_INET,
    port: u16,
    addr: u32,
    zero: [8]u8 = @splat(0),
};

/// Listens on 127.0.0.1 (a free port) for clients presenting `token`.
pub fn start(gpa: Allocator, io: Io, wake: *const fn () void, token: []const u8) !*WsServer {
    const fd = socket(AF_INET, SOCK_STREAM, 0);
    if (fd < 0) return error.Socket;
    errdefer _ = std.c.close(fd);
    const one: c_int = 1;
    _ = std.c.setsockopt(fd, SOL_SOCKET, SO_REUSEADDR, &one, @sizeOf(c_int));
    var addr: SockaddrIn = .{ .port = 0, .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    if (std.c.bind(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)) != 0) return error.Bind;
    if (std.c.listen(fd, 8) != 0) return error.Listen;
    var len: std.c.socklen_t = @sizeOf(SockaddrIn);
    if (std.c.getsockname(fd, @ptrCast(&addr), &len) != 0) return error.Bind;

    const s = try gpa.create(WsServer);
    errdefer gpa.destroy(s);
    s.* = .{ .gpa = gpa, .io = io, .wake = wake, .token = try gpa.dupe(u8, token), .listen_fd = fd, .port = std.mem.bigToNative(u16, addr.port) };
    s.thread = try std.Thread.spawn(.{}, run, .{s});
    return s;
}

pub fn destroy(s: *WsServer) void {
    s.stop.store(true, .release);
    s.thread.join();
    _ = std.c.close(s.listen_fd);
    for (s.conns.items) |c| s.freeConn(c);
    s.conns.deinit(s.gpa);
    for (s.inbox.items) |m| s.gpa.free(m.text);
    s.inbox.deinit(s.gpa);
    s.closed.deinit(s.gpa);
    s.gpa.free(s.token);
    s.gpa.destroy(s);
}

fn freeConn(s: *WsServer, c: *Conn) void {
    _ = std.c.close(c.fd);
    c.in.deinit(s.gpa);
    c.partial.deinit(s.gpa);
    s.gpa.destroy(c);
}

/// The next message from a client, if any (caller owns its text).
pub fn poll(s: *WsServer) ?Message {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    if (s.inbox.items.len == 0) return null;
    return s.inbox.orderedRemove(0);
}

/// A connection that closed since the last call, if any.
pub fn pollClosed(s: *WsServer) ?u32 {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    return s.closed.pop();
}

/// How many clients are connected (upgraded).
pub fn connected(s: *WsServer) usize {
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    var n: usize = 0;
    for (s.conns.items) |c| n += @intFromBool(c.open);
    return n;
}

/// Sends a text message to client `conn` (0: every client).
pub fn send(s: *WsServer, conn: u32, text: []const u8) void {
    var head: [10]u8 = undefined;
    const h = frameHeader(&head, 0x1, text.len);
    // One write per frame.
    const frame_bytes = std.mem.concat(s.gpa, u8, &.{ h, text }) catch return;
    defer s.gpa.free(frame_bytes);
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    for (s.conns.items) |c| if (c.open and (conn == 0 or c.id == conn)) writeAll(c.fd, frame_bytes);
}

fn frameHeader(buf: *[10]u8, opcode: u8, len: usize) []const u8 {
    buf[0] = 0x80 | opcode; // FIN
    if (len < 126) {
        buf[1] = @intCast(len);
        return buf[0..2];
    }
    if (len <= 0xffff) {
        buf[1] = 126;
        std.mem.writeInt(u16, buf[2..4], @intCast(len), .big);
        return buf[0..4];
    }
    buf[1] = 127;
    std.mem.writeInt(u64, buf[2..10], len, .big);
    return buf[0..10];
}

fn writeAll(fd: c_int, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.send(fd, rest.ptr, rest.len, MSG_NOSIGNAL);
        if (n <= 0) {
            if (n < 0 and std.c.errno(n) == .INTR) continue;
            return;
        }
        rest = rest[@intCast(n)..];
    }
}

fn run(s: *WsServer) void {
    var fds: std.ArrayList(std.c.pollfd) = .empty;
    defer fds.deinit(s.gpa);
    while (!s.stop.load(.acquire)) {
        fds.clearRetainingCapacity();
        fds.append(s.gpa, .{ .fd = s.listen_fd, .events = std.c.POLL.IN, .revents = 0 }) catch return;
        s.mutex.lockUncancelable(s.io);
        for (s.conns.items) |c| fds.append(s.gpa, .{ .fd = c.fd, .events = std.c.POLL.IN, .revents = 0 }) catch {};
        s.mutex.unlock(s.io);
        // Wake now and then to notice `stop`.
        if (std.c.poll(fds.items.ptr, @intCast(fds.items.len), 200) <= 0) continue;
        if (fds.items[0].revents != 0) s.acceptOne();
        for (fds.items[1..]) |p| if (p.revents != 0) s.readFrom(p.fd);
    }
}

fn acceptOne(s: *WsServer) void {
    const fd = std.c.accept(s.listen_fd, null, null);
    if (fd < 0) return;
    const c = s.gpa.create(Conn) catch {
        _ = std.c.close(fd);
        return;
    };
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    c.* = .{ .id = s.next_id, .fd = fd };
    s.next_id += 1;
    s.conns.append(s.gpa, c) catch {
        s.freeConn(c);
    };
}

fn connByFd(s: *WsServer, fd: c_int) ?*Conn {
    for (s.conns.items) |c| if (c.fd == fd) return c;
    return null;
}

fn readFrom(s: *WsServer, fd: c_int) void {
    var buf: [64 * 1024]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    s.mutex.lockUncancelable(s.io);
    defer s.mutex.unlock(s.io);
    const c = s.connByFd(fd) orelse return;
    if (n <= 0) return s.drop(c);
    c.in.appendSlice(s.gpa, buf[0..@intCast(n)]) catch return s.drop(c);
    if (!c.open) {
        if (!s.handshake(c)) return;
    }
    while (c.open) {
        const used = s.frame(c) orelse break;
        if (used == 0) return; // dropped
        c.in.replaceRangeAssumeCapacity(0, used, &.{});
    }
}

/// Removes `c` (lock held).
fn drop(s: *WsServer, c: *Conn) void {
    for (s.conns.items, 0..) |o, i| if (o == c) {
        _ = s.conns.swapRemove(i);
        break;
    };
    if (c.open) s.closed.append(s.gpa, c.id) catch {};
    s.freeConn(c);
    s.wake();
}

/// Answers the HTTP upgrade once the request is complete. False if the
/// connection was dropped or the request isn't complete yet.
fn handshake(s: *WsServer, c: *Conn) bool {
    const end = std.mem.indexOf(u8, c.in.items, "\r\n\r\n") orelse {
        if (c.in.items.len > 16 * 1024) s.drop(c);
        return false;
    };
    const req = c.in.items[0..end];
    const key = headerValue(req, "sec-websocket-key") orelse {
        writeAll(c.fd, "HTTP/1.1 400 Bad Request\r\nContent-Length: 0\r\n\r\n");
        s.drop(c);
        return false;
    };
    const auth = headerValue(req, "x-claude-code-ide-authorization") orelse "";
    if (!std.crypto.timing_safe.eql([32]u8, padded(auth), padded(s.token)) or auth.len != s.token.len) {
        writeAll(c.fd, "HTTP/1.1 401 Unauthorized\r\nContent-Length: 0\r\n\r\n");
        s.drop(c);
        return false;
    }
    var digest: [20]u8 = undefined;
    var sha = std.crypto.hash.Sha1.init(.{});
    sha.update(key);
    sha.update("258EAFA5-E914-47DA-95CA-C5AB0DC85B11");
    sha.final(&digest);
    var accept: [28]u8 = undefined;
    _ = std.base64.standard.Encoder.encode(&accept, &digest);
    var resp: [256]u8 = undefined;
    const proto: []const u8 = if (headerValue(req, "sec-websocket-protocol") != null) "Sec-WebSocket-Protocol: mcp\r\n" else "";
    const r = std.fmt.bufPrint(&resp, "HTTP/1.1 101 Switching Protocols\r\nUpgrade: websocket\r\nConnection: Upgrade\r\nSec-WebSocket-Accept: {s}\r\n{s}\r\n", .{ accept, proto }) catch return false;
    writeAll(c.fd, r);
    c.in.replaceRangeAssumeCapacity(0, end + 4, &.{});
    c.open = true;
    return true;
}

fn padded(s: []const u8) [32]u8 {
    var out: [32]u8 = @splat(0);
    @memcpy(out[0..@min(s.len, 32)], s[0..@min(s.len, 32)]);
    return out;
}

/// A header's value (names compare case-insensitively).
fn headerValue(req: []const u8, name: []const u8) ?[]const u8 {
    var lines = std.mem.splitSequence(u8, req, "\r\n");
    _ = lines.next(); // request line
    while (lines.next()) |line| {
        const colon = std.mem.indexOfScalar(u8, line, ':') orelse continue;
        if (std.ascii.eqlIgnoreCase(std.mem.trim(u8, line[0..colon], " "), name)) return std.mem.trim(u8, line[colon + 1 ..], " \t");
    }
    return null;
}

/// Handles one complete frame at the start of `c.in`: bytes used, null if
/// incomplete, 0 if the connection was dropped.
fn frame(s: *WsServer, c: *Conn) ?usize {
    const b = c.in.items;
    if (b.len < 2) return null;
    const fin = b[0] & 0x80 != 0;
    const opcode = b[0] & 0x0f;
    const masked = b[1] & 0x80 != 0;
    var len: u64 = b[1] & 0x7f;
    var at: usize = 2;
    if (len == 126) {
        if (b.len < 4) return null;
        len = std.mem.readInt(u16, b[2..4], .big);
        at = 4;
    } else if (len == 127) {
        if (b.len < 10) return null;
        len = std.mem.readInt(u64, b[2..10], .big);
        at = 10;
    }
    if (len > 64 * 1024 * 1024) {
        s.drop(c);
        return 0;
    }
    var mask: [4]u8 = .{ 0, 0, 0, 0 };
    if (masked) {
        if (b.len < at + 4) return null;
        mask = b[at..][0..4].*;
        at += 4;
    }
    if (b.len < at + len) return null;
    const payload = b[at .. at + @as(usize, @intCast(len))];
    for (payload, 0..) |*p, i| p.* ^= mask[i % 4];
    const used = at + payload.len;
    switch (opcode) {
        0x0, 0x1, 0x2 => {
            c.partial.appendSlice(s.gpa, payload) catch {};
            if (fin) {
                const text = c.partial.toOwnedSlice(s.gpa) catch return used;
                s.inbox.append(s.gpa, .{ .conn = c.id, .text = text }) catch s.gpa.free(text);
                s.wake();
            }
        },
        0x8 => { // close: answer and drop
            var h: [10]u8 = undefined;
            writeAll(c.fd, frameHeader(&h, 0x8, 0));
            s.drop(c);
            return 0;
        },
        0x9 => { // ping: pong with the same payload
            var h: [10]u8 = undefined;
            writeAll(c.fd, frameHeader(&h, 0xA, payload.len));
            writeAll(c.fd, payload);
        },
        else => {},
    }
    return used;
}

test "handshake, auth, messages both ways" {
    const gpa = std.testing.allocator;
    const S = struct {
        fn noWake() void {}
    };
    const s = try start(gpa, std.testing.io, S.noWake, "secret-token-123");
    defer s.destroy();

    const fd = socket(AF_INET, SOCK_STREAM, 0);
    defer _ = std.c.close(fd);
    var addr: SockaddrIn = .{ .port = std.mem.nativeToBig(u16, s.port), .addr = std.mem.nativeToBig(u32, 0x7f000001) };
    try std.testing.expectEqual(0, std.c.connect(fd, @ptrCast(&addr), @sizeOf(SockaddrIn)));
    writeAll(fd, "GET / HTTP/1.1\r\nHost: x\r\nUpgrade: websocket\r\nConnection: Upgrade\r\n" ++
        "Sec-WebSocket-Key: dGhlIHNhbXBsZSBub25jZQ==\r\nSec-WebSocket-Version: 13\r\n" ++
        "Sec-WebSocket-Protocol: mcp\r\nX-Claude-Code-Ide-Authorization: secret-token-123\r\n\r\n");
    var buf: [512]u8 = undefined;
    const n = std.c.read(fd, &buf, buf.len);
    const resp = buf[0..@intCast(n)];
    try std.testing.expect(std.mem.startsWith(u8, resp, "HTTP/1.1 101"));
    // The RFC 6455 example key's answer.
    try std.testing.expect(std.mem.indexOf(u8, resp, "s3pPLMBiTxaQ9kYGzzhZRbK+xOo=") != null);

    // A masked client text frame arrives as a message.
    const msg = "{\"id\":1}";
    var frame_buf: [6 + msg.len]u8 = undefined;
    frame_buf[0] = 0x81;
    frame_buf[1] = 0x80 | msg.len;
    const mask = [4]u8{ 1, 2, 3, 4 };
    @memcpy(frame_buf[2..6], &mask);
    for (msg, 0..) |ch, i| frame_buf[6 + i] = ch ^ mask[i % 4];
    writeAll(fd, &frame_buf);
    var got: ?Message = null;
    for (0..200) |_| {
        got = s.poll();
        if (got != null) break;
        std.Thread.yield() catch {};
        s.io.sleep(.fromMilliseconds(5), .awake) catch {};
    }
    defer s.gpa.free(got.?.text);
    try std.testing.expectEqualStrings(msg, got.?.text);

    // And an answer goes back as an unmasked text frame.
    s.send(got.?.conn, "{\"ok\":true}");
    const m = std.c.read(fd, &buf, buf.len);
    try std.testing.expectEqual(0x81, buf[0]);
    try std.testing.expectEqualStrings("{\"ok\":true}", buf[2..@intCast(m)]);
}
