//! LSP snippets (`insertTextFormat: 2`): the text to insert and its tab
//! stops. Supports `$1`, `${1}`, `${1:default}` (defaults may nest),
//! `${1|one,two|}` (the first choice), `$0` (the final cursor), variables
//! (`$TM_FILENAME`, `${VAR:default}` -> the default) and `\` escapes. A stop
//! repeated later (a mirror) keeps its first place only.

const std = @import("std");
const Allocator = std.mem.Allocator;

const Snippet = @This();

/// A tab stop: its number and its byte range in `text`.
pub const Stop = struct { index: u32, start: usize, end: usize };

text: []u8,
/// Visiting order: 1, 2, ... then 0 (the final cursor) if present.
stops: []Stop,

pub fn deinit(s: Snippet, gpa: Allocator) void {
    gpa.free(s.text);
    gpa.free(s.stops);
}

pub fn parse(gpa: Allocator, src: []const u8) !Snippet {
    var p: Parser = .{ .gpa = gpa, .src = src };
    defer p.stops.deinit(gpa);
    errdefer p.out.deinit(gpa);
    try p.body(null);
    // Order: by number, $0 last; a mirror keeps the first occurrence.
    var stops: std.ArrayList(Stop) = .empty;
    errdefer stops.deinit(gpa);
    for (p.stops.items) |s| {
        const dup = for (stops.items) |o| {
            if (o.index == s.index) break true;
        } else false;
        if (!dup) try stops.append(gpa, s);
    }
    std.mem.sort(Stop, stops.items, {}, struct {
        fn lessThan(_: void, a: Stop, b: Stop) bool {
            if (a.index == 0) return false;
            if (b.index == 0) return true;
            return a.index < b.index;
        }
    }.lessThan);
    return .{ .text = try p.out.toOwnedSlice(gpa), .stops = try stops.toOwnedSlice(gpa) };
}

const Parser = struct {
    gpa: Allocator,
    src: []const u8,
    i: usize = 0,
    out: std.ArrayList(u8) = .empty,
    stops: std.ArrayList(Stop) = .empty,

    /// Text until `end` (a `}` closing a placeholder) or the end.
    fn body(p: *Parser, end: ?u8) Allocator.Error!void {
        while (p.i < p.src.len) {
            const c = p.src[p.i];
            if (end != null and c == end.?) return;
            switch (c) {
                '\\' => {
                    // `\$`, `\}`, `\\`: the character itself.
                    if (p.i + 1 < p.src.len and std.mem.indexOfScalar(u8, "$}\\,|", p.src[p.i + 1]) != null) {
                        try p.out.append(p.gpa, p.src[p.i + 1]);
                        p.i += 2;
                    } else {
                        try p.out.append(p.gpa, c);
                        p.i += 1;
                    }
                },
                '$' => try p.dollar(),
                else => {
                    try p.out.append(p.gpa, c);
                    p.i += 1;
                },
            }
        }
    }

    fn number(p: *Parser) ?u32 {
        const start = p.i;
        while (p.i < p.src.len and std.ascii.isDigit(p.src[p.i])) p.i += 1;
        if (p.i == start) return null;
        return std.fmt.parseInt(u32, p.src[start..p.i], 10) catch null;
    }

    fn name(p: *Parser) []const u8 {
        const start = p.i;
        while (p.i < p.src.len and (std.ascii.isAlphanumeric(p.src[p.i]) or p.src[p.i] == '_')) p.i += 1;
        return p.src[start..p.i];
    }

    fn dollar(p: *Parser) Allocator.Error!void {
        p.i += 1; // '$'
        if (p.i >= p.src.len) return p.out.append(p.gpa, '$');
        if (std.ascii.isDigit(p.src[p.i])) {
            const n = p.number().?;
            const at = p.out.items.len;
            return p.stops.append(p.gpa, .{ .index = n, .start = at, .end = at });
        }
        if (p.src[p.i] != '{') {
            // $VARIABLE: unknown variables are empty.
            if (p.name().len == 0) try p.out.append(p.gpa, '$');
            return;
        }
        p.i += 1; // '{'
        const start = p.out.items.len;
        if (p.number()) |n| {
            if (p.i < p.src.len and p.src[p.i] == ':') {
                p.i += 1;
                try p.body('}');
            } else if (p.i < p.src.len and p.src[p.i] == '|') {
                // A choice: the first option.
                p.i += 1;
                const opt_start = p.i;
                while (p.i < p.src.len and p.src[p.i] != ',' and p.src[p.i] != '|') p.i += 1;
                try p.out.appendSlice(p.gpa, p.src[opt_start..p.i]);
                while (p.i < p.src.len and p.src[p.i] != '}') p.i += 1;
            }
            if (p.i < p.src.len and p.src[p.i] == '}') p.i += 1;
            return p.stops.append(p.gpa, .{ .index = n, .start = start, .end = p.out.items.len });
        }
        // ${VAR} / ${VAR:default}: the default.
        _ = p.name();
        if (p.i < p.src.len and p.src[p.i] == ':') {
            p.i += 1;
            try p.body('}');
        } else {
            while (p.i < p.src.len and p.src[p.i] != '}') p.i += 1;
        }
        if (p.i < p.src.len and p.src[p.i] == '}') p.i += 1;
    }
};

const testing = std.testing;

fn expectStop(s: Snippet, i: usize, index: u32, text: []const u8) !void {
    try testing.expectEqual(index, s.stops[i].index);
    try testing.expectEqualStrings(text, s.text[s.stops[i].start..s.stops[i].end]);
}

test "placeholders, plain stops and the final cursor" {
    const s = try parse(testing.allocator, "doThing(${1:path}, ${2:opts})$0");
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("doThing(path, opts)", s.text);
    try testing.expectEqual(3, s.stops.len);
    try expectStop(s, 0, 1, "path");
    try expectStop(s, 1, 2, "opts");
    try expectStop(s, 2, 0, "");
    try testing.expectEqual(s.text.len, s.stops[2].start);
}

test "nesting, choices, mirrors, variables and escapes" {
    const s = try parse(testing.allocator, "${1:a${2:b}} ${3|x,y|} $1 \\$5 ${TM_FILENAME:file} $HOME");
    defer s.deinit(testing.allocator);
    try testing.expectEqualStrings("ab x  $5 file ", s.text);
    try expectStop(s, 0, 1, "ab");
    try expectStop(s, 1, 2, "b");
    try expectStop(s, 2, 3, "x");
    try testing.expectEqual(3, s.stops.len); // the mirrored $1 isn't a second stop
}
