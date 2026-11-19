//! Editor tests: AI completion asked for by hand (`SPC a f`, `<A-f>`).
//! No model and no network: the editor's transport is a stand-in here, and
//! so is the key.

const std = @import("std");
const testing = std.testing;
const Io = std.Io;
const Editor = @import("../Editor.zig");
const ai_fill = Editor.ai_fill;
const fill = @import("../ai/fill.zig");
const settings = @import("../config/settings.zig");
const support = @import("support.zig");
const testEditor = support.testEditor;
const expectText = support.expectText;
const settlePicker = support.settlePicker;

/// The network: answers what a test set, and remembers what it was sent.
const Net = struct {
    var status: u16 = 200;
    var body: []const u8 = "";
    /// Stay in flight (a model that takes a minute) until canceled.
    var hold: bool = false;
    var calls: usize = 0;
    var anthropic_calls: usize = 0;
    var deepseek_calls: usize = 0;
    var local_calls: usize = 0;
    var key_sent: bool = false;
    /// The key sent to a host that isn't its service's.
    var key_strayed: bool = false;
    var whole_file_sent: bool = false;
    var entered: std.atomic.Value(bool) = .init(false);
    var canceled: std.atomic.Value(bool) = .init(false);

    fn reset(s: u16, b: []const u8) void {
        status = s;
        body = b;
        hold = false;
        calls = 0;
        anthropic_calls = 0;
        deepseek_calls = 0;
        local_calls = 0;
        key_sent = false;
        key_strayed = false;
        whole_file_sent = false;
        entered.store(false, .release);
        canceled.store(false, .release);
    }

    fn send(a: std.mem.Allocator, io: Io, call: fill.Call) anyerror!fill.Response {
        calls += 1;
        const to_anthropic = std.mem.indexOf(u8, call.url, "api.anthropic.com") != null;
        const to_deepseek = std.mem.indexOf(u8, call.url, "api.deepseek.com") != null;
        if (to_anthropic) anthropic_calls += 1 else if (to_deepseek) deepseek_calls += 1 else local_calls += 1;
        for (call.secret_headers) |h| {
            if (!std.mem.eql(u8, h.name, "x-api-key")) continue;
            const ant = std.mem.eql(u8, h.value, "sk-ant-test");
            const ds = std.mem.eql(u8, h.value, "sk-ds-test");
            if (ant or ds) key_sent = true;
            if ((ant and !to_anthropic) or (ds and !to_deepseek)) key_strayed = true;
        }
        whole_file_sent = std.mem.indexOf(u8, call.body, "first line of the file") != null;
        entered.store(true, .release);
        if (hold) {
            io.sleep(.fromSeconds(60), .awake) catch |err| {
                canceled.store(true, .release);
                return err;
            };
        }
        return .{ .status = status, .body = try a.dupe(u8, body) };
    }
};

fn noKey(_: ai_fill.Backend) ?[]const u8 {
    return null;
}

/// Anthropic's key only.
fn testKey(b: ai_fill.Backend) ?[]const u8 {
    return if (b == .anthropic) "sk-ant-test" else null;
}

/// Every service's key.
fn allKeys(b: ai_fill.Backend) ?[]const u8 {
    return switch (b) {
        .local => null,
        .anthropic => "sk-ant-test",
        .deepseek => "sk-ds-test",
    };
}

/// An editor that asks `Net`, with or without a key.
fn fillEditor(content: []const u8, key: bool) !Editor {
    var ed = try testEditor(content);
    ed.ai_request.transport = Net.send;
    ed.ai_request.key = if (key) testKey else noKey;
    return ed;
}

/// Waits for the answer and lets the editor take it.
fn settle(ed: *Editor) !void {
    const j = ed.ai_request.job orelse return;
    while (!j.finished()) try testing.io.sleep(.fromMilliseconds(1), .awake);
    ed.tick();
}

fn waitEntered() !void {
    while (!Net.entered.load(.acquire)) try testing.io.sleep(.fromMilliseconds(1), .awake);
}

const ollama_one = "{\"response\":\"return 1;\",\"done\":true}";

fn lastToast(ed: *Editor) []const u8 {
    return if (ed.toasts.items.len > 0) ed.toasts.items[ed.toasts.items.len - 1].text() else "";
}

