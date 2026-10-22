//! Loader-shim implementation of the wrapper.
//!
//! The shim exports the normal Vulkan loader entry points.  Calls are
//! forwarded to the platform loader, except for:
//!
//!   * vkEnumerateInstanceExtensionProperties: append VK_KHR_wayland_surface
//!   * vkCreateInstance: translate a request for wayland_surface into a
//!     request for android_surface
//!   * vkGetInstanceProcAddr: hand out the wayland entry points
//!   * vkCreateWaylandSurfaceKHR / vkGetPhysicalDeviceWaylandPresentationSupportKHR
//!   * vkGetPhysicalDeviceSurfaceCapabilitiesKHR: give the client a useful
//!     extent instead of the Android window's initial 1x1 size
//!   * vkCreateSwapchainKHR: resize the client-side Wayland window to the
//!     swapchain extent before the driver dequeues its first buffer

const std = @import("std");
const vk = @import("vk.zig");
const native = @import("native.zig");
const bridge = @import("bridge.zig");
const ww = @import("wayland_window.zig");

const allocator = std.heap.c_allocator;

const SurfaceEntry = struct {
    /// Non-null only for windows this shim created.  Provider-owned windows
    /// are left alone when the Vulkan surface is destroyed.
    window: ?*ww.WaylandNativeWindow = null,
};

var surface_map: std.AutoHashMapUnmanaged(usize, SurfaceEntry) = .empty;
var surface_map_mutex: std.atomic.Mutex = .unlocked;

fn mapLock() void {
    while (!surface_map_mutex.tryLock()) std.atomic.spinLoopHint();
}

fn mapUnlock() void {
    surface_map_mutex.unlock();
}

fn rememberSurface(surface: vk.VkSurfaceKHR, owned: ?*ww.WaylandNativeWindow) bool {
    const s = surface orelse return owned == null;
    mapLock();
    defer mapUnlock();
    surface_map.put(allocator, @intFromPtr(s), .{ .window = owned }) catch return false;
    return true;
}

fn forgetSurface(surface: vk.VkSurfaceKHR) ?SurfaceEntry {
    const s = surface orelse return null;
    mapLock();
    defer mapUnlock();
    const entry = surface_map.get(@intFromPtr(s));
    _ = surface_map.remove(@intFromPtr(s));
    return entry;
}

fn windowForSurface(surface: vk.VkSurfaceKHR) ?*ww.WaylandNativeWindow {
    const s = surface orelse return null;
    mapLock();
    defer mapUnlock();
    const entry = surface_map.get(@intFromPtr(s)) orelse return null;
    return entry.window;
}

fn envU32(name: [*:0]const u8, default: u32) u32 {
    const raw = native.envZ(name) orelse return default;
    return std.fmt.parseInt(u32, std.mem.span(raw), 10) catch default;
}

const undefined_extent: vk.VkExtent2D = .{
    .width = std.math.maxInt(u32),
    .height = std.math.maxInt(u32),
};

/// `VKWL_WIDTH`/`VKWL_HEIGHT` pin the surface to a fixed size.  Otherwise the
/// current extent tracks the Wayland window.  Reporting a defined extent is
/// important for clients such as vkcube: after a suboptimal present they
/// compare currentExtent with their swapchain size and recreate the swapchain
/// when it differs.  The undefined sentinel is always different and makes that
/// check loop forever.
fn envExtent() ?vk.VkExtent2D {
    if (native.envZ("VKWL_WIDTH") == null and native.envZ("VKWL_HEIGHT") == null) return null;
    const width = @max(1, @min(envU32("VKWL_WIDTH", 1280), 16384));
    const height = @max(1, @min(envU32("VKWL_HEIGHT", 720), 16384));
    return .{ .width = width, .height = height };
}

fn defaultWindowExtent() vk.VkExtent2D {
    return envExtent() orelse .{ .width = 1280, .height = 720 };
}

