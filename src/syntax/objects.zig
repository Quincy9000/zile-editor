//! Syntax-aware text objects from the tree-sitter tree:
//!   if / af   function       (inner: the body between its braces)
//!   ic / ac   class / struct (inner: the body between its braces)
//!   ia / aa   argument       (around: plus its comma and spacing)
//!
//! The grammars don't ship textobject queries, so each language lists which
//! node types count; one generic algorithm handles the rest.

const std = @import("std");
const c = @import("tree_sitter");
const Text = @import("../core/Text.zig");
const motions = @import("../core/motions.zig");
const textobjects = @import("../core/textobjects.zig");
const Syntax = @import("Syntax.zig");

const Range = textobjects.Range;
const Scope = textobjects.Scope;

pub const Object = enum { function, class, argument };

const Spec = struct {
    functions: []const []const u8,
    classes: []const []const u8,
    /// Parameter and argument lists; their named children are arguments.
    lists: []const []const u8,
    /// A class node inside one of these grows to include it in `ac`
    /// (Zig's `const Foo = struct {...};`).
    class_wrappers: []const []const u8 = &.{},
    /// Nodes that can be folded (when they span two lines or more).
    folds: []const []const u8 = &.{},
};

/// JavaScript, and TypeScript on top of it (TSX the same).
const js_spec = Spec{
    .functions = &.{ "function_declaration", "function_expression", "function", "arrow_function", "method_definition", "generator_function_declaration", "generator_function" },
    .classes = &.{ "class_declaration", "class", "abstract_class_declaration", "interface_declaration", "enum_declaration" },
    .lists = &.{ "formal_parameters", "arguments", "type_arguments", "type_parameters" },
    .class_wrappers = &.{"export_statement"},
    .folds = &.{
        "function_declaration", "function_expression", "arrow_function", "method_definition", "class_declaration",
        "class_body",           "statement_block",     "object",         "array",             "switch_body",
        "interface_body",       "object_type",         "enum_body",      "jsx_element",       "comment",
        "template_string",      "import_statement",
    },
};

const specs = std.StaticStringMap(Spec).initComptime(.{
    .{ "json", Spec{ .functions = &.{}, .classes = &.{"object"}, .lists = &.{"array"}, .folds = &.{ "object", "array" } } },
    .{ "toml", Spec{
        .functions = &.{},
        .classes = &.{ "table", "table_array_element" },
        .lists = &.{"array"},
        .folds = &.{ "table", "table_array_element", "array", "inline_table" },
    } },
    .{ "yaml", Spec{
        .functions = &.{},
        .classes = &.{"block_mapping_pair"},
        .lists = &.{"flow_sequence"},
        .folds = &.{ "block_mapping_pair", "block_sequence_item", "flow_mapping", "flow_sequence" },
    } },
    .{ "javascript", js_spec },
    .{ "typescript", js_spec },
    .{ "tsx", js_spec },
    .{ "css", Spec{
        .functions = &.{},
        .classes = &.{ "rule_set", "media_statement", "keyframes_statement" },
        .lists = &.{"arguments"},
        .folds = &.{ "rule_set", "media_statement", "keyframes_statement", "supports_statement", "comment" },
    } },
    .{ "html", Spec{
        .functions = &.{},
        .classes = &.{ "element", "script_element", "style_element" },
        .lists = &.{},
        .folds = &.{ "element", "script_element", "style_element", "comment" },
    } },
    .{ "zig", Spec{
        .functions = &.{ "function_declaration", "test_declaration" },
        .classes = &.{ "struct_declaration", "enum_declaration", "union_declaration", "opaque_declaration" },
        // Call arguments are direct children of call_expression here.
        .lists = &.{ "parameters", "arguments", "call_expression" },
        .class_wrappers = &.{"variable_declaration"},
        .folds = &.{
            "function_declaration", "test_declaration", "struct_declaration", "enum_declaration",
            "union_declaration",    "block",            "switch_expression",  "struct_initializer",
        },
    } },
    .{ "c", Spec{
        .functions = &.{"function_definition"},
        .classes = &.{ "struct_specifier", "union_specifier", "enum_specifier" },
        .lists = &.{ "parameter_list", "argument_list" },
        .folds = &.{
            "function_definition", "struct_specifier", "enum_specifier",   "union_specifier",
            "compound_statement",  "switch_statement", "initializer_list", "comment",
        },
    } },
    .{ "rust", Spec{
        .functions = &.{ "function_item", "closure_expression" },
        .classes = &.{ "struct_item", "enum_item", "union_item", "impl_item", "trait_item" },
        .lists = &.{ "parameters", "arguments", "type_arguments", "type_parameters" },
        .folds = &.{
            "function_item", "impl_item", "struct_item", "enum_item",   "trait_item",
            "mod_item",      "block",     "match_block", "block_comment",
        },
    } },
    .{ "go", Spec{
        .functions = &.{ "function_declaration", "method_declaration", "func_literal" },
        .classes = &.{ "struct_type", "interface_type" },
        .lists = &.{ "parameter_list", "argument_list", "type_arguments", "type_parameter_list" },
        // `ac` on a struct takes `Foo struct {...}`.
        .class_wrappers = &.{"type_spec"},
        .folds = &.{
            "function_declaration", "method_declaration",          "func_literal",          "block",
            "type_declaration",     "literal_value",               "import_declaration",    "const_declaration",
            "var_declaration",      "expression_switch_statement", "type_switch_statement", "select_statement",
            "comment",
        },
    } },
    .{ "lua", Spec{
        .functions = &.{ "function_declaration", "function_definition" },
        .classes = &.{"table_constructor"},
        .lists = &.{ "parameters", "arguments" },
        .folds = &.{
            "function_declaration", "function_definition", "if_statement",     "for_statement",
            "while_statement",      "repeat_statement",    "do_statement",     "table_constructor",
            "comment",
        },
    } },
    .{ "python", Spec{
        .functions = &.{"function_definition"},
        .classes = &.{"class_definition"},
        .lists = &.{ "parameters", "argument_list" },
        .folds = &.{
            "function_definition", "class_definition", "if_statement", "for_statement",
            "while_statement",     "with_statement",   "try_statement", "dictionary",
        },
    } },
});

