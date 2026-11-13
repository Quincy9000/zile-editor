const std = @import("std");
const rl = @import("raylib");

const Editor = @import("Editor.zig");
const glfw = @import("input/glfw.zig");
const Font = @import("ui/Font.zig");
const Theme = @import("ui/Theme.zig");
const render = @import("ui/render.zig");
const keys = @import("input/keys.zig");
const Tui = @import("tui/Tui.zig");
const config = @import("config/config.zig");
const grammars = @import("config/grammars.zig");
const state_files = @import("editor/state_files.zig");
const notifications = @import("editor/notifications.zig");
const window_ops = @import("editor/window_ops.zig");
const smooth_scrolling = @import("editor/smooth_scrolling.zig");
const run_popup = @import("editor/run_popup.zig");
const borders = @import("editor/borders.zig");
const resting = @import("editor/resting.zig");
const row_model = @import("editor/row_model.zig");

const usage =
    \\usage: zile [options] [file]
    \\
    \\options:
    \\  --font <path>       TTF/OTF font file (default: discovered monospace font)
    \\  --font-size <px>    font size in pixels (default: 18)
    \\  -t, --tui           draw in the terminal instead of a window (automatic
    \\                      when there is no display, e.g. over SSH)
    \\  -h, --help          show this help
    \\  --grammar install [name...]
    \\                      fetch and build the grammars named in
    \\                      ~/.config/zile/languages.toml
    \\  --grammar list      every language and where its grammar comes from
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
    // `zile --grammar ...` does that and nothing else.
    {
        var it = init.minimal.args.iterate();
        _ = it.skip();
        if (it.next()) |first| if (std.mem.eql(u8, first, "--grammar")) {
            var rest: std.ArrayList([]const u8) = .empty;
            defer rest.deinit(gpa);
            while (it.next()) |a| try rest.append(gpa, a);
            std.process.exit(grammars.main(gpa, io, rest.items));
        };
    }
    const args = try parseArgs(init);
    // Terminal mode: our own screen first thing, before loading anything.
    const env0 = init.environ_map;
    const tui_mode = args.tui or (env0.get("DISPLAY") == null and env0.get("WAYLAND_DISPLAY") == null);
    const early = tui_mode and init.environ_map.get("ZILE_TEST_KEYS") == null and Tui.enterEarly();
    errdefer if (early) Tui.leaveEarly();
    // Languages from the config, before any file opens.
    const config_report = config.load(io);
    const test_keys = init.environ_map.get("ZILE_TEST_KEYS");
    const test_screenshot = init.environ_map.get("ZILE_TEST_SCREENSHOT");

    var ed = try Editor.init(gpa, io);
    defer ed.deinit();
    ed.environ = init.environ_map;
    // Old sessions and undo histories past the limits go.
    state_files.pruneStoredData(&ed);
    // What is remembered between runs: the session and the visits, saved on
    // the way out (however we leave).
    defer {
        state_files.saveSession(&ed, false);
        state_files.rememberPositions(&ed);
        state_files.saveVisits(&ed);
    }
    for (config_report.problems) |p| notifications.notify(&ed, .err, "{s}", .{p});
    ed.theme_names = &Theme.names;
    state_files.loadTheme(&ed);
    if (args.file) |path| ed.openArg(path);
    // No file: the start screen (not under scripted keys, which expect to
    // begin in normal mode).
    if (args.file == null and test_keys == null) state_files.openStarter(&ed) catch {};

    var theme = Theme.get(ed.theme_index);
    syncTerminalColors(&ed, theme);

    // Terminal mode when asked, or when there is no display to open a window on.
    const env = init.environ_map;
    const no_display = env.get("DISPLAY") == null and env.get("WAYLAND_DISPLAY") == null;
    if (args.tui or no_display) return runTui(gpa, io, &ed, test_keys, test_screenshot);

    // raylib warns about every oversized box-drawing glyph; only show errors.
    rl.SetTraceLogLevel(rl.LOG_ERROR);
    // A screenshot run must not take the keyboard from whoever is typing.
    const flags: c_uint = rl.FLAG_WINDOW_RESIZABLE | rl.FLAG_VSYNC_HINT;
    const quiet: c_uint = rl.FLAG_WINDOW_UNFOCUSED;
    rl.SetConfigFlags(if (test_screenshot != null) flags | quiet else flags);
    rl.InitWindow(1100, 720, "zile");
    // No window after all (no X11/GL libraries, a display we can't reach):
    // the terminal still works.
    if (!rl.IsWindowReady()) return runTui(gpa, io, &ed, test_keys, test_screenshot);
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
    // Without a Nerd Font the icons would be boxes.
    if (!font.has_icons) ed.options.icons = false;
    // A screenshot should show where things are, not a scroll in mid-glide.
    if (test_screenshot != null) ed.options.smooth_scroll = false;

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
    var focused = true;
    while (!rl.WindowShouldClose() and !ed.should_quit) : (frame += 1) {
        // Autosave: modified files are written when zile loses focus.
        const now_focused = rl.IsWindowFocused();
        if (focused and !now_focused) state_files.focusLost(&ed);
        focused = now_focused;
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
        if (theme != Theme.get(ed.theme_index)) {
            theme = Theme.get(ed.theme_index);
            syncTerminalColors(&ed, theme);
        }

        handleMouse(&ed, &font);
        // After everything that scrolls this frame (keys and the wheel): a
        // scroll the glide hasn't taken in yet would show for one frame as
        // a jump ahead and back.
        smooth_scrolling.animate(&ed, rl.GetFrameTime());
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
        // Something is still moving (a gliding scroll, a fading toast):
        // draw the next frame without waiting for input.
        if (notifications.wantsFrames(&ed)) glfw.wake();
        rl.EndDrawing();
    }
}