fn realDeviceProc(device: vk.VkDevice, name: [*:0]const u8) vk.PFN_vkVoidFunction {
    const gdpa = native.getGdpa() orelse
        global(vk.PFN_vkGetDeviceProcAddr, "vkGetDeviceProcAddr") orelse return null;
    return gdpa(device, name);
}

fn deviceProc(comptime T: type, device: vk.VkDevice, name: [*:0]const u8) ?T {
    const pfn = realDeviceProc(device, name) orelse return null;
    return @ptrCast(pfn);
}

fn destroyNativeSurface(
    instance: vk.VkInstance,
    surface: vk.VkSurfaceKHR,
    pAllocator: ?*const anyopaque,
) void {
    const gipa = native.getGipa() orelse return;
    const pfn = gipa(instance, "vkDestroySurfaceKHR") orelse return;
    const destroy: *const fn (vk.VkInstance, vk.VkSurfaceKHR, ?*const anyopaque) callconv(.c) void = @ptrCast(pfn);
    destroy(instance, surface, pAllocator);
}

fn global(comptime T: type, name: [*:0]const u8) ?T {
    const gipa = native.getGipa() orelse return null;
    const pfn = gipa(null, name) orelse return null;
    return @ptrCast(pfn);
}

pub fn getInstanceProcAddr(instance: vk.VkInstance, pName: [*:0]const u8) callconv(.c) vk.PFN_vkVoidFunction {
    const gipa = native.getGipa() orelse return null;
    const name = std.mem.span(pName);

    if (instance == null) {
        if (std.mem.eql(u8, name, "vkGetInstanceProcAddr")) return @ptrCast(&getInstanceProcAddr);
        if (std.mem.eql(u8, name, "vkCreateInstance")) return @ptrCast(&createInstance);
        if (std.mem.eql(u8, name, "vkEnumerateInstanceExtensionProperties")) return @ptrCast(&enumerateInstanceExtensionProperties);
        if (std.mem.eql(u8, name, "vkEnumerateInstanceLayerProperties")) return @ptrCast(&enumerateInstanceLayerProperties);
        if (std.mem.eql(u8, name, "vkEnumerateInstanceVersion")) return @ptrCast(&enumerateInstanceVersion);
        if (std.mem.eql(u8, name, "vkGetDeviceProcAddr")) return @ptrCast(&getDeviceProcAddr);
        return gipa(null, pName);
    }

    if (std.mem.eql(u8, name, "vkGetInstanceProcAddr")) return @ptrCast(&getInstanceProcAddr);
    if (std.mem.eql(u8, name, "vkGetDeviceProcAddr")) {
        if (gipa(instance, pName)) |pfn| native.setGdpa(@ptrCast(pfn));
        return @ptrCast(&getDeviceProcAddr);
    }
    if (std.mem.eql(u8, name, "vkCreateWaylandSurfaceKHR")) return @ptrCast(&createWaylandSurfaceKHR);
    if (std.mem.eql(u8, name, "vkDestroySurfaceKHR")) return @ptrCast(&destroySurfaceKHR);
    if (std.mem.eql(u8, name, "vkGetPhysicalDeviceWaylandPresentationSupportKHR")) return @ptrCast(&getPhysicalDeviceWaylandPresentationSupportKHR);
    if (std.mem.eql(u8, name, "vkGetPhysicalDeviceSurfaceCapabilitiesKHR")) return @ptrCast(&getPhysicalDeviceSurfaceCapabilitiesKHR);
    if (std.mem.eql(u8, name, "vkCreateSwapchainKHR")) return @ptrCast(&createSwapchainKHR);
    if (std.mem.eql(u8, name, "vkDestroySwapchainKHR")) return @ptrCast(&destroySwapchainKHR);

    return gipa(instance, pName);
}

const NativeCaps = struct {
    valid: bool = false,
    surface: bool = false,
    wayland: bool = false,
    android: bool = false,
};

