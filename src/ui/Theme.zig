//! UI colors: the built-in colour schemes (`SPC t t` picks one). "zile" is
//! hand-tuned; the others are derived from nine-colour palettes at compile
//! time (`fromPalette`, in the spirit of mini.base16 / mini.hues). Theme files
//! (ZON) arrive with config.

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
diff_add: Color,
diff_change: Color,
diff_delete: Color,
ghost_bg: Color,
ghost_current_bg: Color,
ghost_fg: Color,
/// AI suggestions (gray, so they never read as code).
ai_fg: Color,
fold_fg: Color,
diag_error: Color,
diag_warning: Color,
diag_info: Color,
diag_hint: Color,
search_current: Color,
/// Other occurrences of the word under the cursor.
cursorword_bg: Color,
/// Trailing whitespace.
trail_bg: Color,
/// The indent scope's guide line.
indent_guide: Color,
/// Inlay hints (type and parameter labels from the language server).
inlay_fg: Color,
inlay_bg: Color,
/// Text color for each syntax style (`.none` is plain text).
syntax: std.EnumArray(Style, Color),

const Theme = @This();

pub const default: Theme = .{
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
    .diff_add = hex("#98c379"),
    .diff_change = hex("#e5c07b"),
    .diff_delete = hex("#e06c75"),
    .ghost_bg = hex("#2a1c22"),
    .ghost_current_bg = hex("#3a2530"),
    .ghost_fg = hex("#c08890"),
    .ai_fg = hex("#62657c"),
    .fold_fg = hex("#7aa8d6"),
    .diag_error = hex("#e06c75"),
    .diag_warning = hex("#e5c07b"),
    .diag_info = hex("#7aa8d6"),
    .diag_hint = hex("#6c6f88"),
    .search_current = hex("#6b5a2a"),
    .cursorword_bg = hex("#2b2d3c"),
    .trail_bg = hex("#5a2a32"),
    .indent_guide = hex("#4a4d63"),
    .inlay_fg = hex("#7a7d96"),
    .inlay_bg = hex("#1f2029"),
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
        .tag = hex("#e06c75"),
        .tag_attribute = hex("#e5a06b"),
        .tag_delimiter = hex("#8a8da5"),
    }),
};

/// The colours a scheme is derived from.
pub const Palette = struct {
    name: []const u8,
    light: bool = false,
    bg: []const u8,
    fg: []const u8,
    red: []const u8,
    orange: []const u8,
    yellow: []const u8,
    green: []const u8,
    cyan: []const u8,
    blue: []const u8,
    purple: []const u8,
};

/// `a` moved `t` of the way toward `b`.
fn mix(a: Color, b: Color, t: f32) Color {
    const ch = struct {
        fn f(x: u8, y: u8, k: f32) u8 {
            const xf: f32 = @floatFromInt(x);
            const yf: f32 = @floatFromInt(y);
            return @intFromFloat(@round(xf + (yf - xf) * k));
        }
    }.f;
    return .{ .r = ch(a.r, b.r, t), .g = ch(a.g, b.g, t), .b = ch(a.b, b.b, t), .a = 255 };
}

