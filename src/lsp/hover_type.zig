//! The type in a language server's hover text, for `SPC l y` (yank the type
//! of what the cursor is on). Hovers are markdown, and say the type inside a
//! declaration: `const user: User | undefined`, `(property) onClick?: (e:
//! MouseEvent) => void`, `function f(a: A): B`, `type Props = { ... }`. This
//! takes the declaration apart; what it doesn't recognise is yanked whole.

const std = @import("std");

/// The type `hover` (markdown) tells of, a slice of it, or, for a function,
/// its type written out in `buf` (`(a: A) => B`). Null when there is no
/// declaration in it.
pub fn of(hover: []const u8, buf: []u8) ?[]const u8 {
    // clangd says it outright, before the declaration: "Type: `std::vector<int>`".
    if (labelled(hover, "Type: `")) |t| return t;
    var first = block(hover, 0) orelse return null;
    // rust-analyzer starts with where the item lives (`my_crate::module`),
    // in a block of its own: the declaration is the next one.
    if (isPath(first.text)) if (block(hover, first.end)) |next| {
        first = next;
    };
    // zls says the resolved type in a block of its own: `(u32)`.
    var from = first.end;
    while (block(hover, from)) |b| : (from = b.end) {
        const t = std.mem.trim(u8, b.text, " \t\r\n");
        if (t.len > 2 and t[0] == '(' and t[t.len - 1] == ')' and closes(t, 0) == t.len - 1) return t[1 .. t.len - 1];
    }
    // gopls writes the type after the name, with nothing between them.
    if (std.mem.eql(u8, first.lang, "go")) if (goType(first.text)) |t| return t;
    return fromDeclaration(first.text, buf);
}

/// What follows `label` up to the closing backquote, on a line of its own.
fn labelled(hover: []const u8, label: []const u8) ?[]const u8 {
    var lines = std.mem.splitScalar(u8, hover, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, " \t\r");
        if (!std.mem.startsWith(u8, line, label)) continue;
        const rest = line[label.len..];
        const end = std.mem.indexOfScalar(u8, rest, '`') orelse continue;
        if (end > 0) return rest[0..end];
    }
    return null;
}

/// A block that is only a path: one line of names joined by `::`.
fn isPath(text: []const u8) bool {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (t.len == 0) return false;
    for (t) |b| if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == ':')) return false;
    return true;
}

/// `var x []string`, `const n int = 3`, `field Name string`: the type.
fn goType(text: []const u8) ?[]const u8 {
    const d = std.mem.trim(u8, text, " \t\r\n");
    for ([_][]const u8{ "var ", "const ", "field " }) |w| if (std.mem.startsWith(u8, d, w)) {
        const rest = d[w.len..];
        const sp = std.mem.indexOfScalar(u8, rest, ' ') orelse return null;
        var t = rest[sp + 1 ..];
        if (std.mem.indexOf(u8, t, " = ")) |eq| t = t[0..eq];
        // (A struct's fields have their tags and comments after the type.)
        if (std.mem.indexOfAny(u8, t, "`\n")) |cut| t = t[0..cut];
        t = std.mem.trim(u8, t, " \t");
        return if (t.len > 0) t else null;
    };
    return null;
}

const Block = struct { text: []const u8, end: usize, lang: []const u8 = "" };

/// The next fenced code block at or after `from`; with no fence at all, the
/// whole text counts as one (a plain-text hover).
fn block(hover: []const u8, from: usize) ?Block {
    const open = std.mem.indexOfPos(u8, hover, from, "```") orelse {
        if (from > 0 or std.mem.trim(u8, hover, " \t\r\n").len == 0) return null;
        return .{ .text = hover, .end = hover.len };
    };
    const body = (std.mem.indexOfScalarPos(u8, hover, open, '\n') orelse return null) + 1;
    const close = std.mem.indexOfPos(u8, hover, body, "```") orelse hover.len;
    return .{ .text = hover[body..close], .end = @min(close + 3, hover.len), .lang = std.mem.trim(u8, hover[open + 3 .. body], " \t\r\n") };
}

/// Words a declaration starts with that aren't its name.
const leading = [_][]const u8{ "export ", "declare ", "default ", "const ", "let ", "var ", "readonly ", "static ", "public ", "private ", "protected ", "abstract ", "async ", "pub ", "comptime ", "mut " };

