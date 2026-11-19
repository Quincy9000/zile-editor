//! AI completion asked for by hand: a model writes what belongs at the
//! cursor (fill-in-the-middle), and the editor shows it to take or drop.
//!
//! The backends answer the same question (`Query` in, text out):
//!
//!   local      the model on this machine, through Ollama: `Ghost.zig`'s
//!              request (the model's own FIM tokens), nothing written anew
//!   anthropic  Anthropic's Messages API, `claude-haiku-5-5` unless another
//!              model is set; usable only with $ANTHROPIC_API_KEY
//!   deepseek   DeepSeek's, which takes the same requests (its
//!              Anthropic-compatible API), `deepseek-flash`; usable only with
//!              $DEEPSEEK_API_KEY (or $DEEPSEEK_API)
//!
//! A service that speaks the Messages API is a row of `apis`; nothing else
//! here knows one from another.
//!
//! Everything here is apart from the editor: what is sent and how a reply
//! is read are plain functions, and the network is a function handed in
//! (`Transport`), so tests ask without one. A `Job` runs one question as an
//! `Io` task; destroying it cancels the task, which abandons a request on
//! its way (the connection closes, so Ollama stops generating too).

const std = @import("std");
const Allocator = std.mem.Allocator;
const Io = std.Io;
const Ghost = @import("Ghost.zig");

pub const Backend = enum {
    local,
    anthropic,
    deepseek,

    pub fn title(b: Backend) []const u8 {
        return switch (b) {
            .local => "Local",
            else => apiOf(b).?.title,
        };
    }
};

/// A service answering the Messages API's requests, and its key.
pub const Api = struct {
    title: []const u8,
    /// Its Messages endpoint.
    url: []const u8,
    /// The environment variables its key may be in, the first set one
    /// counts. The value is read when a question is asked and is never
    /// written anywhere.
    key_names: []const []const u8,
    /// The model asked unless config.zon names another.
    model: []const u8,
    /// Thinking can be turned off whatever the model (else only on a
    /// Haiku: `withoutThinking`).
    thinking_off: bool = false,
};

pub const apis = std.enums.EnumArray(Backend, ?Api).init(.{
    .local = null,
    .anthropic = .{
        .title = "Anthropic",
        .url = "https://api.anthropic.com/v1/messages",
        .key_names = &.{"ANTHROPIC_API_KEY"},
        .model = "claude-haiku-5-5",
    },
    .deepseek = .{
        .title = "DeepSeek",
        .url = "https://api.deepseek.com/anthropic/v1/messages",
        .key_names = &.{ "DEEPSEEK_API_KEY", "DEEPSEEK_API" },
        .model = "deepseek-flash",
        .thinking_off = true,
    },
});

/// The API `b` is asked through; null for the local model.
pub fn apiOf(b: Backend) ?Api {
    return apis.get(b);
}

/// The name of the variable `b`'s key is looked for in first ("" for the
/// local model), to say what is missing.
pub fn keyName(b: Backend) []const u8 {
    const api = apiOf(b) orelse return "";
    return api.key_names[0];
}

pub const default_model = "claude-haiku-5-5";
const api_version = "2026-10-21";
/// Most tokens of code a completion may have.
pub const max_tokens = 400;
/// On a model that thinks before it writes, thinking counts toward the
/// request's cap: room for it, so the code isn't cut off.
const thinking_room = 1600;

/// A key that is there and not blank.
pub fn hasKey(key: ?[]const u8) bool {
    return std.mem.trim(u8, key orelse return false, " \t\r\n").len > 0;
}

/// Whether `b` can be asked with `key` (its own): the local model always,
/// a service with a key.
pub fn available(b: Backend, key: ?[]const u8) bool {
    return b == .local or hasKey(key);
}

pub const Choice = struct {
    backend: Backend,
    /// The one wanted can't be asked (its key is gone): this is Local.
    fell_back: bool = false,
};

/// The backend to ask when `wanted` is the one selected (`key` is its
/// key). Only a missing key changes it; a request that fails never does.
pub fn choose(wanted: Backend, key: ?[]const u8) Choice {
    if (available(wanted, key)) return .{ .backend = wanted };
    return .{ .backend = .local, .fell_back = true };
}

pub const Split = struct { prefix: []const u8, suffix: []const u8 };

/// `text` cut at `cursor` (a byte offset; past the end is the end, inside
/// a character is that character's start).
pub fn split(text: []const u8, cursor: usize) Split {
    var c = @min(cursor, text.len);
    while (c > 0 and c < text.len and (text[c] & 0xC0) == 0x80) c -= 1;
    return .{ .prefix = text[0..c], .suffix = text[c..] };
}

/// What is asked: the text around the cursor, and optionally what the user
/// wants there and the file's name.
pub const Query = struct {
    prefix: []const u8,
    suffix: []const u8,
    hint: []const u8 = "",
    file: []const u8 = "",
};

