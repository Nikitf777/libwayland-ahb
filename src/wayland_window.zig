//! Client-side `ANativeWindow` backed by Wayland + `android_wlegl`.
//!
//! The native Vulkan driver understands `VK_KHR_android_surface`, i.e. an
//! `ANativeWindow*` whose buffers are `AHardwareBuffer`s.  This file builds
//! exactly that object on top of a client-created `wl_surface`:
//!
//!   * `dequeueBuffer` allocates an AHB lazily and hands it to the driver;
//!   * `queueBuffer` exports the AHB through `android_wlegl` and attaches the
//!     resulting `wl_buffer`;
//!   * `wl_buffer.release` returns the buffer to the pool;
//!   * `wl_surface.frame` callbacks pace `queueBuffer` to the compositor's
//!     refresh, falling back to release/pool backpressure if they stop arriving.
//!
//! The driver only sees the embedded `ANativeWindow`.  Zig does not guarantee
//! that a regular struct keeps its fields in declaration order, so the reverse
//! mapping always goes through `@fieldParentPtr`; never cast the window pointer
//! back to `WaylandNativeWindow` directly.

const std = @import("std");
const wl = @import("wl.zig");
const c = wl.c;
const ahb = @import("ahb.zig");
const nw = @import("native_window.zig");
const native = @import("native.zig");
const dlfcn = @import("dlfcn.zig");

const allocator = std.heap.c_allocator;

// The C shim uses a fixed-argument ABI because the Adreno driver calls the
// variadic ANativeWindow.perform slot through a fixed prototype.  See
// native_window_shim.c for the details.
extern fn vkwl_native_window_perform(
    window: ?*anyopaque,
    operation: c_int,
    a1: u64,
    a2: u64,
    a3: u64,
    a4: u64,
    a5: u64,
    a6: u64,
) callconv(.c) c_int;

const EINVAL: c_int = 22;
const ENOMEM: c_int = 12;
const EPIPE: c_int = 32;

const max_buffers = 4;
const default_target_buffers = 3;
const frame_wait_timeout_ms: c_int = 200;

const BufferState = enum {
    free,
    dequeued,
    queued,
    fronted,
};

pub const Buffer = struct {
    // This is the object the driver receives.  Recover Buffer with
    // @fieldParentPtr; do not assume it is at offset zero.
    base: nw.ANativeWindowBuffer,
    window: *WaylandNativeWindow,
    ahb: *ahb.HardwareBuffer,
    wl_buffer: ?*c.wl_buffer = null,
    state: BufferState = .free,
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    alloc_width: i32 = 0,
    alloc_height: i32 = 0,
    alloc_format: i32 = 0,
    alloc_usage: u64 = 0,
};

