//! Native-bionic Wayland EGL shim.
//!
//! Termux applications normally resolve `libEGL.so` to Mesa.  Mesa's Wayland
//! EGL platform needs a DRM render node (linux-dmabuf v4 feedback's
//! `main_device`, or legacy `wl_drm`), which Android/KGSL does not provide to
//! `untrusted_app`.  This shim instead loads the platform EGL implementation
//! (vendor Adreno) and translates the Wayland EGL surface to the same
//! client-side `ANativeWindow` + AHB + `android_wlegl` path used by the Vulkan
//! shim.
//!
//! Only the Wayland-platform entry points are intercepted.  Everything else
//! is exported as a direct-call forwarder generated from the platform libEGL.

const std = @import("std");
const egl_native = @import("egl_native.zig");
const ww = @import("wayland_window.zig");

pub const c = @cImport({
    @cDefine("__ANDROID_MIN_SDK_VERSION__", "35");
    @cDefine("WL_EGL_PLATFORM", "1");
    @cInclude("EGL/egl.h");
    @cInclude("EGL/eglext.h");
    @cInclude("wayland-client.h");
    @cInclude("wayland-egl.h");
    @cInclude("wayland-egl-backend.h");
});

const EGL_PLATFORM_WAYLAND: c.EGLenum = 0x31D8;
const EGL_PLATFORM_ANDROID: c.EGLenum = 0x3141;
const EGL_PLATFORM_SURFACELESS: c.EGLenum = 0x31DD;
const EGL_EXTENSIONS: c.EGLint = 0x3055;
const EGL_NONE: c.EGLint = 0x3038;

const allocator = std.heap.c_allocator;

var wayland_displays: std.AutoHashMapUnmanaged(usize, void) = .empty;
var wayland_display_mutex: std.atomic.Mutex = .unlocked;

