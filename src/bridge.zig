//! The Wayland -> Android window bridge.
//!
//! The preferred path is client-side: this project creates an `ANativeWindow`
//! itself (`wayland_window.zig`) and exports its AHB-backed buffers through
//! `android_wlegl`.  That works for any normal Wayland client.
//!
//! A compositor or embedding toolkit can still override the mapping with
//! `vkwlSetWaylandWindowProvider`, or by exporting
//! `vkwl_wayland_to_android_window` with the same signature.  In that case the
//! returned window is provider-owned and is never destroyed by the shim.
//!
//! The provider hook is useful because a compositor may already have an
//! `ANativeWindow` that corresponds to its own surface, but it is not required.

const std = @import("std");
const native = @import("native.zig");
const dlfcn = @import("dlfcn.zig");
const wl = @import("wl.zig");
const ww = @import("wayland_window.zig");

pub const WindowProvider = *const fn (
    display: ?*anyopaque, // struct wl_display*
    surface: ?*anyopaque, // struct wl_surface*
) callconv(.c) ?*anyopaque; // struct ANativeWindow*

pub const AcquiredWindow = struct {
    window: *anyopaque,
    owned: ?*ww.WaylandNativeWindow = null,
};

var provider: ?WindowProvider = null;

pub fn setWindowProvider(p: ?WindowProvider) void {
    provider = p;
}

/// Resolve a Wayland surface to a window.  If `owned` is non-null, the caller
/// must call `releaseAcquired` when the Vulkan surface is destroyed.
pub fn acquireWindow(display: ?*anyopaque, surface: ?*anyopaque) ?AcquiredWindow {
    const display_ptr = display orelse return null;
    const surface_ptr = surface orelse return null;

    if (provider) |p| {
        if (p(display, surface)) |window| {
            return .{ .window = window };
        }
    }

    if (dlfcn.dlsym(dlfcn.default_handle, "vkwl_wayland_to_android_window")) |sym| {
        const f: WindowProvider = @ptrCast(@alignCast(sym));
        if (f(display, surface)) |window| {
            return .{ .window = window };
        }
    }

    const wl_display: *wl.Display = @ptrCast(@alignCast(display_ptr));
    const wl_surface: *wl.Surface = @ptrCast(@alignCast(surface_ptr));
    const window = ww.WaylandNativeWindow.create(wl_display, wl_surface) catch |err| {
        native.log("client-side Wayland window creation failed: {s}", .{@errorName(err)});
        return null;
    };

    return .{
        .window = @ptrCast(window.handle()),
        .owned = window,
    };
}

pub fn releaseAcquired(acquired: AcquiredWindow) void {
    if (acquired.owned) |window| window.release();
}
