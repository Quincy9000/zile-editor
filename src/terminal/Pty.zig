//! A child process attached to a pseudo-terminal (Linux, via libc's
//! `forkpty`). Bytes read from `fd` are what the program printed; bytes
//! written to it are what it reads as typed input.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Pty = @This();

/// The PTY's controlling side. -1 once closed.
fd: c_int,
/// 0: no process of ours in it (`openOnly`).
pid: c_int,
/// `openOnly`: the terminal's own side, held open so the terminal lasts
/// between programs (the debugger's program comes and goes). -1: none.
held: c_int = -1,

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
    return spawnEnv(gpa, argv, cwd, size, &.{});
}

/// `spawn` with extra environment variables ("NAME=value").
pub fn spawnEnv(gpa: Allocator, argv: []const []const u8, cwd: []const u8, size: Size, extra_env: []const []const u8) !Pty {
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
        // zile's own test hooks aren't for the programs it runs.
        if (std.mem.startsWith(u8, s, "ZILE_TEST_")) continue;
        try env.append(arena, e);
    }
    try env.append(arena, "TERM=xterm-256color");
    try env.append(arena, "COLORTERM=truecolor");
    try env.append(arena, "TERM_PROGRAM=zile");
    for (extra_env) |e| try env.append(arena, (try arena.dupeSentinel(u8, e, 0)).ptr);
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

extern "c" fn posix_openpt(flags: c_int) c_int;
extern "c" fn grantpt(fd: c_int) c_int;
extern "c" fn unlockpt(fd: c_int) c_int;
extern "c" fn open(path: [*:0]const u8, flags: c_int, ...) c_int;
const O_RDWR = 0o2;
const O_NOCTTY = 0o400;
const O_CLOEXEC = 0o2000000;

/// A terminal with no program in it yet, for one started elsewhere (gdb's
/// program, given `deviceName`). Not zile's controlling terminal, nor
/// anyone's: the program it gets can make it its own (Ctrl-C, job control).
/// `release` lets it end once that program is gone.
pub fn openOnly(size: Size) !Pty {
    const fd = posix_openpt(O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (fd < 0) return error.NoPty;
    errdefer _ = std.c.close(fd);
    if (grantpt(fd) != 0 or unlockpt(fd) != 0) return error.NoPty;
    var name: [128]u8 = undefined;
    if (ptsname_r(fd, &name, name.len) != 0) return error.NoPty;
    const held = open(@ptrCast(&name), O_RDWR | O_NOCTTY | O_CLOEXEC);
    if (held < 0) return error.NoPty;
    const p: Pty = .{ .fd = fd, .pid = 0, .held = held };
    p.resize(size);
    return p;
}

/// `openOnly`'s terminal: let go of its side, so it ends (reads see the
/// end) once no program has it open.
pub fn release(p: *Pty) void {
    if (p.held >= 0) _ = std.c.close(p.held);
    p.held = -1;
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

extern "c" fn ptsname_r(fd: c_int, buf: [*]u8, len: usize) c_int;

/// The terminal device the child has (`/dev/pts/N`), in `buf`: another
/// program can be given it too (the debugger's program).
pub fn deviceName(p: *const Pty, buf: []u8) ?[]const u8 {
    if (ptsname_r(p.fd, buf.ptr, buf.len) != 0) return null;
    return std.mem.sliceTo(buf, 0);
}

/// Tells the child its new window size (it gets SIGWINCH).
pub fn resize(p: *const Pty, size: Size) void {
    const ws: Winsize = .{ .row = size.rows, .col = size.cols, .xpixel = size.cols *| size.cell_w, .ypixel = size.rows *| size.cell_h };
    _ = ioctl(p.fd, TIOCSWINSZ, &ws);
}

/// Hangs up on the child (as closing a terminal window does).
pub fn hangup(p: *const Pty) void {
    // (`kill(0, ...)` would signal zile's own process group.)
    if (p.pid > 0) _ = killProcess(p.pid, SIGHUP);
}

/// Ends the child for sure.
pub fn kill(p: *const Pty) void {
    if (p.pid > 0) _ = killProcess(p.pid, SIGKILL);
}

/// Waits up to `ms` for output (or the child going away).
pub fn waitReadable(p: *const Pty, ms: i32) bool {
    var fds = [_]std.c.pollfd{.{ .fd = p.fd, .events = std.c.POLL.IN, .revents = 0 }};
    return std.c.poll(&fds, 1, ms) > 0;
}

/// Reaps the child; returns its exit code (128 + signal if killed).
pub fn wait(p: *const Pty) u8 {
    if (p.pid <= 0) return 0;
    var status: c_int = 0;
    while (std.c.waitpid(p.pid, &status, 0) < 0) {
        if (std.c.errno(@as(c_int, -1)) != .INTR) return 255;
    }
    const s: u32 = @bitCast(status);
    if (s & 0x7f == 0) return @truncate(s >> 8); // exited
    return @truncate(128 + (s & 0x7f)); // killed by a signal
}

pub fn close(p: *Pty) void {
    p.release();
    if (p.fd >= 0) _ = std.c.close(p.fd);
    p.fd = -1;
}

test "openOnly: another program writes to it; it ends once released and that program is gone" {
    var p = try openOnly(.{ .cols = 80, .rows = 24 });
    defer p.close();
    var name_buf: [128]u8 = undefined;
    const name = p.deviceName(&name_buf).?;
    const cmd = try std.fmt.allocPrint(std.testing.allocator, "printf hi > {s}", .{name});
    defer std.testing.allocator.free(cmd);
    var other = try spawn(std.testing.allocator, &.{ "/bin/sh", "-c", cmd }, "/", .{ .cols = 80, .rows = 24 });
    defer other.close();
    _ = other.wait();
    var out: [64]u8 = undefined;
    try std.testing.expect(p.waitReadable(2000));
    const n = p.read(&out);
    try std.testing.expectEqualStrings("hi", out[0..n]);
    // Held: no end yet. Released: the end.
    try std.testing.expect(!p.waitReadable(50));
    p.release();
    try std.testing.expect(p.waitReadable(2000));
    try std.testing.expectEqual(0, p.read(&out));
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