fn displayLock() void {
    while (!wayland_display_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn displayUnlock() void {
    wayland_display_mutex.unlock();
}

fn displayKey(display: c.EGLDisplay) usize {
    if (display == null) return 0;
    return @intFromPtr(display);
}

fn markWaylandDisplay(display: c.EGLDisplay) void {
    if (display == null) return;
    displayLock();
    defer displayUnlock();
    wayland_displays.put(allocator, displayKey(display), {}) catch {};
}

fn isWaylandDisplay(display: c.EGLDisplay) bool {
    if (display == null) return false;
    displayLock();
    defer displayUnlock();
    return wayland_displays.contains(displayKey(display));
}

fn vendorDisplay() c.EGLDisplay {
    const api = egl_native.get() orelse return null;
    return @ptrCast(api.get_display(null));
}

fn vendorDisplayForPlatform(
    platform: c.EGLenum,
    native_display: ?*anyopaque,
    attribs: ?[*]const isize,
) c.EGLDisplay {
    const api = egl_native.get() orelse return null;

    if (platform == EGL_PLATFORM_ANDROID or platform == EGL_PLATFORM_SURFACELESS) {
        if (api.get_platform_display) |f| {
            if (f(platform, native_display, attribs)) |display| return @ptrCast(display);
        }
        // The Android vendor EGL may not implement the Mesa surfaceless
        // platform, but it does support surfaceless contexts on its normal
        // Android display.
        return vendorDisplay();
    }

    if (api.get_platform_display) |f| return @ptrCast(f(platform, native_display, attribs));
    return null;
}

fn vendorDisplayForPlatformExt(
    platform: c.EGLenum,
    native_display: ?*anyopaque,
    attribs: ?[*]const c.EGLint,
) c.EGLDisplay {
    const api = egl_native.get() orelse return null;

    if (api.get_platform_display_ext) |f| {
        if (f(platform, native_display, attribs)) |display| return @ptrCast(display);
    }

    // Fall back to the core entry point with a converted attribute list.
    var converted: [32]isize = undefined;
    const converted_ptr = convertAttribs(attribs, converted[0..]);
    return vendorDisplayForPlatform(platform, native_display, converted_ptr);
}

fn convertAttribs(
    attribs: ?[*]const c.EGLint,
    out: []isize,
) ?[*]const isize {
    const src = attribs orelse return null;
    if (out.len < 2) return null;

    var i: usize = 0;
    while (i + 1 < out.len) {
        out[i] = src[i];
        out[i + 1] = src[i + 1];
        if (src[i] == EGL_NONE) return out[0..i + 1].ptr;
        i += 2;
    }
    out[out.len - 1] = EGL_NONE;
    return out.ptr;
}

fn waylandWindowFor(
    dpy: c.EGLDisplay,
    config: c.EGLConfig,
    native_window: ?*anyopaque,
    attribs: ?[*]const c.EGLint,
) c.EGLSurface {
    const api = egl_native.get() orelse return null;
    const raw = native_window orelse return null;
    const ew: *c.wl_egl_window = @ptrCast(@alignCast(raw));
    if (ew.surface == null) return null;
    const surface: *c.wl_surface = @ptrCast(ew.surface);
    const wl_display: *c.wl_display = @ptrCast(c.wl_proxy_get_display(@ptrCast(surface)) orelse return null);

    const window = ww.WaylandNativeWindow.acquireEglWindow(
        @ptrCast(wl_display),
        @ptrCast(ew),
    ) orelse return null;
    return @ptrCast(api.create_window_surface(dpy, config, window.handle(), attribs));
}

// ---------------------------------------------------------------------------
// Intercepted entry points
// ---------------------------------------------------------------------------

export fn eglGetDisplay(display_id: c.EGLNativeDisplayType) callconv(.c) c.EGLDisplay {
    const display = vendorDisplay();
    // A non-null native display in a Wayland client is the wl_display.  The
    // vendor EGL display is still the Android platform display.
    if (display_id != null) markWaylandDisplay(display);
    egl_native.log("eglGetDisplay -> Android vendor display", .{});
    return display;
}

export fn eglGetPlatformDisplay(
    platform: c.EGLenum,
    native_display: ?*anyopaque,
    attrib_list: ?[*]const c.EGLAttrib,
) callconv(.c) c.EGLDisplay {
    if (platform == EGL_PLATFORM_WAYLAND) {
        const display = vendorDisplay();
        markWaylandDisplay(display);
        egl_native.log("eglGetPlatformDisplay(Wayland) -> Android vendor display", .{});
        return display;
    }
    return vendorDisplayForPlatform(platform, native_display, attrib_list);
}

export fn eglGetPlatformDisplayEXT(
    platform: c.EGLenum,
    native_display: ?*anyopaque,
    attrib_list: ?[*]const c.EGLint,
) callconv(.c) c.EGLDisplay {
    if (platform == EGL_PLATFORM_WAYLAND) {
        const display = vendorDisplay();
        markWaylandDisplay(display);
        egl_native.log("eglGetPlatformDisplayEXT(Wayland) -> Android vendor display", .{});
        return display;
    }
    return vendorDisplayForPlatformExt(platform, native_display, attrib_list);
}

export fn eglCreateWindowSurface(
    dpy: c.EGLDisplay,
    config: c.EGLConfig,
    win: c.EGLNativeWindowType,
    attrib_list: ?[*]const c.EGLint,
) callconv(.c) c.EGLSurface {
    const api = egl_native.get() orelse return null;
    if (isWaylandDisplay(dpy)) {
        return waylandWindowFor(dpy, config, @ptrCast(win), attrib_list);
    }
    return @ptrCast(api.create_window_surface(dpy, config, @ptrCast(win), attrib_list));
}

export fn eglCreatePlatformWindowSurface(
    dpy: c.EGLDisplay,
    config: c.EGLConfig,
    native_window: ?*anyopaque,
    attrib_list: ?[*]const c.EGLAttrib,
) callconv(.c) c.EGLSurface {
    const api = egl_native.get() orelse return null;
    if (isWaylandDisplay(dpy)) {
        var converted: [32]c.EGLint = undefined;
        const converted_ptr = convertAttribsToInt(attrib_list, converted[0..]);
        return waylandWindowFor(dpy, config, native_window, converted_ptr);
    }
    if (api.create_platform_window_surface) |f| {
        return @ptrCast(f(dpy, config, native_window, attrib_list));
    }
    var converted: [32]c.EGLint = undefined;
    const converted_ptr = convertAttribsToInt(attrib_list, converted[0..]);
    return @ptrCast(api.create_window_surface(dpy, config, native_window, converted_ptr));
}

export fn eglCreatePlatformWindowSurfaceEXT(
    dpy: c.EGLDisplay,
    config: c.EGLConfig,
    native_window: ?*anyopaque,
    attrib_list: ?[*]const c.EGLint,
) callconv(.c) c.EGLSurface {
    const api = egl_native.get() orelse return null;
    if (isWaylandDisplay(dpy)) {
        return waylandWindowFor(dpy, config, native_window, attrib_list);
    }
    if (api.create_platform_window_surface_ext) |f| {
        return @ptrCast(f(dpy, config, native_window, attrib_list));
    }
    return @ptrCast(api.create_window_surface(dpy, config, native_window, attrib_list));
}

fn convertAttribsToInt(
    attribs: ?[*]const c.EGLAttrib,
    out: []c.EGLint,
) ?[*]const c.EGLint {
    const src = attribs orelse return null;
    if (out.len < 2) return null;

    var i: usize = 0;
    while (i + 1 < out.len) {
        out[i] = @intCast(src[i]);
        out[i + 1] = @intCast(src[i + 1]);
        if (src[i] == EGL_NONE) return out[0..i + 1].ptr;
        i += 2;
    }
    out[out.len - 1] = EGL_NONE;
    return out.ptr;
}

// ---------------------------------------------------------------------------
// Extension string injection
// ---------------------------------------------------------------------------

var client_extensions: [8192]u8 = undefined;
var client_extensions_init: bool = false;
var client_extensions_mutex: std.atomic.Mutex = .unlocked;

fn clientExtensions(vendor: ?[*:0]const u8) ?[*:0]const u8 {
    while (!client_extensions_mutex.tryLock()) std.atomic.spinLoopHint();
    defer client_extensions_mutex.unlock();

    if (!client_extensions_init) {
        var end: usize = 0;
        if (vendor) |v| {
            const src = std.mem.span(v);
            const n = @min(src.len, client_extensions.len - 1);
            @memcpy(client_extensions[0..n], src[0..n]);
            end = n;
        }

        const extras = [_][]const u8{
            "EGL_EXT_platform_base",
            "EGL_EXT_platform_wayland",
            "EGL_KHR_platform_wayland",
        };
        for (extras) |extra| {
            const current = client_extensions[0..end];
            if (std.mem.indexOf(u8, current, extra) != null) continue;
            if (end + 1 + extra.len + 1 > client_extensions.len) break;
            client_extensions[end] = ' ';
            end += 1;
            @memcpy(client_extensions[end .. end + extra.len], extra);
            end += extra.len;
        }
        client_extensions[end] = 0;
        client_extensions_init = true;
    }

    return @ptrCast(&client_extensions);
}

export fn eglQueryString(
    dpy: c.EGLDisplay,
    name: c.EGLint,
) callconv(.c) ?[*:0]const u8 {
    const api = egl_native.get() orelse return null;
    const value = api.query_string(dpy, name);
    if (dpy == null and name == EGL_EXTENSIONS) return clientExtensions(value);
    return value;
}

// ---------------------------------------------------------------------------
// Proc lookup and forwarder binding
// ---------------------------------------------------------------------------

fn procNameEquals(name: []const u8, expected: []const u8) bool {
    return std.mem.eql(u8, name, expected);
}

export fn eglGetProcAddress(name: [*:0]const u8) callconv(.c) ?*anyopaque {
    const n = std.mem.span(name);
    if (procNameEquals(n, "eglGetDisplay")) return @ptrCast(@constCast(&eglGetDisplay));
    if (procNameEquals(n, "eglGetPlatformDisplay")) return @ptrCast(@constCast(&eglGetPlatformDisplay));
    if (procNameEquals(n, "eglGetPlatformDisplayEXT")) return @ptrCast(@constCast(&eglGetPlatformDisplayEXT));
    if (procNameEquals(n, "eglCreateWindowSurface")) return @ptrCast(@constCast(&eglCreateWindowSurface));
    if (procNameEquals(n, "eglCreatePlatformWindowSurface")) return @ptrCast(@constCast(&eglCreatePlatformWindowSurface));
    if (procNameEquals(n, "eglCreatePlatformWindowSurfaceEXT")) return @ptrCast(@constCast(&eglCreatePlatformWindowSurfaceEXT));
    if (procNameEquals(n, "eglQueryString")) return @ptrCast(@constCast(&eglQueryString));
    if (procNameEquals(n, "eglGetProcAddress")) return @ptrCast(@constCast(&eglGetProcAddress));

    const api = egl_native.get() orelse return null;
    return api.get_proc_address(name);
}

/// Binding entry point for the generated direct-call forwarders.
export fn vkwl_lookup_egl_native(name: [*:0]const u8) ?*anyopaque {
    return egl_native.lookupRaw(name);
}
