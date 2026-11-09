//! UI colors. Theme files (ZON) arrive with config; for now one built-in theme.

const std = @import("std");
const rl = @import("raylib");
const Style = @import("../syntax/highlight.zig").Style;

pub const Color = rl.Color;

bg: Color,
fg: Color,
gutter_fg: Color,
gutter_current_fg: Color,
cursorline_bg: Color,
cursor: Color,
cursor_text: Color,
status_bg: Color,
status_fg: Color,
status_dim: Color,
mode_normal: Color,
mode_insert: Color,
mode_text: Color,
message_info: Color,
message_err: Color,
popup_bg: Color,
popup_border: Color,
whichkey_key: Color,
whichkey_group: Color,
whichkey_command: Color,
mode_picker: Color,
mode_visual: Color,
selection_bg: Color,
match_fg: Color,
backdrop: Color,
search_match: Color,
fold_bg: Color,
fold_fg: Color,
diag_error: Color,
diag_warning: Color,
diag_info: Color,
diag_hint: Color,
search_current: Color,
/// Text color for each syntax style (`.none` is plain text).
syntax: std.EnumArray(Style, Color),

pub const default: @This() = .{
    .bg = hex("#17181f"),
    .fg = hex("#d4d6e4"),
    .gutter_fg = hex("#4a4d63"),
    .gutter_current_fg = hex("#c8a35a"),
    .cursorline_bg = hex("#1f2029"),
    .cursor = hex("#e6c384"),
    .cursor_text = hex("#17181f"),
    .status_bg = hex("#23242f"),
    .status_fg = hex("#b8bacb"),
    .status_dim = hex("#6c6f88"),
    .mode_normal = hex("#7aa8d6"),
    .mode_insert = hex("#98c379"),
    .mode_text = hex("#17181f"),
    .message_info = hex("#b8bacb"),
    .message_err = hex("#e06c75"),
    .popup_bg = hex("#1d1e27"),
    .popup_border = hex("#34364a"),
    .whichkey_key = hex("#e6c384"),
    .whichkey_group = hex("#c49ee8"),
    .whichkey_command = hex("#d4d6e4"),
    .mode_picker = hex("#c49ee8"),
    .mode_visual = hex("#e6c384"),
    .selection_bg = hex("#363a52"),
    .match_fg = hex("#e6c384"),
    .backdrop = hex("#0a0b1099"),
    .search_match = hex("#3d3a2a"),
    .fold_bg = hex("#1d2030"),
    .fold_fg = hex("#7aa8d6"),
    .diag_error = hex("#e06c75"),
    .diag_warning = hex("#e5c07b"),
    .diag_info = hex("#7aa8d6"),
    .diag_hint = hex("#6c6f88"),
    .search_current = hex("#6b5a2a"),
    .syntax = .init(.{
        .none = hex("#d4d6e4"),
        .comment = hex("#6c6f88"),
        .keyword = hex("#c49ee8"),
        .string = hex("#98c379"),
        .escape = hex("#56b6c2"),
        .number = hex("#e5a06b"),
        .constant = hex("#e5a06b"),
        .builtin = hex("#e06c75"),
        .type = hex("#e6c384"),
        .function = hex("#7aa8d6"),
        .property = hex("#8fb8d8"),
        .parameter = hex("#d8b4a0"),
        .operator = hex("#a3a6bd"),
        .punctuation = hex("#8a8da5"),
        .attribute = hex("#e6c384"),
        .label = hex("#56b6c2"),
        .module = hex("#e6c384"),
    }),
};

/// Parses "#rrggbb" or "#rrggbbaa" at compile time.
pub fn hex(comptime s: []const u8) Color {
    comptime {
        @setEvalBranchQuota(10_000);
        if (s.len != 7 and s.len != 9 or s[0] != '#') @compileError("expected #rrggbb or #rrggbbaa, got " ++ s);
        const byte = struct {
            fn at(i: usize) u8 {
                return std.fmt.parseInt(u8, s[i .. i + 2], 16) catch @compileError("bad hex color " ++ s);
            }
        }.at;
        return .{ .r = byte(1), .g = byte(3), .b = byte(5), .a = if (s.len == 9) byte(7) else 255 };
    }
}