/// Who is asked, and how to reach them.
pub const Config = struct {
    backend: Backend,
    /// Local: where Ollama is, and its model.
    host: []const u8 = "http://localhost:11434",
    local_model: []const u8 = "",
    /// A service: the model, and the key (kept in memory for the request).
    model: []const u8 = default_model,
    key: []const u8 = "",

    /// The model asked, for the label.
    pub fn modelName(c: Config) []const u8 {
        return if (c.backend == .local) c.local_model else c.model;
    }
};

/// An HTTP POST of JSON.
pub const Call = struct {
    url: []const u8,
    /// Headers that hold a secret (the key). They go to the host asked and
    /// no further: `http` never follows a redirect.
    secret_headers: []const std.http.Header = &.{},
    headers: []const std.http.Header = &.{},
    body: []const u8,
};

pub const Response = struct {
    status: u16,
    /// In the allocator the transport was given.
    body: []const u8,
};

/// Sends a call and gives back what came. The real one is `http`.
pub const Transport = *const fn (a: Allocator, io: Io, call: Call) anyerror!Response;

/// What a question came to. Text and messages are in the allocator given.
pub const Outcome = union(enum) {
    /// What the model wrote, tidied (`clean`); may be empty.
    text: []const u8,
    /// Why there is none, to show.
    failed: []const u8,
};

// ---------------------------------------------------------------------
// A service with the Messages API (Anthropic, DeepSeek)
// ---------------------------------------------------------------------

const system_prompt =
    \\You are the code completion engine of a text editor. The user message holds the file being edited, split at the cursor: <prefix> is everything before the cursor and <suffix> is everything after it, both exactly as they are in the file, whitespace included. A <hint>, when there is one, is the user's note on what they want at the cursor.
    \\
    \\Reply with exactly the text to insert at the cursor. The editor inserts your reply as it is, so that prefix + reply + suffix becomes the file. So write code only: no explanation, no markdown fences, and none of the text that is already in the suffix. Start right where the prefix stops, mid-word or mid-line if that is where the cursor is, and match the file's language, indentation and style.
    \\
    \\Write what is missing at this spot, such as the rest of the statement, the block, or the function body, and stop there: the rest of the file is the user's. If nothing is missing, reply with nothing.
;

/// The user message: the file as `<prefix>` and `<suffix>`, verbatim.
pub fn userMessage(a: Allocator, q: Query) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    if (q.file.len > 0) try out.print(a, "<file>{s}</file>\n", .{q.file});
    try out.print(a, "<prefix>{s}</prefix>\n<suffix>{s}</suffix>", .{ q.prefix, q.suffix });
    const hint = std.mem.trim(u8, q.hint, " \t\r\n");
    if (hint.len > 0) try out.print(a, "\n<hint>{s}</hint>", .{hint});
    return out.toOwnedSlice(a);
}

/// A Haiku answers a completion without thinking first (the request turns
/// thinking off, which Haiku accepts at low effort): faster, and the whole
/// cap goes to code. Other Claude models can't have it off, so they keep
/// their own default and get room for it instead. A service that can turn
/// it off for any model (`thinking_off`) has it off.
fn withoutThinking(api: Api, model: []const u8) bool {
    return api.thinking_off or std.mem.startsWith(u8, model, "claude-haiku");
}

/// The Messages API request for `q`.
pub fn anthropicBody(a: Allocator, api: Api, model: []const u8, q: Query) ![]u8 {
    const Thinking = struct { type: []const u8 };
    const Message = struct { role: []const u8, content: []const u8 };
    const user = try userMessage(a, q);
    defer a.free(user);
    const off = withoutThinking(api, model);
    return std.json.Stringify.valueAlloc(a, .{
        .model = model,
        .max_tokens = @as(u32, if (off) max_tokens else max_tokens + thinking_room),
        .system = system_prompt,
        .thinking = if (off) @as(?Thinking, .{ .type = "disabled" }) else null,
        .output_config = .{ .effort = "low" },
        .messages = &[_]Message{.{ .role = "user", .content = user }},
    }, .{ .emit_null_optional_fields = false });
}

const AnthropicReply = struct {
    content: []const struct { type: []const u8 = "", text: []const u8 = "" } = &.{},
    stop_reason: ?[]const u8 = null,
    stop_details: ?struct { category: ?[]const u8 = null } = null,
    @"error": ?struct { type: []const u8 = "", message: []const u8 = "" } = null,
};