/// Ask the native loader what it really supports.  This decides whether the
/// shim must translate Wayland to Android or can stay out of the way.
fn queryNativeCaps() NativeCaps {
    var caps = NativeCaps{};
    const real = global(vk.PFN_vkEnumerateInstanceExtensionProperties, "vkEnumerateInstanceExtensionProperties") orelse
        return caps;

    var count: u32 = 0;
    if (real(null, &count, null) != .success) return caps;
    if (count == 0 or count > 128) return caps;

    var props: [128]vk.VkExtensionProperties = undefined;
    var got = count;
    if (real(null, &got, props[0..].ptr) != .success) return caps;

    caps.valid = true;
    for (props[0..got]) |*ext| {
        if (vk.extNameEquals(ext, vk.extension_surface)) caps.surface = true;
        if (vk.extNameEquals(ext, vk.extension_wayland_surface)) caps.wayland = true;
        if (vk.extNameEquals(ext, vk.extension_android_surface)) caps.android = true;
    }
    native.log("native caps: count={d} surface={} wayland={} android={}", .{ got, caps.surface, caps.wayland, caps.android });
    return caps;
}

fn makeWaylandExtension() vk.VkExtensionProperties {
    var ext = vk.VkExtensionProperties{
        .extensionName = [_]u8{0} ** 256,
        .specVersion = vk.WAYLAND_SURFACE_SPEC_VERSION,
    };
    @memcpy(ext.extensionName[0..vk.extension_wayland_surface.len], vk.extension_wayland_surface);
    return ext;
}

pub fn enumerateInstanceExtensionProperties(
    pLayerName: ?[*:0]const u8,
    pPropertyCount: ?*u32,
    pProperties: ?[*]vk.VkExtensionProperties,
) callconv(.c) vk.VkResult {
    const real = global(vk.PFN_vkEnumerateInstanceExtensionProperties, "vkEnumerateInstanceExtensionProperties") orelse
        return .error_initialization_failed;

    // Layer-specific extension lists are not ours to touch.
    if (pLayerName != null) return real(pLayerName, pPropertyCount, pProperties);

    const count_ptr = pPropertyCount orelse return .error_initialization_failed;

    var native_count: u32 = 0;
    var res = real(null, &native_count, null);
    if (res != .success and res != .incomplete) return res;

    // Fixed scratch space: Vulkan loaders expose tens of extensions, not
    // thousands.  Avoid a heap allocator so the shim does not need libc.
    var scratch: [128]vk.VkExtensionProperties = undefined;
    if (native_count > scratch.len) {
        // Do not inject if the list is unexpectedly huge; just pass through.
        if (pProperties == null) {
            count_ptr.* = native_count;
            return .success;
        }
        var got = @min(count_ptr.*, native_count);
        res = real(null, &got, pProperties);
        count_ptr.* = got;
        return res;
    }

    if (native_count > 0) {
        var got: u32 = native_count;
        res = real(null, &got, scratch[0..].ptr);
        if (res != .success and res != .incomplete) return res;
        native_count = got;
    }

    var has_surface = false;
    var has_wayland = false;
    var has_android = false;
    for (scratch[0..native_count]) |*ext| {
        if (vk.extNameEquals(ext, vk.extension_surface)) has_surface = true;
        if (vk.extNameEquals(ext, vk.extension_wayland_surface)) has_wayland = true;
        if (vk.extNameEquals(ext, vk.extension_android_surface)) has_android = true;
    }

    // Don't advertise Wayland if the driver family doesn't provide the base
    // surface extension or the Android surface we would translate to, and
    // don't duplicate it if the loader already has it (e.g. when
    // VKWL_NATIVE_LOADER points at a Mesa-backed loader).
    const inject = has_surface and has_android and !has_wayland;
    const total = native_count + @intFromBool(inject);

    if (pProperties == null) {
        count_ptr.* = total;
        return .success;
    }

    const capacity = count_ptr.*;
    const copy_count = @min(capacity, native_count);
    if (copy_count > 0) {
        @memcpy(pProperties.?[0..copy_count], scratch[0..copy_count]);
    }

    var written: u32 = copy_count;
    if (inject and capacity > native_count) {
        pProperties.?[written] = makeWaylandExtension();
        written += 1;
    }

    count_ptr.* = written;
    return if (capacity < total) .incomplete else .success;
}

