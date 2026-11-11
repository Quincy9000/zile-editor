//! Emmet abbreviations: `div.card>h2{Title}+p*2` becomes markup, written as
//! a snippet whose tab stops are the empty contents and attribute values.
//!
//!   name        an element (`div`, `View`); left out it is a `div`
//!   #id .class  attributes (`class` is `className` in JSX)
//!   [a b=x]     more attributes (`[href]` leaves its value to fill in)
//!   {text}      the content
//!   *3          three of it; `$` in it counts 1, 2, 3 (`$$` = 01, 02 ...)
//!   >  +  ^     child, sibling, back up a level;  ( )  a group
//!
//! Pure: text in, snippet out.

const std = @import("std");
const Allocator = std.mem.Allocator;

pub const Options = struct {
    /// JSX: `className`, `htmlFor`, and void elements self-close.
    jsx: bool = false,
    /// One level of indentation.
    unit: []const u8 = "  ",
    /// The current line's indentation (lines after the first get it).
    indent: []const u8 = "",
};

const Node = struct {
    name: []const u8 = "",
    id: []const u8 = "",
    classes: std.ArrayList([]const u8) = .empty,
    attrs: std.ArrayList(Attr) = .empty,
    text: ?[]const u8 = null,
    count: usize = 1,
    children: std.ArrayList(*Node) = .empty,
    /// A `( )` group: only its children are written.
    group: bool = false,
};

const Attr = struct { name: []const u8, value: ?[]const u8 };

const Parser = struct {
    a: Allocator,
    src: []const u8,
    i: usize = 0,

    fn peek(p: *Parser) u8 {
        return if (p.i < p.src.len) p.src[p.i] else 0;
    }

    /// Siblings up to `)` or the end; returns them and how many levels a
    /// `^` asked to climb out of this list.
    fn seq(p: *Parser, out: *std.ArrayList(*Node)) error{ OutOfMemory, Invalid }!usize {
        while (true) {
            const n = try p.term();
            try out.append(p.a, n);
            switch (p.peek()) {
                '>' => {
                    p.i += 1;
                    const climbs = try p.seq(&n.children);
                    if (climbs == 0) return 0;
                    if (climbs > 1) return climbs - 1;
                    // `^`: the next one is this one's sibling.
                },
                '+' => p.i += 1,
                '^' => {
                    var climbs: usize = 0;
                    while (p.peek() == '^') : (p.i += 1) climbs += 1;
                    return climbs;
                },
                ')', 0 => return 0,
                else => return error.Invalid,
            }
        }
    }

    fn term(p: *Parser) !*Node {
        const n = try p.a.create(Node);
        n.* = .{};
        if (p.peek() == '(') {
            p.i += 1;
            n.group = true;
            _ = try p.seq(&n.children);
            if (p.peek() != ')') return error.Invalid;
            p.i += 1;
            n.count = try p.multiplier();
            return n;
        }
        const name_start = p.i;
        while (p.i < p.src.len and isNameByte(p.src[p.i])) p.i += 1;
        n.name = p.src[name_start..p.i];
        while (true) switch (p.peek()) {
            '#' => {
                p.i += 1;
                n.id = p.word();
            },
            '.' => {
                p.i += 1;
                const c = p.word();
                if (c.len == 0) return error.Invalid;
                try n.classes.append(p.a, c);
            },
            '[' => {
                p.i += 1;
                try p.attributes(n);
            },
            '{' => {
                p.i += 1;
                const start = p.i;
                var depth: usize = 0;
                while (p.i < p.src.len) : (p.i += 1) {
                    if (p.src[p.i] == '{') depth += 1;
                    if (p.src[p.i] == '}') {
                        if (depth == 0) break;
                        depth -= 1;
                    }
                }
                if (p.i >= p.src.len) return error.Invalid;
                n.text = p.src[start..p.i];
                p.i += 1;
            },
            '*' => n.count = try p.multiplier(),
            else => break,
        };
        if (n.name.len == 0 and n.id.len == 0 and n.classes.items.len == 0 and n.attrs.items.len == 0 and n.text == null)
            return error.Invalid;
        return n;
    }

    fn multiplier(p: *Parser) !usize {
        if (p.peek() != '*') return 1;
        p.i += 1;
        const start = p.i;
        while (p.i < p.src.len and std.ascii.isDigit(p.src[p.i])) p.i += 1;
        const n = std.fmt.parseInt(usize, p.src[start..p.i], 10) catch return error.Invalid;
        if (n == 0 or n > 100) return error.Invalid;
        return n;
    }

    fn word(p: *Parser) []const u8 {
        const start = p.i;
        while (p.i < p.src.len and (isNameByte(p.src[p.i]) or p.src[p.i] == '$') and p.src[p.i] != '.') p.i += 1;
        return p.src[start..p.i];
    }

    fn attributes(p: *Parser, n: *Node) !void {
        while (true) {
            while (p.peek() == ' ') p.i += 1;
            if (p.peek() == ']') {
                p.i += 1;
                return;
            }
            const start = p.i;
            while (p.i < p.src.len and p.src[p.i] != '=' and p.src[p.i] != ' ' and p.src[p.i] != ']') p.i += 1;
            const name = p.src[start..p.i];
            if (name.len == 0) return error.Invalid;
            var value: ?[]const u8 = null;
            if (p.peek() == '=') {
                p.i += 1;
                const q = p.peek();
                if (q == '"' or q == '\'') {
                    p.i += 1;
                    const vs = p.i;
                    while (p.i < p.src.len and p.src[p.i] != q) p.i += 1;
                    if (p.i >= p.src.len) return error.Invalid;
                    value = p.src[vs..p.i];
                    p.i += 1;
                } else {
                    const vs = p.i;
                    while (p.i < p.src.len and p.src[p.i] != ' ' and p.src[p.i] != ']') p.i += 1;
                    value = p.src[vs..p.i];
                }
            }
            try n.attrs.append(p.a, .{ .name = name, .value = value });
            if (p.i >= p.src.len) return error.Invalid;
        }
    }
};