fn typeOf(n: c.TSNode) []const u8 {
    return std.mem.span(c.ts_node_type(n));
}

fn isOneOf(n: c.TSNode, types: []const []const u8) bool {
    const t = typeOf(n);
    for (types) |want| if (std.mem.eql(u8, t, want)) return true;
    return false;
}

fn startOf(n: c.TSNode) usize {
    return c.ts_node_start_byte(n);
}

fn endOf(n: c.TSNode) usize {
    return c.ts_node_end_byte(n);
}

/// The object of `kind` around `pos` (`count` levels out for functions and
/// classes), or null if there is none or the language has no spec.
pub fn find(s: *Syntax, t: *const Text, pos: usize, kind: Object, scope: Scope, count: usize) ?Range {
    const spec = specs.get(s.lang.name) orelse return null;
    s.update(t);
    const tree = s.tree orelse return null;
    const root = c.ts_tree_root_node(tree);
    const p: u32 = @intCast(@min(pos, t.len()));
    var node = c.ts_node_descendant_for_byte_range(root, p, p);
    if (c.ts_node_is_null(node)) return null;

    switch (kind) {
        .argument => return argument(t, node, spec, scope),
        .function, .class => {
            const types = if (kind == .function) spec.functions else spec.classes;
            var found: ?c.TSNode = null;
            var levels = count;
            while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
                if (!isOneOf(node, types)) continue;
                found = node;
                levels -= 1;
                if (levels == 0) break;
            }
            const n = found orelse return null;
            if (scope == .inner) return inner(t, n);
            var outer = n;
            if (kind == .class) {
                const parent = c.ts_node_parent(n);
                if (!c.ts_node_is_null(parent) and isOneOf(parent, spec.class_wrappers)) outer = parent;
            }
            return .{ .start = startOf(outer), .end = endOf(outer) };
        },
    }
}