pub fn createInstance(
    pCreateInfo: ?*const vk.VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: ?*vk.VkInstance,
) callconv(.c) vk.VkResult {
    const real = global(vk.PFN_vkCreateInstance, "vkCreateInstance") orelse
        return .error_initialization_failed;

    const ci = pCreateInfo orelse return .error_initialization_failed;
    const names = ci.ppEnabledExtensionNames;

    var wants_wayland = false;
    if (names) |list| {
        for (0..ci.enabledExtensionCount) |i| {
            if (vk.nameEquals(list[i], vk.extension_wayland_surface)) {
                wants_wayland = true;
                break;
            }
        }
    }

    // Nothing to translate; keep the normal path allocation-free.
    if (!wants_wayland) return real(ci, pAllocator, pInstance);

    // If the driver already implements Wayland (Mesa, for example), or if it
    // has no Android surface to translate to, leave the create-info untouched.
    const caps = queryNativeCaps();
    if (caps.wayland or !caps.android) {
        if (caps.valid) {
            native.log("native driver handles wayland={} android={}; not translating", .{ caps.wayland, caps.android });
        }
        return real(ci, pAllocator, pInstance);
    }

    const list_in = names orelse return .error_initialization_failed;
    const alloc_count = @as(usize, ci.enabledExtensionCount) + 1;

    var list_out: [64][*:0]const u8 = undefined;
    if (alloc_count > list_out.len) {
        native.log("too many instance extensions ({d}); not translating", .{ci.enabledExtensionCount});
        return real(ci, pAllocator, pInstance);
    }

    var count: usize = 0;
    var has_android = false;
    for (0..ci.enabledExtensionCount) |i| {
        const name = list_in[i];
        if (vk.nameEquals(name, vk.extension_wayland_surface)) continue;
        if (vk.nameEquals(name, vk.extension_android_surface)) has_android = true;
        list_out[count] = name;
        count += 1;
    }
    if (!has_android) {
        list_out[count] = vk.extension_android_surface;
        count += 1;
    }

    var rewritten = ci.*;
    rewritten.enabledExtensionCount = @intCast(count);
    rewritten.ppEnabledExtensionNames = list_out[0..count].ptr;

    native.log("translating instance extensions: VK_KHR_wayland_surface -> VK_KHR_android_surface", .{});
    return real(&rewritten, pAllocator, pInstance);
}

pub fn enumerateInstanceLayerProperties(
    pPropertyCount: ?*u32,
    pProperties: ?[*]vk.VkLayerProperties,
) callconv(.c) vk.VkResult {
    const real = global(vk.PFN_vkEnumerateInstanceLayerProperties, "vkEnumerateInstanceLayerProperties") orelse
        return .error_initialization_failed;
    return real(pPropertyCount, pProperties);
}

pub fn enumerateInstanceVersion(pApiVersion: ?*u32) callconv(.c) vk.VkResult {
    const real = global(vk.PFN_vkEnumerateInstanceVersion, "vkEnumerateInstanceVersion") orelse
        return .error_initialization_failed;
    return real(pApiVersion);
}

pub fn getDeviceProcAddr(device: vk.VkDevice, pName: [*:0]const u8) callconv(.c) vk.PFN_vkVoidFunction {
    if (device == null) {
        const gipa = native.getGipa() orelse return null;
        return gipa(null, pName);
    }
    const name = std.mem.span(pName);
    if (std.mem.eql(u8, name, "vkCreateSwapchainKHR")) return @ptrCast(&createSwapchainKHR);
    if (std.mem.eql(u8, name, "vkDestroySwapchainKHR")) return @ptrCast(&destroySwapchainKHR);
    return realDeviceProc(device, pName);
}