/// Reads the Messages API's reply: the text blocks of a 200, or what went
/// wrong, said as the API (`api`) says it.
pub fn anthropicReply(a: Allocator, api: Api, res: Response) !Outcome {
    const who = api.title;
    const parsed = std.json.parseFromSliceLeaky(AnthropicReply, a, res.body, .{ .ignore_unknown_fields = true }) catch {
        return failed(a, "{s}: HTTP {d}, and a reply that isn't JSON", .{ who, res.status });
    };
    if (res.status != 200 or parsed.@"error" != null) {
        const e = parsed.@"error" orelse return failed(a, "{s}: HTTP {d}", .{ who, res.status });
        return switch (res.status) {
            401 => failed(a, "{s}: {s} (HTTP 401; check {s})", .{ who, e.message, api.key_names[0] }),
            else => failed(a, "{s}: {s} (HTTP {d}, {s})", .{ who, e.message, res.status, e.type }),
        };
    }
    // A request the model's safeguards declined is a 200 with this reason.
    if (parsed.stop_reason) |r| if (std.mem.eql(u8, r, "refusal")) {
        const category = if (parsed.stop_details) |d| d.category orelse "" else "";
        return if (category.len > 0)
            failed(a, "{s} declined to complete this ({s})", .{ who, category })
        else
            failed(a, "{s} declined to complete this", .{who});
    };
    // By type, not position: a reply can begin with thinking blocks.
    var text: std.ArrayList(u8) = .empty;
    for (parsed.content) |block| {
        if (std.mem.eql(u8, block.type, "text")) try text.appendSlice(a, block.text);
    }
    return .{ .text = text.items };
}

// ---------------------------------------------------------------------
// The local backend
// ---------------------------------------------------------------------

/// Reads Ollama's reply: the model's text, or its error as it says it.
pub fn localReply(a: Allocator, cfg: Config, res: Response) !Outcome {
    if (res.status == 200) {
        const text = Ghost.replyText(a, res.body) catch return failed(a, "Local: a reply from Ollama that isn't JSON", .{});
        return .{ .text = text };
    }
    const Err = struct { @"error": []const u8 = "" };
    const e: Err = std.json.parseFromSliceLeaky(Err, a, res.body, .{ .ignore_unknown_fields = true }) catch .{};
    if (e.@"error".len > 0) return failed(a, "Local: {s} (Ollama, model {s})", .{ e.@"error", cfg.local_model });
    return failed(a, "Local: HTTP {d} from Ollama at {s}", .{ res.status, cfg.host });
}

// ---------------------------------------------------------------------
// Both
// ---------------------------------------------------------------------

fn failed(a: Allocator, comptime fmt: []const u8, args: anytype) !Outcome {
    return .{ .failed = try std.fmt.allocPrint(a, fmt, args) };
}

/// The call that asks `cfg`'s backend. The local model gets its own
/// format (its FIM tokens; a hint has no place in it), a service the
/// instructions and the file.
pub fn request(a: Allocator, cfg: Config, q: Query) !Call {
    const api = apiOf(cfg.backend) orelse return .{
        .url = try Ghost.generateUrl(a, cfg.host),
        .body = try Ghost.requestBody(a, cfg.local_model, q.prefix, q.suffix, max_tokens),
    };
    const secret = try a.alloc(std.http.Header, 1);
    secret[0] = .{ .name = "x-api-key", .value = cfg.key };
    const plain = try a.alloc(std.http.Header, 1);
    plain[0] = .{ .name = "anthropic-version", .value = api_version };
    return .{
        .url = api.url,
        .secret_headers = secret,
        .headers = plain,
        .body = try anthropicBody(a, api, cfg.model, q),
    };
}

/// Asks, and reads the answer: `complete(prefix, suffix, hint) -> text`,
/// for either backend. Stopping it is the task's cancelation (`Job`).
/// `a` is an arena's allocator: what is returned lives in it.
pub fn complete(a: Allocator, io: Io, transport: Transport, cfg: Config, q: Query) Outcome {
    return ask(a, io, transport, cfg, q) catch .{ .failed = "AI completion: out of memory" };
}

fn ask(a: Allocator, io: Io, transport: Transport, cfg: Config, q: Query) !Outcome {
    const call = try request(a, cfg, q);
    const api = apiOf(cfg.backend);
    const res = transport(a, io, call) catch |err| return if (api) |s|
        failed(a, "{s}: the request didn't get through ({s})", .{ s.title, @errorName(err) })
    else
        failed(a, "Local: no answer from Ollama at {s} ({s})", .{ cfg.host, @errorName(err) });
    const outcome = if (api) |s| try anthropicReply(a, s, res) else try localReply(a, cfg, res);
    return switch (outcome) {
        .text => |t| .{ .text = clean(t, q.suffix) },
        .failed => outcome,
    };
}