fn isNameByte(b: u8) bool {
    return std.ascii.isAlphanumeric(b) or b == '-' or b == '_' or b == ':' or b == '@' or b == '!';
}

const void_elements = [_][]const u8{ "area", "base", "br", "col", "embed", "hr", "img", "input", "link", "meta", "source", "track", "wbr" };

fn isVoid(name: []const u8) bool {
    for (void_elements) |v| if (std.mem.eql(u8, v, name)) return true;
    return false;
}

/// Attributes an element gets even when not asked for (to fill in).
fn defaultAttrs(name: []const u8) []const []const u8 {
    if (std.mem.eql(u8, name, "a")) return &.{"href"};
    if (std.mem.eql(u8, name, "img")) return &.{ "src", "alt" };
    if (std.mem.eql(u8, name, "input")) return &.{"type"};
    if (std.mem.eql(u8, name, "label")) return &.{"for"};
    if (std.mem.eql(u8, name, "form")) return &.{"action"};
    if (std.mem.eql(u8, name, "link")) return &.{ "rel", "href" };
    if (std.mem.eql(u8, name, "script")) return &.{"src"};
    return &.{};
}

const Writer = struct {
    a: Allocator,
    out: std.ArrayList(u8) = .empty,
    opts: Options,
    stop: u32 = 0,

    fn raw(w: *Writer, s: []const u8) !void {
        try w.out.appendSlice(w.a, s);
    }

    /// Text as the snippet shows it: `$ } \` escaped, `$` numbered.
    fn lit(w: *Writer, s: []const u8, index: usize) !void {
        var i: usize = 0;
        while (i < s.len) : (i += 1) {
            if (s[i] == '$') {
                var width: usize = 0;
                while (i < s.len and s[i] == '$') : (i += 1) width += 1;
                i -= 1;
                var buf: [16]u8 = undefined;
                const num = std.fmt.bufPrint(&buf, "{d:0>[1]}", .{ index, width }) catch "";
                try w.raw(num);
                continue;
            }
            if (s[i] == '}' or s[i] == '\\') try w.raw("\\");
            try w.out.append(w.a, s[i]);
        }
    }

    fn placeholder(w: *Writer) !void {
        w.stop += 1;
        var buf: [16]u8 = undefined;
        try w.raw(std.fmt.bufPrint(&buf, "${{{d}}}", .{w.stop}) catch "");
    }

    fn newline(w: *Writer, depth: usize) !void {
        try w.raw("\n");
        try w.raw(w.opts.indent);
        for (0..depth) |_| try w.raw(w.opts.unit);
    }

    fn attr(w: *Writer, name: []const u8, value: ?[]const u8, index: usize) !void {
        const n = if (w.opts.jsx and std.mem.eql(u8, name, "class")) "className" else if (w.opts.jsx and std.mem.eql(u8, name, "for")) "htmlFor" else name;
        try w.raw(" ");
        try w.lit(n, index);
        try w.raw("=\"");
        if (value) |v| try w.lit(v, index) else try w.placeholder();
        try w.raw("\"");
    }

    /// The nodes of a list, each on its own line when `block`.
    fn list(w: *Writer, nodes: []const *Node, depth: usize, first: *bool, outer_index: usize) error{OutOfMemory}!void {
        for (nodes) |n| for (0..n.count) |k| {
            const index = if (n.count > 1) k + 1 else outer_index;
            if (n.group) {
                try w.list(n.children.items, depth, first, index);
                continue;
            }
            if (!first.*) try w.newline(depth);
            first.* = false;
            try w.element(n, depth, index);
        };
    }

    fn element(w: *Writer, n: *const Node, depth: usize, index: usize) !void {
        const name = if (n.name.len > 0) n.name else "div";
        try w.raw("<");
        try w.lit(name, index);
        if (n.id.len > 0) try w.attr("id", n.id, index);
        if (n.classes.items.len > 0) {
            try w.raw(if (w.opts.jsx) " className=\"" else " class=\"");
            for (n.classes.items, 0..) |c, i| {
                if (i > 0) try w.raw(" ");
                try w.lit(c, index);
            }
            try w.raw("\"");
        }
        for (defaultAttrs(name)) |d| {
            const given = for (n.attrs.items) |a| {
                if (std.mem.eql(u8, a.name, d)) break true;
            } else false;
            if (!given) try w.attr(d, null, index);
        }
        for (n.attrs.items) |a| try w.attr(a.name, a.value, index);
        if (isVoid(name)) return w.raw(if (w.opts.jsx) " />" else ">");
        try w.raw(">");
        if (n.children.items.len > 0) {
            // Children each on a line of their own, a level in.
            if (n.text) |t| {
                try w.newline(depth + 1);
                try w.lit(t, index);
            }
            var first = false;
            try w.list(n.children.items, depth + 1, &first, index);
            try w.newline(depth);
        } else if (n.text) |t| {
            try w.lit(t, index);
        } else try w.placeholder();
        try w.raw("</");
        try w.lit(name, index);
        try w.raw(">");
    }
};