/// The inside of a function or class: between the braces of its body (linewise
/// when they sit on their own lines, like `i{`), or the whole indented body.
fn inner(t: *const Text, n: c.TSNode) ?Range {
    const field = "body";
    var body = c.ts_node_child_by_field_name(n, field.ptr, field.len);
    if (c.ts_node_is_null(body)) body = n;
    // First '{' and last '}' among the body's direct children.
    var open: ?c.TSNode = null;
    var close: ?c.TSNode = null;
    const count = c.ts_node_child_count(body);
    for (0..count) |i| {
        const child = c.ts_node_child(body, @intCast(i));
        const ty = typeOf(child);
        if (open == null and std.mem.eql(u8, ty, "{")) open = child;
        if (std.mem.eql(u8, ty, "}")) close = child;
    }
    if (open != null and close != null) {
        const o = startOf(open.?);
        const cl = startOf(close.?);
        const lo = t.lineOf(o);
        const lc = t.lineOf(cl);
        if (lc >= lo + 2 and blankBetween(t, o + 1, t.lineEnd(lo)) and motions.firstNonBlank(t, lc) == cl) {
            return .{ .start = t.lineStart(lo + 1), .end = t.lineEnd(lc - 1), .linewise = true };
        }
        return .{ .start = o + 1, .end = cl };
    }
    // No braces (Python): the body's whole lines. A block can end at the start
    // of the next line (its trailing newline); don't count that line.
    const start = startOf(body);
    var end = endOf(body);
    if (end > start and end == t.lineStart(t.lineOf(end))) end -= 1;
    return .{ .start = t.lineStart(t.lineOf(start)), .end = t.lineEnd(t.lineOf(end)), .linewise = true };
}

fn blankBetween(t: *const Text, from: usize, to: usize) bool {
    for (from..to) |i| {
        const b = t.byteAt(i);
        if (b != ' ' and b != '\t' and b != '\r') return false;
    }
    return true;
}

/// The callee of a call node (`add` in `add(a, b)`) is not an argument.
fn isCallee(parent: c.TSNode, node: c.TSNode) bool {
    const field = "function";
    const callee = c.ts_node_child_by_field_name(parent, field.ptr, field.len);
    return !c.ts_node_is_null(callee) and c.ts_node_eq(callee, node);
}

/// The list element around the cursor; `around` adds the separating comma
/// and whitespace (after it, or before it for the last element).
fn argument(t: *const Text, start_node: c.TSNode, spec: Spec, scope: Scope) ?Range {
    // Walk up to the node whose parent is a list.
    var node = start_node;
    var elem: ?c.TSNode = null;
    while (!c.ts_node_is_null(node)) : (node = c.ts_node_parent(node)) {
        if (isOneOf(node, spec.lists)) {
            // The cursor is on the list itself (a comma or space): no element.
            break;
        }
        const parent = c.ts_node_parent(node);
        if (!c.ts_node_is_null(parent) and isOneOf(parent, spec.lists) and c.ts_node_is_named(node) and
            !isCallee(parent, node))
        {
            elem = node;
            break;
        }
    }
    const e = elem orelse return null;
    const r: Range = .{ .start = startOf(e), .end = endOf(e) };
    if (scope == .inner) return r;

    // Trailing ", " if there is one...
    const next = c.ts_node_next_sibling(e);
    if (!c.ts_node_is_null(next) and std.mem.eql(u8, typeOf(next), ",")) {
        var end = endOf(next);
        while (end < t.len() and (t.byteAt(end) == ' ' or t.byteAt(end) == '\t')) end += 1;
        return .{ .start = r.start, .end = end };
    }
    // ...else the ", " before it.
    const prev = c.ts_node_prev_sibling(e);
    if (!c.ts_node_is_null(prev) and std.mem.eql(u8, typeOf(prev), ",")) {
        return .{ .start = startOf(prev), .end = r.end };
    }
    return r;
}

pub const FoldLines = struct { first: usize, last: usize };

