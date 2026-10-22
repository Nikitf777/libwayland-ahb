//! Exported entry points.
//!
//! Build this as libvkwl.so and load it under the name "libvulkan.so"
//! (a symlink is enough).  vulkaninfo's dlopen("libvulkan.so") then lands
//! here, and we forward to the platform loader.

const std = @import("std");
const vk = @import("vk.zig");
const wrapper = @import("wrapper.zig");
const bridge = @import("bridge.zig");
const native = @import("native.zig");

// A shared library must never pull in an unwinder/backtracer.  Besides being
// smaller, this keeps the shim free of platform-specific libc helpers.
pub const panic = std.debug.no_panic;

export fn vkGetInstanceProcAddr(instance: vk.VkInstance, pName: [*:0]const u8) callconv(.c) vk.PFN_vkVoidFunction {
    return wrapper.getInstanceProcAddr(instance, pName);
}

export fn vkGetDeviceProcAddr(device: vk.VkDevice, pName: [*:0]const u8) callconv(.c) vk.PFN_vkVoidFunction {
    return wrapper.getDeviceProcAddr(device, pName);
}

export fn vkCreateInstance(
    pCreateInfo: ?*const vk.VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: ?*vk.VkInstance,
) callconv(.c) vk.VkResult {
    return wrapper.createInstance(pCreateInfo, pAllocator, pInstance);
}

export fn vkEnumerateInstanceExtensionProperties(
    pLayerName: ?[*:0]const u8,
    pPropertyCount: ?*u32,
    pProperties: ?[*]vk.VkExtensionProperties,
) callconv(.c) vk.VkResult {
    return wrapper.enumerateInstanceExtensionProperties(pLayerName, pPropertyCount, pProperties);
}

export fn vkEnumerateInstanceLayerProperties(
    pPropertyCount: ?*u32,
    pProperties: ?[*]vk.VkLayerProperties,
) callconv(.c) vk.VkResult {
    return wrapper.enumerateInstanceLayerProperties(pPropertyCount, pProperties);
}

export fn vkEnumerateInstanceVersion(pApiVersion: ?*u32) callconv(.c) vk.VkResult {
    return wrapper.enumerateInstanceVersion(pApiVersion);
}

export fn vkCreateWaylandSurfaceKHR(
    instance: vk.VkInstance,
    pCreateInfo: ?*const vk.VkWaylandSurfaceCreateInfoKHR,
    pAllocator: ?*const anyopaque,
    pSurface: ?*vk.VkSurfaceKHR,
) callconv(.c) vk.VkResult {
    return wrapper.createWaylandSurfaceKHR(instance, pCreateInfo, pAllocator, pSurface);
}

export fn vkDestroySurfaceKHR(
    instance: vk.VkInstance,
    surface: vk.VkSurfaceKHR,
    pAllocator: ?*const anyopaque,
) callconv(.c) void {
    wrapper.destroySurfaceKHR(instance, surface, pAllocator);
}

export fn vkGetPhysicalDeviceWaylandPresentationSupportKHR(
    physicalDevice: vk.VkPhysicalDevice,
    queueFamilyIndex: u32,
    display: ?*anyopaque,
) callconv(.c) vk.VkBool32 {
    return wrapper.getPhysicalDeviceWaylandPresentationSupportKHR(physicalDevice, queueFamilyIndex, display);
}

/// Public hook for an in-process Wayland compositor / embedding toolkit.
///
/// The provider is called from vkCreateWaylandSurfaceKHR and must return an
/// ANativeWindow* that corresponds to the given wl_surface.
export fn vkwlSetWaylandWindowProvider(provider: ?bridge.WindowProvider) callconv(.c) void {
    bridge.setWindowProvider(provider);
    native.log("Wayland->ANativeWindow provider {s}", .{if (provider == null) "cleared" else "registered"});
}
