//! The picker's background worker: runs a source's producer (e.g. walking the
//! file tree) and fuzzy-matches the items against the current query, keeping the
//! main thread free.
//!
//! The main thread sets the query and copies out result snapshots; the worker
//! publishes a new snapshot after every match pass and calls `wake` so the UI
//! redraws. Each snapshot records which query generation it answers, so the UI
//! can wait for up-to-date results before accepting a selection.
//!
//! Matching is incremental: new items are scored as they arrive, and a query
//! that extends the previous one only rescans the previous matches.

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const fuzzy = @import("fuzzy.zig");
const Items = @import("Items.zig");

const Engine = @This();

pub const Result = struct {
    index: u32,
    score: i32,
};

/// The best results kept per snapshot (the list scrolls within these).
pub const max_results = 1000;
pub const max_query_len = 256;

pub const Snapshot = struct {
    results: [max_results]Result = undefined,
    len: usize = 0,
    /// Items matching the query (may exceed `len`).
    matched: usize = 0,
    /// Items produced so far.
    total: usize = 0,
    /// Increments on every publish.
    gen: u64 = 0,
    /// The query generation these results answer.
    query_gen: u64 = 0,
    /// The producer has finished.
    done: bool = false,

    pub fn slice(s: *const Snapshot) []const Result {
        return s.results[0..s.len];
    }
};

/// Fills `engine.items` on the worker thread, calling `checkpoint` between
/// batches. Must not touch editor state.
pub const Producer = *const fn (e: *Engine) anyerror!void;

gpa: Allocator,
io: Io,
items: Items,
wake: *const fn () void,
producer: ?Producer = null,
thread: ?std.Thread = null,

/// A child process the producer is reading from (e.g. rg), killed on destroy
/// so the worker's read ends promptly. 0 when none.
child_pid: std.atomic.Value(std.posix.pid_t) = .init(0),

mutex: Io.Mutex = .init,
/// Signals the worker: query changed or stop requested.
work: Io.Condition = .init,
/// Signals waiters: a snapshot was published.
published: Io.Condition = .init,

// Guarded by `mutex`.
query: [max_query_len]u8 = undefined,
query_len: usize = 0,
query_gen: u64 = 0,
stop: bool = false,
out: Snapshot = .{},

// Worker-thread only.
w_query: [max_query_len]u8 = undefined,
w_query_len: usize = 0,
w_query_gen: u64 = 0,
/// Query of the last match pass, for incremental narrowing.
w_last: [max_query_len]u8 = undefined,
w_last_len: usize = 0,
/// Items already considered by `w_matches`.
w_seen: usize = 0,
w_matches: std.ArrayList(Result) = .empty,
w_scratch: fuzzy.Scratch = .{},

pub fn create(gpa: Allocator, io: Io, wake: *const fn () void) Allocator.Error!*Engine {
    const e = try gpa.create(Engine);
    e.* = .{ .gpa = gpa, .io = io, .items = .init(gpa), .wake = wake };
    return e;
}

/// Starts the worker. Items added before this call (static sources) are visible
/// to it; `producer`, if any, runs on the worker to add more.
pub fn start(e: *Engine, producer: ?Producer) std.Thread.SpawnError!void {
    e.producer = producer;
    e.thread = try std.Thread.spawn(.{}, run, .{e});
}

pub fn destroy(e: *Engine) void {
    if (e.thread) |t| {
        e.mutex.lockUncancelable(e.io);
        e.stop = true;
        e.mutex.unlock(e.io);
        e.work.signal(e.io);
        const pid = e.child_pid.load(.acquire);
        if (pid != 0) std.posix.kill(pid, std.posix.SIG.TERM) catch {};
        t.join();
    }
    e.w_matches.deinit(e.gpa);
    e.items.deinit();
    e.gpa.destroy(e);
}

/// Sets the query (truncated to `max_query_len`). Returns its generation.
pub fn setQuery(e: *Engine, q: []const u8) u64 {
    const len = @min(q.len, max_query_len);
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    @memcpy(e.query[0..len], q[0..len]);
    e.query_len = len;
    e.query_gen += 1;
    e.work.signal(e.io);
    return e.query_gen;
}

/// Copies the latest snapshot into `dst` if it is newer. Returns true if copied.
pub fn poll(e: *Engine, dst: *Snapshot) bool {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    if (e.out.gen == dst.gen) return false;
    dst.* = e.out;
    return true;
}

/// Blocks until results for query generation `gen` are published.
pub fn waitFor(e: *Engine, gen: u64) void {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    while (!e.stop and e.out.query_gen < gen) e.published.waitUncancelable(e.io, &e.mutex);
}

/// For producers, between batches: picks up query changes, matches what was
/// produced so far, and publishes. Fails with `Canceled` once stop is requested.
pub fn checkpoint(e: *Engine) error{Canceled}!void {
    if (!e.takeQuery()) return error.Canceled;
    e.matchPass(false);
}

