//! Locate and load the *real* platform EGL implementation.
//!
//! The shim deliberately loads `/system/lib64/libEGL.so` by absolute path.
//! Android's EGL is only a thin loader; it knows how to find the vendor EGL
//! driver (`libEGL_adreno.so`, etc.) through the sphal linker namespace.
//! Termux's Mesa `libEGL.so` must never be used here.

const std = @import("std");
const dlfcn = @import("dlfcn.zig");
const builtin = @import("builtin");

pub const default_loader: [*:0]const u8 = if (builtin.target.ptrBitWidth() == 64)
    "/system/lib64/libEGL.so"
else
    "/system/lib/libEGL.so";

pub const PFNGetDisplay = *const fn (?*anyopaque) callconv(.c) ?*anyopaque;
pub const PFNGetPlatformDisplay = *const fn (u32, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque;
pub const PFNGetPlatformDisplayExt = *const fn (u32, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque;
pub const PFNCreateWindowSurface = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque;
pub const PFNCreatePlatformWindowSurface = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const isize) callconv(.c) ?*anyopaque;
pub const PFNCreatePlatformWindowSurfaceExt = *const fn (?*anyopaque, ?*anyopaque, ?*anyopaque, ?[*]const i32) callconv(.c) ?*anyopaque;
pub const PFNQueryString = *const fn (?*anyopaque, i32) callconv(.c) ?[*:0]const u8;
pub const PFNGetProcAddress = *const fn ([*:0]const u8) callconv(.c) ?*anyopaque;
pub const PFNTerminate = *const fn (?*anyopaque) callconv(.c) u32;

pub const Api = struct {
    get_display: PFNGetDisplay,
    get_platform_display: ?PFNGetPlatformDisplay,
    get_platform_display_ext: ?PFNGetPlatformDisplayExt,
    create_window_surface: PFNCreateWindowSurface,
    create_platform_window_surface: ?PFNCreatePlatformWindowSurface,
    create_platform_window_surface_ext: ?PFNCreatePlatformWindowSurfaceExt,
    query_string: PFNQueryString,
    get_proc_address: PFNGetProcAddress,
    terminate: ?PFNTerminate,
};

var mutex: std.atomic.Mutex = .unlocked;
var handle: ?*anyopaque = null;
var api: ?Api = null;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    mutex.unlock();
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (dlfcn.getenv("VKWL_LOG") == null) return;
    std.debug.print("[eglahb] " ++ fmt ++ "\n", args);
}

fn lookup(handle_: ?*anyopaque, comptime name: [*:0]const u8, comptime T: type) ?T {
    const sym = dlfcn.dlsym(handle_, name) orelse return null;
    return @ptrCast(@alignCast(sym));
}

/// Must be called with `mutex` held.
fn openLocked() ?*anyopaque {
    if (handle) |h| return h;

    const path = dlfcn.getenv("VKWL_NATIVE_EGL") orelse default_loader;
    const h = dlfcn.dlopen(path, dlfcn.RTLD_NOW | dlfcn.RTLD_LOCAL) orelse {
        log("cannot open native EGL '{s}': {s}", .{ path, dlfcn.errorMessage() });
        return null;
    };

    handle = h;
    log("using native EGL '{s}'", .{path});
    return h;
}

/// Must be called with `mutex` held.
fn initLocked() ?*const Api {
    if (api) |*loaded| return loaded;

    const h = openLocked() orelse return null;
    const get_display = lookup(h, "eglGetDisplay", PFNGetDisplay) orelse {
        log("native EGL has no eglGetDisplay: {s}", .{dlfcn.errorMessage()});
        return null;
    };
    const create_window_surface =
        lookup(h, "eglCreateWindowSurface", PFNCreateWindowSurface) orelse {
            log("native EGL has no eglCreateWindowSurface: {s}", .{dlfcn.errorMessage()});
            return null;
        };
    const query_string = lookup(h, "eglQueryString", PFNQueryString) orelse {
        log("native EGL has no eglQueryString: {s}", .{dlfcn.errorMessage()});
        return null;
    };
    const get_proc_address = lookup(h, "eglGetProcAddress", PFNGetProcAddress) orelse {
        log("native EGL has no eglGetProcAddress: {s}", .{dlfcn.errorMessage()});
        return null;
    };

    const gpa = get_proc_address;
    api = .{
        .get_display = get_display,
        .get_platform_display = lookup(h, "eglGetPlatformDisplay", PFNGetPlatformDisplay),
        .get_platform_display_ext = if (gpa("eglGetPlatformDisplayEXT")) |sym|
            @ptrCast(@alignCast(sym))
        else
            null,
        .create_window_surface = create_window_surface,
        .create_platform_window_surface = lookup(h, "eglCreatePlatformWindowSurface", PFNCreatePlatformWindowSurface),
        .create_platform_window_surface_ext = if (gpa("eglCreatePlatformWindowSurfaceEXT")) |sym|
            @ptrCast(@alignCast(sym))
        else
            null,
        .query_string = query_string,
        .get_proc_address = get_proc_address,
        .terminate = lookup(h, "eglTerminate", PFNTerminate),
    };
    return &api.?;
}

pub fn get() ?*const Api {
    lock();
    defer unlock();
    return initLocked();
}

pub fn lookupRaw(name: [*:0]const u8) ?*anyopaque {
    lock();
    defer unlock();
    const h = openLocked() orelse return null;
    return dlfcn.dlsym(h, name);
}
