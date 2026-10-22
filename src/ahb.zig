//! `AHardwareBuffer` bindings.
//!
//! The public NDK header exposes allocation/describe/release, but
//! `AHardwareBuffer_getNativeHandle` is hidden.  Both live in
//! `libnativewindow.so`, so we resolve everything with `dlopen`/`dlsym`
//! instead of adding a link-time dependency on a system library.

const std = @import("std");
const dlfcn = @import("dlfcn.zig");

pub const c = @cImport({
    @cDefine("__ANDROID_MIN_SDK_VERSION__", "35");
    @cInclude("android/hardware_buffer.h");
});

pub const HardwareBuffer = c.AHardwareBuffer;
pub const Desc = c.AHardwareBuffer_Desc;

pub const format_rgba8888 = c.AHARDWAREBUFFER_FORMAT_R8G8B8A8_UNORM;
pub const format_rgbx8888 = c.AHARDWAREBUFFER_FORMAT_R8G8B8X8_UNORM;
pub const format_rgb888 = c.AHARDWAREBUFFER_FORMAT_R8G8B8_UNORM;
pub const format_rgb565 = c.AHARDWAREBUFFER_FORMAT_R5G6B5_UNORM;
pub const format_rgba_f16 = c.AHARDWAREBUFFER_FORMAT_R16G16B16A16_FLOAT;
pub const format_rgb10a2 = c.AHARDWAREBUFFER_FORMAT_R10G10B10A2_UNORM;

pub const usage_gpu_sampled = c.AHARDWAREBUFFER_USAGE_GPU_SAMPLED_IMAGE;
pub const usage_gpu_framebuffer = c.AHARDWAREBUFFER_USAGE_GPU_FRAMEBUFFER;
pub const usage_cpu_write_often = c.AHARDWAREBUFFER_USAGE_CPU_WRITE_OFTEN;

/// The stable `native_handle_t` header.  The data array follows immediately:
/// `numFds` ints of file descriptors, then `numInts` payload ints.
pub const NativeHandle = extern struct {
    version: c_int,
    numFds: c_int,
    numInts: c_int,
};

pub fn handleData(handle: *const NativeHandle) [*]const c_int {
    return @ptrFromInt(@intFromPtr(handle) + @sizeOf(NativeHandle));
}

pub fn handleFd(handle: *const NativeHandle, index: usize) c_int {
    return handleData(handle)[index];
}

pub fn handleInts(handle: *const NativeHandle) [*]const c_int {
    return handleData(handle) + @as(usize, @intCast(handle.numFds));
}

pub fn handleIntBytes(handle: *const NativeHandle) []const u8 {
    const count = @as(usize, @intCast(handle.numInts));
    return @as([*]const u8, @ptrCast(handleInts(handle)))[0 .. count * @sizeOf(c_int)];
}

const AllocateFn = *const fn (*const Desc, *?*HardwareBuffer) callconv(.c) c_int;
const DescribeFn = *const fn (*const HardwareBuffer, *Desc) callconv(.c) void;
const AcquireFn = *const fn (*HardwareBuffer) callconv(.c) void;
const ReleaseFn = *const fn (*HardwareBuffer) callconv(.c) void;
const GetNativeHandleFn = *const fn (*const HardwareBuffer) callconv(.c) ?*const NativeHandle;
const IsSupportedFn = *const fn (*const Desc) callconv(.c) c_int;

const Api = struct {
    allocate: AllocateFn,
    describe: DescribeFn,
    acquire: AcquireFn,
    release: ReleaseFn,
    get_native_handle: GetNativeHandleFn,
    is_supported: ?IsSupportedFn,
};

var mutex: std.atomic.Mutex = .unlocked;
var api: ?Api = null;

fn lock() void {
    while (!mutex.tryLock()) std.atomic.spinLoopHint();
}

fn unlock() void {
    mutex.unlock();
}

fn loadSymbol(handle: ?*anyopaque, comptime name: [*:0]const u8, comptime T: type) ?T {
    const sym = dlfcn.dlsym(handle, name) orelse return null;
    return @ptrCast(@alignCast(sym));
}

fn initLocked() ?*const Api {
    if (api != null) return &api.?;

    const candidates = [_][*:0]const u8{
        "libnativewindow.so",
        if (@sizeOf(usize) == 8) "/system/lib64/libnativewindow.so" else "/system/lib/libnativewindow.so",
    };

    var lib: ?*anyopaque = null;
    for (candidates) |path| {
        lib = dlfcn.dlopen(path, dlfcn.RTLD_NOW | dlfcn.RTLD_LOCAL);
        if (lib != null) break;
    }
    const h = lib orelse {
        std.debug.print("[vkwl] cannot open libnativewindow.so: {s}\n", .{dlfcn.errorMessage()});
        return null;
    };

    const allocate_fn = loadSymbol(h, "AHardwareBuffer_allocate", AllocateFn) orelse return null;
    const describe_fn = loadSymbol(h, "AHardwareBuffer_describe", DescribeFn) orelse return null;
    const acquire_fn = loadSymbol(h, "AHardwareBuffer_acquire", AcquireFn) orelse return null;
    const release_fn = loadSymbol(h, "AHardwareBuffer_release", ReleaseFn) orelse return null;
    const get_native_handle_fn = loadSymbol(h, "AHardwareBuffer_getNativeHandle", GetNativeHandleFn) orelse return null;
    const is_supported_fn = loadSymbol(h, "AHardwareBuffer_isSupported", IsSupportedFn);

    api = .{
        .allocate = allocate_fn,
        .describe = describe_fn,
        .acquire = acquire_fn,
        .release = release_fn,
        .get_native_handle = get_native_handle_fn,
        .is_supported = is_supported_fn,
    };
    return &api.?;
}

pub fn getApi() ?*const Api {
    lock();
    defer unlock();
    return initLocked();
}

pub fn allocate(desc: *const Desc) ?*HardwareBuffer {
    const a = getApi() orelse return null;
    var out: ?*HardwareBuffer = null;
    const rc = a.allocate(desc, &out);
    if (rc != 0) return null;
    return out;
}

pub fn describe(buffer: *const HardwareBuffer, out: *Desc) void {
    const a = getApi() orelse return;
    a.describe(buffer, out);
}

pub fn acquire(buffer: *HardwareBuffer) void {
    const a = getApi() orelse return;
    a.acquire(buffer);
}

pub fn release(buffer: *HardwareBuffer) void {
    const a = getApi() orelse return;
    a.release(buffer);
}

pub fn getNativeHandle(buffer: *const HardwareBuffer) ?*const NativeHandle {
    const a = getApi() orelse return null;
    return a.get_native_handle(buffer);
}

pub fn isSupported(desc: *const Desc) bool {
    const a = getApi() orelse return true;
    if (a.is_supported) |f| return f(desc) != 0;
    return true;
}