pub const WaylandNativeWindow = struct {
    // This is the object the driver receives.  Recover the window with
    // @fieldParentPtr; do not assume it is at offset zero.
    base: nw.ANativeWindow,

    display: *c.wl_display,
    surface: *c.wl_surface,

    display_wrapper: ?*c.wl_display = null,
    surface_wrapper: ?*c.wl_surface = null,
    queue: ?*c.wl_event_queue = null,
    registry: ?*c.wl_registry = null,
    wlegl: ?*c.android_wlegl = null,

    egl_window: ?*c.wl_egl_window = null,

    mutex: std.c.pthread_mutex_t = .{},
    dispatch_mutex: std.c.pthread_mutex_t = .{},

    width: i32 = 1,
    height: i32 = 1,
    format: i32 = ahb.format_rgba8888,
    usage: u64 = ahb.usage_gpu_sampled | ahb.usage_gpu_framebuffer,
    data_space: i32 = 0,
    transform: i32 = 0,
    swap_interval: i32 = 1,
    target_buffer_count: usize = default_target_buffers,

    buffers: [max_buffers]?*Buffer = @splat(null),
    free_count: u32 = 0,
    youngest: ?*Buffer = null,

    pending: [max_buffers]?*Buffer = @splat(null),
    pending_len: usize = 0,
    fronted: [max_buffers]?*Buffer = @splat(null),
    fronted_len: usize = 0,

    frame_callback: ?*c.wl_callback = null,
    /// Cleared if the compositor does not answer a frame callback.  Keeping
    /// the flag avoids stalling every present on compositors without frame
    /// callbacks.
    frame_wait_supported: bool = true,
    refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),
    destroying: bool = false,

    pub fn create(display: *c.wl_display, surface: *c.wl_surface) !*WaylandNativeWindow {
        const self = try allocator.create(WaylandNativeWindow);
        self.* = .{
            .base = undefined,
            .display = display,
            .surface = surface,
        };
        errdefer self.destroyInternal();

        initBase(self);

        self.queue = c.wl_display_create_queue(display) orelse {
            native.log("wl_display_create_queue failed", .{});
            return error.NoEventQueue;
        };

        const display_wrapper_proxy = wl.createWrapper(display) orelse return error.NoDisplayWrapper;
        const display_wrapper: *c.wl_display = @ptrCast(display_wrapper_proxy);
        self.display_wrapper = display_wrapper;
        wl.setQueue(display_wrapper_proxy, self.queue.?);

        self.registry = c.wl_display_get_registry(display_wrapper) orelse return error.NoRegistry;
        wl.setQueue(self.registry.?, self.queue.?);
        _ = c.wl_registry_add_listener(self.registry.?, &registry_listener, self);

        const surface_wrapper_proxy = wl.createWrapper(surface) orelse return error.NoSurfaceWrapper;
        const surface_wrapper: *c.wl_surface = @ptrCast(surface_wrapper_proxy);
        self.surface_wrapper = surface_wrapper;
        wl.setQueue(surface_wrapper_proxy, self.queue.?);

        if (c.wl_display_roundtrip_queue(display, self.queue.?) < 0) {
            native.log("wl_display_roundtrip_queue failed: {d}", .{c.wl_display_get_error(display)});
            return error.ProtocolError;
        }
        if (self.wlegl == null) {
            native.log("compositor does not advertise android_wlegl", .{});
            return error.NoAndroidWlegl;
        }

        const ew_raw = c.wl_egl_window_create(surface, self.width, self.height);
        if (ew_raw == null) return error.NoEglWindow;
        const ew: *c.wl_egl_window = @ptrCast(ew_raw);
        self.egl_window = ew;
        ew.driver_private = self;
        ew.resize_callback = &eglResizeCallback;
        ew.destroy_window_callback = &eglDestroyCallback;

        native.log("client Wayland window created: {d}x{d} fmt=0x{x} usage=0x{x}", .{
            self.width,
            self.height,
            self.format,
            self.usage,
        });
        return self;
    }

    pub fn release(self: *WaylandNativeWindow) void {
        if (self.refcount.fetchSub(1, .acq_rel) == 1) self.destroyInternal();
    }

    pub fn handle(self: *WaylandNativeWindow) *nw.ANativeWindow {
        return &self.base;
    }

    /// Called by `wl_egl_window_resize` (or directly by the Vulkan swapchain
    /// wrapper).  Buffers are reallocated lazily on the next dequeue.
    pub fn resize(self: *WaylandNativeWindow, width: i32, height: i32) void {
        const w = @max(1, @min(width, 16384));
        const h = @max(1, @min(height, 16384));
        pthread_mutex_lock(&self.mutex);
        defer pthread_mutex_unlock(&self.mutex);

        if (self.width == w and self.height == h) return;
        self.width = w;
        self.height = h;
        if (self.egl_window) |ew| {
            ew.width = w;
            ew.height = h;
        }
        native.log("Wayland window resized to {d}x{d}", .{ w, h });
    }

    // ------------------------------------------------------------------
    // Buffer pool
    // ------------------------------------------------------------------

    fn ensureBuffersLocked(self: *WaylandNativeWindow) c_int {
        // Retire free buffers that no longer match the requested size/format.
        for (&self.buffers) |*slot| {
            const buf = slot.* orelse continue;
            if (buf.state != .free) continue;
            if (buf.alloc_width == self.width and
                buf.alloc_height == self.height and
                buf.alloc_format == self.format and
                buf.alloc_usage == self.usage)
            {
                continue;
            }
            slot.* = null;
            if (self.youngest == buf) self.youngest = null;
            if (self.free_count > 0) self.free_count -= 1;
            bufferDecRef(&buf.base.common);
        }

        var count: usize = 0;
        for (self.buffers) |slot| {
            if (slot != null) count += 1;
        }

        while (count < self.target_buffer_count) {
            const buf = self.createBufferLocked() orelse return -ENOMEM;
            var placed = false;
            for (&self.buffers) |*slot| {
                if (slot.* == null) {
                    slot.* = buf;
                    placed = true;
                    break;
                }
            }
            if (!placed) {
                bufferDecRef(&buf.base.common);
                break;
            }
            self.free_count += 1;
            count += 1;
        }

        return 0;
    }

    fn createBufferLocked(self: *WaylandNativeWindow) ?*Buffer {
        var desc = std.mem.zeroes(ahb.Desc);
        desc.width = @intCast(self.width);
        desc.height = @intCast(self.height);
        desc.layers = 1;
        desc.format = @intCast(self.format);
        desc.usage = self.usage;

        if (!ahb.isSupported(&desc)) {
            native.log("AHardwareBuffer_isSupported rejected {d}x{d} fmt=0x{x} usage=0x{x}", .{
                self.width,
                self.height,
                self.format,
                self.usage,
            });
            return null;
        }

        const ahb_buf = ahb.allocate(&desc) orelse {
            native.log("AHardwareBuffer_allocate failed for {d}x{d} fmt=0x{x} usage=0x{x}", .{
                self.width,
                self.height,
                self.format,
                self.usage,
            });
            return null;
        };

        var actual = std.mem.zeroes(ahb.Desc);
        ahb.describe(ahb_buf, &actual);
        const native_handle = ahb.getNativeHandle(ahb_buf) orelse {
            native.log("AHardwareBuffer has no native handle", .{});
            ahb.release(ahb_buf);
            return null;
        };

        const buf = allocator.create(Buffer) catch {
            ahb.release(ahb_buf);
            return null;
        };

        buf.* = .{
            .base = std.mem.zeroes(nw.ANativeWindowBuffer),
            .window = self,
            .ahb = ahb_buf,
            .alloc_width = self.width,
            .alloc_height = self.height,
            .alloc_format = self.format,
            .alloc_usage = self.usage,
        };
        buf.base.common.magic = nw.ANDROID_NATIVE_BUFFER_MAGIC;
        buf.base.common.version = @intCast(@sizeOf(nw.ANativeWindowBuffer));
        buf.base.common.incRef = &bufferIncRef;
        buf.base.common.decRef = &bufferDecRef;
        buf.base.width = @intCast(actual.width);
        buf.base.height = @intCast(actual.height);
        buf.base.stride = @intCast(actual.stride);
        buf.base.format = @bitCast(actual.format);
        buf.base.usage_deprecated = @bitCast(@as(u32, @truncate(actual.usage)));
        buf.base.layerCount = 1;
        buf.base.handle = native_handle;
        buf.base.usage = actual.usage;

        native.log("allocated AHB buffer: {d}x{d} stride={d} fmt=0x{x} usage=0x{x}", .{
            actual.width,
            actual.height,
            actual.stride,
            actual.format,
            actual.usage,
        });
        return buf;
    }

    fn pickFreeLocked(self: *WaylandNativeWindow) ?*Buffer {
        if (self.free_count == 0) return null;

        // Avoid immediately reusing the buffer the compositor just released;
        // with two or three buffers this gives the GPU a chance to finish.
        for (self.buffers) |slot| {
            const buf = slot orelse continue;
            if (buf.state != .free) continue;
            if (buf == self.youngest) continue;
            return buf;
        }
        for (self.buffers) |slot| {
            const buf = slot orelse continue;
            if (buf.state == .free) return buf;
        }
        return null;
    }

    fn removeFrontedLocked(self: *WaylandNativeWindow, target: *Buffer) void {
        var i: usize = 0;
        while (i < self.fronted_len) : (i += 1) {
            if (self.fronted[i] == target) {
                var j = i;
                while (j + 1 < self.fronted_len) : (j += 1) {
                    self.fronted[j] = self.fronted[j + 1];
                }
                self.fronted_len -= 1;
                self.fronted[self.fronted_len] = null;
                return;
            }
        }
    }

    fn pushPendingLocked(self: *WaylandNativeWindow, buf: *Buffer) bool {
        if (self.pending_len >= self.pending.len) return false;
        self.pending[self.pending_len] = buf;
        self.pending_len += 1;
        return true;
    }

    fn popPendingLocked(self: *WaylandNativeWindow) ?*Buffer {
        if (self.pending_len == 0) return null;
        const buf = self.pending[0].?;
        var i: usize = 0;
        while (i + 1 < self.pending_len) : (i += 1) {
            self.pending[i] = self.pending[i + 1];
        }
        self.pending_len -= 1;
        self.pending[self.pending_len] = null;
        return buf;
    }

    fn drainOneLocked(self: *WaylandNativeWindow) c_int {
        const buf = self.popPendingLocked() orelse return 0;
        const surface = self.surface_wrapper orelse return -EINVAL;
        const queue = self.queue orelse return -EINVAL;

        if (buf.wl_buffer == null) {
            buf.wl_buffer = createWleglBuffer(self, buf) orelse {
                native.log("android_wlegl buffer export failed", .{});
                buf.state = .free;
                self.free_count += 1;
                self.youngest = buf;
                return -ENOMEM;
            };
        }

        c.wl_surface_attach(surface, buf.wl_buffer.?, 0, 0);
        if (self.egl_window) |ew| {
            ew.attached_width = buf.base.width;
            ew.attached_height = buf.base.height;
        }

        if (wl.getVersion(surface) >= 4) {
            c.wl_surface_damage_buffer(surface, 0, 0, buf.base.width, buf.base.height);
        } else {
            c.wl_surface_damage(surface, 0, 0, buf.base.width, buf.base.height);
        }

        // Request the callback before the commit that schedules this frame.
        // The compositor answers it on its next vsync tick.
        if (self.swap_interval > 0 and self.frame_callback == null) {
            if (c.wl_surface_frame(surface)) |cb| {
                wl.setQueue(cb, queue);
                _ = c.wl_callback_add_listener(cb, &callback_listener, self);
                self.frame_callback = cb;
            }
        }

        c.wl_surface_commit(surface);

        buf.state = .fronted;
        if (self.fronted_len < self.fronted.len) {
            self.fronted[self.fronted_len] = buf;
            self.fronted_len += 1;
        }

        _ = c.wl_display_flush(self.display);
        return 0;
    }

    /// Wait for a specific frame callback, dispatching the private queue in
    /// bounded slices so a compositor that never answers cannot hang the
    /// present path forever.
    fn waitForFrame(self: *WaylandNativeWindow, cb: *c.wl_callback) c_int {
        while (true) {
            pthread_mutex_lock(&self.mutex);
            if (self.destroying) {
                pthread_mutex_unlock(&self.mutex);
                return -EPIPE;
            }
            if (!self.frame_wait_supported or self.frame_callback != cb) {
                pthread_mutex_unlock(&self.mutex);
                return 0;
            }
            pthread_mutex_unlock(&self.mutex);

            const rc = self.dispatchTimeout(frame_wait_timeout_ms);
            if (rc < 0) return -EPIPE;
            if (rc == 0) {
                pthread_mutex_lock(&self.mutex);
                if (self.frame_wait_supported and self.frame_callback == cb) {
                    self.frame_wait_supported = false;
                    native.log("no frame callback within {d} ms; disabling vsync wait", .{frame_wait_timeout_ms});
                }
                pthread_mutex_unlock(&self.mutex);
                return 0;
            }
        }
    }

    /// Dispatch the private queue, but return after `timeout_ms` if no event
    /// arrives.  Returns 1 after an event/dispatch attempt, 0 on timeout.
    fn dispatchTimeout(self: *WaylandNativeWindow, timeout_ms: c_int) c_int {
        const queue = self.queue orelse return -EINVAL;
        const display = self.display;
        pthread_mutex_lock(&self.dispatch_mutex);
        defer pthread_mutex_unlock(&self.dispatch_mutex);

        const prep = c.wl_display_prepare_read_queue(display, queue);
        if (prep != 0) {
            if (std.c.errno(prep) == .AGAIN) {
                const rc = c.wl_display_dispatch_queue_pending(display, queue);
                if (rc < 0) {
                    native.log("wl_display_dispatch_queue_pending failed: {d}", .{c.wl_display_get_error(display)});
                    return -EPIPE;
                }
                // Another thread currently owns the display read lock.  Give
                // it a moment rather than spinning.
                const pause = std.c.timespec{ .sec = 0, .nsec = 1_000_000 };
                _ = std.c.nanosleep(&pause, null);
                return 1;
            }
            native.log("wl_display_prepare_read_queue failed: {s}", .{@tagName(std.c.errno(prep))});
            return -EPIPE;
        }

        _ = c.wl_display_flush(display);

        var pfd = std.c.pollfd{
            .fd = c.wl_display_get_fd(display),
            .events = std.c.POLL.IN,
            .revents = 0,
        };
        const prc = std.c.poll(@ptrCast(&pfd), 1, timeout_ms);
        if (prc == 0) {
            c.wl_display_cancel_read(display);
            return 0;
        }
        if (prc < 0) {
            c.wl_display_cancel_read(display);
            if (std.c.errno(prc) == .INTR) return 1;
            native.log("poll on Wayland fd failed: {s}", .{@tagName(std.c.errno(prc))});
            return -EPIPE;
        }

        if (c.wl_display_read_events(display) < 0) {
            native.log("wl_display_read_events failed: {d}", .{c.wl_display_get_error(display)});
            return -EPIPE;
        }
        const rc = c.wl_display_dispatch_queue_pending(display, queue);
        if (rc < 0) {
            native.log("wl_display_dispatch_queue_pending failed: {d}", .{c.wl_display_get_error(display)});
            return -EPIPE;
        }
        return 1;
    }

    fn dispatchBlocking(self: *WaylandNativeWindow) c_int {
        const queue = self.queue orelse return -EINVAL;
        pthread_mutex_lock(&self.dispatch_mutex);
        defer pthread_mutex_unlock(&self.dispatch_mutex);

        const rc = c.wl_display_dispatch_queue(self.display, queue);
        if (rc < 0) {
            native.log("wl_display_dispatch_queue failed: {d}", .{c.wl_display_get_error(self.display)});
            return -EPIPE;
        }
        return rc;
    }

    fn destroyInternal(self: *WaylandNativeWindow) void {
        pthread_mutex_lock(&self.mutex);
        if (self.destroying) {
            pthread_mutex_unlock(&self.mutex);
            return;
        }
        self.destroying = true;
        pthread_mutex_unlock(&self.mutex);

        if (self.frame_callback) |cb| {
            self.frame_callback = null;
            c.wl_callback_destroy(cb);
        }

        for (&self.buffers) |*slot| {
            const buf = slot.* orelse continue;
            slot.* = null;
            if (buf.wl_buffer) |wb| {
                buf.wl_buffer = null;
                c.wl_buffer_destroy(wb);
            }
            bufferDecRef(&buf.base.common);
        }
        self.buffers = @splat(null);
        self.pending = @splat(null);
        self.fronted = @splat(null);
        self.pending_len = 0;
        self.fronted_len = 0;
        self.free_count = 0;
        self.youngest = null;

        if (self.egl_window) |ew| {
            self.egl_window = null;
            ew.driver_private = null;
            ew.resize_callback = null;
            ew.destroy_window_callback = null;
            c.wl_egl_window_destroy(@ptrCast(ew));
        }

        if (self.wlegl) |wlegl| {
            self.wlegl = null;
            c.android_wlegl_destroy(wlegl);
        }
        if (self.registry) |registry| {
            self.registry = null;
            c.wl_registry_destroy(registry);
        }
        if (self.surface_wrapper) |surface| {
            self.surface_wrapper = null;
            c.wl_proxy_wrapper_destroy(@ptrCast(surface));
        }
        if (self.display_wrapper) |display| {
            self.display_wrapper = null;
            c.wl_proxy_wrapper_destroy(@ptrCast(display));
        }
        if (self.queue) |queue| {
            self.queue = null;
            c.wl_event_queue_destroy(queue);
        }

        allocator.destroy(self);
    }
};