test "ai fill: <A-f> asks the local model and shows what it wrote; nothing is in the file until <A-;> takes it, as one undo step" {
    Net.reset(200, ollama_one);
    // Local is asked even with a key: Anthropic costs nothing until chosen.
    var ed = try fillEditor("fn one() u8 {\n    \n}", true);
    defer ed.deinit();
    try testing.expectEqual(.local, ed.options.ai_backend);
    try ed.feed("ggjAx = <A-f>");
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("asking Local… (A-f stops)", ai_fill.indicator(&ed, &buf));
    try settle(&ed);
    try testing.expectEqual(1, Net.local_calls);
    try testing.expectEqual(0, Net.anthropic_calls);
    try testing.expect(!Net.key_sent);

    // On show, not in the file.
    try expectText(&ed, "fn one() u8 {\n    x = \n}");
    try testing.expectEqualStrings("return 1;", ai_fill.previewHere(&ed).?);
    try testing.expectEqualStrings("Local: A-; takes it, Esc drops it", ai_fill.indicator(&ed, &buf));

    try ed.feed("<A-;>");
    try expectText(&ed, "fn one() u8 {\n    x = return 1;\n}");
    try testing.expectEqual(null, ai_fill.previewHere(&ed));
    try testing.expectEqualStrings("", ai_fill.indicator(&ed, &buf));

    // One `u` takes the completion back, and only it.
    try ed.feed("<Esc>u");
    try expectText(&ed, "fn one() u8 {\n    x = \n}");
    try ed.feed("u");
    try expectText(&ed, "fn one() u8 {\n    \n}");
}

test "ai fill: Esc drops it, so does typing something else; typing it out keeps the rest, <A-l> takes a line" {
    Net.reset(200, "{\"response\":\"a();\\nb();\"}");
    var ed = try fillEditor("{\n\n}", false);
    defer ed.deinit();

    try ed.feed("ggji<A-f>");
    try settle(&ed);
    try testing.expectEqualStrings("a();\nb();", ai_fill.previewHere(&ed).?);
    try ed.feed("<Esc>");
    try testing.expectEqual(null, ed.ai_request.preview);
    try expectText(&ed, "{\n\n}");

    try ed.feed("i<A-f>");
    try settle(&ed);
    try ed.feed("z");
    try testing.expectEqual(null, ed.ai_request.preview);
    try expectText(&ed, "{\nz\n}");

    try ed.feed("<BS><A-f>");
    try settle(&ed);
    // The model's own first letter, typed: the rest stays on show.
    try ed.feed("a");
    try testing.expectEqualStrings("();\nb();", ai_fill.previewHere(&ed).?);
    try ed.feed("<A-l>");
    try expectText(&ed, "{\na();\n}");
    try testing.expectEqualStrings("\nb();", ai_fill.previewHere(&ed).?);
    try ed.feed("<A-l>");
    try expectText(&ed, "{\na();\nb();\n}");
    try testing.expectEqual(null, ed.ai_request.preview);
}

test "ai fill: pressing again stops a question on its way, and so does moving on; either backend's request is abandoned" {
    for ([_]fill.Backend{ .local, .anthropic }) |backend| {
        Net.reset(200, ollama_one);
        Net.hold = true;
        var ed = try fillEditor("first line of the file\n", true);
        defer ed.deinit();
        ed.options.ai_backend = backend;

        try ed.feed("A<A-f>");
        try waitEntered();
        try testing.expect(ed.ai_request.job != null);
        try ed.feed("<A-f>");
        try testing.expectEqual(null, ed.ai_request.job);
        try testing.expect(Net.canceled.load(.acquire));
        try testing.expectEqualStrings("AI completion: stopped asking", ed.message.text());

        // Asked again, then the text changes under it: dropped, unanswered.
        Net.entered.store(false, .release);
        Net.canceled.store(false, .release);
        try ed.feed("<A-f>");
        try waitEntered();
        try ed.feed("!");
        try testing.expectEqual(null, ed.ai_request.job);
        try testing.expect(Net.canceled.load(.acquire));
        try testing.expectEqual(null, ed.ai_request.preview);
        try expectText(&ed, "first line of the file!\n");

        // And leaving insert mode.
        Net.entered.store(false, .release);
        try ed.feed("<A-f>");
        try waitEntered();
        try ed.feed("<Esc>");
        try testing.expectEqual(null, ed.ai_request.job);
    }
}