/// Foldable line ranges containing `line`, innermost first, without
/// duplicates (a Zig function and its body block fold the same lines).
///
/// Looks up from both ends of the line: on `const Foo = struct {` the first
/// word belongs to the declaration while the `{` is inside the struct.
pub fn foldsAround(s: *Syntax, t: *const Text, line: usize, out: []FoldLines) []FoldLines {
    const spec = specs.get(s.lang.name) orelse return out[0..0];
    s.update(t);
    const tree = s.tree orelse return out[0..0];
    const root = c.ts_tree_root_node(tree);
    const first_byte = motions.firstNonBlank(t, line);
    var last_byte = t.lineEnd(line);
    while (last_byte > first_byte and (t.byteAt(last_byte - 1) == ' ' or t.byteAt(last_byte - 1) == '\t')) last_byte -= 1;
    var n: usize = 0;
    for ([_]usize{ first_byte, last_byte -| 1 }) |pos| {
        const p: u32 = @intCast(@max(pos, first_byte));
        var node = c.ts_node_descendant_for_byte_range(root, p, p);
        while (!c.ts_node_is_null(node) and n < out.len) : (node = c.ts_node_parent(node)) {
            if (!isOneOf(node, spec.folds)) continue;
            const r: FoldLines = .{ .first = t.lineOf(startOf(node)), .last = t.lineOf(endOf(node)) };
            if (r.last <= r.first or line < r.first or line > r.last) continue;
            const seen = for (out[0..n]) |o| {
                if (o.first == r.first and o.last == r.last) break true;
            } else false;
            if (seen) continue;
            out[n] = r;
            n += 1;
        }
    }
    // Innermost (smallest) first.
    std.mem.sort(FoldLines, out[0..n], {}, struct {
        fn lessThan(_: void, a: FoldLines, b: FoldLines) bool {
            return a.last - a.first < b.last - b.first;
        }
    }.lessThan);
    return out[0..n];
}

/// Every foldable line range in the file (for `zM`).
pub fn allFolds(gpa: std.mem.Allocator, s: *Syntax, t: *const Text, out: *std.ArrayList(FoldLines)) !void {
    const spec = specs.get(s.lang.name) orelse return;
    s.update(t);
    const tree = s.tree orelse return;
    try collectFolds(gpa, spec, t, c.ts_tree_root_node(tree), out);
}

fn collectFolds(gpa: std.mem.Allocator, spec: Spec, t: *const Text, node: c.TSNode, out: *std.ArrayList(FoldLines)) !void {
    if (isOneOf(node, spec.folds)) {
        const r: FoldLines = .{ .first = t.lineOf(startOf(node)), .last = t.lineOf(endOf(node)) };
        if (r.last > r.first) try out.append(gpa, r);
    }
    for (0..c.ts_node_named_child_count(node)) |i| try collectFolds(gpa, spec, t, c.ts_node_named_child(node, @intCast(i)), out);
}

/// One entry of a file outline (from the language server or the tree).
pub const Symbol = struct {
    /// Qualified with its parents: `Foo.get`. Owned.
    name: []u8,
    kind: []const u8,
    line: u32,
    col: u32,
};

/// The functions and classes in the tree, in document order, named by their
/// `name` field (or, for Zig's `const Foo = struct {...}`, the declaration's
/// name). Caller owns the names.
pub fn outline(gpa: std.mem.Allocator, s: *Syntax, t: *const Text, out: *std.ArrayList(Symbol)) !void {
    const spec = specs.get(s.lang.name) orelse return;
    s.update(t);
    const tree = s.tree orelse return;
    var prefix: std.ArrayList(u8) = .empty;
    defer prefix.deinit(gpa);
    try walk(gpa, spec, t, c.ts_tree_root_node(tree), &prefix, out);
}

fn walk(gpa: std.mem.Allocator, spec: Spec, t: *const Text, node: c.TSNode, prefix: *std.ArrayList(u8), out: *std.ArrayList(Symbol)) !void {
    const is_fn = isOneOf(node, spec.functions);
    const is_class = isOneOf(node, spec.classes);
    const outer_len = prefix.items.len;
    defer prefix.shrinkRetainingCapacity(outer_len);
    if (is_fn or is_class) {
        if (symbolName(spec, t, node)) |name| {
            const qualified = try std.mem.concat(gpa, u8, &.{ prefix.items, if (prefix.items.len > 0) "." else "", name });
            errdefer gpa.free(qualified);
            const start = startOf(node);
            const line = t.lineOf(start);
            try out.append(gpa, .{
                .name = qualified,
                .kind = if (is_fn) "fn" else "type",
                .line = @intCast(line),
                .col = @intCast(start - t.lineStart(line)),
            });
            if (is_class) {
                if (prefix.items.len > 0) try prefix.append(gpa, '.');
                try prefix.appendSlice(gpa, name);
            }
        }
    }
    const n = c.ts_node_named_child_count(node);
    for (0..n) |i| try walk(gpa, spec, t, c.ts_node_named_child(node, @intCast(i)), prefix, out);
}