// ----------------------------------------------------------------------
// ANativeWindow vtable
// ----------------------------------------------------------------------

fn initBase(self: *WaylandNativeWindow) void {
    self.base = std.mem.zeroes(nw.ANativeWindow);
    self.base.common.magic = nw.ANDROID_NATIVE_WINDOW_MAGIC;
    self.base.common.version = @intCast(@sizeOf(nw.ANativeWindow));
    self.base.common.incRef = &windowIncRef;
    self.base.common.decRef = &windowDecRef;
    self.base.flags = 0;
    self.base.minSwapInterval = 0;
    self.base.maxSwapInterval = 1;
    self.base.setSwapInterval = &setSwapInterval;
    self.base.dequeueBuffer_DEPRECATED = &dequeueBufferDeprecated;
    self.base.queueBuffer_DEPRECATED = &queueBufferDeprecated;
    self.base.query = &query;
    self.base.perform = @ptrCast(&vkwl_native_window_perform);
    self.base.cancelBuffer_DEPRECATED = &cancelBufferDeprecated;
    self.base.dequeueBuffer = &dequeueBuffer;
    self.base.queueBuffer = &queueBuffer;
    self.base.cancelBuffer = &cancelBuffer;
}

fn windowFromBase(base: *nw.ANativeWindow) *WaylandNativeWindow {
    return @alignCast(@fieldParentPtr("base", base));
}