/// A whole theme from a palette: surfaces are the background moved toward
/// the foreground, tints are the background moved toward an accent.
pub fn fromPalette(comptime p: Palette) Theme {
    @setEvalBranchQuota(200_000);
    const bg = hex(p.bg);
    const fg = hex(p.fg);
    const red = hex(p.red);
    const orange = hex(p.orange);
    const yellow = hex(p.yellow);
    const green = hex(p.green);
    const cyan = hex(p.cyan);
    const blue = hex(p.blue);
    const purple = hex(p.purple);
    const dim = mix(bg, fg, 0.45);
    var backdrop = mix(bg, hex("#000000"), if (p.light) 0.35 else 0.6);
    backdrop.a = 0x99;
    return .{
        .bg = bg,
        .fg = fg,
        .gutter_fg = mix(bg, fg, 0.3),
        .gutter_current_fg = if (p.light) orange else yellow,
        .cursorline_bg = mix(bg, fg, 0.05),
        .cursor = if (p.light) fg else yellow,
        .cursor_text = bg,
        .status_bg = mix(bg, fg, 0.09),
        .status_fg = mix(bg, fg, 0.8),
        .status_dim = dim,
        .mode_normal = blue,
        .mode_insert = green,
        .mode_text = bg,
        .message_info = mix(bg, fg, 0.8),
        .message_err = red,
        .popup_bg = mix(bg, fg, 0.04),
        .popup_border = mix(bg, fg, 0.2),
        .whichkey_key = if (p.light) orange else yellow,
        .whichkey_group = purple,
        .whichkey_command = fg,
        .mode_picker = purple,
        .mode_visual = yellow,
        .selection_bg = mix(bg, blue, 0.28),
        .match_fg = if (p.light) orange else yellow,
        .backdrop = backdrop,
        .search_match = mix(bg, yellow, 0.28),
        .fold_bg = mix(bg, blue, 0.08),
        .diff_add = green,
        .diff_change = yellow,
        .diff_delete = red,
        .ghost_bg = mix(bg, red, 0.12),
        .ghost_current_bg = mix(bg, red, 0.22),
        .ghost_fg = mix(fg, red, 0.5),
        .ai_fg = mix(bg, fg, 0.38),
        .fold_fg = blue,
        .diag_error = red,
        .diag_warning = yellow,
        .diag_info = blue,
        .diag_hint = dim,
        .search_current = mix(bg, yellow, 0.55),
        .cursorword_bg = mix(bg, fg, 0.13),
        .trail_bg = mix(bg, red, 0.4),
        .indent_guide = mix(bg, fg, 0.28),
        .inlay_fg = mix(bg, fg, 0.5),
        .inlay_bg = mix(bg, fg, 0.08),
        .syntax = .init(.{
            .none = fg,
            .comment = dim,
            .keyword = purple,
            .string = green,
            .escape = cyan,
            .number = orange,
            .constant = orange,
            .builtin = red,
            .type = yellow,
            .function = blue,
            .property = mix(fg, blue, 0.5),
            .parameter = mix(fg, orange, 0.45),
            .operator = mix(bg, fg, 0.72),
            .punctuation = mix(bg, fg, 0.62),
            .attribute = yellow,
            .label = cyan,
            .module = yellow,
            .tag = red,
            .tag_attribute = orange,
            .tag_delimiter = mix(bg, fg, 0.62),
        }),
    };
}

const palettes = [_]Palette{
    .{ .name = "gruvbox", .bg = "#282828", .fg = "#ebdbb2", .red = "#fb4934", .orange = "#fe8019", .yellow = "#fabd2f", .green = "#b8bb26", .cyan = "#8ec07c", .blue = "#83a598", .purple = "#d3869b" },
    .{ .name = "tokyonight", .bg = "#1a1b26", .fg = "#c0caf5", .red = "#f7768e", .orange = "#ff9e64", .yellow = "#e0af68", .green = "#9ece6a", .cyan = "#7dcfff", .blue = "#7aa2f7", .purple = "#bb9af7" },
    .{ .name = "catppuccin", .bg = "#1e1e2e", .fg = "#cdd6f4", .red = "#f38ba8", .orange = "#fab387", .yellow = "#f9e2af", .green = "#a6e3a1", .cyan = "#94e2d5", .blue = "#89b4fa", .purple = "#cba6f7" },
    .{ .name = "nord", .bg = "#2e3440", .fg = "#d8dee9", .red = "#bf616a", .orange = "#d08770", .yellow = "#ebcb8b", .green = "#a3be8c", .cyan = "#88c0d0", .blue = "#81a1c1", .purple = "#b48ead" },
    .{ .name = "rose-pine", .bg = "#191724", .fg = "#e0def4", .red = "#eb6f92", .orange = "#ebbcba", .yellow = "#f6c177", .green = "#9ccfd8", .cyan = "#9ccfd8", .blue = "#31748f", .purple = "#c4a7e7" },
    .{ .name = "solarized-light", .light = true, .bg = "#fdf6e3", .fg = "#586e75", .red = "#dc322f", .orange = "#cb4b16", .yellow = "#b58900", .green = "#859900", .cyan = "#2aa198", .blue = "#268bd2", .purple = "#6c71c4" },
    .{ .name = "github-light", .light = true, .bg = "#ffffff", .fg = "#24292f", .red = "#cf222e", .orange = "#bc4c00", .yellow = "#9a6700", .green = "#116329", .cyan = "#1b7c83", .blue = "#0969da", .purple = "#8250df" },
};