fn fromDeclaration(text: []const u8, buf: []u8) ?[]const u8 {
    var d = std.mem.trim(u8, text, " \t\r\n");
    // `(alias) type Foo = ...` is followed by its `import Foo` line.
    if (std.mem.lastIndexOf(u8, d, "\nimport ")) |i| d = std.mem.trimEnd(u8, d[0..i], " \t\r\n");
    // `(+1 overload)`.
    if (std.mem.endsWith(u8, d, ")")) if (std.mem.lastIndexOf(u8, d, " (+")) |i| {
        d = std.mem.trimEnd(u8, d[0..i], " \t");
    };
    // `(property) `, `(parameter) `, `(method) `, `(alias) `...
    while (d.len > 0 and d[0] == '(') {
        const close = std.mem.indexOfScalar(u8, d, ')') orelse break;
        const kind = d[1..close];
        const word = for (kind) |b| {
            if (!std.ascii.isAlphabetic(b) and b != ' ') break false;
        } else kind.len > 0;
        if (!word or close + 1 >= d.len or d[close + 1] != ' ') break;
        d = std.mem.trimStart(u8, d[close + 1 ..], " ");
    }
    strip: while (true) {
        for (leading) |w| if (std.mem.startsWith(u8, d, w)) {
            d = d[w.len..];
            continue :strip;
        };
        break;
    }
    if (d.len == 0) return null;
    // `type Name<T> = ...`: what it is.
    if (std.mem.startsWith(u8, d, "type ")) {
        const eq = topLevel(d, '=') orelse return std.mem.trim(u8, d[5..], " ");
        return std.mem.trim(u8, d[eq + 1 ..], " \t\r\n");
    }
    // A named thing is its own type: its name (with its parameters).
    for ([_][]const u8{ "interface ", "class ", "enum ", "namespace ", "module " }) |w| if (std.mem.startsWith(u8, d, w)) {
        const rest = d[w.len..];
        const end = std.mem.indexOfAny(u8, rest, " {\n") orelse rest.len;
        return rest[0..end];
    };
    const fun = std.mem.startsWith(u8, d, "function ");
    if (fun) d = std.mem.trimStart(u8, d["function ".len..], " *");
    // `name(args): R` (a function, a method): `(args) => R`.
    if (callStart(d)) |open| {
        const close = closes(d, open) orelse return d;
        const after = std.mem.trimStart(u8, d[close + 1 ..], " ");
        if (after.len > 0 and after[0] == ':') {
            // With its own type parameters, when it has them.
            var start = open;
            if (open > 0 and d[open - 1] == '>') start = opens(d, open - 1) orelse open;
            const ret = std.mem.trim(u8, after[1..], " \t\r\n");
            return std.fmt.bufPrint(buf, "{s} => {s}", .{ d[start .. close + 1], ret }) catch d;
        }
        // (No `: R` after it: another language's way of writing one. Whole.)
        if (fun) return d;
    }
    // `name: T`, `name?: T` (and `name: T = value`, as zig says it).
    if (topLevel(d, ':')) |colon| {
        var t = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n");
        if (topLevel(t, '=')) |eq| t = std.mem.trimEnd(u8, t[0..eq], " \t");
        if (t.len > 0) return t;
    }
    return d;
}

fn opener(b: u8) bool {
    return b == '(' or b == '[' or b == '{' or b == '<';
}

fn closer(b: u8) bool {
    return b == ')' or b == ']' or b == '}' or b == '>';
}

/// The `>` of `=>` is an arrow, not a bracket.
fn arrow(d: []const u8, i: usize) bool {
    return d[i] == '>' and i > 0 and d[i - 1] == '=';
}

/// The first `want` outside every bracket (and not part of `=>`, `==`).
fn topLevel(d: []const u8, want: u8) ?usize {
    var depth: usize = 0;
    for (d, 0..) |b, i| {
        if (arrow(d, i)) continue;
        if (opener(b)) depth += 1 else if (closer(b)) depth -|= 1 else if (b == want and depth == 0) {
            if (want == '=' and i + 1 < d.len and (d[i + 1] == '>' or d[i + 1] == '=')) continue;
            if (want == ':' and i + 1 < d.len and d[i + 1] == ':') return null; // `a::b`, not a type's colon
            return i;
        }
    }
    return null;
}

/// The `(` that opens a declaration's parameters: the first one outside
/// `<...>`, when only a name (dots, type arguments) comes before it.
fn callStart(d: []const u8) ?usize {
    var depth: usize = 0;
    for (d, 0..) |b, i| {
        if (b == '<') depth += 1 else if (b == '>' and !arrow(d, i)) depth -|= 1 else if (depth == 0) {
            if (b == '(') return if (i > 0) i else null;
            if (!(std.ascii.isAlphanumeric(b) or b == '_' or b == '$' or b == '.' or b == '#' or b >= 0x80)) return null;
        }
    }
    return null;
}