fn windowFromConst(base: *const nw.ANativeWindow) *WaylandNativeWindow {
    const mutable: *nw.ANativeWindow = @constCast(base);
    return @alignCast(@fieldParentPtr("base", mutable));
}

fn windowFromCommon(common: *nw.NativeBase) *WaylandNativeWindow {
    const native_window: *nw.ANativeWindow = @alignCast(@fieldParentPtr("common", common));
    return windowFromBase(native_window);
}

fn bufferFromBase(base: *nw.ANativeWindowBuffer) *Buffer {
    return @alignCast(@fieldParentPtr("base", base));
}

fn bufferFromCommon(common: *nw.NativeBase) *Buffer {
    const native_buffer: *nw.ANativeWindowBuffer = @alignCast(@fieldParentPtr("common", common));
    return bufferFromBase(native_buffer);
}

fn windowIncRef(base: *nw.NativeBase) callconv(.c) void {
    const self = windowFromCommon(base);
    _ = self.refcount.fetchAdd(1, .monotonic);
}

fn windowDecRef(base: *nw.NativeBase) callconv(.c) void {
    windowFromCommon(base).release();
}

fn bufferIncRef(base: *nw.NativeBase) callconv(.c) void {
    const buf = bufferFromCommon(base);
    _ = buf.refcount.fetchAdd(1, .monotonic);
}