/// The real transport: one request on a connection of its own, closed
/// after (or when the task is canceled half way). A redirect isn't
/// followed (its status is what comes back), so the key is only ever sent
/// to the host that was asked.
pub fn http(a: Allocator, io: Io, call: Call) anyerror!Response {
    var client: std.http.Client = .{ .allocator = a, .io = io };
    defer client.deinit();
    var reply: Io.Writer.Allocating = .init(a);
    errdefer reply.deinit();
    // (std's `privileged_headers` are never written to the request in
    // this Zig, so all of them go as `extra_headers`.)
    const headers = try std.mem.concat(a, std.http.Header, &.{ call.headers, call.secret_headers });
    defer a.free(headers);
    const res = try client.fetch(.{
        .location = .{ .url = call.url },
        .method = .POST,
        .payload = call.body,
        .keep_alive = false,
        .redirect_behavior = .unhandled,
        .headers = .{ .content_type = .{ .override = "application/json" } },
        .extra_headers = headers,
        .response_writer = &reply.writer,
    });
    return .{ .status = @intFromEnum(res.status), .body = try reply.toOwnedSlice() };
}

// ---------------------------------------------------------------------
// Tidying what a model wrote
// ---------------------------------------------------------------------

/// What a model wrote, as it goes in the file: without the markdown fence
/// around it, and without a tail that only repeats how the suffix begins.
/// A slice of `text`.
pub fn clean(text: []const u8, suffix: []const u8) []const u8 {
    return trimOverlap(stripFences(text), suffix);
}

/// `text` without a markdown fence around it (```` ```zig ```` ... ```` ``` ````).
/// Text that isn't fenced comes back as it is, its indentation too.
pub fn stripFences(text: []const u8) []const u8 {
    const lead = std.mem.trimStart(u8, text, " \t\r\n");
    if (!std.mem.startsWith(u8, lead, "```")) return text;
    // The fence's own line goes (its language with it).
    const first_end = std.mem.indexOfScalar(u8, lead, '\n') orelse return "";
    var body = lead[first_end + 1 ..];
    const tail = std.mem.trimEnd(u8, body, " \t\r\n");
    if (std.mem.endsWith(u8, tail, "```")) {
        body = tail[0 .. tail.len - 3];
        // The line break before the closing fence was the fence's.
        if (std.mem.endsWith(u8, body, "\r\n")) body = body[0 .. body.len - 2] else if (std.mem.endsWith(u8, body, "\n")) body = body[0 .. body.len - 1];
    }
    return body;
}

fn isWord(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_' or c >= 0x80;
}

/// How many closing brackets and quotes of `text` close nothing in it:
/// each `)`, `]`, `}` beyond the ones opened, and one for a quote that
/// comes an odd number of times.
fn unmatchedClosers(text: []const u8) usize {
    var open = [_]usize{ 0, 0, 0 };
    var quotes = [_]usize{ 0, 0, 0 };
    var extra: usize = 0;
    for (text) |c| switch (c) {
        '(' => open[0] += 1,
        '[' => open[1] += 1,
        '{' => open[2] += 1,
        ')', ']', '}' => {
            const i: usize = if (c == ')') 0 else if (c == ']') 1 else 2;
            if (open[i] > 0) open[i] -= 1 else extra += 1;
        },
        '"' => quotes[0] += 1,
        '\'' => quotes[1] += 1,
        '`' => quotes[2] += 1,
        else => {},
    };
    for (quotes) |n| extra += n % 2;
    return extra;
}

/// Whether the last `k` bytes of `text`, which are also how `suffix`
/// begins, are a repeat of the suffix (and not code of the completion's
/// own that happens to end the same way).
fn repeatsSuffix(text: []const u8, suffix: []const u8, k: usize) bool {
    const tail = text[text.len - k ..];
    var has_word = false;
    var closers: usize = 0;
    for (tail) |c| {
        if (isWord(c)) has_word = true;
        if (std.mem.indexOfScalar(u8, ")]}\"'`", c) != null) closers += 1;
    }
    if (has_word) {
        // Code said again: whole words of it, at both ends (`value` before
        // `else` shares an `e`, and repeats nothing).
        const starts_clean = text.len == k or !isWord(tail[0]) or !isWord(text[text.len - k - 1]);
        const ends_clean = k == suffix.len or !isWord(tail[k - 1]) or !isWord(suffix[k]);
        return starts_clean and ends_clean;
    }
    // Only brackets, quotes, punctuation and blank space. Closers repeat
    // the suffix when the completion opened nothing for them to close
    // (`a, b)` before `)`); `f(x)` before `)` keeps its own bracket.
    return closers <= unmatchedClosers(text);
}

/// `text` without a tail that repeats the start of `suffix`: models asked
/// to fill a gap often write on into what follows it.
pub fn trimOverlap(text: []const u8, suffix: []const u8) []const u8 {
    var k = @min(text.len, suffix.len);
    while (k > 0) : (k -= 1) {
        if (!std.mem.eql(u8, text[text.len - k ..], suffix[0..k])) continue;
        if (repeatsSuffix(text, suffix, k)) return text[0 .. text.len - k];
    }
    return text;
}