/// Night Owl, with the colours of night-owl.nvim: derived like the others,
/// then the places where it has a colour of its own (strings are peach, not
/// green; the cursor is steel blue; its own selection and search blues).
const night_owl = blk: {
    var t = fromPalette(.{ .name = "night-owl", .bg = "#021727", .fg = "#d6deeb", .red = "#ef5350", .orange = "#f78c6c", .yellow = "#ffcb8b", .green = "#c5e478", .cyan = "#7fdbca", .blue = "#82aaff", .purple = "#c792ea" });
    t.syntax.set(.string, hex("#ecc48d"));
    t.syntax.set(.comment, hex("#637777"));
    t.syntax.set(.constant, hex("#82aaff"));
    t.syntax.set(.builtin, hex("#ff5874"));
    t.syntax.set(.property, hex("#78ccf0"));
    t.syntax.set(.parameter, hex("#d7dbe0"));
    t.syntax.set(.operator, hex("#c792ea"));
    // JSX / HTML as night-owl.nvim: teal tags and brackets, green props.
    t.syntax.set(.tag, hex("#7fdbca"));
    t.syntax.set(.tag_attribute, hex("#c5e478"));
    t.syntax.set(.tag_delimiter, hex("#7fdbca"));
    t.gutter_fg = hex("#4b6479");
    t.gutter_current_fg = hex("#c5e4fc");
    t.cursor = hex("#80a4c2");
    t.cursorline_bg = hex("#0b253a");
    t.selection_bg = hex("#1d3b53");
    t.search_match = hex("#063e5d");
    t.search_current = hex("#234d70");
    t.cursorword_bg = hex("#33384d");
    t.indent_guide = hex("#7e97ac");
    t.fold_bg = hex("#092135");
    t.status_bg = hex("#0b2942");
    t.popup_bg = hex("#01111d");
    t.popup_border = hex("#5f7e97");
    t.diff_add = hex("#9ccc65");
    t.diff_change = hex("#e2b93d");
    t.status_dim = hex("#5f7e97");
    t.ai_fg = hex("#4b6479");
    const result = t;
    break :blk result;
};

/// Themes tuned by hand beyond their palette.
const tuned = [_]struct { []const u8, Theme }{.{ "night-owl", night_owl }};

/// Every built-in theme: "zile" first, then one per palette, then the tuned.
pub const all = blk: {
    var out: [1 + palettes.len + tuned.len]Theme = undefined;
    out[0] = default;
    for (palettes, 1..) |p, i| out[i] = fromPalette(p);
    for (tuned, 1 + palettes.len..) |t, i| out[i] = t[1];
    const result = out;
    break :blk result;
};

pub const names = blk: {
    var out: [1 + palettes.len + tuned.len][]const u8 = undefined;
    out[0] = "zile";
    for (palettes, 1..) |p, i| out[i] = p.name;
    for (tuned, 1 + palettes.len..) |t, i| out[i] = t[0];
    const result = out;
    break :blk result;
};

/// Theme `index` (the default for an index out of range).
pub fn get(index: usize) *const Theme {
    return &all[if (index < all.len) index else 0];
}

/// Black or white, whichever reads better on `c`.
pub fn contrast(c: Color) Color {
    const lum = 0.299 * @as(f32, @floatFromInt(c.r)) + 0.587 * @as(f32, @floatFromInt(c.g)) + 0.114 * @as(f32, @floatFromInt(c.b));
    return if (lum > 140) .{ .r = 0, .g = 0, .b = 0, .a = 255 } else .{ .r = 255, .g = 255, .b = 255, .a = 255 };
}

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
