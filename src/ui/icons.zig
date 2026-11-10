//! File-type icons (mini.icons) from the Nerd Fonts private-use glyphs, for
//! picker rows. One table, by extension or whole file name.

const std = @import("std");

pub const Icon = struct {
    cp: u21,
    /// "#rrggbb".
    color: [3]u8,
};

fn icon(cp: u21, comptime color: []const u8) Icon {
    const b = struct {
        fn at(comptime s: []const u8, i: usize) u8 {
            return std.fmt.parseInt(u8, s[i .. i + 2], 16) catch unreachable;
        }
    }.at;
    return .{ .cp = cp, .color = .{ b(color, 1), b(color, 3), b(color, 5) } };
}

pub const folder = icon(0xF07B, "#7aa8d6");
pub const file = icon(0xF15B, "#8a8da5");

const zig = icon(0xE6A9, "#f7a41d");
const c_lang = icon(0xE61E, "#599eff");
const cpp = icon(0xE61D, "#f34b7d");
const header = icon(0xF0FD, "#a074c4");
const rust = icon(0xE7A8, "#dea584");
const python = icon(0xE606, "#ffbc03");
const javascript = icon(0xE74E, "#cbcb41");
const typescript = icon(0xE628, "#519aba");
const json = icon(0xE60B, "#cbcb41");
const markdown = icon(0xE73E, "#9aa5ce");
const lua = icon(0xE620, "#51a0cf");
const go = icon(0xE627, "#00add8");
const html = icon(0xE736, "#e44d26");
const css = icon(0xE749, "#42a5f5");
const shell = icon(0xE795, "#89e051");
const config = icon(0xE615, "#6d8086");
const git = icon(0xE702, "#f14c28");
const lock = icon(0xF023, "#bbbbbb");
const image = icon(0xF1C5, "#a074c4");
const text = icon(0xF15C, "#89e051");

const by_extension = std.StaticStringMap(Icon).initComptime(.{
    .{ "zig", zig },         .{ "zon", zig },          .{ "c", c_lang },       .{ "h", header },      .{ "cpp", cpp },
    .{ "cc", cpp },          .{ "hpp", header },       .{ "rs", rust },        .{ "py", python },     .{ "js", javascript },
    .{ "mjs", javascript },  .{ "jsx", javascript },   .{ "ts", typescript },  .{ "tsx", typescript }, .{ "json", json },
    .{ "md", markdown },     .{ "lua", lua },          .{ "go", go },          .{ "html", html },     .{ "css", css },
    .{ "scss", css },        .{ "sh", shell },         .{ "bash", shell },     .{ "zsh", shell },     .{ "fish", shell },
    .{ "toml", config },     .{ "yaml", config },      .{ "yml", config },     .{ "ini", config },    .{ "conf", config },
    .{ "lock", lock },       .{ "png", image },        .{ "jpg", image },      .{ "jpeg", image },    .{ "gif", image },
    .{ "svg", image },       .{ "webp", image },       .{ "txt", text },       .{ "scm", config },
});

const by_name = std.StaticStringMap(Icon).initComptime(.{
    .{ ".gitignore", git },  .{ ".gitmodules", git }, .{ ".gitattributes", git }, .{ "Makefile", config },
    .{ "LICENSE", text },    .{ "README", text },     .{ "Cargo.lock", lock },
});

/// The icon for a path; a trailing `/` is a folder.
pub fn forPath(path: []const u8) Icon {
    if (std.mem.endsWith(u8, path, "/")) return folder;
    const base = std.fs.path.basename(path);
    if (by_name.get(base)) |i| return i;
    const dot = std.mem.lastIndexOfScalar(u8, base, '.') orelse return file;
    return by_extension.get(base[dot + 1 ..]) orelse file;
}

/// Every glyph used, for the font atlas.
pub const codepoints = blk: {
    const all = [_]Icon{ folder, file, zig, c_lang, cpp, header, rust, python, javascript, typescript, json, markdown, lua, go, html, css, shell, config, git, lock, image, text };
    var out: [all.len]u21 = undefined;
    for (all, 0..) |i, n| out[n] = i.cp;
    const result = out;
    break :blk result;
};

test "icons by extension, name and folder" {
    try std.testing.expectEqual(zig.cp, forPath("src/main.zig").cp);
    try std.testing.expectEqual(folder.cp, forPath("src/").cp);
    try std.testing.expectEqual(git.cp, forPath("a/.gitignore").cp);
    try std.testing.expectEqual(file.cp, forPath("weird.xyz").cp);
}
