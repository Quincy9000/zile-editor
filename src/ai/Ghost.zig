//! AI ghost completion: fill-in-the-middle from a local model through
//! Ollama's `/api/generate` (the text before the cursor as `prompt`, after
//! it as `suffix`; the model's template adds its FIM tokens).
//!
//! One worker thread. The editor submits a request per keystroke; only the
//! latest is kept, and it waits for a short pause in typing before going
//! out. The reply is picked up on the main thread (`take`), which checks it
//! still fits where the cursor is.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;

const Ghost = @This();

pub const Result = struct {
    gen: u64,
    /// The suggestion (owned), or null with `failed` set.
    text: ?[]u8,
    failed: bool = false,
};

const Job = struct { gen: u64, prefix: []u8, suffix: []u8 };

gpa: Allocator,
io: Io,
wake: *const fn () void,
/// Full URL of the generate endpoint, and the model name (owned).
url: []u8,
model: []u8,
thread: std.Thread = undefined,
mutex: Io.Mutex = .init,
cond: Io.Condition = .init,
// Guarded by `mutex`.
want: ?Job = null,
result: ?Result = null,
stop: bool = false,

/// Pause in typing before asking (newer keystrokes replace the request).
const debounce_ms = 120;
/// Most tokens a suggestion may have.
const max_tokens = 96;

pub fn create(gpa: Allocator, io: Io, wake: *const fn () void, host: []const u8, model: []const u8) !*Ghost {
    const g = try gpa.create(Ghost);
    errdefer gpa.destroy(g);
    const url = try std.fmt.allocPrint(gpa, "{s}/api/generate", .{std.mem.trimEnd(u8, host, "/")});
    errdefer gpa.free(url);
    g.* = .{ .gpa = gpa, .io = io, .wake = wake, .url = url, .model = try gpa.dupe(u8, model) };
    g.thread = try std.Thread.spawn(.{}, run, .{g});
    return g;
}

pub fn destroy(g: *Ghost) void {
    g.mutex.lockUncancelable(g.io);
    g.stop = true;
    g.cond.signal(g.io);
    g.mutex.unlock(g.io);
    g.thread.join();
    if (g.want) |j| g.freeJob(j);
    if (g.result) |r| if (r.text) |t| g.gpa.free(t);
    g.gpa.free(g.url);
    g.gpa.free(g.model);
    g.gpa.destroy(g);
}

fn freeJob(g: *Ghost, j: Job) void {
    g.gpa.free(j.prefix);
    g.gpa.free(j.suffix);
}

/// Asks for a suggestion between `prefix` and `suffix` (copied), replacing
/// any request not yet sent.
pub fn submit(g: *Ghost, gen: u64, prefix: []const u8, suffix: []const u8) !void {
    const p = try g.gpa.dupe(u8, prefix);
    errdefer g.gpa.free(p);
    const s = try g.gpa.dupe(u8, suffix);
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    if (g.want) |old| g.freeJob(old);
    g.want = .{ .gen = gen, .prefix = p, .suffix = s };
    g.cond.signal(g.io);
}

/// The latest reply, if one arrived (caller owns its text).
pub fn take(g: *Ghost) ?Result {
    g.mutex.lockUncancelable(g.io);
    defer g.mutex.unlock(g.io);
    const r = g.result orelse return null;
    g.result = null;
    return r;
}

fn run(g: *Ghost) void {
    var client: std.http.Client = .{ .allocator = g.gpa, .io = g.io };
    defer client.deinit();
    while (true) {
        g.mutex.lockUncancelable(g.io);
        while (g.want == null and !g.stop) g.cond.waitUncancelable(g.io, &g.mutex);
        if (g.stop) {
            g.mutex.unlock(g.io);
            return;
        }
        const job = g.want.?;
        g.want = null;
        g.mutex.unlock(g.io);
        defer g.freeJob(job);

        // Still typing? A newer request replaces this one.
        g.io.sleep(.fromMilliseconds(debounce_ms), .awake) catch {};
        g.mutex.lockUncancelable(g.io);
        const newer = g.want != null or g.stop;
        g.mutex.unlock(g.io);
        if (newer) continue;

        const text = g.ask(&client, job) catch null;
        g.mutex.lockUncancelable(g.io);
        if (g.result) |old| if (old.text) |t| g.gpa.free(t);
        g.result = .{ .gen = job.gen, .text = text, .failed = text == null };
        g.mutex.unlock(g.io);
        g.wake();
    }
}

