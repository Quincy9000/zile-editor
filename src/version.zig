//! zile's version. The number is build.zig.zon's (the one place it is
//! written; it goes up with each commit), and a debug build says so, since
//! it is many times slower than the release one.
const builtin = @import("builtin");

pub const number: []const u8 = @import("build_info").version;

/// "0.1.0", or "0.1.0 debug".
pub const text: []const u8 = number ++ if (builtin.mode == .debug) " debug" else "";