/// New terminals take their default colours from the theme.
fn syncTerminalColors(ed: *Editor, theme: *const Theme) void {
    ed.term_fg = .{ .r = theme.fg.r, .g = theme.fg.g, .b = theme.fg.b };
    ed.term_bg = .{ .r = theme.popup_bg.r, .g = theme.popup_bg.g, .b = theme.popup_bg.b };
}

extern fn rlDrawRenderBatchActive() void; // rlgl, part of raylib

fn runTui(gpa: std.mem.Allocator, io: std.Io, ed: *Editor, test_keys: ?[]const u8, snapshot: ?[]const u8) !void {
    Tui.run(gpa, io, ed, .{ .test_keys = test_keys, .test_snapshot = snapshot }) catch |err| switch (err) {
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

/// Wheel movement over a terminal not yet turned into whole lines
/// (touchpads and smooth wheels report fractions of a notch).
var wheel_rest: f32 = 0;

/// Whole lines to scroll for this frame's wheel movement (three per notch).
fn wheelLines(wheel: f32) isize {
    if (wheel == 0) return 0;
    // A change of direction starts over.
    if ((wheel > 0) == (wheel_rest > 0)) wheel_rest = 0;
    wheel_rest += -wheel * 3;
    const whole = @trunc(wheel_rest);
    wheel_rest -= whole;
    return @intFromFloat(whole);
}

fn handleMouse(ed: *Editor, font: *const Font) void {
    const pos = rl.GetMousePosition();
    const wheel = glfw.takeWheel();
    // Ctrl+wheel zooms.
    if (wheel != 0 and (rl.IsKeyDown(rl.KEY_LEFT_CONTROL) or rl.IsKeyDown(rl.KEY_RIGHT_CONTROL))) {
        ed.zoom_request += if (wheel > 0) 1 else -1;
        return;
    }
    const clicked = rl.IsMouseButtonPressed(rl.MOUSE_BUTTON_LEFT);
    hoverMouse(ed, font, pos);
    if (borderMouse(ed, pos, clicked)) return;
    // A press that started on text: dragging selects, letting go copies.
    if (ed.mouse_drag != null and !clicked) {
        if (rl.IsMouseButtonReleased(rl.MOUSE_BUTTON_LEFT) or !rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            row_model.mouseRelease(ed);
        } else if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) {
            const l = render.windowLayout(ed, font, ed.window);
            if (l.cellAt(font, pos.x - l.x0, pos.y - l.y0)) |cell| row_model.mouseDrag(ed, cell.row, cell.col);
        }
    }
    if (wheel == 0 and !clicked) return;
    const lines = wheelLines(wheel);
    // The command editor keeps focus while it is open.
    if (ed.cmd_float != null) {
        if (lines != 0) ed.scrollLines(lines);
        return;
    }
    // The terminal popup takes the wheel (scrollback) while it is open.
    if (run_popup.popupTerminal(ed)) |t| {
        if (lines != 0) t.scroll(lines);
        return;
    }
    const w = ed.windows.at(pos.x, pos.y) orelse return;
    window_ops.focusWindow(ed, w);
    if (w.term) |t| {
        if (lines != 0) t.scroll(lines);
        return;
    }
    // Editor windows take the wheel as it is, fractions and all.
    smooth_scrolling.scrollSmooth(ed, -wheel * 3);
    if (clicked) {
        const l = render.windowLayout(ed, font, w);
        if (l.cellAt(font, pos.x - l.x0, pos.y - l.y0)) |cell| row_model.mousePress(ed, cell.row, cell.col, clicks.count(cell.row, cell.col, rl.GetTime()));
    }
}

/// The pointer over the focused window's text, buttons up: a diagnostic
/// under it pops up after a moment.
fn hoverMouse(ed: *Editor, font: *const Font, pos: rl.Vector2) void {
    const busy = rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT);
    resting.mouseHover(ed, if (busy) null else render.hoverCell(ed, font, pos.x, pos.y));
}

/// The cursor shape last asked of raylib.
var pointer_shown: borders.Pointer = .normal;

/// Window borders (`borders.borderPress` and co.): true while the mouse is
/// busy with one.
fn borderMouse(ed: *Editor, pos: rl.Vector2, clicked: bool) bool {
    const slop = 4;
    const busy = if (rl.IsMouseButtonDown(rl.MOUSE_BUTTON_LEFT)) borders.borderDrag(ed, pos.x, pos.y) else borders.borderRelease(ed);
    const shape = borders.pointerAt(ed, pos.x, pos.y, slop);
    if (shape != pointer_shown) {
        pointer_shown = shape;
        rl.SetMouseCursor(switch (shape) {
            .normal => rl.MOUSE_CURSOR_DEFAULT,
            .resize_columns => rl.MOUSE_CURSOR_RESIZE_EW,
            .resize_rows => rl.MOUSE_CURSOR_RESIZE_NS,
        });
    }
    return busy or (clicked and borders.borderPress(ed, pos.x, pos.y, slop));
}

/// Double and triple clicks: presses on the same cell close together.
pub const ClickCounter = struct {
    last_time: f64 = -10,
    row: usize = 0,
    col: usize = 0,
    n: u8 = 0,

    pub fn count(c: *ClickCounter, row: usize, col: usize, now: f64) u8 {
        const again = now - c.last_time < 0.4 and row == c.row and col == c.col;
        c.n = if (again) @min(c.n + 1, 3) else 1;
        c.last_time = now;
        c.row = row;
        c.col = col;
        return c.n;
    }
};
var clicks: ClickCounter = .{};

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
