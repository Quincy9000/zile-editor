//! Ordered keyboard input straight from GLFW.
//!
//! raylib keeps key presses and typed characters in two separate queues, so the
//! relative order of e.g. `x` and `<Esc>` within one frame is lost. That is fatal
//! for modal editing (fast typing, keyboard macros). We install our own GLFW
//! key/char callbacks that record one ordered stream of `KeyEvent`s, and chain to
//! raylib's original callbacks so its own input state keeps working.
//!
//! All callbacks run on the main thread, inside raylib's PollInputEvents (called
//! from EndDrawing). `wake()` is the only function safe to call from other threads.

const std = @import("std");
const keys = @import("keys.zig");
const KeyEvent = keys.KeyEvent;
const Mods = keys.Mods;
const Special = keys.Special;

const GLFWwindow = opaque {};
const KeyFn = *const fn (?*GLFWwindow, c_int, c_int, c_int, c_int) callconv(.c) void;
const CharFn = *const fn (?*GLFWwindow, c_uint) callconv(.c) void;

// Provided by raylib's bundled GLFW (rglfw.c), linked statically.
extern fn glfwGetCurrentContext() ?*GLFWwindow;
extern fn glfwSetKeyCallback(window: ?*GLFWwindow, callback: ?KeyFn) ?KeyFn;
extern fn glfwSetCharCallback(window: ?*GLFWwindow, callback: ?CharFn) ?CharFn;
extern fn glfwGetKeyName(key: c_int, scancode: c_int) ?[*:0]const u8;
extern fn glfwPostEmptyEvent() void;

const GLFW_RELEASE = 0;

const GLFW_MOD_SHIFT = 0x1;
const GLFW_MOD_CONTROL = 0x2;
const GLFW_MOD_ALT = 0x4;
const GLFW_MOD_SUPER = 0x8;

var prev_key_cb: ?KeyFn = null;
var prev_char_cb: ?CharFn = null;
var installed = false;

/// Modifier state from the most recent key event. GLFW delivers the char event
/// for a keystroke right after its key event, so this is the char's modifiers.
var last_mods: c_int = 0;

const queue_cap = 512;
var queue: [queue_cap]KeyEvent = undefined;
var head: usize = 0; // next to read
var len: usize = 0;
var dropped: usize = 0;

/// Must be called after InitWindow, on the main thread.
pub fn install() error{NoWindow}!void {
    std.debug.assert(!installed);
    // raylib's GetWindowHandle() returns the native (X11/Wayland) handle on Linux,
    // not the GLFWwindow, so ask GLFW for the window whose context is current.
    const window = glfwGetCurrentContext() orelse return error.NoWindow;
    prev_key_cb = glfwSetKeyCallback(window, onKey);
    prev_char_cb = glfwSetCharCallback(window, onChar);
    installed = true;
}

/// Pops the next event in the order it was typed.
pub fn next() ?KeyEvent {
    if (len == 0) return null;
    const ev = queue[head];
    head = (head + 1) % queue_cap;
    len -= 1;
    return ev;
}

/// Number of events lost because the queue was full (should stay 0).
pub fn droppedCount() usize {
    return dropped;
}

/// Wakes the main loop out of raylib's event wait. Thread-safe.
pub fn wake() void {
    glfwPostEmptyEvent();
}

fn push(ev: KeyEvent) void {
    if (len == queue_cap) {
        dropped += 1;
        return;
    }
    queue[(head + len) % queue_cap] = ev;
    len += 1;
}

fn toMods(m: c_int) Mods {
    return .{
        .shift = m & GLFW_MOD_SHIFT != 0,
        .ctrl = m & GLFW_MOD_CONTROL != 0,
        .alt = m & GLFW_MOD_ALT != 0,
        .super = m & GLFW_MOD_SUPER != 0,
    };
}

fn onKey(window: ?*GLFWwindow, key: c_int, scancode: c_int, action: c_int, mods: c_int) callconv(.c) void {
    if (prev_key_cb) |cb| cb(window, key, scancode, action, mods);
    last_mods = mods;
    // TODO(terminal): the kitty keyboard protocol wants releases and repeat flags.
    if (action == GLFW_RELEASE) return;

    const m = toMods(mods);
    if (specialKey(key)) |s| {
        push(.{ .key = .{ .special = s }, .mods = m });
        return;
    }
    // Printable keys normally arrive as text through onChar. When ctrl/alt/super is
    // held, GLFW either sends no char or sends one we must ignore, so the key
    // event is the source of truth.
    if (m.blocksText()) {
        if (printableCodepoint(key, scancode)) |cp| {
            push(.{ .key = .{ .codepoint = cp }, .mods = m });
        }
    }
}

fn onChar(window: ?*GLFWwindow, codepoint: c_uint) callconv(.c) void {
    if (prev_char_cb) |cb| cb(window, codepoint);
    // Already emitted from onKey with its modifiers.
    // TODO(windows): AltGr reports as ctrl+alt there; accept chars in that case.
    if (toMods(last_mods).blocksText()) return;
    const cp = std.math.cast(u21, codepoint) orelse return;
    if (!std.unicode.utf8ValidCodepoint(cp)) return;
    push(KeyEvent.char(cp));
}

fn specialKey(key: c_int) ?Special {
    return switch (key) {
        256 => .escape,
        257, 335 => .enter, // ENTER, KP_ENTER
        258 => .tab,
        259 => .backspace,
        260 => .insert,
        261 => .delete,
        262 => .right,
        263 => .left,
        264 => .down,
        265 => .up,
        266 => .page_up,
        267 => .page_down,
        268 => .home,
        269 => .end,
        290...301 => @enumFromInt(@intFromEnum(Special.f1) + @as(u8, @intCast(key - 290))),
        else => null,
    };
}

/// The unshifted, layout-aware character a printable key produces.
fn printableCodepoint(key: c_int, scancode: c_int) ?u21 {
    if (glfwGetKeyName(key, scancode)) |name_z| {
        const name = std.mem.span(name_z);
        if (name.len > 0) {
            const n = std.unicode.utf8ByteSequenceLength(name[0]) catch return null;
            if (n <= name.len) {
                const cp = std.unicode.utf8Decode(name[0..n]) catch return null;
                return if (cp >= 'A' and cp <= 'Z') cp + ('a' - 'A') else cp;
            }
        }
    }
    // Keys GLFW has no name for (space) or a missing layout: GLFW key codes for
    // printable keys equal their US-layout ASCII values.
    return switch (key) {
        'A'...'Z' => @intCast(key + ('a' - 'A')),
        32...64, 91...96 => @intCast(key),
        else => null,
    };
}
