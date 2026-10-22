//! Exact AOSP `ANativeWindow` / `ANativeWindowBuffer` ABI.
//!
//! These layouts come from `system/window.h` (the stable C ABI used by the
//! platform graphics stack), not from the public opaque NDK type.  Keep the
//! compile-time assertions in sync with the offsets documented in the README.

const std = @import("std");
const ahb = @import("ahb.zig");

pub const ANDROID_NATIVE_WINDOW_MAGIC: c_int = 0x5f776e64; // '_wnd'
pub const ANDROID_NATIVE_BUFFER_MAGIC: c_int = 0x5f626672; // '_bfr'

pub const NATIVE_WINDOW_SURFACE: c_int = 1;

pub const NATIVE_WINDOW_WIDTH: c_int = 0;
pub const NATIVE_WINDOW_HEIGHT: c_int = 1;
pub const NATIVE_WINDOW_FORMAT: c_int = 2;
pub const NATIVE_WINDOW_MIN_UNDEQUEUED_BUFFERS: c_int = 3;
pub const NATIVE_WINDOW_QUEUES_TO_WINDOW_COMPOSER: c_int = 4;
pub const NATIVE_WINDOW_CONCRETE_TYPE: c_int = 5;
pub const NATIVE_WINDOW_DEFAULT_WIDTH: c_int = 6;
pub const NATIVE_WINDOW_DEFAULT_HEIGHT: c_int = 7;
pub const NATIVE_WINDOW_TRANSFORM_HINT: c_int = 8;
pub const NATIVE_WINDOW_CONSUMER_RUNNING_BEHIND: c_int = 9;
pub const NATIVE_WINDOW_CONSUMER_USAGE_BITS: c_int = 10;
pub const NATIVE_WINDOW_STICKY_TRANSFORM: c_int = 11;
pub const NATIVE_WINDOW_DEFAULT_DATASPACE: c_int = 12;
pub const NATIVE_WINDOW_BUFFER_AGE: c_int = 13;
pub const NATIVE_WINDOW_IS_VALID: c_int = 17;
pub const NATIVE_WINDOW_DATASPACE: c_int = 20;
pub const NATIVE_WINDOW_MAX_BUFFER_COUNT: c_int = 21;

pub const NATIVE_WINDOW_SET_USAGE: c_int = 0;
pub const NATIVE_WINDOW_CONNECT: c_int = 1;
pub const NATIVE_WINDOW_DISCONNECT: c_int = 2;
pub const NATIVE_WINDOW_SET_CROP: c_int = 3;
pub const NATIVE_WINDOW_SET_BUFFER_COUNT: c_int = 4;
pub const NATIVE_WINDOW_SET_BUFFERS_GEOMETRY: c_int = 5;
pub const NATIVE_WINDOW_SET_BUFFERS_TRANSFORM: c_int = 6;
pub const NATIVE_WINDOW_SET_BUFFERS_TIMESTAMP: c_int = 7;
pub const NATIVE_WINDOW_SET_BUFFERS_DIMENSIONS: c_int = 8;
pub const NATIVE_WINDOW_SET_BUFFERS_FORMAT: c_int = 9;
pub const NATIVE_WINDOW_SET_SCALING_MODE: c_int = 10;
pub const NATIVE_WINDOW_API_CONNECT: c_int = 13;
pub const NATIVE_WINDOW_API_DISCONNECT: c_int = 14;
pub const NATIVE_WINDOW_SET_BUFFERS_DATASPACE: c_int = 19;
pub const NATIVE_WINDOW_SET_AUTO_REFRESH: c_int = 22;
pub const NATIVE_WINDOW_SET_USAGE64: c_int = 30;
pub const NATIVE_WINDOW_SET_FRAME_RATE: c_int = 40;

pub const NativeBase = extern struct {
    magic: c_int,
    version: c_int,
    reserved: [4]?*anyopaque,
    incRef: ?*const fn (*NativeBase) callconv(.c) void,
    decRef: ?*const fn (*NativeBase) callconv(.c) void,
};

pub const ANativeWindow = extern struct {
    common: NativeBase,

    flags: u32,
    minSwapInterval: c_int,
    maxSwapInterval: c_int,
    xdpi: f32,
    ydpi: f32,
    oem: [4]isize,

    setSwapInterval: ?*const fn (*ANativeWindow, c_int) callconv(.c) c_int,
    dequeueBuffer_DEPRECATED: ?*const fn (*ANativeWindow, *?*ANativeWindowBuffer) callconv(.c) c_int,
    lockBuffer_DEPRECATED: ?*const fn (*ANativeWindow, *ANativeWindowBuffer) callconv(.c) c_int,
    queueBuffer_DEPRECATED: ?*const fn (*ANativeWindow, *ANativeWindowBuffer) callconv(.c) c_int,
    query: ?*const fn (*const ANativeWindow, c_int, *c_int) callconv(.c) c_int,
    perform: ?*const fn (*ANativeWindow, c_int, ...) callconv(.c) c_int,
    cancelBuffer_DEPRECATED: ?*const fn (*ANativeWindow, *ANativeWindowBuffer) callconv(.c) c_int,

    dequeueBuffer: ?*const fn (*ANativeWindow, *?*ANativeWindowBuffer, *c_int) callconv(.c) c_int,
    queueBuffer: ?*const fn (*ANativeWindow, *ANativeWindowBuffer, c_int) callconv(.c) c_int,
    cancelBuffer: ?*const fn (*ANativeWindow, *ANativeWindowBuffer, c_int) callconv(.c) c_int,
};

pub const ANativeWindowBuffer = extern struct {
    common: NativeBase,
    width: c_int,
    height: c_int,
    stride: c_int,
    format: c_int,
    usage_deprecated: c_int,
    layerCount: usize,
    reserved: [1]?*anyopaque,
    handle: ?*const ahb.NativeHandle,
    usage: u64,
    reserved_proc: [8 - @sizeOf(u64) / @sizeOf(usize)]?*anyopaque,
};

comptime {
    std.debug.assert(@sizeOf(ANativeWindow) == 192);
    std.debug.assert(@offsetOf(ANativeWindow, "flags") == 56);
    std.debug.assert(@offsetOf(ANativeWindow, "setSwapInterval") == 112);
    std.debug.assert(@offsetOf(ANativeWindow, "query") == 144);
    std.debug.assert(@offsetOf(ANativeWindow, "perform") == 152);
    std.debug.assert(@offsetOf(ANativeWindow, "dequeueBuffer") == 168);
    std.debug.assert(@offsetOf(ANativeWindow, "queueBuffer") == 176);
    std.debug.assert(@offsetOf(ANativeWindow, "cancelBuffer") == 184);

    std.debug.assert(@sizeOf(ANativeWindowBuffer) == 168);
    std.debug.assert(@offsetOf(ANativeWindowBuffer, "width") == 56);
    std.debug.assert(@offsetOf(ANativeWindowBuffer, "stride") == 64);
    std.debug.assert(@offsetOf(ANativeWindowBuffer, "format") == 68);
    std.debug.assert(@offsetOf(ANativeWindowBuffer, "handle") == 96);
    std.debug.assert(@offsetOf(ANativeWindowBuffer, "usage") == 104);
}