/// Copies the shared query into worker state. Returns false if stopping.
fn takeQuery(e: *Engine) bool {
    e.mutex.lockUncancelable(e.io);
    defer e.mutex.unlock(e.io);
    if (e.stop) return false;
    @memcpy(e.w_query[0..e.query_len], e.query[0..e.query_len]);
    e.w_query_len = e.query_len;
    e.w_query_gen = e.query_gen;
    return true;
}

/// The query when the worker started (query-driven producers like rg read it).
pub fn producerQuery(e: *const Engine) []const u8 {
    return e.w_query[0..e.w_query_len];
}

fn run(e: *Engine) void {
    if (!e.takeQuery()) return;
    if (e.producer) |produce| {
        produce(e) catch |err| switch (err) {
            error.Canceled => return,
            else => std.log.warn("picker source failed: {s}", .{@errorName(err)}),
        };
    }
    if (!e.takeQuery()) return;
    e.matchPass(true);

    while (true) {
        e.mutex.lockUncancelable(e.io);
        while (!e.stop and e.query_gen == e.w_query_gen) e.work.waitUncancelable(e.io, &e.mutex);
        e.mutex.unlock(e.io);
        if (!e.takeQuery()) return;
        e.matchPass(true);
    }
}

fn matchPass(e: *Engine, done: bool) void {
    const n = e.items.count();
    const query = e.w_query[0..e.w_query_len];
    const last = e.w_last[0..e.w_last_len];

    if (query.len > 0) {
        const q = fuzzy.Query.init(query);
        if (std.mem.eql(u8, query, last)) {
            // Same query: only score the items that arrived since.
            e.scoreRange(q, e.w_seen, n);
        } else if (last.len > 0 and std.mem.startsWith(u8, query, last)) {
            // Narrowing: only previous matches can still match.
            var kept: usize = 0;
            for (e.w_matches.items) |r| {
                if (fuzzy.score(q, e.items.get(r.index).text, &e.w_scratch)) |s| {
                    e.w_matches.items[kept] = .{ .index = r.index, .score = s };
                    kept += 1;
                }
            }
            e.w_matches.shrinkRetainingCapacity(kept);
            e.scoreRange(q, e.w_seen, n);
        } else {
            e.w_matches.clearRetainingCapacity();
            e.scoreRange(q, 0, n);
        }
        std.mem.sort(Result, e.w_matches.items, @as(*const Items, &e.items), betterThan);
    } else {
        e.w_matches.clearRetainingCapacity();
    }
    e.w_seen = n;
    @memcpy(e.w_last[0..query.len], query);
    e.w_last_len = query.len;
    e.publish(n, done);
}

fn scoreRange(e: *Engine, q: fuzzy.Query, from: usize, to: usize) void {
    for (from..to) |i| {
        const s = fuzzy.score(q, e.items.get(i).text, &e.w_scratch) orelse continue;
        e.w_matches.append(e.gpa, .{ .index = @intCast(i), .score = s }) catch return;
    }
}

/// Higher score first, then shorter text, then original order.
fn betterThan(items: *const Items, a: Result, b: Result) bool {
    if (a.score != b.score) return a.score > b.score;
    const la = items.get(a.index).text.len;
    const lb = items.get(b.index).text.len;
    if (la != lb) return la < lb;
    return a.index < b.index;
}

fn publish(e: *Engine, n: usize, done: bool) void {
    {
        e.mutex.lockUncancelable(e.io);
        defer e.mutex.unlock(e.io);
        const out = &e.out;
        if (e.w_query_len == 0) {
            // Empty query: everything, in source order.
            out.len = @min(n, max_results);
            for (out.results[0..out.len], 0..) |*r, i| r.* = .{ .index = @intCast(i), .score = 0 };
            out.matched = n;
        } else {
            out.len = @min(e.w_matches.items.len, max_results);
            @memcpy(out.results[0..out.len], e.w_matches.items[0..out.len]);
            out.matched = e.w_matches.items.len;
        }
        out.total = n;
        out.gen += 1;
        out.query_gen = e.w_query_gen;
        out.done = done;
    }
    e.published.broadcast(e.io);
    e.wake();
}

fn noWake() void {}

test "static items: match, narrow, widen" {
    const testing = std.testing;
    const e = try create(testing.allocator, testing.io, noWake);
    defer e.destroy();
    for ([_][]const u8{ "src/main.zig", "src/Editor.zig", "build.zig", "README.md" }) |t| {
        try e.items.append(.{ .text = t });
    }
    try e.start(null);

    var snap: Snapshot = .{};
    e.waitFor(e.setQuery("zig"));
    _ = e.poll(&snap);
    try testing.expectEqual(3, snap.matched);

    e.waitFor(e.setQuery("zigm")); // narrowing
    _ = e.poll(&snap);
    try testing.expectEqual(0, snap.matched);

    e.waitFor(e.setQuery("main")); // unrelated: full rescan
    _ = e.poll(&snap);
    try testing.expectEqual(1, snap.matched);
    try testing.expectEqualStrings("src/main.zig", e.items.get(snap.slice()[0].index).text);

    e.waitFor(e.setQuery(""));
    _ = e.poll(&snap);
    try testing.expectEqual(4, snap.matched);
    try testing.expect(snap.done);
}