// ---------------------------------------------------------------------
// One question, as a task
// ---------------------------------------------------------------------

pub const Job = struct {
    gpa: Allocator,
    /// Everything the question and its answer need (the key too).
    arena: std.heap.ArenaAllocator,
    io: Io,
    wake: *const fn () void,
    transport: Transport,
    cfg: Config,
    query: Query,
    /// The key's copy, wiped when the job goes.
    key: []u8,
    future: Io.Future(void) = undefined,
    done: std.atomic.Value(bool) = .init(false),
    /// Valid once `finished`.
    outcome: Outcome = .{ .failed = "" },

    /// Starts asking (`cfg` and `q` are copied). `wake` is called, from
    /// the task, when the answer is there.
    pub fn start(gpa: Allocator, io: Io, wake: *const fn () void, transport: Transport, cfg: Config, q: Query) !*Job {
        const j = try gpa.create(Job);
        errdefer gpa.destroy(j);
        j.* = .{ .gpa = gpa, .arena = .init(gpa), .io = io, .wake = wake, .transport = transport, .cfg = cfg, .query = q, .key = &.{} };
        errdefer j.arena.deinit();
        const a = j.arena.allocator();
        j.key = try a.dupe(u8, cfg.key);
        errdefer std.crypto.secureZero(u8, j.key);
        j.cfg.key = j.key;
        j.cfg.host = try a.dupe(u8, cfg.host);
        j.cfg.local_model = try a.dupe(u8, cfg.local_model);
        j.cfg.model = try a.dupe(u8, cfg.model);
        j.query = .{
            .prefix = try a.dupe(u8, q.prefix),
            .suffix = try a.dupe(u8, q.suffix),
            .hint = try a.dupe(u8, q.hint),
            .file = try a.dupe(u8, q.file),
        };
        j.future = try io.concurrent(run, .{j});
        return j;
    }

    fn run(j: *Job) void {
        j.outcome = complete(j.arena.allocator(), j.io, j.transport, j.cfg, j.query);
        j.done.store(true, .release);
        j.wake();
    }

    pub fn finished(j: *const Job) bool {
        return j.done.load(.acquire);
    }

    /// Ends it. A question still on its way is canceled: the task's
    /// blocking read or write returns, and the connection is closed.
    pub fn destroy(j: *Job) void {
        _ = j.future.cancel(j.io);
        std.crypto.secureZero(u8, j.key);
        j.arena.deinit();
        j.gpa.destroy(j);
    }
};

// ---------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------

const testing = std.testing;

test "fill: the buffer splits at the cursor, never inside a character" {
    const s = split("fn main() {}", 11);
    try testing.expectEqualStrings("fn main() {", s.prefix);
    try testing.expectEqualStrings("}", s.suffix);
    // Both ends, and past the end.
    try testing.expectEqualStrings("", split("abc", 0).prefix);
    try testing.expectEqualStrings("abc", split("abc", 0).suffix);
    try testing.expectEqualStrings("abc", split("abc", 99).prefix);
    try testing.expectEqualStrings("", split("abc", 99).suffix);
    // "é" is two bytes: an offset between them is its start.
    const e = split("caf\xc3\xa9!", 4);
    try testing.expectEqualStrings("caf", e.prefix);
    try testing.expectEqualStrings("\xc3\xa9!", e.suffix);
    // Whatever the cut, the two halves are the text.
    for (0..8) |i| {
        const h = split("a\xe2\x82\xacb\n", i);
        try testing.expectEqual(6, h.prefix.len + h.suffix.len);
    }
}

test "fill: Anthropic is there with a key only; without it the choice is Local, said" {
    try testing.expect(available(.local, null));
    try testing.expect(!available(.anthropic, null));
    try testing.expect(!available(.anthropic, ""));
    try testing.expect(!available(.anthropic, "  \n"));
    try testing.expect(available(.anthropic, "sk-ant-test"));

    // Key set: what is selected is what is asked.
    try testing.expectEqual(Choice{ .backend = .anthropic }, choose(.anthropic, "sk-ant-test"));
    try testing.expectEqual(Choice{ .backend = .local }, choose(.local, "sk-ant-test"));
    // Key unset: Local, and not a fall back when Local was the choice.
    try testing.expectEqual(Choice{ .backend = .local }, choose(.local, null));
    // Key gone while Anthropic is selected: Local, flagged to be said.
    try testing.expectEqual(Choice{ .backend = .local, .fell_back = true }, choose(.anthropic, null));
}

