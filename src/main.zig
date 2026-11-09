const std = @import("std");
const rl = @import("raylib");

const Editor = @import("Editor.zig");
const glfw = @import("input/glfw.zig");
const Font = @import("ui/Font.zig");
const Theme = @import("ui/Theme.zig");
const render = @import("ui/render.zig");
const keys = @import("input/keys.zig");
const Tui = @import("tui/Tui.zig");

const usage =
    \\usage: zile [options] [file]
    \\
    \\options:
    \\  --font <path>       TTF/OTF font file (default: discovered monospace font)
    \\  --font-size <px>    font size in pixels (default: 18)
    \\  -t, --tui           draw in the terminal instead of a window (automatic
    \\                      when there is no display, e.g. over SSH)
    \\  -h, --help          show this help
    \\
    \\debug environment variables:
    \\  ZILE_TEST_KEYS=<keys>         feed key notation at startup, e.g. "ihello<Esc>"
    \\  ZILE_TEST_SCREENSHOT=<path>   save a PNG of the first frames, then exit
    \\
;

const Args = struct {
    file: ?[]const u8 = null,
    tui: bool = false,
    font: ?[]const u8 = null,
    font_size: i32 = 18,
};

fn parseArgs(init: std.process.Init) !Args {
    var out: Args = .{};
    var it = init.minimal.args.iterate();
    _ = it.skip();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "-h") or std.mem.eql(u8, arg, "--help")) {
            std.debug.print("{s}", .{usage});
            std.process.exit(0);
        } else if (std.mem.eql(u8, arg, "-t") or std.mem.eql(u8, arg, "--tui")) {
            out.tui = true;
        } else if (std.mem.eql(u8, arg, "--font")) {
            out.font = it.next() orelse return error.MissingArgument;
        } else if (std.mem.eql(u8, arg, "--font-size")) {
            const v = it.next() orelse return error.MissingArgument;
            out.font_size = std.fmt.parseInt(i32, v, 10) catch return error.InvalidArgument;
        } else if (std.mem.startsWith(u8, arg, "-") and arg.len > 1) {
            std.log.err("unknown option '{s}'\n\n{s}", .{ arg, usage });
            return error.InvalidArgument;
        } else {
            out.file = arg;
        }
    }
    return out;
}

pub fn main(init: std.process.Init) !void {
    const gpa = init.gpa;
    const io = init.io;
    const args = try parseArgs(init);
    const test_keys = init.environ_map.get("ZILE_TEST_KEYS");
    const test_screenshot = init.environ_map.get("ZILE_TEST_SCREENSHOT");

    var ed = try Editor.init(gpa, io);
    defer ed.deinit();
    if (args.file) |path| ed.openArg(path);

    const theme = &Theme.default;
    ed.term_fg = .{ .r = theme.fg.r, .g = theme.fg.g, .b = theme.fg.b };
    ed.term_bg = .{ .r = theme.popup_bg.r, .g = theme.popup_bg.g, .b = theme.popup_bg.b };

    // Terminal mode when asked, or when there is no display to open a window on.
    const env = init.environ_map;
    const no_display = env.get("DISPLAY") == null and env.get("WAYLAND_DISPLAY") == null;
    if (args.tui or no_display) return runTui(gpa, io, &ed, theme, test_keys, test_screenshot);

    // raylib warns about every oversized box-drawing glyph; only show errors.
    rl.SetTraceLogLevel(rl.LOG_ERROR);
    rl.SetConfigFlags(rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT);
    rl.InitWindow(1100, 720, "zile");
    // No window after all (no X11/GL libraries, a display we can't reach):
    // the terminal still works.
    if (!rl.IsWindowReady()) return runTui(gpa, io, &ed, theme, test_keys, test_screenshot);
    defer rl.CloseWindow();
    // raylib closes the window on Esc by default; Esc is a mode key here.
    rl.SetExitKey(rl.KEY_NULL);
    try glfw.install();
    ed.wake_fn = glfw.wake;
    ed.registers.clipboard = .{ .get = clipboardGet, .set = clipboardSet };
    // Sleep until input arrives instead of redrawing at 60 fps. Worker threads
    // (LSP, terminal) will call glfw.wake() when they have results.
    if (test_screenshot == null) rl.EnableEventWaiting();

    var font = try Font.load(gpa, io, args.font, args.font_size);
    defer font.deinit();

    // Size the view before scripted keys so scrolling behaves like the real window.
    _ = render.prepare(&ed, &font, rl.GetScreenWidth(), rl.GetScreenHeight());
    // Scripted keys: "<Wait>" splits them into segments fed ~0.75s apart, so
    // async results (language server, pickers) can arrive in between.
    var script = std.mem.splitSequence(u8, test_keys orelse "", "<Wait>");
    var next_segment_frame: usize = 0;
    var screenshot_frame: ?usize = null;
    const wait_frames = 45;

    var title: TitleCache = .{};
    var frame: usize = 0;
    while (!rl.WindowShouldClose() and !ed.should_quit) : (frame += 1) {
        if (frame == next_segment_frame and screenshot_frame == null) {
            if (script.next()) |segment| {
                ed.feed(segment) catch |err| std.log.err("ZILE_TEST_KEYS: {s}", .{@errorName(err)});
                next_segment_frame = frame + wait_frames;
            } else screenshot_frame = frame + 5;
        }
        while (glfw.next()) |ev| {
            // Zoom works everywhere (pickers, terminals): the usual app keys.
            if (zoomKey(&ed, ev)) continue;
            ed.handleKey(ev);
        }
        ed.tick();
        applyZoom(&ed, gpa, io, &font, args);

        handleMouse(&ed, &font);
        const l = render.prepare(&ed, &font, rl.GetScreenWidth(), rl.GetScreenHeight());
        title.update(&ed);

        rl.BeginDrawing();
        render.draw(&ed, &font, theme, l);
        if (test_screenshot) |path| {
            // A few frames let the window settle and pickers fill.
            if (screenshot_frame == frame) {
                const path_z = try gpa.dupeSentinel(u8, path, 0);
                defer gpa.free(path_z);
                // Draw calls are batched until EndDrawing; flush so the
                // screenshot sees this frame.
                rlDrawRenderBatchActive();
                rl.TakeScreenshot(path_z.ptr);
                ed.should_quit = true;
            }
        }
        rl.EndDrawing();
    }
}

