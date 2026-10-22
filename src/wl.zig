//! Minimal Wayland client bindings.
//!
//! We use `@cImport` for the Wayland headers because libwayland exposes most
//! of the protocol helpers as `static inline` functions.  Re-declaring them by
//! hand would mean duplicating the protocol ABI, which is exactly the kind of
//! thing that goes subtly wrong.
//!
//! `android_wlegl` is generated from `protocols/android_wlegl.xml` and lives in
//! `src/protocol/`.

const std = @import("std");

pub const c = @cImport({
    // Termux's bionic headers refuse unversioned Android targets.
    @cDefine("__ANDROID_MIN_SDK_VERSION__", "35");
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("wayland-egl-backend.h");
    @cInclude("protocol/android_wlegl_client.h");
});

pub const Display = c.wl_display;
pub const Surface = c.wl_surface;
pub const Buffer = c.wl_buffer;
pub const Callback = c.wl_callback;
pub const EventQueue = c.wl_event_queue;
pub const Registry = c.wl_registry;
pub const AndroidWlegl = c.android_wlegl;
pub const AndroidWleglHandle = c.android_wlegl_handle;
pub const EglWindow = c.wl_egl_window;

pub fn proxy(ptr: anytype) *c.wl_proxy {
    return @ptrCast(ptr);
}

pub fn createWrapper(ptr: anytype) ?*c.wl_proxy {
    const wrapped = c.wl_proxy_create_wrapper(@ptrCast(ptr)) orelse return null;
    return @ptrCast(wrapped);
}

pub fn setQueue(ptr: anytype, queue: *c.wl_event_queue) void {
    c.wl_proxy_set_queue(proxy(ptr), queue);
}

pub fn getVersion(ptr: anytype) u32 {
    return c.wl_proxy_get_version(proxy(ptr));
}