test "fill: the Anthropic request: the file as prefix and suffix, the hint, Haiku without thinking" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const q: Query = .{ .prefix = "const x = ", .suffix = ";\n", .hint = " a prime ", .file = "src/a.zig" };

    try testing.expectEqualStrings(
        "<file>src/a.zig</file>\n<prefix>const x = </prefix>\n<suffix>;\n</suffix>\n<hint>a prime</hint>",
        try userMessage(a, q),
    );
    // No hint, no file: neither tag.
    try testing.expectEqualStrings("<prefix>a</prefix>\n<suffix>b</suffix>", try userMessage(a, .{ .prefix = "a", .suffix = "b" }));

    const call = try request(a, .{ .backend = .anthropic, .key = "sk-ant-test" }, q);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", call.url);
    try testing.expectEqualStrings("x-api-key", call.secret_headers[0].name);
    try testing.expectEqualStrings("sk-ant-test", call.secret_headers[0].value);
    try testing.expectEqualStrings("anthropic-version", call.headers[0].name);
    // The key is in its header and nowhere in the body.
    try testing.expect(std.mem.indexOf(u8, call.body, "sk-ant-test") == null);

    const Body = struct {
        model: []const u8,
        max_tokens: u32,
        system: []const u8,
        thinking: ?struct { type: []const u8 } = null,
        output_config: struct { effort: []const u8 },
        messages: []const struct { role: []const u8, content: []const u8 },
    };
    const body = try std.json.parseFromSliceLeaky(Body, a, call.body, .{});
    try testing.expectEqualStrings("claude-haiku-5-5", body.model);
    try testing.expectEqual(400, body.max_tokens);
    try testing.expectEqualStrings("disabled", body.thinking.?.type);
    try testing.expectEqualStrings("low", body.output_config.effort);
    try testing.expectEqual(1, body.messages.len);
    try testing.expectEqualStrings("user", body.messages[0].role);
    try testing.expect(std.mem.indexOf(u8, body.messages[0].content, "<prefix>const x = </prefix>") != null);
    try testing.expect(std.mem.indexOf(u8, body.system, "no markdown fences") != null);
    // Sampling settings are not sent (the API refuses them).
    try testing.expect(std.mem.indexOf(u8, call.body, "temperature") == null);

    // Another model keeps its thinking (it can't be turned off there) and
    // gets room for it.
    const other = try std.json.parseFromSliceLeaky(Body, a, try anthropicBody(a, apiOf(.anthropic).?, "claude-opus-5-5", q), .{});
    try testing.expectEqual(null, other.thinking);
    try testing.expectEqual(2000, other.max_tokens);
}

test "fill: DeepSeek is asked as Anthropic is, at its own address, with its own key and model" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ds = apiOf(.deepseek).?;
    try testing.expectEqualStrings("DeepSeek", Backend.deepseek.title());
    try testing.expectEqualStrings("DEEPSEEK_API_KEY", keyName(.deepseek));
    try testing.expectEqualStrings("", keyName(.local));
    try testing.expect(!available(.deepseek, null));
    try testing.expectEqual(Choice{ .backend = .local, .fell_back = true }, choose(.deepseek, " "));

    const call = try request(a, .{ .backend = .deepseek, .model = ds.model, .key = "sk-ds-test" }, .{ .prefix = "a", .suffix = "b" });
    try testing.expectEqualStrings("https://api.deepseek.com/anthropic/v1/messages", call.url);
    try testing.expectEqualStrings("sk-ds-test", call.secret_headers[0].value);
    try testing.expect(std.mem.indexOf(u8, call.body, "sk-ds-test") == null);
    const Body = struct { model: []const u8, max_tokens: u32, thinking: ?struct { type: []const u8 } = null };
    const body = try std.json.parseFromSliceLeaky(Body, a, call.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("deepseek-flash", body.model);
    // Its models all answer without thinking (its fill-in is non-thinking).
    try testing.expectEqualStrings("disabled", body.thinking.?.type);
    try testing.expectEqual(400, body.max_tokens);

    // Its failures carry its name and its key's.
    const bad = try anthropicReply(a, ds, .{ .status = 401, .body = "{\"error\":{\"type\":\"authentication_error\",\"message\":\"bad key\"}}" });
    try testing.expectEqualStrings("DeepSeek: bad key (HTTP 401; check DEEPSEEK_API_KEY)", bad.failed);
}