/// The snippet for `abbr`, or null if it isn't an abbreviation. Owned.
pub fn expand(gpa: Allocator, abbr: []const u8, opts: Options) Allocator.Error!?[]u8 {
    if (abbr.len == 0) return null;
    var arena: std.heap.ArenaAllocator = .init(gpa);
    defer arena.deinit();
    const a = arena.allocator();
    var p: Parser = .{ .a = a, .src = abbr };
    var roots: std.ArrayList(*Node) = .empty;
    _ = p.seq(&roots) catch |err| switch (err) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return null,
    };
    if (p.i != abbr.len) return null;
    var w: Writer = .{ .a = a, .opts = opts };
    var first = true;
    try w.list(roots.items, 0, &first, 1);
    try w.raw("$0");
    return try gpa.dupe(u8, w.out.items);
}

/// Whether `abbr` looks meant as an abbreviation (not a word of prose): it
/// uses an operator, or starts with a known element or a component name.
pub fn looksLikeAbbreviation(abbr: []const u8, jsx: bool) bool {
    if (abbr.len == 0) return false;
    if (std.mem.indexOfAny(u8, abbr, ">+^*.#[{(") != null) return std.ascii.isAlphabetic(abbr[0]) or abbr[0] == '.' or abbr[0] == '#' or abbr[0] == '(' or abbr[0] == '[';
    if (jsx and std.ascii.isUpper(abbr[0])) return true;
    return isElement(abbr);
}