pub fn createWaylandSurfaceKHR(
    instance: vk.VkInstance,
    pCreateInfo: ?*const vk.VkWaylandSurfaceCreateInfoKHR,
    pAllocator: ?*const anyopaque,
    pSurface: ?*vk.VkSurfaceKHR,
) callconv(.c) vk.VkResult {
    const gipa = native.getGipa() orelse return .error_initialization_failed;
    const ci = pCreateInfo orelse return .error_initialization_failed;
    const out = pSurface orelse return .error_initialization_failed;
    out.* = null;

    const pfn = gipa(instance, "vkCreateAndroidSurfaceKHR") orelse {
        native.log("native driver has no vkCreateAndroidSurfaceKHR", .{});
        return .error_extension_not_present;
    };
    const create_android: vk.PFN_vkCreateAndroidSurfaceKHR = @ptrCast(pfn);

    const acquired = bridge.acquireWindow(ci.display, ci.surface) orelse {
        native.log("cannot create an ANativeWindow for wl_surface {*}", .{ci.surface});
        return .error_initialization_failed;
    };

    // The Wayland create-info's pNext chain describes Wayland-specific
    // behaviour.  It is not safe to forward to the Android surface path.
    var android_info = vk.VkAndroidSurfaceCreateInfoKHR{
        .sType = .android_surface_create_info_khr,
        .pNext = null,
        .flags = ci.flags,
        .window = acquired.window,
    };

    native.log("creating Android surface from Wayland surface {*}", .{ci.surface});
    const res = create_android(instance, &android_info, pAllocator, out);
    if (res != .success) {
        bridge.releaseAcquired(acquired);
        return res;
    }

    if (!rememberSurface(out.*, acquired.owned)) {
        // The driver must not keep a surface that is not in our map: we would
        // not be able to release the client-side window on destruction.
        destroyNativeSurface(instance, out.*, pAllocator);
        out.* = null;
        bridge.releaseAcquired(acquired);
        return .error_out_of_host_memory;
    }

    return .success;
}

pub fn destroySurfaceKHR(
    instance: vk.VkInstance,
    surface: vk.VkSurfaceKHR,
    pAllocator: ?*const anyopaque,
) callconv(.c) void {
    const entry = forgetSurface(surface);
    destroyNativeSurface(instance, surface, pAllocator);
    if (entry) |e| {
        if (e.window) |window| window.release();
    }
}

pub fn getPhysicalDeviceSurfaceCapabilitiesKHR(
    physical_device: vk.VkPhysicalDevice,
    surface: vk.VkSurfaceKHR,
    pCaps: ?*vk.VkSurfaceCapabilitiesKHR,
) callconv(.c) vk.VkResult {
    const query = native.lookup(
        vk.PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR,
        "vkGetPhysicalDeviceSurfaceCapabilitiesKHR",
    ) orelse return .error_extension_not_present;

    const res = query(physical_device, surface, pCaps);
    if (res != .success) return res;

    const caps = pCaps orelse return res;
    const window = windowForSurface(surface);
    if (window == null) return res;

    // The Android WSI reports the window's initial 1x1 size.  Use the pinned
    // extent when requested, otherwise track the Wayland window size.  The
    // native driver still calls ANativeWindow.perform(SET_BUFFERS_DIMENSIONS)
    // with the swapchain size; a client that wants a different size must
    // resize its Wayland surface so the window follows it.
    if (envExtent()) |extent| {
        if (caps.currentExtent.width != extent.width or caps.currentExtent.height != extent.height) {
            caps.currentExtent = extent;
            if (caps.maxImageExtent.width < extent.width) caps.maxImageExtent.width = extent.width;
            if (caps.maxImageExtent.height < extent.height) caps.maxImageExtent.height = extent.height;
            window.?.resize(@intCast(extent.width), @intCast(extent.height));
            native.log("pinned surface extent: {d}x{d}", .{ extent.width, extent.height });
        }
    } else {
        if (window.?.width <= 1 or window.?.height <= 1) {
            const fallback = defaultWindowExtent();
            window.?.resize(@intCast(fallback.width), @intCast(fallback.height));
        }
        const extent: vk.VkExtent2D = .{
            .width = @intCast(window.?.width),
            .height = @intCast(window.?.height),
        };
        caps.currentExtent = extent;
        if (caps.minImageExtent.width > extent.width) caps.minImageExtent.width = extent.width;
        if (caps.minImageExtent.height > extent.height) caps.minImageExtent.height = extent.height;
        if (caps.maxImageExtent.width < extent.width) caps.maxImageExtent.width = extent.width;
        if (caps.maxImageExtent.height < extent.height) caps.maxImageExtent.height = extent.height;
        native.log("surface extent: {d}x{d}", .{ extent.width, extent.height });
    }
    return res;
}