fn symbolName(spec: Spec, t: *const Text, node: c.TSNode) ?[]const u8 {
    const field = "name";
    var named = c.ts_node_child_by_field_name(node, field.ptr, field.len);
    if (c.ts_node_is_null(named)) {
        // Rust's `impl Foo` names its type in the `type` field.
        const type_field = "type";
        named = c.ts_node_child_by_field_name(node, type_field.ptr, type_field.len);
    }
    if (c.ts_node_is_null(named)) {
        // Zig: `const Foo = struct {...}` names the struct through its parent.
        const parent = c.ts_node_parent(node);
        if (c.ts_node_is_null(parent) or !isOneOf(parent, spec.class_wrappers)) return null;
        for (0..c.ts_node_named_child_count(parent)) |i| {
            const child = c.ts_node_named_child(parent, @intCast(i));
            if (std.mem.eql(u8, typeOf(child), "identifier")) {
                named = child;
                break;
            }
        } else return null;
    }
    return t.slice(startOf(named), endOf(named));
}

const testing = std.testing;

test "outline from the tree" {
    const gpa = testing.allocator;
    const src = "const Foo = struct {\n    fn get() void {}\n};\nfn top() void {}\n";
    var t = try Text.init(gpa, src);
    defer t.deinit(gpa);
    var s = Syntax.forPath("t.zig").?;
    defer s.deinit(gpa);
    var syms: std.ArrayList(Symbol) = .empty;
    defer {
        for (syms.items) |sym| gpa.free(sym.name);
        syms.deinit(gpa);
    }
    try outline(gpa, &s, &t, &syms);
    try testing.expectEqual(3, syms.items.len);
    try testing.expectEqualStrings("Foo", syms.items[0].name);
    try testing.expectEqualStrings("Foo.get", syms.items[1].name);
    try testing.expectEqual(1, syms.items[1].line);
    try testing.expectEqualStrings("top", syms.items[2].name);
}

fn objectText(src: []const u8, path: []const u8, pos: usize, kind: Object, scope: Scope) ![]const u8 {
    const gpa = testing.allocator;
    var t = try Text.init(gpa, src);
    defer t.deinit(gpa);
    var s = Syntax.forPath(path).?;
    defer s.deinit(gpa);
    const r = find(&s, &t, pos, kind, scope, 1) orelse return "<null>";
    return try gpa.dupe(u8, t.slice(r.start, r.end));
}

test "zig: functions, structs, arguments" {
    const src =
        \\const Foo = struct {
        \\    a: u8,
        \\    pub fn get(self: Foo, x: u8) u8 {
        \\        return add(self.a, x);
        \\    }
        \\};
    ;
    const at_return = std.mem.indexOf(u8, src, "return").?;
    const cases = .{
        .{ at_return, Object.function, Scope.inner, "        return add(self.a, x);" },
        .{ at_return, Object.function, Scope.around, "pub fn get(self: Foo, x: u8) u8 {\n        return add(self.a, x);\n    }" },
        .{ at_return, Object.class, Scope.inner, "    a: u8,\n    pub fn get(self: Foo, x: u8) u8 {\n        return add(self.a, x);\n    }" },
        .{ at_return, Object.class, Scope.around, src[0 .. src.len - 1] ++ ";" },
        .{ std.mem.indexOf(u8, src, "x: u8").?, Object.argument, Scope.inner, "x: u8" },
        .{ std.mem.indexOf(u8, src, "self: Foo").?, Object.argument, Scope.around, "self: Foo, " },
        .{ std.mem.indexOf(u8, src, "x);").?, Object.argument, Scope.around, ", x" },
    };
    inline for (cases) |case| {
        const got = try objectText(src, "t.zig", case[0], case[1], case[2]);
        defer if (!std.mem.eql(u8, got, "<null>")) testing.allocator.free(got);
        try testing.expectEqualStrings(case[3], got);
    }
}

test "python bodies are indented blocks" {
    const src = "class A:\n    def f(self, y):\n        return y\n";
    const got = try objectText(src, "t.py", std.mem.indexOf(u8, src, "return").?, .function, .inner);
    defer testing.allocator.free(got);
    try testing.expectEqualStrings("        return y", got);
}

// ---------------------------------------------------------------------------
// Moving by the shape of the code (helix's Alt keys, nvim-treesitter's
// incremental selection and swap): the tree around a selection.

fn rootOf(s: *Syntax, t: *const Text) ?c.TSNode {
    s.update(t);
    const tree = s.tree orelse return null;
    return c.ts_tree_root_node(tree);
}

