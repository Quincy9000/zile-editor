//! Signature help: the function being called, shown while its arguments are typed.

const std = @import("std");
const Buffer = @import("../core/Buffer.zig");
const Lsp = @import("../lsp/Lsp.zig");
const Editor = @import("../Editor.zig");
const SignatureHelp = Editor.SignatureHelp;

pub fn closeSignature(ed: *Editor) void {
    const s = ed.signature orelse return;
    s.deinit(ed.gpa);
    ed.signature = null;
}

/// A `textDocument/signatureHelp` reply: the active signature and
/// parameter, or nothing (closes the popup).
pub fn showSignature(ed: *Editor, b: *Buffer, result: std.json.Value) !void {
    closeSignature(ed);
    if (b != ed.buffer or ed.mode != .insert) return;
    const sigs = Lsp.field(result, "signatures") orelse return;
    if (sigs != .array or sigs.array.items.len == 0) return;
    const active_sig: usize = if (Lsp.field(result, "activeSignature")) |v| (if (v == .integer) @intCast(@max(v.integer, 0)) else 0) else 0;
    const sig = sigs.array.items[@min(active_sig, sigs.array.items.len - 1)];
    const label = Lsp.str(Lsp.field(sig, "label")) orelse return;
    const active_param: ?usize = blk: {
        const v = Lsp.field(sig, "activeParameter") orelse Lsp.field(result, "activeParameter") orelse break :blk 0;
        break :blk if (v == .integer and v.integer >= 0) @intCast(v.integer) else null;
    };
    var help: SignatureHelp = .{ .label = try ed.gpa.dupe(u8, label), .doc = &.{} };
    errdefer help.deinit(ed.gpa);
    var doc_src: ?std.json.Value = Lsp.field(sig, "documentation");
    if (Lsp.field(sig, "parameters")) |params| if (params == .array and active_param != null and active_param.? < params.array.items.len) {
        const param = params.array.items[active_param.?];
        if (Lsp.field(param, "label")) |v| switch (v) {
            // Offsets into the label (UTF-16 by the spec; ASCII in practice).
            .array => |a| if (a.items.len == 2 and a.items[0] == .integer and a.items[1] == .integer) {
                help.param_start = @min(@as(usize, @intCast(@max(a.items[0].integer, 0))), label.len);
                help.param_end = @min(@as(usize, @intCast(@max(a.items[1].integer, 0))), label.len);
            },
            .string => |param_text| if (std.mem.indexOf(u8, label, param_text)) |at| {
                help.param_start = at;
                help.param_end = at + param_text.len;
            },
            else => {},
        };
        if (Lsp.field(param, "documentation")) |d| doc_src = d;
    };
    if (doc_src) |d| {
        const doc_text = Lsp.str(d) orelse Lsp.str(Lsp.field(d, "value")) orelse "";
        help.doc = try ed.gpa.dupe(u8, std.mem.trim(u8, std.mem.sliceTo(doc_text, '\n'), " \t"));
    }
    ed.signature = help;
}