test "ai fill: Anthropic can be chosen only with its key; then it gets the whole file and the key in a header" {
    Net.reset(200, "{\"content\":[{\"type\":\"text\",\"text\":\"```\\nsecond();\\n```\"}],\"stop_reason\":\"end_turn\"}");
    // No key: Local is all there is, and the list says why.
    var bare = try fillEditor("x", false);
    defer bare.deinit();
    try testing.expect(ai_fill.available(&bare, .local));
    try testing.expect(!ai_fill.available(&bare, .anthropic));
    ai_fill.setBackend(&bare, .anthropic);
    try testing.expectEqual(.local, bare.options.ai_backend);
    try testing.expect(std.mem.indexOf(u8, bare.message.text(), "ANTHROPIC_API_KEY") != null);
    try bare.feed("<Space>ab");
    settlePicker(&bare);
    try testing.expectEqual(.ai_backends, bare.picker.?.kind);
    try testing.expect(std.mem.startsWith(u8, bare.picker.?.itemAt(0).?.text, "Local: "));
    try testing.expectEqualStrings("current", bare.picker.?.itemAt(0).?.detail);
    try testing.expectEqualStrings("Anthropic: claude-haiku-5-5", bare.picker.?.itemAt(1).?.text);
    try testing.expectEqualStrings("no API key", bare.picker.?.itemAt(1).?.detail);
    // Picking it anyway changes nothing.
    try bare.feed("j<CR>");
    try testing.expectEqual(.local, bare.options.ai_backend);

    // With the key: still Local until it is picked.
    var ed = try fillEditor("first line of the file\n\nlast();", true);
    defer ed.deinit();
    try testing.expectEqual(.local, ai_fill.selected(&ed));
    try ed.feed("<Space>ab");
    settlePicker(&ed);
    try testing.expectEqualStrings("current", ed.picker.?.itemAt(0).?.detail);
    try testing.expectEqualStrings("", ed.picker.?.itemAt(1).?.detail);
    try ed.feed("j<CR>");
    try testing.expectEqual(.anthropic, ed.options.ai_backend);
    try testing.expect(std.mem.startsWith(u8, ed.message.text(), "AI completion: Anthropic (claude-haiku-5-5)"));

    // From normal mode, SPC a f: after the cursor's character (line 2 is
    // empty: at its start).
    try ed.feed("ggj<Space>af");
    try testing.expectEqual(.insert, ed.mode);
    try settle(&ed);
    try testing.expectEqual(1, Net.anthropic_calls);
    try testing.expectEqual(0, Net.local_calls);
    try testing.expect(Net.key_sent);
    try testing.expect(Net.whole_file_sent);
    // The fence is gone; who wrote it is said.
    try testing.expectEqualStrings("second();", ai_fill.previewHere(&ed).?);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("Anthropic: A-; takes it, Esc drops it", ai_fill.indicator(&ed, &buf));
    try ed.feed("<A-;>");
    try expectText(&ed, "first line of the file\nsecond();\nlast();");
}

test "ai fill: DeepSeek is a backend like Anthropic: its own key, its own model, its own address" {
    Net.reset(200, "{\"content\":[{\"type\":\"text\",\"text\":\"second();\"}],\"stop_reason\":\"end_turn\"}");
    // Only Anthropic's key: DeepSeek is listed, not available.
    var ant = try fillEditor("x", true);
    defer ant.deinit();
    try testing.expect(!ai_fill.available(&ant, .deepseek));
    ai_fill.setBackend(&ant, .deepseek);
    try testing.expectEqual(.local, ant.options.ai_backend);
    try testing.expect(std.mem.indexOf(u8, ant.message.text(), "DEEPSEEK_API_KEY") != null);

    var ed = try fillEditor("first line of the file\n\nlast();", true);
    defer ed.deinit();
    ed.ai_request.key = allKeys;
    try ed.feed("<Space>ab");
    settlePicker(&ed);
    try testing.expectEqualStrings("DeepSeek: deepseek-flash", ed.picker.?.itemAt(2).?.text);
    try testing.expectEqualStrings("", ed.picker.?.itemAt(2).?.detail);
    try ed.feed("jj<CR>");
    try testing.expectEqual(.deepseek, ed.options.ai_backend);
    try testing.expect(std.mem.startsWith(u8, ed.message.text(), "AI completion: DeepSeek (deepseek-flash)"));

    try ed.feed("ggj<Space>af");
    try settle(&ed);
    try testing.expectEqual(1, Net.deepseek_calls);
    try testing.expectEqual(0, Net.anthropic_calls + Net.local_calls);
    try testing.expect(Net.key_sent);
    try testing.expect(!Net.key_strayed);
    try testing.expect(Net.whole_file_sent);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("DeepSeek: A-; takes it, Esc drops it", ai_fill.indicator(&ed, &buf));
    try ed.feed("<A-;>");
    try expectText(&ed, "first line of the file\nsecond();\nlast();");
}

