//! Snippets offered in completion, by file type (from the nvim config's
//! `config/snippets.lua`). Bodies use LSP snippet syntax; four leading
//! spaces are one level of indentation, written in the file's own style.
//!
//! React Native ones are for `.jsx` and `.tsx`, the JS/TS ones for the whole
//! family, the type ones for TypeScript only.

const std = @import("std");

pub const Snippet = struct { prefix: []const u8, desc: []const u8, body: []const u8 };

const rn = [_]Snippet{
    .{ .prefix = "rnc", .desc = "RN functional component", .body =
    \\import { StyleSheet, View, Text } from 'react-native';
    \\
    \\export default function ${1:ComponentName}() {
    \\    return (
    \\        <View style={styles.container}>
    \\            <Text>$0</Text>
    \\        </View>
    \\    );
    \\}
    \\
    \\const styles = StyleSheet.create({
    \\    container: {
    \\        flex: 1,
    \\    },
    \\});
    },
    .{ .prefix = "us", .desc = "useState", .body = "const [${1:value}, set${2:Value}] = useState($0);" },
    .{ .prefix = "ue", .desc = "useEffect (async inner function)", .body =
    \\useEffect(() => {
    \\    const ${1:load} = async () => {
    \\        $0
    \\    };
    \\
    \\    ${1}();
    \\}, [$2]);
    },
    .{ .prefix = "ufe", .desc = "useFocusEffect (async inner function)", .body =
    \\useFocusEffect(
    \\    useCallback(() => {
    \\        const ${1:load} = async () => {
    \\            $0
    \\        };
    \\
    \\        ${1}();
    \\    }, [$2])
    \\);
    },
    .{ .prefix = "uc", .desc = "useCallback", .body =
    \\const ${1:handleThing} = useCallback(() => {
    \\    $0
    \\}, [$2]);
    },
    .{ .prefix = "um", .desc = "useMemo", .body =
    \\const ${1:value} = useMemo(() => {
    \\    return $0;
    \\}, [$2]);
    },
    .{ .prefix = "ur", .desc = "useRef", .body = "const ${1:ref} = useRef(${2:null});" },
    .{ .prefix = "press", .desc = "Pressable with onPress", .body =
    \\<Pressable
    \\    onPress={() => {
    \\        $0
    \\    }}
    \\    hitSlop={${1:8}}
    \\>
    \\    $2
    \\</Pressable>
    },
    .{ .prefix = "input", .desc = "TextInput bound to state", .body =
    \\<TextInput
    \\    value={${1:value}}
    \\    onChangeText={${2:setValue}}
    \\    placeholder="$3"
    \\/>$0
    },
    .{ .prefix = "sty", .desc = "StyleSheet entry", .body =
    \\const styles = StyleSheet.create({
    \\    ${1:name}: {
    \\        $0
    \\    },
    \\});
    },
    .{ .prefix = "flatlist", .desc = "FlatList with renderItem", .body =
    \\<FlatList
    \\    data={$1}
    \\    keyExtractor={(item) => item.id}
    \\    renderItem={({ item }) => (
    \\        $0
    \\    )}
    \\/>
    },
};

const jsts = [_]Snippet{
    .{ .prefix = "af", .desc = "async function", .body =
    \\async function ${1:name}(${2:args}) {
    \\    $0
    \\}
    },
    .{ .prefix = "aa", .desc = "async arrow assigned to const", .body =
    \\const ${1:name} = async (${2:args}) => {
    \\    $0
    \\};
    },
    .{ .prefix = "tc", .desc = "try / catch", .body =
    \\try {
    \\    $1
    \\} catch (${2:err}) {
    \\    $0
    \\}
    },
    .{ .prefix = "fetch", .desc = "fetch + await + json + error handling", .body =
    \\try {
    \\    const res = await fetch(${1:url});
    \\    if (!res.ok) throw new Error('Request failed: ' + res.status);
    \\    const ${2:data} = await res.json();
    \\    $0
    \\} catch (err) {
    \\    console.error(err);
    \\}
    },
    .{ .prefix = "log", .desc = "console.log with label", .body = "console.log('${1:label}:', $0);" },
};

const ts_types = [_]Snippet{
    .{ .prefix = "intf", .desc = "interface", .body =
    \\interface ${1:Name} {
    \\    $0
    \\}
    },
    .{ .prefix = "type", .desc = "type alias", .body = "type ${1:Name} = $0;" },
    .{ .prefix = "props", .desc = "component Props type", .body =
    \\type Props = {
    \\    $0
    \\};
    },
};

/// The snippet lists for a file of language `lang` (tree-sitter name) at
/// `path`.
pub fn forFile(lang: []const u8, path: []const u8) [3][]const Snippet {
    const eql = std.mem.eql;
    const js_family = eql(u8, lang, "javascript") or eql(u8, lang, "typescript") or eql(u8, lang, "tsx");
    const react = eql(u8, lang, "tsx") or (eql(u8, lang, "javascript") and std.mem.endsWith(u8, path, ".jsx"));
    const typed = eql(u8, lang, "typescript") or eql(u8, lang, "tsx");
    return .{
        if (react) &rn else &.{},
        if (js_family) &jsts else &.{},
        if (typed) &ts_types else &.{},
    };
}

/// `body` as it is inserted on a line indented by `indent`: each four
/// spaces at a line's start one `unit`, lines after the first indented to
/// match.
pub fn render(gpa: std.mem.Allocator, body: []const u8, indent: []const u8, unit: []const u8) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(gpa);
    var lines = std.mem.splitScalar(u8, body, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            try out.append(gpa, '\n');
            if (line.len > 0) try out.appendSlice(gpa, indent);
        }
        first = false;
        var i: usize = 0;
        while (i + 4 <= line.len and std.mem.eql(u8, line[i .. i + 4], "    ")) : (i += 4) try out.appendSlice(gpa, unit);
        try out.appendSlice(gpa, line[i..]);
    }
    return out.toOwnedSlice(gpa);
}

/// The common React Native components, offered between JSX tags in every
/// file (as in the nvim config's `jsx_tags` source).
pub const rn_components = [_][]const u8{
    "View",            "Text",                 "ScrollView",        "FlatList",   "SectionList",
    "Pressable",       "TouchableOpacity",     "TouchableHighlight", "TextInput", "Image",
    "ImageBackground", "SafeAreaView",         "KeyboardAvoidingView", "ActivityIndicator", "Modal",
    "Button",          "Switch",               "StatusBar",
};

test "scoped by file type; tabs become the file's indentation" {
    const tsx = forFile("tsx", "a.tsx");
    try std.testing.expect(tsx[0].len > 0 and tsx[1].len > 0 and tsx[2].len > 0);
    const js = forFile("javascript", "a.js");
    try std.testing.expect(js[0].len == 0 and js[1].len > 0 and js[2].len == 0);
    try std.testing.expect(forFile("javascript", "a.jsx")[0].len > 0);
    try std.testing.expect(forFile("zig", "a.zig")[1].len == 0);
    const out = try render(std.testing.allocator, "if {\n    x\n}", "  ", "  ");
    defer std.testing.allocator.free(out);
    try std.testing.expectEqualStrings("if {\n    x\n  }", out);
}
