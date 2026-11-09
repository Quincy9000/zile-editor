//! A child process attached to a pseudo-terminal (Linux, via libc's
//! `forkpty`). Bytes read from `fd` are what the program printed; bytes
//! written to it are what it reads as typed input.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pty = @This();

/// The PTY's controlling side. -1 once closed.
fd: c_int,
pid: c_int,

const Winsize = extern struct { row: u16, col: u16, xpixel: u16, ypixel: u16 };
extern "c" fn forkpty(master: *c_int, name: ?[*]u8, termp: ?*const anyopaque, winp: ?*const Winsize) c_int;
extern "c" fn ioctl(fd: c_int, request: c_ulong, ...) c_int;
const killProcess = @extern(*const fn (c_int, c_int) callconv(.c) c_int, .{ .name = "kill" });
const TIOCSWINSZ: c_ulong = 0x5414;
const SIGHUP = 1;
const SIGKILL = 9;

pub const Size = struct { cols: u16, rows: u16, cell_w: u16 = 0, cell_h: u16 = 0 };

/// Starts `argv` in directory `cwd` with TERM=xterm-256color. Everything the
/// child needs is prepared before forking (a forked child of a threaded
/// process must not allocate).
pub fn spawn(gpa: Allocator, argv: []const []const u8, cwd: []const u8, size: Size) !Pty {
    var arena_state: std.heap.ArenaAllocator = .init(gpa);
    defer arena_state.deinit();
    const arena = arena_state.allocator();

    const c_argv = try arena.allocSentinel(?[*:0]const u8, argv.len, null);
    for (argv, 0..) |a, i| c_argv[i] = (try arena.dupeSentinel(u8, a, 0)).ptr;
    const c_cwd = try arena.dupeSentinel(u8, cwd, 0);

    // The environment, with our terminal type instead of the editor's.
    var env: std.ArrayList(?[*:0]const u8) = .empty;
    var i: usize = 0;
    while (std.c.environ[i]) |e| : (i += 1) {
        const s = std.mem.span(e);
        if (std.mem.startsWith(u8, s, "TERM=") or std.mem.startsWith(u8, s, "COLORTERM=")) continue;
        try env.append(arena, e);
    }
    try env.append(arena, "TERM=xterm-256color");
    try env.append(arena, "COLORTERM=truecolor");
    try env.append(arena, "TERM_PROGRAM=zile");
    const c_env = try arena.allocSentinel(?[*:0]const u8, env.items.len, null);
    @memcpy(c_env[0..env.items.len], env.items);

    const ws: Winsize = .{ .row = size.rows, .col = size.cols, .xpixel = size.cols *| size.cell_w, .ypixel = size.rows *| size.cell_h };
    var master: c_int = -1;
    const pid = forkpty(&master, null, null, &ws);
    if (pid < 0) return error.ForkFailed;
    if (pid == 0) {
        // Child: only async-signal-safe calls from here.
        _ = std.c.chdir(c_cwd.ptr);
        _ = std.c.execve(c_argv[0].?, c_argv.ptr, c_env.ptr);
        std.c._exit(127);
    }
    return .{ .fd = master, .pid = pid };
}

/// The user's shell ($SHELL, else /bin/sh).
pub fn userShell() []const u8 {
    if (std.c.getenv("SHELL")) |s| {
        const shell = std.mem.span(s);
        if (shell.len > 0 and shell[0] == '/') return shell;
    }
    return "/bin/sh";
}

/// Blocks until output arrives. 0 means the child is gone (EOF / EIO).
pub fn read(p: *const Pty, buf: []u8) usize {
    while (true) {
        const n = std.c.read(p.fd, buf.ptr, buf.len);
        if (n > 0) return @intCast(n);
        if (n < 0 and std.c.errno(n) == .INTR) continue;
        return 0;
    }
}

/// Sends input to the child (all of it, unless the child has gone).
pub fn write(p: *const Pty, bytes: []const u8) void {
    var rest = bytes;
    while (rest.len > 0) {
        const n = std.c.write(p.fd, rest.ptr, rest.len);
        if (n > 0) {
            rest = rest[@intCast(n)..];
        } else if (n < 0 and (std.c.errno(n) == .INTR or std.c.errno(n) == .AGAIN)) {
            continue;
        } else return;
    }
}

/// Tells the child its new window size (it gets SIGWINCH).
pub fn resize(p: *const Pty, size: Size) void {
    const ws: Winsize = .{ .row = size.rows, .col = size.cols, .xpixel = size.cols *| size.cell_w, .ypixel = size.rows *| size.cell_h };
    _ = ioctl(p.fd, TIOCSWINSZ, &ws);
}

/// Hangs up on the child (as closing a terminal window does).
pub fn hangup(p: *const Pty) void {
    _ = killProcess(p.pid, SIGHUP);
}

/// Ends the child for sure.
pub fn kill(p: *const Pty) void {
    _ = killProcess(p.pid, SIGKILL);
}

/// Waits up to `ms` for output (or the child going away).
pub fn waitReadable(p: *const Pty, ms: i32) bool {
    var fds = [_]std.c.pollfd{.{ .fd = p.fd, .events = std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&fds, 1, ms) > 0;
}

/// Reaps the child; returns its exit code (128 + signal if killed).
pub fn wait(p: *const Pty) u8 {
    var status: c_int = 0;
    while (std.c.waitpid(p.pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return 255;
    }
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return @truncate(s >> 8); // exited
    return @truncate(128 + (s & 0x7f)); // killed by a signal
}

pub fn close(p: *Pty) void {
    if (p.fd >= 0) _ = std.c.close(p.fd);
    p.fd = -1;
}

test "run a command and read its output" {
    var p = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", "printf 'hi\\n'; exit 3" }, "/", .{ .cols = 80, .rows = 24 });
    defer p.close();
    var out: [256]u8 = undefined;
    var len: usize = 0;
    while (true) {
        const n = p.read(out[len..]);
        if (n == 0) break;
        len += n;
    }
    // The PTY turns "\n" into "\r\n".
    try std.testing.expectEqualStrings("hi\r\n", out[0..len]);
    try std.testing.expectEqual(3, p.wait());
}