fn rangeOf(n: c.TSNode) Range {
    return .{ .start = startOf(n), .end = endOf(n) };
}

fn sameRange(a: c.TSNode, b: c.TSNode) bool {
    return startOf(a) == startOf(b) and endOf(a) == endOf(b);
}

/// The node `[start, end)` is: the smallest named one covering it, then the
/// outermost of the nodes with exactly its range (an argument rather than
/// the identifier that is all of it), so siblings are the list's items.
fn nodeAt(root: c.TSNode, start: usize, end: usize) ?c.TSNode {
    const e: u32 = @intCast(@max(end, start + 1) - 1);
    var n = c.ts_node_named_descendant_for_byte_range(root, @intCast(start), e);
    if (c.ts_node_is_null(n)) return null;
    while (true) {
        const p = c.ts_node_parent(n);
        if (c.ts_node_is_null(p) or !sameRange(p, n)) break;
        n = p;
    }
    return n;
}

/// `Alt-u`: the selection grown to the next node up the tree (from a cursor,
/// the node under it).
pub fn expand(s: *Syntax, t: *const Text, sel: Range) ?Range {
    const root = rootOf(s, t) orelse return null;
    var n = nodeAt(root, sel.start, sel.end) orelse return null;
    while (startOf(n) >= sel.start and endOf(n) <= sel.end) {
        const p = c.ts_node_parent(n);
        if (c.ts_node_is_null(p)) return null;
        n = p;
    }
    return rangeOf(n);
}

fn isComment(n: c.TSNode) bool {
    return std.mem.indexOf(u8, typeOf(n), "comment") != null;
}

fn namedSibling(n: c.TSNode, forward: bool) ?c.TSNode {
    var m = n;
    while (true) {
        m = if (forward) c.ts_node_next_named_sibling(m) else c.ts_node_prev_named_sibling(m);
        if (c.ts_node_is_null(m)) return null;
        if (!isComment(m)) return m;
    }
}

/// The node a sibling move starts from. A selection: the node it is. A
/// cursor: the biggest node starting where the one under it starts (at an
/// argument's first letter, the argument; at a statement's, the statement).
fn moveNode(root: c.TSNode, sel: Range, cursor_only: bool) ?c.TSNode {
    var n = nodeAt(root, sel.start, sel.end) orelse return null;
    if (!cursor_only) return n;
    while (true) {
        const p = c.ts_node_parent(n);
        if (c.ts_node_is_null(p) or c.ts_node_is_null(c.ts_node_parent(p)) or startOf(p) != startOf(n)) break;
        n = p;
    }
    return n;
}

/// `Alt-n` / `Alt-p`: the next / previous sibling of the node at the
/// selection (or cursor), climbing to a parent that has one.
pub fn sibling(s: *Syntax, t: *const Text, sel: Range, cursor_only: bool, forward: bool) ?Range {
    const root = rootOf(s, t) orelse return null;
    var n = moveNode(root, sel, cursor_only) orelse return null;
    while (true) {
        if (namedSibling(n, forward)) |m| return rangeOf(m);
        const p = c.ts_node_parent(n);
        if (c.ts_node_is_null(p) or c.ts_node_is_null(c.ts_node_parent(p))) return null;
        n = p;
    }
}

/// `Alt-N` / `Alt-P`: the node at the selection (or cursor) and the sibling
/// it trades places with: `{ node, other }`.
pub fn swapPair(s: *Syntax, t: *const Text, sel: Range, cursor_only: bool, forward: bool) ?[2]Range {
    const root = rootOf(s, t) orelse return null;
    var n = moveNode(root, sel, cursor_only) orelse return null;
    while (true) {
        if (namedSibling(n, forward)) |m| return .{ rangeOf(n), rangeOf(m) };
        // From a cursor, a node with no sibling that way stands for its parent.
        if (!cursor_only) return null;
        const p = c.ts_node_parent(n);
        if (c.ts_node_is_null(p) or c.ts_node_is_null(c.ts_node_parent(p))) return null;
        n = p;
    }
}