fn bufferDecRef(base: *nw.NativeBase) callconv(.c) void {
    const buf = bufferFromCommon(base);
    if (buf.refcount.fetchSub(1, .acq_rel) == 1) {
        if (buf.wl_buffer) |wb| {
            buf.wl_buffer = null;
            c.wl_buffer_destroy(wb);
        }
        ahb.release(buf.ahb);
        allocator.destroy(buf);
    }
}

fn setSwapInterval(base: *nw.ANativeWindow, interval: c_int) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.swap_interval = @max(0, @min(interval, 1));
    return 0;
}

fn dequeueBuffer(
    base: *nw.ANativeWindow,
    out: *?*nw.ANativeWindowBuffer,
    fence: *c_int,
) callconv(.c) c_int {
    const self = windowFromBase(base);
    out.* = null;
    fence.* = -1;

    while (true) {
        pthread_mutex_lock(&self.mutex);
        if (self.destroying) {
            pthread_mutex_unlock(&self.mutex);
            return -EPIPE;
        }
        if (self.ensureBuffersLocked() != 0) {
            pthread_mutex_unlock(&self.mutex);
            return -ENOMEM;
        }
        if (self.pickFreeLocked()) |buf| {
            buf.state = .dequeued;
            if (self.free_count > 0) self.free_count -= 1;
            out.* = &buf.base;
            fence.* = -1;
            pthread_mutex_unlock(&self.mutex);
            return 0;
        }
        pthread_mutex_unlock(&self.mutex);

        if (self.dispatchBlocking() < 0) return -EPIPE;
    }
}