test "ai fill: the key gone mid-session: Local answers from then on, and it is said once" {
    Net.reset(200, ollama_one);
    var ed = try fillEditor("x\n", true);
    defer ed.deinit();
    ai_fill.setBackend(&ed, .anthropic);
    try testing.expectEqual(.anthropic, ed.options.ai_backend);

    ed.ai_request.key = noKey;
    const toasts_before = ed.toasts.items.len;
    try ed.feed("A<A-f>");
    try settle(&ed);
    try testing.expectEqual(.local, ed.options.ai_backend);
    try testing.expectEqual(toasts_before + 1, ed.toasts.items.len);
    try testing.expectEqualStrings("No ANTHROPIC_API_KEY: the local model answers", lastToast(&ed));
    try testing.expectEqual(1, Net.local_calls);
    try testing.expectEqual(0, Net.anthropic_calls);
    try testing.expect(!Net.key_sent);
    try testing.expectEqualStrings("return 1;", ai_fill.previewHere(&ed).?);

    // Not said again.
    try ed.feed("<Esc>A<A-f>");
    try settle(&ed);
    try testing.expectEqual(toasts_before + 1, ed.toasts.items.len);
}

test "ai fill: a request that fails is said, and the other backend is never asked in its place" {
    Net.reset(529, "{\"type\":\"error\",\"error\":{\"type\":\"overloaded_error\",\"message\":\"Overloaded\"}}");
    var ed = try fillEditor("x\n", true);
    defer ed.deinit();
    ai_fill.setBackend(&ed, .anthropic);
    try ed.feed("A<A-f>");
    try settle(&ed);
    try testing.expectEqualStrings("Anthropic: Overloaded (HTTP 529, overloaded_error)", ed.message.text());
    try testing.expectEqual(.err, ed.message.kind);
    try testing.expectEqual(1, Net.calls);
    try testing.expectEqual(0, Net.local_calls);
    try testing.expectEqual(.anthropic, ed.options.ai_backend);
    try testing.expectEqual(null, ed.ai_request.preview);
    try testing.expectEqual(null, ed.ai_request.job);
    try expectText(&ed, "x\n");

    // The local model not there: said too, and Anthropic isn't asked.
    Net.reset(404, "{\"error\":\"model 'tiny' not found\"}");
    ai_fill.setBackend(&ed, .local);
    try ed.feed("<Esc>A<A-f>");
    try settle(&ed);
    try testing.expect(std.mem.startsWith(u8, ed.message.text(), "Local: model 'tiny' not found"));
    try testing.expectEqual(0, Net.anthropic_calls);

    // An empty completion.
    Net.reset(200, "{\"response\":\"\\n\"}");
    try ed.feed("<Esc>A<A-f>");
    try settle(&ed);
    try testing.expectEqualStrings("AI completion: Local has nothing to add here", ed.message.text());
    try testing.expectEqual(null, ed.ai_request.preview);
}