/// Whether `n` is a function worth jumping to: a declaration or method, or
/// an arrow / function expression given a name (`const Foo = () => ...`),
/// not every callback.
fn isNamedFunction(spec: Spec, n: c.TSNode) bool {
    if (!isOneOf(n, spec.functions)) return false;
    const ty = typeOf(n);
    const anonymous = std.mem.eql(u8, ty, "arrow_function") or std.mem.eql(u8, ty, "function_expression") or
        std.mem.eql(u8, ty, "function") or std.mem.eql(u8, ty, "closure_expression") or std.mem.eql(u8, ty, "func_literal");
    if (!anonymous) return true;
    const p = c.ts_node_parent(n);
    return !c.ts_node_is_null(p) and isOneOf(p, &.{ "variable_declarator", "pair", "public_field_definition", "assignment_expression" });
}

/// `Alt-f` / `Alt-F`: the start of the next / previous function's line.
pub fn functionStart(s: *Syntax, t: *const Text, pos: usize, forward: bool) ?usize {
    const spec = specs.get(s.lang.name) orelse return null;
    const root = rootOf(s, t) orelse return null;
    const line = t.lineOf(@min(pos, t.len()));
    var best: ?usize = null;
    findFunction(spec, t, root, line, forward, &best);
    return if (best) |l| motions.firstNonBlank(t, l) else null;
}

fn findFunction(spec: Spec, t: *const Text, n: c.TSNode, line: usize, forward: bool, best: *?usize) void {
    // Nothing in a node that ends before (forward) / starts after it.
    const first = t.lineOf(startOf(n));
    const last = t.lineOf(@min(endOf(n), t.len()));
    if (forward and last <= line) return;
    if (!forward and first >= line) return;
    if (isNamedFunction(spec, n)) {
        if (forward and first > line and (best.* == null or first < best.*.?)) best.* = first;
        if (!forward and first < line and (best.* == null or first > best.*.?)) best.* = first;
    }
    const count = c.ts_node_named_child_count(n);
    var i: u32 = 0;
    while (i < count) : (i += 1) findFunction(spec, t, c.ts_node_named_child(n, i), line, forward, best);
}

/// Sticky context: the first lines of the scopes `line` is inside that
/// start above it (function, class, `if`, JSX element...), outermost first,
/// at most `out.len` (the innermost ones).
pub fn contextLines(s: *Syntax, t: *const Text, line: usize, out: []usize) []usize {
    const spec = specs.get(s.lang.name) orelse return out[0..0];
    const root = rootOf(s, t) orelse return out[0..0];
    if (line >= t.lineCount()) return out[0..0];
    const pos: u32 = @intCast(motions.firstNonBlank(t, line));
    var n = c.ts_node_descendant_for_byte_range(root, pos, pos);
    // Innermost first, into a scratch list, then the last `out.len` reversed.
    var found: [32]usize = undefined;
    var k: usize = 0;
    while (!c.ts_node_is_null(n) and k < found.len) : (n = c.ts_node_parent(n)) {
        if (!isOneOf(n, spec.folds) or isOneOf(n, &.{ "comment", "block_comment", "template_string", "import_statement" })) continue;
        const first = t.lineOf(startOf(n));
        if (first >= line) continue;
        if (k > 0 and found[k - 1] == first) continue;
        found[k] = first;
        k += 1;
    }
    const n_out = @min(k, out.len);
    for (0..n_out) |i| out[i] = found[n_out - 1 - i];
    return out[0..n_out];
}

