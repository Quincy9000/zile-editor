//! Identifier case conversion (`Alt-c`): split a name into its words and
//! join them again in another style. Leading and trailing underscores
//! (`_private`, `__init__`) are kept as they are.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Style = enum {
    snake, // user_name
    camel, // userName
    pascal, // UserName
    screaming, // USER_NAME
    kebab, // user-name

    /// The style after this one in the `Alt-c` cycle.
    pub fn next(s: Style) Style {
        return switch (s) {
            .snake => .camel,
            .camel => .pascal,
            .pascal => .screaming,
            .screaming => .kebab,
            .kebab => .snake,
        };
    }
};

/// A character that can be part of a name (`-` joins kebab-case words).
pub fn isNameChar(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '_' or b == '-';
}

/// The style `word` is written in (a single lowercase word counts as snake).
pub fn detect(word: []const u8) Style {
    const core = std.mem.trim(u8, word, "_");
    if (std.mem.indexOfScalar(u8, core, '-') != null) return .kebab;
    var upper = false;
    var lower = false;
    for (core) |b| {
        if (std.ascii.isUpper(b)) upper = true;
        if (std.ascii.isLower(b)) lower = true;
    }
    if (upper and !lower) return .screaming;
    if (std.mem.indexOfScalar(u8, core, '_') != null) return .snake;
    if (core.len > 0 and std.ascii.isUpper(core[0])) return .pascal;
    return if (upper) .camel else .snake;
}

/// `word` in `style`. Caller frees.
pub fn convert(gpa: Allocator, word: []const u8, style: Style) ![]u8 {
    const lead = word.len - std.mem.trimStart(u8, word, "_").len;
    const trail = word.len - std.mem.trimEnd(u8, word, "_").len;
    if (lead == word.len) return gpa.dupe(u8, word);
    const core = word[lead .. word.len - trail];

    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    try out.appendSlice(gpa, word[0..lead]);
    var parts: [64][]const u8 = undefined;
    const n = split(core, &parts);
    for (parts[0..n], 0..) |part, i| {
        const sep: ?u8 = switch (style) {
            .snake, .screaming => '_',
            .kebab => '-',
            .camel, .pascal => null,
        };
        if (i > 0) if (sep) |c| try out.append(gpa, c);
        for (part, 0..) |b, j| {
            const up = switch (style) {
                .screaming => true,
                .snake, .kebab => false,
                .pascal => j == 0,
                .camel => j == 0 and i > 0,
            };
            try out.append(gpa, if (up) std.ascii.toUpper(b) else std.ascii.toLower(b));
        }
    }
    try out.appendSlice(gpa, word[word.len - trail ..]);
    return out.toOwnedSlice(gpa);
}

/// `Alt-c`: `word` in the next style that changes it. Caller frees.
pub fn cycle(gpa: Allocator, word: []const u8) ![]u8 {
    var style = detect(word).next();
    for (0..5) |_| {
        const out = try convert(gpa, word, style);
        if (!std.mem.eql(u8, out, word)) return out;
        gpa.free(out);
        style = style.next();
    }
    return gpa.dupe(u8, word);
}

/// The words of a name: split at `_` and `-`, before an uppercase letter that
/// follows a lowercase one or a digit, and before the last capital of a run
/// followed by a lowercase letter (`HTTPServer` -> `HTTP`, `Server`).
fn split(name: []const u8, out: [][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    var i: usize = 0;
    while (i < name.len) : (i += 1) {
        const b = name[i];
        if (b == '_' or b == '-') {
            if (i > start and n < out.len) {
                out[n] = name[start..i];
                n += 1;
            }
            start = i + 1;
            continue;
        }
        if (i > start and std.ascii.isUpper(b)) {
            const prev = name[i - 1];
            const boundary = std.ascii.isLower(prev) or std.ascii.isDigit(prev) or
                (std.ascii.isUpper(prev) and i + 1 < name.len and std.ascii.isLower(name[i + 1]));
            if (boundary and n < out.len) {
                out[n] = name[start..i];
                n += 1;
                start = i;
            }
        }
    }
    if (start < name.len and n < out.len) {
        out[n] = name[start..];
        n += 1;
    }
    return n;
}

test "case styles convert and cycle" {
    const gpa = std.testing.allocator;
    const Case = struct { in: []const u8, style: Style, out: []const u8 };
    for ([_]Case{
        .{ .in = "user_name", .style = .camel, .out = "userName" },
        .{ .in = "userName", .style = .pascal, .out = "UserName" },
        .{ .in = "UserName", .style = .screaming, .out = "USER_NAME" },
        .{ .in = "USER_NAME", .style = .kebab, .out = "user-name" },
        .{ .in = "user-name", .style = .snake, .out = "user_name" },
        .{ .in = "HTTPServer", .style = .snake, .out = "http_server" },
        .{ .in = "parseJSON2Html", .style = .snake, .out = "parse_json2_html" },
        .{ .in = "_private_thing", .style = .camel, .out = "_privateThing" },
        .{ .in = "__init__", .style = .pascal, .out = "__Init__" },
    }) |cs| {
        const got = try convert(gpa, cs.in, cs.style);
        defer gpa.free(got);
        try std.testing.expectEqualStrings(cs.out, got);
    }
    try std.testing.expectEqual(Style.snake, detect("name"));
    try std.testing.expectEqual(Style.screaming, detect("MAX"));
    // A full turn of the cycle comes back.
    var word = try gpa.dupe(u8, "user_name");
    for ([_][]const u8{ "userName", "UserName", "USER_NAME", "user-name", "user_name" }) |want| {
        const next = try cycle(gpa, word);
        gpa.free(word);
        word = next;
        try std.testing.expectEqualStrings(want, word);
    }
    gpa.free(word);
    // One word: snake and camel are the same, so on to Pascal.
    const one = try cycle(gpa, "name");
    defer gpa.free(one);
    try std.testing.expectEqualStrings("Name", one);
}