extern fn rlDrawRenderBatchActive() void; // rlgl, part of raylib

fn runTui(gpa: std.mem.Allocator, io: std.Io, ed: *Editor, theme: *const Theme, test_keys: ?[]const u8, snapshot: ?[]const u8) !void {
    Tui.run(gpa, io, ed, .{ .theme = theme, .test_keys = test_keys, .test_snapshot = snapshot }) catch |err| switch (err) {
        error.NotATerminal => {
            std.log.err("no display to open a window on, and not running in a terminal", .{});
            return err;
        },
        else => return err,
    };
}

fn clipboardGet(gpa: std.mem.Allocator) ?[]u8 {
    const text = rl.GetClipboardText() orelse return null;
    return gpa.dupe(u8, std.mem.span(text)) catch null;
}

fn clipboardSet(gpa: std.mem.Allocator, text: []const u8) void {
    const z = gpa.dupeSentinel(u8, text, 0) catch return;
    defer gpa.free(z);
    rl.SetClipboardText(z.ptr);
}

/// The wheel scrolls the window under the pointer; a click focuses that
/// window and moves the cursor there.
/// Ctrl+= / Ctrl+- / Ctrl+0: zoom. True when the key was one of them.
fn zoomKey(ed: *Editor, ev: keys.KeyEvent) bool {
    if (!ev.mods.ctrl or ev.mods.alt or ev.key != .codepoint) return false;
    switch (ev.key.codepoint) {
        '=', '+' => ed.zoom_request += 1,
        '-' => ed.zoom_request -= 1,
        '0' => ed.zoom_reset = true,
        else => return false,
    }
    return true;
}

const min_font_size = 8;
const max_font_size = 72;

/// Reloads the font at the requested size (the glyph atlas is baked per size).
fn applyZoom(ed: *Editor, gpa: std.mem.Allocator, io: std.Io, font: *Font, args: Args) void {
    if (ed.zoom_request == 0 and !ed.zoom_reset) return;
    const current: i32 = font.font.baseSize;
    const size = if (ed.zoom_reset) args.font_size else std.math.clamp(current + 2 * ed.zoom_request, min_font_size, max_font_size);
    ed.zoom_request = 0;
    ed.zoom_reset = false;
    if (size == current) return;
    const fresh = Font.load(gpa, io, args.font, size) catch return;
    font.deinit();
    font.* = fresh;
    ed.setMessage(.info, "text size {d}", .{size});
}

fn handleMouse(ed: *Editor, font: *const Font) void {
    const pos = rl.GetMousePosition();
    const wheel = rl.GetMouseWheelMove();
    // Ctrl+wheel zooms.
    if (wheel != 0 and (rl.IsKeyDown(rl.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KEY_RIGHT_CONTROL))) {
        ed.zoom_request += if (wheel > 0) 1 else -1;
        return;
    }
    const clicked = rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
    if (wheel == 0 and !clicked) return;
    // The command editor keeps focus while it is open.
    if (ed.cmd_float != null) {
        if (wheel != 0) ed.scrollLines(@intFromFloat(-wheel * 3));
        return;
    }
    // The terminal popup takes the wheel (scrollback) while it is open.
    if (ed.popupTerminal()) |t| {
        if (wheel != 0) t.scroll(@intFromFloat(-wheel * 3));
        return;
    }
    const w = ed.windows.at(pos.x, pos.y) orelse return;
    ed.focusWindow(w);
    if (w.term) |t| {
        if (wheel != 0) t.scroll(@intFromFloat(-wheel * 3));
        return;
    }
    if (wheel != 0) ed.scrollLines(@intFromFloat(-wheel * 3));
    if (clicked) {
        const l = render.windowLayout(ed, font, w);
        if (l.cellAt(font, pos.x - l.x0, pos.y - l.y0)) |cell| ed.clickCell(cell.row, cell.col);
    }
}

/// Keeps the window title in sync without calling into GLFW every frame.
const TitleCache = struct {
    buf: [512]u8 = undefined,
    len: usize = 0,

    fn update(tc: *TitleCache, ed: *Editor) void {
        var next: [512]u8 = undefined;
        const title = std.fmt.bufPrintSentinel(&next, "{s}{s} - zile", .{
            ed.buffer.displayName(),
            if (ed.buffer.modified) " [+]" else "",
        }, 0) catch return;
        if (std.mem.eql(u8, title, tc.buf[0..tc.len])) return;
        @memcpy(tc.buf[0..title.len], title);
        tc.len = title.len;
        rl.SetWindowTitle(title.ptr);
    }
};
