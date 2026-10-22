//! Minimal Vulkan ABI definitions.
//!
//! This is deliberately *not* a full Vulkan header binding.  A loader shim
//! only has to understand the small set of structures that cross the boundary
//! it rewrites.  Everything else is passed through untouched, so keeping the
//! ABI surface small also keeps the wrapper small and easy to audit.
//!
//! All layouts here must match the C definitions in <vulkan/vulkan_core.h>
//! (and <vulkan/vulkan_android.h> / <vulkan/vulkan_wayland.h>).

const std = @import("std");

pub const VkBool32 = u32;
pub const VkFlags = u32;
pub const VkInstanceCreateFlags = u32;
pub const VkSurfaceCreateFlagsKHR = u32;

/// Opaque, non-dispatchable handles.  We never dereference them.
pub const VkInstance = ?*anyopaque;
pub const VkPhysicalDevice = ?*anyopaque;
pub const VkDevice = ?*anyopaque;
pub const VkSurfaceKHR = ?*anyopaque;
pub const VkSwapchainKHR = ?*anyopaque;
pub const VkImage = ?*anyopaque;
pub const VkFormat = i32;
pub const VkColorSpaceKHR = i32;
pub const VkPresentModeKHR = i32;
pub const VkSharingMode = i32;
pub const VkImageUsageFlags = u32;
pub const VkSurfaceTransformFlagsKHR = u32;
pub const VkCompositeAlphaFlagsKHR = u32;
pub const VkSwapchainCreateFlagsKHR = u32;

/// PFN_vkVoidFunction
pub const PFN_vkVoidFunction = ?*const fn () callconv(.c) void;

pub const VkResult = enum(i32) {
    success = 0,
    not_ready = 1,
    timeout = 2,
    event_set = 3,
    event_reset = 4,
    incomplete = 5,

    error_out_of_host_memory = -1,
    error_out_of_device_memory = -2,
    error_initialization_failed = -3,
    error_device_lost = -4,
    error_memory_map_failed = -5,
    error_layer_not_present = -6,
    error_extension_not_present = -7,
    error_feature_not_present = -8,
    error_incompatible_driver = -9,
    error_too_many_objects = -10,
    error_format_not_supported = -11,
    error_fragmented_pool = -12,
    error_unknown = -13,

    error_surface_lost_khr = -1000000000,
    error_native_window_in_use_khr = -1000000001,
    error_out_of_date_khr = -1000001004,
    error_validation_failed = -1000011001,
};

pub const VkStructureType = enum(i32) {
    application_info = 0,
    instance_create_info = 1,
    wayland_surface_create_info_khr = 1000006000,
    android_surface_create_info_khr = 1000008000,
    swapchain_create_info_khr = 1000001000,
};

pub const VkQueueFlags = u32;
pub const QUEUE_GRAPHICS_BIT: VkQueueFlags = 0x00000001;

pub const VkExtensionProperties = extern struct {
    extensionName: [256]u8,
    specVersion: u32,
};

pub const VkLayerProperties = extern struct {
    layerName: [256]u8,
    specVersion: u32,
    implementationVersion: u32,
    description: [256]u8,
};

pub const VkApplicationInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    pApplicationName: ?[*:0]const u8,
    applicationVersion: u32,
    pEngineName: ?[*:0]const u8,
    engineVersion: u32,
    apiVersion: u32,
};

pub const VkInstanceCreateInfo = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkInstanceCreateFlags,
    pApplicationInfo: ?*const VkApplicationInfo,
    enabledLayerCount: u32,
    ppEnabledLayerNames: ?[*]const [*:0]const u8,
    enabledExtensionCount: u32,
    ppEnabledExtensionNames: ?[*]const [*:0]const u8,
};

pub const VkWaylandSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkSurfaceCreateFlagsKHR,
    display: ?*anyopaque, // struct wl_display*
    surface: ?*anyopaque, // struct wl_surface*
};

pub const VkAndroidSurfaceCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkSurfaceCreateFlagsKHR,
    window: ?*anyopaque, // struct ANativeWindow*
};

pub const VkExtent2D = extern struct {
    width: u32,
    height: u32,
};

pub const VkExtent3D = extern struct {
    width: u32,
    height: u32,
    depth: u32,
};

pub const VkSurfaceCapabilitiesKHR = extern struct {
    minImageCount: u32,
    maxImageCount: u32,
    currentExtent: VkExtent2D,
    minImageExtent: VkExtent2D,
    maxImageExtent: VkExtent2D,
    maxImageArrayLayers: u32,
    supportedTransforms: VkSurfaceTransformFlagsKHR,
    currentTransform: u32,
    supportedCompositeAlpha: VkCompositeAlphaFlagsKHR,
    supportedUsageFlags: VkImageUsageFlags,
};

pub const VkSurfaceFormatKHR = extern struct {
    format: VkFormat,
    colorSpace: VkColorSpaceKHR,
};