/// The bracket that closes the one at `open`.
fn closes(d: []const u8, open: usize) ?usize {
    var depth: usize = 0;
    for (d[open..], open..) |b, i| {
        if (arrow(d, i)) continue;
        if (opener(b)) depth += 1 else if (closer(b)) {
            depth -|= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

/// The bracket that opens the one closing at `close`.
fn opens(d: []const u8, close: usize) ?usize {
    var depth: usize = 0;
    var i = close + 1;
    while (i > 0) {
        i -= 1;
        if (arrow(d, i)) continue;
        if (closer(d[i])) depth += 1 else if (opener(d[i])) {
            depth -|= 1;
            if (depth == 0) return i;
        }
    }
    return null;
}

fn expectType(want: []const u8, hover: []const u8) !void {
    var buf: [1024]u8 = undefined;
    try std.testing.expectEqualStrings(want, of(hover, &buf) orelse return error.NoType);
}

test "the type in a hover: TypeScript's declarations" {
    try expectType("User | undefined", "```typescript\nconst user: User | undefined\n```");
    try expectType("(e: MouseEvent) => void", "```typescript\n(property) Props.onClick?: (e: MouseEvent) => void\n```\n---\nCalled on click.");
    try expectType("React.MouseEvent<HTMLButtonElement, MouseEvent>", "```typescript\n(parameter) e: React.MouseEvent<HTMLButtonElement, MouseEvent>\n```");
    try expectType("{ id: number; tags: string[] }", "```typescript\nlet row: { id: number; tags: string[] }\n```");
    try expectType("number", "```typescript\n(alias) const count: number\nimport count\n```");
    try expectType("Record<string, () => void>", "```tsx\n(property) handlers: Record<string, () => void>\n```");
    // A function is its signature as a type.
    try expectType("<S>(initialState: S | (() => S)) => [S, Dispatch<SetStateAction<S>>]", "```typescript\nfunction useState<S>(initialState: S | (() => S)): [S, Dispatch<SetStateAction<S>>] (+1 overload)\n```");
    try expectType("<U>(callbackfn: (value: number) => U, thisArg?: any) => U[]", "```typescript\n(method) Array<number>.map<U>(callbackfn: (value: number) => U, thisArg?: any): U[]\n```");
    try expectType("() => JSX.Element", "```tsx\nfunction Navbar(): JSX.Element\n```");
    // A type alias is what it stands for; an interface or class, its name.
    try expectType("{\n    a: string;\n    b?: number;\n}", "```typescript\ntype Props = {\n    a: string;\n    b?: number;\n}\n```");
    try expectType("\"a\" | \"b\"", "```typescript\n(alias) type Kind = \"a\" | \"b\"\nimport Kind\n```");
    try expectType("User", "```typescript\ninterface User\n```");
    try expectType("Store<T>", "```typescript\nclass Store<T>\n```");
}

test "the type in a hover: other servers" {
    // zls: the resolved type has a block of its own.
    try expectType("u32", "```zig\nconst x = count()\n```\n```zig\n(u32)\n```");
    try expectType("std.ArrayList(u8)", "```zig\nvar list: std.ArrayList(u8) = .empty\n```");
    try expectType("fn add(a: i32, b: i32) i32", "```zig\nfn add(a: i32, b: i32) i32\n```");
    try expectType("Vec<String>", "```rust\nlet mut names: Vec<String>\n```");
    // rust-analyzer: where the item lives comes first, then the item.
    try expectType("String", "```rust\nmy_crate::model::User\n```\n\n```rust\npub name: String\n```\n---\nThe name.");
    try expectType("fn load(path: &Path) -> Result<Config, Error>", "```rust\nmy_crate::config\n```\n\n```rust\npub fn load(path: &Path) -> Result<Config, Error>\n```");
    // clangd: the type has a line of its own.
    try expectType("std::vector<int>", "### variable `xs`\n\n---\nType: `std::vector<int>`\n\n---\n```cpp\nstd::vector<int> xs\n```");
    try expectType("const char *", "### field `name`\n\n---\nType: `const char *`\nOffset: 8 bytes\n\n---\n```cpp\n// In Person\nconst char *name\n```");
    try expectType("int add(int a, int b)", "### function `add`\n\n---\n→ `int`\nParameters:\n- `int a`\n- `int b`\n\n---\n```cpp\nint add(int a, int b)\n```");
    // gopls: the type follows the name.
    try expectType("[]string", "```go\nvar x []string\n```");
    try expectType("map[string]int", "```go\nfield Counts map[string]int `json:\"counts\"`\n```");
    try expectType("func Load(path string) (*Config, error)", "```go\nfunc Load(path string) (*Config, error)\n```");
    // pyright.
    try expectType("list[int]", "```python\n(variable) xs: list[int]\n```");
    // Not a declaration it knows: all of it. Nothing: nothing.
    try expectType("x y z", "```text\nx y z\n```");
    try expectType("int", "plain text hover: int");
    var buf: [64]u8 = undefined;
    try std.testing.expectEqual(null, of("", &buf));
}