test "ai fill: aibackend and aimodel in config.zon" {
    const loaded = settings.parse(
        \\.{
        \\    .aibackend = .anthropic,
        \\    .aimodel = "claude-sonnet-5-5",
        \\}
    );
    try testing.expectEqual(0, loaded.problems.len);
    var ed = try fillEditor("x", true);
    defer ed.deinit();
    try testing.expectEqualStrings("claude-haiku-5-5", ed.options.ai_model);
    _ = settings.apply(&ed, &loaded.settings);
    try testing.expectEqual(.anthropic, ed.options.ai_backend);
    try testing.expectEqualStrings("claude-sonnet-5-5", ed.options.ai_model);
    var buf: [200]u8 = undefined;
    const r = ai_fill.row(&ed, .anthropic, &buf);
    try testing.expectEqualStrings("Anthropic: claude-sonnet-5-5", r.text);
    try testing.expectEqualStrings("current", r.detail);

    // Set to Anthropic in the file, but no key when zile runs: Local.
    var bare = try fillEditor("x", false);
    defer bare.deinit();
    _ = settings.apply(&bare, &loaded.settings);
    try testing.expectEqual(.local, ai_fill.selected(&bare));

    // A backend that doesn't exist is the file's mistake, with its line.
    const wrong = settings.parse(".{\n    .aibackend = .openai,\n}");
    try testing.expect(wrong.problems.len > 0);
    try testing.expect(std.mem.startsWith(u8, wrong.problems[0], "config.zon:2:"));
}

test "ai fill: the backend picked is remembered: written to config.zon, which is otherwise left as it was" {
    const gpa = testing.allocator;
    const io = testing.io;
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var dir_buf: [Io.Dir.max_path_bytes]u8 = undefined;
    const dir = dir_buf[0..try tmp.dir.realPath(io, &dir_buf)];
    const file = try std.fs.path.join(gpa, &.{ dir, "config.zon" });
    defer gpa.free(file);
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = "// mine\n.{\n    .wrap = false,\n}\n" });
    settings.test_file = file;
    defer settings.test_file = null;

    var ed = try fillEditor("x", true);
    defer ed.deinit();
    try ed.feed("<Space>ab");
    settlePicker(&ed);
    try ed.feed("j<CR>");
    try testing.expectEqual(.anthropic, ed.options.ai_backend);
    try testing.expectEqualStrings("AI completion: Anthropic (claude-haiku-5-5), kept in config.zon", ed.message.text());
    {
        const text = try tmp.dir.readFileAlloc(io, "config.zon", gpa, .limited(4096));
        defer gpa.free(text);
        try testing.expectEqualStrings("// mine\n.{\n    .wrap = false,\n    .aibackend = .anthropic,\n}\n", text);
    }
    // The next zile starts with it.
    {
        const source = try tmp.dir.readFileAllocOptions(io, "config.zon", gpa, .limited(4096), .of(u8), 0);
        defer gpa.free(source);
        var next = try fillEditor("x", true);
        defer next.deinit();
        try testing.expectEqual(.local, next.options.ai_backend);
        _ = settings.apply(&next, &settings.parse(source).settings);
        try testing.expectEqual(.anthropic, ai_fill.selected(&next));
        try testing.expect(!next.options.wrap);
    }
    // Picked back: the same line, changed.
    ai_fill.setBackend(&ed, .local);
    {
        const text = try tmp.dir.readFileAlloc(io, "config.zon", gpa, .limited(4096));
        defer gpa.free(text);
        try testing.expectEqualStrings("// mine\n.{\n    .wrap = false,\n    .aibackend = .local,\n}\n", text);
    }

    // The key gone: Local answers, but what was picked stays in the file
    // (a key missing today isn't a change of mind).
    ai_fill.setBackend(&ed, .anthropic);
    ed.ai_request.key = noKey;
    try testing.expectEqual(.local, ai_fill.selected(&ed));
    // And without a key nothing can be picked, so nothing is written.
    ai_fill.setBackend(&ed, .anthropic);
    {
        const text = try tmp.dir.readFileAlloc(io, "config.zon", gpa, .limited(4096));
        defer gpa.free(text);
        try testing.expect(std.mem.indexOf(u8, text, ".aibackend = .anthropic,") != null);
    }

    // A file with a mistake in it is left alone: the pick holds until zile
    // closes, and that is said.
    try tmp.dir.writeFile(io, .{ .sub_path = "config.zon", .data = ".{\n    .wrap = fals,\n}\n" });
    ed.ai_request.key = testKey;
    ai_fill.setBackend(&ed, .anthropic);
    try testing.expectEqual(.anthropic, ed.options.ai_backend);
    try testing.expect(std.mem.indexOf(u8, ed.message.text(), "config.zon has a mistake") != null);
    {
        const text = try tmp.dir.readFileAlloc(io, "config.zon", gpa, .limited(4096));
        defer gpa.free(text);
        try testing.expectEqualStrings(".{\n    .wrap = fals,\n}\n", text);
    }
}