pub const VkSwapchainCreateInfoKHR = extern struct {
    sType: VkStructureType,
    pNext: ?*const anyopaque,
    flags: VkSwapchainCreateFlagsKHR,
    surface: VkSurfaceKHR,
    minImageCount: u32,
    imageFormat: VkFormat,
    imageColorSpace: VkColorSpaceKHR,
    imageExtent: VkExtent2D,
    imageArrayLayers: u32,
    imageUsage: VkImageUsageFlags,
    imageSharingMode: VkSharingMode,
    queueFamilyIndexCount: u32,
    pQueueFamilyIndices: ?[*]const u32,
    preTransform: u32,
    compositeAlpha: u32,
    presentMode: VkPresentModeKHR,
    clipped: VkBool32,
    oldSwapchain: VkSwapchainKHR,
};

pub const VkQueueFamilyProperties = extern struct {
    queueFlags: VkQueueFlags,
    queueCount: u32,
    timestampValidBits: u32,
    minImageTransferGranularity: VkExtent3D,
};

// Entry point prototypes (only the ones we actually call or export).
pub const PFN_vkGetInstanceProcAddr = *const fn (
    instance: VkInstance,
    pName: [*:0]const u8,
) callconv(.c) PFN_vkVoidFunction;

pub const PFN_vkCreateInstance = *const fn (
    pCreateInfo: ?*const VkInstanceCreateInfo,
    pAllocator: ?*const anyopaque,
    pInstance: ?*VkInstance,
) callconv(.c) VkResult;

pub const PFN_vkEnumerateInstanceExtensionProperties = *const fn (
    pLayerName: ?[*:0]const u8,
    pPropertyCount: ?*u32,
    pProperties: ?[*]VkExtensionProperties,
) callconv(.c) VkResult;

pub const PFN_vkEnumerateInstanceLayerProperties = *const fn (
    pPropertyCount: ?*u32,
    pProperties: ?[*]VkLayerProperties,
) callconv(.c) VkResult;

pub const PFN_vkEnumerateInstanceVersion = *const fn (
    pApiVersion: ?*u32,
) callconv(.c) VkResult;

pub const PFN_vkGetDeviceProcAddr = *const fn (
    device: VkDevice,
    pName: [*:0]const u8,
) callconv(.c) PFN_vkVoidFunction;

pub const PFN_vkCreateWaylandSurfaceKHR = *const fn (
    instance: VkInstance,
    pCreateInfo: ?*const VkWaylandSurfaceCreateInfoKHR,
    pAllocator: ?*const anyopaque,
    pSurface: ?*VkSurfaceKHR,
) callconv(.c) VkResult;

pub const PFN_vkGetPhysicalDeviceWaylandPresentationSupportKHR = *const fn (
    physicalDevice: VkPhysicalDevice,
    queueFamilyIndex: u32,
    display: ?*anyopaque,
) callconv(.c) VkBool32;

pub const PFN_vkCreateAndroidSurfaceKHR = *const fn (
    instance: VkInstance,
    pCreateInfo: ?*const VkAndroidSurfaceCreateInfoKHR,
    pAllocator: ?*const anyopaque,
    pSurface: ?*VkSurfaceKHR,
) callconv(.c) VkResult;

pub const PFN_vkGetPhysicalDeviceSurfaceCapabilitiesKHR = *const fn (
    physicalDevice: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    pSurfaceCapabilities: ?*VkSurfaceCapabilitiesKHR,
) callconv(.c) VkResult;

pub const PFN_vkGetPhysicalDeviceSurfaceFormatsKHR = *const fn (
    physicalDevice: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    pSurfaceFormatCount: ?*u32,
    pSurfaceFormats: ?[*]VkSurfaceFormatKHR,
) callconv(.c) VkResult;

pub const PFN_vkGetPhysicalDeviceSurfacePresentModesKHR = *const fn (
    physicalDevice: VkPhysicalDevice,
    surface: VkSurfaceKHR,
    pPresentModeCount: ?*u32,
    pPresentModes: ?[*]VkPresentModeKHR,
) callconv(.c) VkResult;

pub const PFN_vkCreateSwapchainKHR = *const fn (
    device: VkDevice,
    pCreateInfo: ?*const VkSwapchainCreateInfoKHR,
    pAllocator: ?*const anyopaque,
    pSwapchain: ?*VkSwapchainKHR,
) callconv(.c) VkResult;

pub const PFN_vkDestroySwapchainKHR = *const fn (
    device: VkDevice,
    swapchain: VkSwapchainKHR,
    pAllocator: ?*const anyopaque,
) callconv(.c) void;

pub const PFN_vkGetPhysicalDeviceQueueFamilyProperties = *const fn (
    physicalDevice: VkPhysicalDevice,
    pQueueFamilyPropertyCount: ?*u32,
    pQueueFamilyProperties: ?[*]VkQueueFamilyProperties,
) callconv(.c) void;

pub const extension_wayland_surface = "VK_KHR_wayland_surface";
pub const extension_android_surface = "VK_KHR_android_surface";
pub const extension_surface = "VK_KHR_surface";

pub const WAYLAND_SURFACE_SPEC_VERSION: u32 = 6;

pub fn nameEquals(name: [*:0]const u8, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.span(name), want);
}

pub fn extNameEquals(ext: *const VkExtensionProperties, want: []const u8) bool {
    return std.mem.eql(u8, std.mem.sliceTo(ext.extensionName[0..], 0), want);
}
