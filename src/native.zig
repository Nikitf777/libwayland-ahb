//! Locates and loads the *real* Vulkan loader.
//!
//! On Android the vendor ICDs (vulkan.adreno.so, etc.) can only be loaded by
//! the platform loader, which knows about the "sphal" linker namespace.  The
//! Termux/Khronos loader cannot dlopen them.  The wrapper therefore sits in
//! front of the platform loader instead of trying to replace the ICD.

const std = @import("std");
const builtin = @import("builtin");
const vk = @import("vk.zig");
const dlfcn = @import("dlfcn.zig");

pub const default_loader: [*:0]const u8 = if (builtin.target.ptrBitWidth() == 64)
    "/system/lib64/libvulkan.so"
else
    "/system/lib/libvulkan.so";

var mutex: std.atomic.Mutex = .unlocked;
var handle: ?*anyopaque = null;
var gipa: ?vk.PFN_vkGetInstanceProcAddr = null;
var gdpa: ?vk.PFN_vkGetDeviceProcAddr = null;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    mutex.unlock();
}

pub fn envZ(name: [*:0]const u8) ?[*:0]const u8 {
    return dlfcn.getenv(name);
}

pub fn log(comptime fmt: []const u8, args: anytype) void {
    if (envZ("VKWL_LOG") == null) return;
    std.debug.print("[vkwl] " ++ fmt ++ "\n", args);
}

/// Must be called with `mutex` held.
fn initLocked() void {
    if (gipa != null) return;

    const path = envZ("VKWL_NATIVE_LOADER") orelse default_loader;
    const h = dlfcn.dlopen(path, dlfcn.RTLD_NOW | dlfcn.RTLD_LOCAL) orelse {
        log("cannot open native loader '{s}': {s}", .{ path, dlfcn.errorMessage() });
        return;
    };

    const symbol = dlfcn.dlsym(h, "vkGetInstanceProcAddr") orelse {
        log("'{s}' has no vkGetInstanceProcAddr: {s}", .{ path, dlfcn.errorMessage() });
        return;
    };

    handle = h;
    gipa = @ptrCast(@alignCast(symbol));
    log("using native loader '{s}'", .{path});
}

pub fn getGipa() ?vk.PFN_vkGetInstanceProcAddr {
    lock();
    defer unlock();
    initLocked();
    return gipa;
}

/// The real `vkGetDeviceProcAddr`, captured from an instance.  The platform
/// loader does not necessarily expose a usable device-proc lookup through
/// `vkGetInstanceProcAddr(NULL, ...)`, but it does once an instance exists.
pub fn setGdpa(pfn: vk.PFN_vkGetDeviceProcAddr) void {
    lock();
    defer unlock();
    gdpa = pfn;
}

pub fn getGdpa() ?vk.PFN_vkGetDeviceProcAddr {
    lock();
    defer unlock();
    initLocked();
    return gdpa;
}

pub fn lookupRaw(name: [*:0]const u8) ?*anyopaque {
    lock();
    defer unlock();
    initLocked();
    const h = handle orelse return null;
    return dlfcn.dlsym(h, name);
}

/// Look up a symbol exported by the real loader (used for functions whose
/// prototype does not carry a VkInstance, e.g. physical-device queries).
pub fn lookup(comptime T: type, name: [*:0]const u8) ?T {
    const symbol = lookupRaw(name) orelse return null;
    return @ptrCast(@alignCast(symbol));
}