fn ask(g: *Ghost, client: *std.http.Client, job: Job) ![]u8 {
    const body = try std.json.Stringify.valueAlloc(g.gpa, .{
        .model = g.model,
        .prompt = job.prefix,
        .suffix = job.suffix,
        .stream = false,
        .options = .{ .num_predict = max_tokens, .temperature = 0.1 },
    }, .{});
    defer g.gpa.free(body);
    var reply: Io.Writer.Allocating = .init(g.gpa);
    defer reply.deinit();
    const res = try client.fetch(.{
        .location = .{ .url = g.url },
        .method = .POST,
        .payload = body,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .response_writer = &reply.writer,
    });
    if (res.status != .ok) return error.BadStatus;
    const parsed = try std.json.parseFromSlice(struct { response: []const u8 = "" }, g.gpa, reply.written(), .{ .ignore_unknown_fields = true });
    defer parsed.deinit();
    return g.gpa.dupe(u8, parsed.value.response);
}

/// Tidies a model's suggestion for the spot it was asked for: no trailing
/// blank space, at most `max_lines` lines, and on a single line without
/// repeating what already follows the cursor (`rest`, e.g. a `)`).
pub fn tidy(text: []const u8, rest: []const u8, max_lines: usize) []const u8 {
    var t = std.mem.trimEnd(u8, text, " \t\r\n");
    var nl: usize = 0;
    for (t, 0..) |c, i| if (c == '\n') {
        nl += 1;
        if (nl == max_lines) {
            t = std.mem.trimEnd(u8, t[0..i], " \t\r");
            break;
        }
    };
    const r = std.mem.trim(u8, rest, " \t");
    if (r.len > 0 and std.mem.indexOfScalar(u8, t, '\n') == null and std.mem.endsWith(u8, t, r)) t = t[0 .. t.len - r.len];
    return t;
}

/// Cuts a suggestion at its first line that repeats a line already nearby
/// (`context`: the lines around the cursor), a common failure of small
/// models (re-suggesting the #includes above, echoing the code below).
/// `line_prefix` is what precedes the cursor on its line, so the first
/// suggested line is compared whole. Short lines (`}`, `break;`) don't
/// count: they legitimately repeat.
pub fn dropRepeats(text: []const u8, line_prefix: []const u8, context: []const u8) []const u8 {
    var start: usize = 0;
    var i: usize = 0;
    var lines = std.mem.splitScalar(u8, text, '\n');
    while (lines.next()) |line| : (i += 1) {
        const whole_buf = if (i == 0) line_prefix else "";
        const trimmed = std.mem.trim(u8, line, " \t");
        const whole_trimmed = if (i == 0) std.mem.trim(u8, whole_buf, " \t") else "";
        // The line as it would read in the file.
        const significant = whole_trimmed.len + trimmed.len >= 6;
        if (significant and appearsIn(context, whole_trimmed, trimmed)) {
            return std.mem.trimEnd(u8, text[0 .. start -| 1], " \t\r\n");
        }
        start += line.len + 1;
    }
    return text;
}

/// Some line of `context`, trimmed, equals `head ++ tail` (trimmed).
fn appearsIn(context: []const u8, head: []const u8, tail: []const u8) bool {
    var it = std.mem.splitScalar(u8, context, '\n');
    while (it.next()) |c| {
        const ct = std.mem.trim(u8, c, " \t\r");
        if (ct.len != head.len + tail.len) continue;
        if (std.mem.startsWith(u8, ct, head) and std.mem.endsWith(u8, ct, tail)) return true;
    }
    return false;
}

test "dropRepeats" {
    const ctx = "#include <stdio.h>\n#include <string.h>\nint x;\n}\n";
    // Keeps the new include, stops at the first repeated one.
    try std.testing.expectEqualStrings("#include <time.h>", dropRepeats("#include <time.h>\n#include <stdio.h>\n#include <math.h>", "", ctx));
    // A first line that only repeats: nothing.
    try std.testing.expectEqualStrings("", dropRepeats("include <string.h>", "#", ctx));
    // Short lines may repeat.
    try std.testing.expectEqualStrings("    return 1;\n}", dropRepeats("    return 1;\n}", "", ctx));
}

test "tidy" {
    try std.testing.expectEqualStrings("a + b;", tidy("a + b;\n\n", "", 8));
    try std.testing.expectEqualStrings("x, y", tidy("x, y)", ")", 8));
    try std.testing.expectEqualStrings("one\ntwo", tidy("one\ntwo\nthree", "", 2));
}