/// HTML element names (what a lone word expands to).
pub const elements = [_][]const u8{
    "a",       "abbr",     "address", "article",  "aside",   "audio",    "b",       "blockquote", "body",     "br",
    "button",  "canvas",   "caption", "code",     "col",     "dd",       "details", "dialog",     "div",      "dl",
    "dt",      "em",       "fieldset", "figcaption", "figure", "footer",  "form",    "h1",         "h2",       "h3",
    "h4",      "h5",       "h6",      "head",     "header",  "hr",       "html",    "i",          "iframe",   "img",
    "input",   "label",    "legend",  "li",       "link",    "main",     "mark",    "meta",       "nav",      "noscript",
    "ol",      "optgroup", "option",  "p",        "picture", "pre",      "progress", "q",         "s",        "script",
    "section", "select",   "slot",    "small",    "source",  "span",     "strong",  "style",      "sub",      "summary",
    "sup",     "svg",      "table",   "tbody",    "td",      "template", "textarea", "tfoot",     "th",       "thead",
    "time",    "title",    "tr",      "u",        "ul",      "video",
};

pub fn isElement(name: []const u8) bool {
    for (elements) |e| if (std.mem.eql(u8, e, name)) return true;
    return false;
}

const testing = std.testing;

fn expectExpand(abbr: []const u8, opts: Options, want: []const u8) !void {
    const got = (try expand(testing.allocator, abbr, opts)) orelse return error.TestExpectedEqual;
    defer testing.allocator.free(got);
    try testing.expectEqualStrings(want, got);
}

test "elements, ids, classes, attributes, text" {
    try expectExpand("div", .{}, "<div>${1}</div>$0");
    try expectExpand(".card", .{}, "<div class=\"card\">${1}</div>$0");
    try expectExpand("p#intro.a.b{Hi}", .{}, "<p id=\"intro\" class=\"a b\">Hi</p>$0");
    try expectExpand("a", .{}, "<a href=\"${1}\">${2}</a>$0");
    try expectExpand("img", .{}, "<img src=\"${1}\" alt=\"${2}\">$0");
    try expectExpand("img", .{ .jsx = true }, "<img src=\"${1}\" alt=\"${2}\" />$0");
    try expectExpand("input[type=email name]", .{}, "<input type=\"email\" name=\"${1}\">$0");
    try expectExpand("View.box", .{ .jsx = true }, "<View className=\"box\">${1}</View>$0");
}

test "nesting, siblings, climbing, groups, counting" {
    try expectExpand("ul>li*2", .{}, "<ul>\n  <li>${1}</li>\n  <li>${2}</li>\n</ul>$0");
    try expectExpand("li.item$*2", .{ .indent = "  " }, "<li class=\"item1\">${1}</li>\n  <li class=\"item2\">${2}</li>$0");
    try expectExpand("div>p+span", .{}, "<div>\n  <p>${1}</p>\n  <span>${2}</span>\n</div>$0");
    try expectExpand("div>p^h1", .{}, "<div>\n  <p>${1}</p>\n</div>\n<h1>${2}</h1>$0");
    try expectExpand("(dt+dd)*2", .{}, "<dt>${1}</dt>\n<dd>${2}</dd>\n<dt>${3}</dt>\n<dd>${4}</dd>$0");
    try expectExpand("p{a\\b}", .{}, "<p>a\\\\b</p>$0");
    try expectExpand("li{n$}*2", .{}, "<li>n1</li>\n<li>n2</li>$0");
}

test "not abbreviations" {
    try testing.expectEqual(null, try expand(testing.allocator, "div>", .{}));
    try testing.expectEqual(null, try expand(testing.allocator, "a b", .{}));
    try testing.expect(looksLikeAbbreviation("div", false));
    try testing.expect(!looksLikeAbbreviation("hello", false));
    try testing.expect(looksLikeAbbreviation("View", true));
    try testing.expect(looksLikeAbbreviation("ul>li*3", false));
}