test "structure: grow the selection, siblings, swaps, functions, context" {
    const gpa = std.testing.allocator;
    const src =
        \\fn add(a: u8, b: u8) u8 {
        \\    if (a > b) {
        \\        return foo(a, b, 3);
        \\    }
        \\    return a + b;
        \\}
        \\
        \\fn two() void {}
    ;
    var t = try Text.init(gpa, src);
    defer t.deinit(gpa);
    var s = Syntax.forPath("x.zig").?;
    defer s.deinit(gpa);
    const at = struct {
        fn f(needle: []const u8) usize {
            return std.mem.indexOf(u8, src, needle).?;
        }
    }.f;
    const slice = struct {
        fn f(r: ?Range) []const u8 {
            const rr = r orelse return "<null>";
            return src[rr.start..rr.end];
        }
    }.f;
    // From the cursor on `a` in `foo(a, ...`: `a` is all of the cursor, so
    // straight to the call; from `foo`'s `f`, the name first.
    const a = at("a, b, 3");
    var r = expand(&s, &t, .{ .start = a, .end = a + 1 }).?;
    try std.testing.expectEqualStrings("foo(a, b, 3)", slice(r));
    r = expand(&s, &t, .{ .start = at("foo"), .end = at("foo") + 1 }).?;
    try std.testing.expectEqualStrings("foo", slice(r));
    r = expand(&s, &t, r).?;
    try std.testing.expectEqualStrings("foo(a, b, 3)", slice(r));
    // Siblings of an argument, from a cursor and from a selection.
    try std.testing.expectEqualStrings("b", slice(sibling(&s, &t, .{ .start = a, .end = a + 1 }, true, true)));
    try std.testing.expectEqualStrings("3", slice(sibling(&s, &t, .{ .start = at("b, 3"), .end = at("b, 3") + 1 }, false, true)));
    // A statement's next sibling is the next statement.
    const if_at = at("if (a");
    try std.testing.expectEqualStrings("return a + b", slice(sibling(&s, &t, .{ .start = if_at, .end = if_at + 1 }, true, true))[0..12]);
    // Swap: `a` with `b`.
    const pair = swapPair(&s, &t, .{ .start = a, .end = a + 1 }, true, true).?;
    try std.testing.expectEqualStrings("a", slice(pair[0]));
    try std.testing.expectEqualStrings("b", slice(pair[1]));
    // Functions.
    try std.testing.expectEqual(at("fn two"), functionStart(&s, &t, a, true).?);
    try std.testing.expectEqual(0, functionStart(&s, &t, at("fn two"), false).?);
    try std.testing.expectEqual(null, functionStart(&s, &t, at("fn two"), true));
    // Context of the `return foo` line: the function, then the `if`.
    var buf: [3]usize = undefined;
    try std.testing.expectEqualSlices(usize, &.{ 0, 1 }, contextLines(&s, &t, 2, &buf));
    try std.testing.expectEqualSlices(usize, &.{0}, contextLines(&s, &t, 4, &buf));
}

test "lua: functions as text objects, folds and outline" {
    const gpa = std.testing.allocator;
    const src = "local M = {}\n\nfunction M.add(a, b)\n  return a + b\nend\n\nlocal f = function(x)\n  return x\nend\n\nreturn M\n";
    var t = try Text.init(gpa, src);
    defer t.deinit(gpa);
    var s = Syntax.forPath("m.lua").?;
    defer s.deinit(gpa);
    const at = std.mem.indexOf(u8, src, "return a").?;
    const r = find(&s, &t, at, .function, .around, 1).?;
    try std.testing.expectEqualStrings("function M.add(a, b)\n  return a + b\nend", src[r.start..r.end]);
    const arg = find(&s, &t, std.mem.indexOf(u8, src, "b)").?, .argument, .inner, 1).?;
    try std.testing.expectEqualStrings("b", src[arg.start..arg.end]);
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "local f").?, functionStart(&s, &t, at, true).?);
}

test "go: functions, methods, structs, arguments" {
    const gpa = std.testing.allocator;
    const src = "package main\n\ntype Point struct {\n\tX, Y int\n}\n\nfunc (p Point) Add(q Point) Point {\n\treturn Point{p.X + q.X, p.Y + q.Y}\n}\n\nfunc main() {\n\tf := func(x int) int { return x }\n\t_ = f(1)\n}\n";
    var t = try Text.init(gpa, src);
    defer t.deinit(gpa);
    var s = Syntax.forPath("main.go").?;
    defer s.deinit(gpa);
    const ret = std.mem.indexOf(u8, src, "return Point").?;
    const m = find(&s, &t, ret, .function, .around, 1).?;
    try std.testing.expect(std.mem.startsWith(u8, src[m.start..m.end], "func (p Point) Add"));
    const st = find(&s, &t, std.mem.indexOf(u8, src, "X, Y").?, .class, .around, 1).?;
    try std.testing.expect(std.mem.startsWith(u8, src[st.start..st.end], "Point struct {"));
    const arg = find(&s, &t, std.mem.indexOf(u8, src, "q Point").?, .argument, .inner, 1).?;
    try std.testing.expectEqualStrings("q Point", src[arg.start..arg.end]);
    // Alt-f: from the method to main, past the func literal.
    try std.testing.expectEqual(std.mem.indexOf(u8, src, "func main").?, functionStart(&s, &t, ret, true).?);
    try std.testing.expectEqual(null, functionStart(&s, &t, std.mem.indexOf(u8, src, "f := ").?, true));
}