fn queueBuffer(
    base: *nw.ANativeWindow,
    buffer: *nw.ANativeWindowBuffer,
    fence: c_int,
) callconv(.c) c_int {
    const self = windowFromBase(base);
    const buf = bufferFromBase(buffer);
    if (buf.window != self) return -EINVAL;

    if (fence >= 0) {
        const rc = syncWait(fence);
        _ = close(fence);
        if (rc < 0) return -EPIPE;
    }

    pthread_mutex_lock(&self.mutex);
    if (self.destroying) {
        pthread_mutex_unlock(&self.mutex);
        return -EPIPE;
    }
    if (buf.state != .dequeued) {
        pthread_mutex_unlock(&self.mutex);
        return -EINVAL;
    }

    buf.state = .queued;
    if (!self.pushPendingLocked(buf)) {
        buf.state = .free;
        self.free_count += 1;
        self.youngest = buf;
        pthread_mutex_unlock(&self.mutex);
        return -EINVAL;
    }

    const rc = self.drainOneLocked();
    var wait_cb: ?*c.wl_callback = null;
    if (rc == 0 and self.swap_interval > 0 and self.frame_wait_supported) {
        wait_cb = self.frame_callback;
    }
    pthread_mutex_unlock(&self.mutex);

    // FIFO-like pacing: do not return the present until the compositor has
    // reached the next vsync.  `dequeueBuffer` still blocks for buffer
    // availability, but TAWC releases buffers promptly, so release events
    // alone are not enough to throttle an uncapped client.
    if (wait_cb) |cb| return self.waitForFrame(cb);
    return rc;
}

fn cancelBuffer(
    base: *nw.ANativeWindow,
    buffer: *nw.ANativeWindowBuffer,
    fence: c_int,
) callconv(.c) c_int {
    const self = windowFromBase(base);
    const buf = bufferFromBase(buffer);
    if (buf.window != self) return -EINVAL;

    if (fence >= 0) _ = close(fence);

    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    if (buf.state != .dequeued) return -EINVAL;
    buf.state = .free;
    self.free_count += 1;
    self.youngest = buf;
    return 0;
}

fn dequeueBufferDeprecated(
    base: *nw.ANativeWindow,
    out: *?*nw.ANativeWindowBuffer,
) callconv(.c) c_int {
    var fence: c_int = -1;
    return dequeueBuffer(base, out, &fence);
}

fn queueBufferDeprecated(
    base: *nw.ANativeWindow,
    buffer: *nw.ANativeWindowBuffer,
) callconv(.c) c_int {
    return queueBuffer(base, buffer, -1);
}

fn cancelBufferDeprecated(
    base: *nw.ANativeWindow,
    buffer: *nw.ANativeWindowBuffer,
) callconv(.c) c_int {
    return cancelBuffer(base, buffer, -1);
}

fn query(base: *const nw.ANativeWindow, what: c_int, out: *c_int) callconv(.c) c_int {
    const self = windowFromConst(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);

    switch (what) {
        nw.NATIVE_WINDOW_WIDTH, nw.NATIVE_WINDOW_DEFAULT_WIDTH => out.* = self.width,
        nw.NATIVE_WINDOW_HEIGHT, nw.NATIVE_WINDOW_DEFAULT_HEIGHT => out.* = self.height,
        nw.NATIVE_WINDOW_FORMAT => out.* = self.format,
        nw.NATIVE_WINDOW_MIN_UNDEQUEUED_BUFFERS => out.* = @intCast(if (self.target_buffer_count > 0) self.target_buffer_count - 1 else 0),
        nw.NATIVE_WINDOW_QUEUES_TO_WINDOW_COMPOSER => out.* = 0,
        nw.NATIVE_WINDOW_CONCRETE_TYPE => out.* = nw.NATIVE_WINDOW_SURFACE,
        nw.NATIVE_WINDOW_TRANSFORM_HINT => out.* = 0,
        nw.NATIVE_WINDOW_CONSUMER_RUNNING_BEHIND => out.* = 0,
        nw.NATIVE_WINDOW_CONSUMER_USAGE_BITS => out.* = @bitCast(@as(u32, @truncate(self.usage))),
        nw.NATIVE_WINDOW_STICKY_TRANSFORM => out.* = 0,
        nw.NATIVE_WINDOW_DEFAULT_DATASPACE, nw.NATIVE_WINDOW_DATASPACE => out.* = self.data_space,
        nw.NATIVE_WINDOW_BUFFER_AGE => out.* = 0,
        nw.NATIVE_WINDOW_IS_VALID => out.* = 1,
        nw.NATIVE_WINDOW_MAX_BUFFER_COUNT => out.* = max_buffers,
        else => return -EINVAL,
    }
    return 0;
}