test "fill: the local request is the model's own: Ollama's prompt and suffix, no instructions" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const call = try request(a, .{ .backend = .local, .host = "http://localhost:11434/", .local_model = "qwen2.5-coder:1.5b-base" }, .{ .prefix = "int main() {\n    ", .suffix = "\n}\n", .hint = "ignored" });
    try testing.expectEqualStrings("http://localhost:11434/api/generate", call.url);
    try testing.expectEqual(0, call.secret_headers.len);
    const Body = struct { model: []const u8, prompt: []const u8, suffix: []const u8, stream: bool, options: struct { num_predict: u32 } };
    const body = try std.json.parseFromSliceLeaky(Body, a, call.body, .{ .ignore_unknown_fields = true });
    try testing.expectEqualStrings("qwen2.5-coder:1.5b-base", body.model);
    try testing.expectEqualStrings("int main() {\n    ", body.prompt);
    try testing.expectEqualStrings("\n}\n", body.suffix);
    try testing.expect(!body.stream);
    try testing.expectEqual(400, body.options.num_predict);
    try testing.expect(std.mem.indexOf(u8, call.body, "ignored") == null);
    try testing.expect(std.mem.indexOf(u8, call.body, "<prefix>") == null);
}

test "fill: a markdown fence around the code is taken off" {
    try testing.expectEqualStrings("return 1;", stripFences("```zig\nreturn 1;\n```"));
    try testing.expectEqualStrings("a\nb", stripFences("```\na\nb\n```\n"));
    try testing.expectEqualStrings("a\r\nb", stripFences("  ```c\r\na\r\nb\r\n```"));
    // Cut off before the closing fence: the opening one still goes.
    try testing.expectEqualStrings("x = 1;\n", stripFences("```python\nx = 1;\n"));
    // Not fenced: untouched, its indentation too.
    try testing.expectEqualStrings("    return 1;\n", stripFences("    return 1;\n"));
    // A fence inside the code isn't one around it.
    try testing.expectEqualStrings("a ``` b", stripFences("a ``` b"));
    try testing.expectEqualStrings("", stripFences("```"));
}

test "fill: a tail that repeats the start of the suffix is trimmed" {
    // The model wrote on into what follows the cursor.
    try testing.expectEqualStrings("    return 1;", trimOverlap("    return 1;\n}", "\n}\n"));
    try testing.expectEqualStrings("return a + b;", trimOverlap("return a + b;\n}\n\nfn next() void {", "\n}\n\nfn next() void {\n}"));
    // A closing bracket the completion never opened is the suffix's.
    try testing.expectEqualStrings("a, b", trimOverlap("a, b)", ");"));
    try testing.expectEqualStrings("hello", trimOverlap("hello\"", "\");"));
    try testing.expectEqualStrings("x + 1", trimOverlap("x + 1;", ";\n"));
    // Its own bracket stays: `call(|)` filled with `f(x)`.
    try testing.expectEqualStrings("f(x)", trimOverlap("f(x)", ");"));
    try testing.expectEqualStrings("\"two\"", trimOverlap("\"two\"", "\", 3)"));
    // A shared letter isn't a repeat: `value` before `else`.
    try testing.expectEqualStrings("value", trimOverlap("value", "else {"));
    try testing.expectEqualStrings("item", trimOverlap("item", "ems"));
    // A whole word said again is.
    try testing.expectEqualStrings("x =", trimOverlap("x = a", " a + b"));
    // Nothing in common, an empty suffix, an empty completion.
    try testing.expectEqualStrings("abc", trimOverlap("abc", "xyz"));
    try testing.expectEqualStrings("abc", trimOverlap("abc", ""));
    try testing.expectEqualStrings("", trimOverlap("", "abc"));
    // Both together, as a reply is cleaned.
    try testing.expectEqualStrings("return 1;", clean("```zig\nreturn 1;\n}\n```", "\n}\n"));
}

const Fake = struct {
    var status: u16 = 200;
    var body: []const u8 = "";
    var calls: usize = 0;
    var last_url: []const u8 = "";
    var fail: ?anyerror = null;

    fn send(a: Allocator, _: Io, call: Call) anyerror!Response {
        calls += 1;
        last_url = try a.dupe(u8, call.url);
        if (fail) |e| return e;
        return .{ .status = status, .body = try a.dupe(u8, body) };
    }

    fn set(s: u16, b: []const u8) void {
        status = s;
        body = b;
        fail = null;
    }
};