pub fn createSwapchainKHR(
    device: vk.VkDevice,
    pCreateInfo: ?*const vk.VkSwapchainCreateInfoKHR,
    pAllocator: ?*const anyopaque,
    pSwapchain: ?*vk.VkSwapchainKHR,
) callconv(.c) vk.VkResult {
    const create: vk.PFN_vkCreateSwapchainKHR = deviceProc(vk.PFN_vkCreateSwapchainKHR, device, "vkCreateSwapchainKHR") orelse
        global(vk.PFN_vkCreateSwapchainKHR, "vkCreateSwapchainKHR") orelse
        return .error_extension_not_present;
    const ci = pCreateInfo orelse return .error_initialization_failed;

    var rewritten = ci.*;
    var tracked_window: ?*ww.WaylandNativeWindow = null;
    if (windowForSurface(rewritten.surface)) |window| {
        if (rewritten.imageExtent.width <= 1 or
            rewritten.imageExtent.height <= 1 or
            rewritten.imageExtent.width > 16384 or
            rewritten.imageExtent.height > 16384)
        {
            rewritten.imageExtent = defaultWindowExtent();
        }
        window.resize(@intCast(rewritten.imageExtent.width), @intCast(rewritten.imageExtent.height));
        window.beginSwapchainCreate();
        tracked_window = window;
        native.log("creating swapchain: {d}x{d} fmt=0x{x} present={d}", .{
            rewritten.imageExtent.width,
            rewritten.imageExtent.height,
            rewritten.imageFormat,
            rewritten.presentMode,
        });
    }
    const res = create(device, &rewritten, pAllocator, pSwapchain);
    if (tracked_window) |window| window.finishSwapchainCreate(res == .success);
    return res;
}

pub fn destroySwapchainKHR(
    device: vk.VkDevice,
    swapchain: vk.VkSwapchainKHR,
    pAllocator: ?*const anyopaque,
) callconv(.c) void {
    const destroy: vk.PFN_vkDestroySwapchainKHR = deviceProc(vk.PFN_vkDestroySwapchainKHR, device, "vkDestroySwapchainKHR") orelse
        global(vk.PFN_vkDestroySwapchainKHR, "vkDestroySwapchainKHR") orelse return;
    destroy(device, swapchain, pAllocator);
}

pub fn getPhysicalDeviceWaylandPresentationSupportKHR(
    physical_device: vk.VkPhysicalDevice,
    queue_family_index: u32,
    display: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    if (display == null) return 0;

    const get_props = native.lookup(
        vk.PFN_vkGetPhysicalDeviceQueueFamilyProperties,
        "vkGetPhysicalDeviceQueueFamilyProperties",
    ) orelse {
        native.log("cannot query queue families; assuming presentation is supported", .{});
        return 1;
    };

    var count: u32 = 0;
    get_props(physical_device, &count, null);
    if (count == 0 or count > 64) return 0;

    var props: [64]vk.VkQueueFamilyProperties = undefined;
    var got = count;
    get_props(physical_device, &got, props[0..].ptr);
    if (queue_family_index >= got) return 0;

    // There is no way to test a wl_display without a wl_surface.  The real
    // answer is available from vkGetPhysicalDeviceSurfaceSupportKHR once the
    // Android surface has been created, so only reject queues that cannot
    // possibly present.
    return if ((props[queue_family_index].queueFlags & vk.QUEUE_GRAPHICS_BIT) != 0) 1 else 0;
}
