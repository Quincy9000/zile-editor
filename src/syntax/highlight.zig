//! Highlight styles and the mapping from tree-sitter capture names
//! (`@keyword.function`, `@string.escape`, ...) to them.

const std = @import("std");

/// What the theme colors. Captures map onto these by name prefix.
pub const Style = enum(u8) {
    none,
    comment,
    keyword,
    string,
    escape,
    number,
    constant,
    builtin,
    type,
    function,
    property,
    parameter,
    operator,
    punctuation,
    attribute,
    label,
    module,
    /// HTML / JSX: element and component names, their attributes (props),
    /// and the `<` `>` `</` `/>` around them.
    tag,
    tag_attribute,
    tag_delimiter,
};

/// Capture name -> style. The longest matching dotted prefix wins, so
/// `function.builtin` beats `function`, and `keyword.return` falls back to
/// `keyword`.
const capture_map = [_]struct { []const u8, Style }{
    .{ "comment", .comment },
    .{ "keyword", .keyword },
    .{ "import", .keyword },
    .{ "string", .string },
    .{ "character", .string },
    .{ "string.escape", .escape },
    .{ "escape", .escape },
    .{ "string.special.key", .property },
    .{ "number", .number },
    .{ "boolean", .constant },
    .{ "constant", .constant },
    .{ "constant.builtin", .builtin },
    .{ "variable.builtin", .builtin },
    .{ "function.builtin", .builtin },
    .{ "type.builtin", .builtin },
    .{ "type", .type },
    .{ "constructor", .type },
    .{ "function", .function },
    .{ "function.macro", .attribute },
    .{ "variable.member", .property },
    .{ "property", .property },
    .{ "field", .property },
    .{ "variable.parameter", .parameter },
    .{ "operator", .operator },
    .{ "punctuation", .punctuation },
    .{ "delimiter", .punctuation },
    .{ "attribute", .attribute },
    .{ "label", .label },
    .{ "module", .module },
    .{ "namespace", .module },
    // CSS at-rules (`@media`, `@keyframes`...) are keywords.
    // Older nvim-treesitter names (SQL's queries use them).
    .{ "conditional", .keyword },
    .{ "repeat", .keyword },
    .{ "include", .keyword },
    .{ "exception", .keyword },
    .{ "storageclass", .keyword },
    .{ "float", .number },
    .{ "parameter", .parameter },
    .{ "tag", .tag },
    .{ "tag.attribute", .tag_attribute },
    .{ "tag.delimiter", .tag_delimiter },
    .{ "tag.error", .none },
    .{ "media", .keyword },
    .{ "supports", .keyword },
    .{ "keyframes", .keyword },
    .{ "charset", .keyword },
};

pub fn styleForCapture(name: []const u8) Style {
    var best: Style = .none;
    var best_len: usize = 0;
    for (capture_map) |entry| {
        const prefix = entry[0];
        const hit = std.mem.eql(u8, name, prefix) or
            (std.mem.startsWith(u8, name, prefix) and name.len > prefix.len and name[prefix.len] == '.');
        if (hit and prefix.len > best_len) {
            best = entry[1];
            best_len = prefix.len;
        }
    }
    return best;
}

test "capture names map by longest prefix" {
    try std.testing.expectEqual(.keyword, styleForCapture("keyword.return"));
    try std.testing.expectEqual(.builtin, styleForCapture("function.builtin"));
    try std.testing.expectEqual(.function, styleForCapture("function.method.call"));
    try std.testing.expectEqual(.escape, styleForCapture("string.escape"));
    try std.testing.expectEqual(.none, styleForCapture("variable"));
    try std.testing.expectEqual(.none, styleForCapture("keywordish"));
}