test "fill: replies are read, and every failure is said (the network is a stand-in here)" {
    var arena: std.heap.ArenaAllocator = .init(testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const io = testing.io;
    const q: Query = .{ .prefix = "fn one() u8 {\n", .suffix = "\n}\n" };
    const claude: Config = .{ .backend = .anthropic, .key = "sk-ant-test" };
    const local: Config = .{ .backend = .local, .host = "http://localhost:11434", .local_model = "tiny" };

    // Anthropic: the text blocks, in order, after a thinking block; the
    // fence and the repeated brace go.
    Fake.set(200,
        \\{"type":"message","content":[{"type":"thinking","thinking":"","signature":"s"},{"type":"text","text":"```zig\n    return 1;"},{"type":"text","text":"\n}\n```"}],"stop_reason":"end_turn"}
    );
    try testing.expectEqualStrings("    return 1;", complete(a, io, Fake.send, claude, q).text);
    try testing.expectEqualStrings("https://api.anthropic.com/v1/messages", Fake.last_url);

    // An empty completion is a text, empty (the editor says so).
    Fake.set(200, "{\"content\":[],\"stop_reason\":\"end_turn\"}");
    try testing.expectEqualStrings("", complete(a, io, Fake.send, claude, q).text);

    // The API's errors, as it words them, with the status.
    Fake.set(401, "{\"type\":\"error\",\"error\":{\"type\":\"authentication_error\",\"message\":\"invalid x-api-key\"}}");
    const unauthorized = complete(a, io, Fake.send, claude, q).failed;
    try testing.expect(std.mem.indexOf(u8, unauthorized, "invalid x-api-key") != null);
    try testing.expect(std.mem.indexOf(u8, unauthorized, "ANTHROPIC_API_KEY") != null);
    try testing.expect(std.mem.indexOf(u8, unauthorized, "sk-ant-test") == null);
    Fake.set(529, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}");
    try testing.expectEqualStrings("Anthropic: Overloaded (HTTP 529, overloaded_error)", complete(a, io, Fake.send, claude, q).failed);
    Fake.set(502, "<html>bad gateway</html>");
    try testing.expect(std.mem.indexOf(u8, complete(a, io, Fake.send, claude, q).failed, "HTTP 502") != null);
    // A declined request is a 200.
    Fake.set(200, "{\"content\":[],\"stop_reason\":\"refusal\",\"stop_details\":{\"type\":\"refusal\",\"category\":\"cyber\"}}");
    try testing.expectEqualStrings("Anthropic declined to complete this (cyber)", complete(a, io, Fake.send, claude, q).failed);
    // No network.
    Fake.fail = error.ConnectionRefused;
    try testing.expect(std.mem.indexOf(u8, complete(a, io, Fake.send, claude, q).failed, "ConnectionRefused") != null);

    // Local: Ollama's `response`, its error, no answer at all.
    Fake.set(200, "{\"model\":\"tiny\",\"response\":\"    return 1;\\n}\",\"done\":true}");
    try testing.expectEqualStrings("    return 1;", complete(a, io, Fake.send, local, q).text);
    try testing.expectEqualStrings("http://localhost:11434/api/generate", Fake.last_url);
    Fake.set(404, "{\"error\":\"model 'tiny' not found\"}");
    try testing.expectEqualStrings("Local: model 'tiny' not found (Ollama, model tiny)", complete(a, io, Fake.send, local, q).failed);
    Fake.fail = error.ConnectionRefused;
    try testing.expectEqualStrings("Local: no answer from Ollama at http://localhost:11434 (ConnectionRefused)", complete(a, io, Fake.send, local, q).failed);

    // A failure of one is never answered by the other: one call each.
    Fake.calls = 0;
    _ = complete(a, io, Fake.send, claude, q);
    try testing.expectEqual(1, Fake.calls);
}

const Slow = struct {
    var entered: std.atomic.Value(bool) = .init(false);
    var canceled: std.atomic.Value(bool) = .init(false);

    /// A model that takes a minute: only cancelation ends it sooner.
    fn send(_: Allocator, io: Io, _: Call) anyerror!Response {
        entered.store(true, .release);
        io.sleep(.fromSeconds(60), .awake) catch |err| {
            canceled.store(true, .release);
            return err;
        };
        return .{ .status = 200, .body = "{}" };
    }
};

fn noWake() void {}

test "fill: a job answers on its own task, and destroying one in flight cancels it (either backend)" {
    const io = testing.io;
    // Answered.
    Fake.set(200, "{\"response\":\"42\"}");
    const j = try Job.start(testing.allocator, io, noWake, Fake.send, .{ .backend = .local, .local_model = "tiny" }, .{ .prefix = "x = ", .suffix = ";" });
    while (!j.finished()) try io.sleep(.fromMilliseconds(1), .awake);
    try testing.expectEqualStrings("42", j.outcome.text);
    j.destroy();

    // In flight: destroy returns at once, and the request was interrupted
    // where it waited.
    for ([_]Backend{ .local, .anthropic }) |backend| {
        Slow.entered.store(false, .release);
        Slow.canceled.store(false, .release);
        const slow = try Job.start(testing.allocator, io, noWake, Slow.send, .{ .backend = backend, .local_model = "tiny", .key = "sk-ant-test" }, .{ .prefix = "a", .suffix = "b" });
        while (!Slow.entered.load(.acquire)) try io.sleep(.fromMilliseconds(1), .awake);
        const before = Io.Timestamp.now(io, .awake);
        slow.destroy();
        const took = before.durationTo(Io.Timestamp.now(io, .awake));
        try testing.expect(Slow.canceled.load(.acquire));
        try testing.expect(took.toMilliseconds() < 5000);
    }
}
