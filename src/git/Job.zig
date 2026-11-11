//! A git command (or a short sequence of them) running in the background, so
//! slow ones (push, pull) never freeze the editor. The editor polls `done`
//! every frame and then reads `ok` / `message`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Job = @This();

/// What the editor does when the job finishes.
pub const Kind = enum { commit, push, pull, switch_branch, create_branch, set_remote, init };

gpa: Allocator,
io: Io,
kind: Kind,
/// Owns the argument strings.
arena: std.heap.ArenaAllocator,
steps: []const []const []const u8,
root: []const u8,
wake: *const fn () void,
thread: std.Thread = undefined,
done: std.atomic.Value(bool) = .init(false),
// Valid once `done`:
ok: bool = false,
/// One short line for the status bar (owned).
message: []u8 = &.{},

/// Runs `steps` in order inside `root`, stopping at the first failure.
pub fn start(gpa: Allocator, io: Io, kind: Kind, root: []const u8, steps: []const []const []const u8, wake: *const fn () void) !*Job {
    const job = try gpa.create(Job);
    errdefer gpa.destroy(job);
    job.* = .{ .gpa = gpa, .io = io, .kind = kind, .arena = .init(gpa), .steps = &.{}, .root = &.{}, .wake = wake };
    errdefer job.arena.deinit();
    const a = job.arena.allocator();
    job.root = try a.dupe(u8, root);
    const copy = try a.alloc([]const []const u8, steps.len);
    for (steps, copy) |argv, *dst| {
        const args = try a.alloc([]const u8, argv.len);
        for (argv, args) |arg, *d| d.* = try a.dupe(u8, arg);
        dst.* = args;
    }
    job.steps = copy;
    job.thread = try std.Thread.spawn(.{}, run, .{job});
    return job;
}

pub fn destroy(job: *Job) void {
    job.thread.join();
    job.gpa.free(job.message);
    job.arena.deinit();
    job.gpa.destroy(job);
}

fn run(job: *Job) void {
    defer {
        job.done.store(true, .release);
        job.wake();
    }
    job.ok = true;
    var last: []const u8 = "";
    var keep: ?std.process.RunResult = null;
    defer if (keep) |r| {
        job.gpa.free(r.stdout);
        job.gpa.free(r.stderr);
    };
    for (job.steps) |argv| {
        if (keep) |r| {
            job.gpa.free(r.stdout);
            job.gpa.free(r.stderr);
            keep = null;
        }
        const r = std.process.run(job.gpa, job.io, .{ .argv = argv, .cwd = .{ .path = job.root } }) catch |err| {
            job.ok = false;
            job.message = std.fmt.allocPrint(job.gpa, "{s}", .{@errorName(err)}) catch &.{};
            return;
        };
        keep = r;
        // git writes progress and errors to stderr; prefer its last line.
        last = lastLine(r.stderr);
        if (last.len == 0) last = lastLine(r.stdout);
        if (!r.term.success()) {
            job.ok = false;
            break;
        }
    }
    job.message = job.gpa.dupe(u8, last) catch &.{};
}

fn lastLine(s: []const u8) []const u8 {
    var it = std.mem.splitBackwardsScalar(u8, std.mem.trim(u8, s, " \n\r"), '\n');
    while (it.next()) |line| {
        const l = std.mem.trim(u8, line, " \r");
        if (l.len > 0) return l;
    }
    return "";
}