export fn vkwl_perform_usage(base: *nw.ANativeWindow, usage: u64) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.usage = usage | ahb.usage_gpu_sampled | ahb.usage_gpu_framebuffer;
    return 0;
}

export fn vkwl_perform_dimensions(base: *nw.ANativeWindow, width: c_int, height: c_int) callconv(.c) c_int {
    windowFromBase(base).resize(width, height);
    return 0;
}

export fn vkwl_perform_format(base: *nw.ANativeWindow, format: c_int) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.format = format;
    return 0;
}

export fn vkwl_perform_buffer_count(base: *nw.ANativeWindow, count: usize) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.target_buffer_count = @max(2, @min(count, max_buffers));
    return 0;
}

export fn vkwl_perform_geometry(
    base: *nw.ANativeWindow,
    width: c_int,
    height: c_int,
    format: c_int,
) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.width = @max(1, @min(width, 16384));
    self.height = @max(1, @min(height, 16384));
    self.format = format;
    if (self.egl_window) |ew| {
        ew.width = self.width;
        ew.height = self.height;
    }
    return 0;
}

export fn vkwl_perform_transform(base: *nw.ANativeWindow, transform: c_int) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.transform = transform;
    return 0;
}

export fn vkwl_perform_dataspace(base: *nw.ANativeWindow, dataspace: c_int) callconv(.c) c_int {
    const self = windowFromBase(base);
    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);
    self.data_space = dataspace;
    return 0;
}

export fn vkwl_perform_ignore(base: *nw.ANativeWindow, operation: c_int) callconv(.c) c_int {
    _ = base;
    _ = operation;
    return 0;
}

// ----------------------------------------------------------------------
// Wayland listeners
// ----------------------------------------------------------------------

const registry_listener = c.wl_registry_listener{
    .global = &onRegistryGlobal,
    .global_remove = &onRegistryGlobalRemove,
};

const buffer_listener = c.wl_buffer_listener{
    .release = &onBufferRelease,
};

const callback_listener = c.wl_callback_listener{
    .done = &onFrameDone,
};

fn onRegistryGlobal(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
    interface: ?[*:0]const u8,
    version: u32,
) callconv(.c) void {
    const self: *WaylandNativeWindow = @ptrCast(@alignCast(data orelse return));
    const reg = registry orelse return;
    const iface = interface orelse return;
    if (self.wlegl != null) return;
    if (!std.mem.eql(u8, std.mem.span(iface), "android_wlegl")) return;

    const bind_version = @max(1, @min(version, 2));
    const proxy = c.wl_registry_bind(reg, name, &c.android_wlegl_interface, bind_version) orelse return;
    self.wlegl = @ptrCast(proxy);
    if (self.queue) |queue| wl.setQueue(proxy, queue);
    native.log("bound android_wlegl v{d}", .{bind_version});
}

fn onRegistryGlobalRemove(
    data: ?*anyopaque,
    registry: ?*c.wl_registry,
    name: u32,
) callconv(.c) void {
    _ = data;
    _ = registry;
    _ = name;
}

fn onBufferRelease(data: ?*anyopaque, buffer: ?*c.wl_buffer) callconv(.c) void {
    const self: *WaylandNativeWindow = @ptrCast(@alignCast(data orelse return));
    const wl_buffer = buffer orelse return;

    pthread_mutex_lock(&self.mutex);
    defer pthread_mutex_unlock(&self.mutex);

    for (self.buffers) |slot| {
        const buf = slot orelse continue;
        if (buf.wl_buffer == wl_buffer) {
            self.removeFrontedLocked(buf);
            if (buf.state == .fronted) {
                buf.state = .free;
                self.free_count += 1;
                self.youngest = buf;
            }
            return;
        }
    }
}

fn onFrameDone(data: ?*anyopaque, callback: ?*c.wl_callback, time: u32) callconv(.c) void {
    _ = time;
    const self: *WaylandNativeWindow = @ptrCast(@alignCast(data orelse return));
    const cb = callback orelse return;

    pthread_mutex_lock(&self.mutex);
    if (self.frame_callback == cb) self.frame_callback = null;
    pthread_mutex_unlock(&self.mutex);

    c.wl_callback_destroy(cb);
}

