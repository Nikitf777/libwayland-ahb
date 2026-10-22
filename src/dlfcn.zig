//! Runtime loader hooks.
//!
//! The Termux Zig toolchain cannot link the platform (bionic) libc because no
//! NDK sysroot is shipped with it.  That is fine for this project: the shim is
//! a shared object that is always loaded into a process which already has
//! libc/libdl mapped, so these symbols are resolved by the platform dynamic
//! linker when our .so is loaded.

const std = @import("std");

pub const RTLD_LAZY: c_int = 0x00001;
pub const RTLD_NOW: c_int = 0x00002;
pub const RTLD_LOCAL: c_int = 0x00000;
pub const RTLD_GLOBAL: c_int = 0x00100;

pub extern fn dlopen(path: ?[*:0]const u8, mode: c_int) ?*anyopaque;
pub extern fn dlsym(handle: ?*anyopaque, name: [*:0]const u8) ?*anyopaque;
pub extern fn dlerror() ?[*:0]const u8;
pub extern fn getenv(name: [*:0]const u8) ?[*:0]const u8;

/// RTLD_DEFAULT
pub const default_handle: ?*anyopaque = null;

pub fn errorMessage() []const u8 {
    const msg = dlerror() orelse return "unknown error";
    return std.mem.span(msg);
}