fn eglResizeCallback(egl_window: [*c]c.wl_egl_window, data: ?*anyopaque) callconv(.c) void {
    _ = data;
    if (egl_window == null) return;
    const ew: *c.wl_egl_window = @ptrCast(egl_window);
    const self: *WaylandNativeWindow = @ptrCast(@alignCast(ew.driver_private orelse return));
    self.resize(ew.width, ew.height);
}

fn eglDestroyCallback(data: ?*anyopaque) callconv(.c) void {
    const self: *WaylandNativeWindow = @ptrCast(@alignCast(data orelse return));
    pthread_mutex_lock(&self.mutex);
    self.egl_window = null;
    pthread_mutex_unlock(&self.mutex);
}

fn createWleglBuffer(self: *WaylandNativeWindow, buf: *Buffer) ?*c.wl_buffer {
    const wlegl = self.wlegl orelse return null;
    const queue = self.queue orelse return null;
    const native_handle = ahb.getNativeHandle(buf.ahb) orelse return null;
    if (native_handle.numFds < 0 or native_handle.numInts < 0) return null;

    const fd_count: usize = @intCast(native_handle.numFds);
    const int_bytes = ahb.handleIntBytes(native_handle);

    var ints: c.wl_array = undefined;
    c.wl_array_init(&ints);
    defer c.wl_array_release(&ints);
    if (int_bytes.len > 0) {
        const dst = c.wl_array_add(&ints, int_bytes.len) orelse return null;
        @memcpy(@as([*]u8, @ptrCast(dst))[0..int_bytes.len], int_bytes);
    }

    const wlegl_wrapper = wl.createWrapper(wlegl) orelse return null;
    defer c.wl_proxy_wrapper_destroy(@ptrCast(wlegl_wrapper));
    c.wl_proxy_set_queue(wlegl_wrapper, queue);

    const wlegl_handle = c.android_wlegl_create_handle(
        @ptrCast(wlegl_wrapper),
        @intCast(fd_count),
        &ints,
    ) orelse return null;
    defer c.android_wlegl_handle_destroy(wlegl_handle);

    for (0..fd_count) |i| {
        c.android_wlegl_handle_add_fd(wlegl_handle, ahb.handleFd(native_handle, i));
    }

    const usage: c_int = @bitCast(@as(u32, @truncate(buf.base.usage)));
    const wl_buffer = c.android_wlegl_create_buffer(
        @ptrCast(wlegl_wrapper),
        buf.base.width,
        buf.base.height,
        buf.base.stride,
        buf.base.format,
        usage,
        wlegl_handle,
    ) orelse return null;
    c.wl_proxy_set_queue(@ptrCast(wl_buffer), queue);

    if (c.wl_buffer_add_listener(wl_buffer, &buffer_listener, self) < 0) {
        c.wl_buffer_destroy(wl_buffer);
        return null;
    }
    return wl_buffer;
}

// ----------------------------------------------------------------------
// Sync fences
// ----------------------------------------------------------------------

extern fn close(fd: c_int) c_int;

const SyncWaitFn = *const fn (c_int, c_int) callconv(.c) c_int;

var sync_mutex: std.atomic.Mutex = .unlocked;
var sync_loaded = false;
var sync_wait_fn: ?SyncWaitFn = null;

fn loadSyncWait() ?SyncWaitFn {
    while (!sync_mutex.tryLock()) std.atomic.spinLoopHint();
    defer sync_mutex.unlock();
    if (sync_loaded) return sync_wait_fn;
    sync_loaded = true;

    const candidates = [_][*:0]const u8{
        "libsync.so",
        if (@sizeOf(usize) == 8) "/system/lib64/libsync.so" else "/system/lib/libsync.so",
    };
    for (candidates) |path| {
        const h = dlfcn.dlopen(path, dlfcn.RTLD_NOW | dlfcn.RTLD_LOCAL) orelse continue;
        if (dlfcn.dlsym(h, "sync_wait")) |sym| {
            sync_wait_fn = @ptrCast(@alignCast(sym));
            return sync_wait_fn;
        }
    }
    native.log("sync_wait unavailable; falling back to poll()", .{});
    return null;
}

fn syncWait(fd: c_int) c_int {
    if (loadSyncWait()) |f| return f(fd, -1);

    var pfd = std.c.pollfd{
        .fd = fd,
        .events = std.c.POLL.IN,
        .revents = 0,
    };
    while (true) {
        const rc = std.c.poll(@ptrCast(&pfd), 1, -1);
        if (rc > 0) return 0;
        if (rc == 0) return -1;
        if (std.c.errno(rc) == .INTR) continue;
        return -1;
    }
}

fn pthread_mutex_lock(m: *std.c.pthread_mutex_t) void {
    _ = std.c.pthread_mutex_lock(m);
}

fn pthread_mutex_unlock(m: *std.c.pthread_mutex_t) void {
    _ = std.c.pthread_mutex_unlock(m);
}
