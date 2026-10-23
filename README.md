# libwayland-ahb

A Vulkan loader shim that makes Android's native Vulkan driver expose
`VK_KHR_wayland_surface`, with a client-side `ANativeWindow` backed by
`AHardwareBuffer` and the compositor's `android_wlegl` protocol.

This lets an ordinary Termux Wayland client render with the vendor GPU driver
(for example `vkcube` under TAWC) instead of falling back to Mesa or software.

## Status

Implemented:

* `VK_KHR_wayland_surface` extension injection and `vkCreateInstance`
  translation to `VK_KHR_android_surface`.
* `vkCreateWaylandSurfaceKHR` / `vkDestroySurfaceKHR`.
* A client-side `ANativeWindow` implementation:
  * buffers are allocated lazily as `AHardwareBuffer`s;
  * `queueBuffer` exports them through `android_wlegl`;
  * `wl_buffer.release` returns them to a small buffer pool;
  * `dequeueBuffer` blocks when the pool is empty;
  * `wl_surface.frame` callbacks pace presentation to the compositor's vsync;
  * only buffers registered by the current native swapchain are dequeued, so
    resumed/hidden windows do not fall into an out-of-date swapchain loop;
  * when the compositor stops answering frame callbacks (a backgrounded TAWC
    activity), `dequeueBuffer` parks until the next callback instead of
    spinning.
* Surface capability patching and swapchain-extent handling.
* A provider override for compositors/embedders
  (`vkwlSetWaylandWindowProvider` or an exported
  `vkwl_wayland_to_android_window`).

Not implemented yet:

* An EGL/GLES shim (step 4).
* Device-dispatch wrapping for every swapchain call.  `vkCreateSwapchainKHR`
  and `vkDestroySwapchainKHR` are intercepted through both
  `vkGetInstanceProcAddr` and `vkGetDeviceProcAddr`; other device entry points
  are passed through to the native driver.
* Unconditional vsync.  If the compositor does not answer a frame callback
  within 200 ms after having answered one before, the shim suspends
  presentation until a callback arrives again, and falls back to
  buffer-release/pool backpressure otherwise.

## How it works

```text
Wayland client (vkcube)
  |  vkCreateWaylandSurfaceKHR
  v
libvkwl.so
  |  creates ANativeWindow + AHB buffers
  |  exports each buffer via android_wlegl
  v
TAWC / Wayland compositor
  |  imports the AHB and composites it
  v
Android display
```

The shim does not replace the native Vulkan loader.  It forwards unknown
entry points to `/system/lib64/libvulkan.so`, because only the platform loader
knows how to load vendor ICDs such as `vulkan.adreno.so` through the Android
linker namespace.

```text
libvkwl.so
  | dlopen("/system/lib64/libvulkan.so")
  v
Android platform Vulkan loader -> /vendor/lib64/hw/vulkan.adreno.so
```

Libraries such as wlroots link directly against `libvulkan.so.1` and therefore
need the Vulkan symbols at load time, before any `vkGetInstanceProcAddr` call.
The shim exports the native loader's entry-point set as direct tail-call stubs.
The stubs jump through slots filled by a constructor at library load time, so
they preserve every argument register and do not need a prototype per command.
`src/vulkan_forwarders.S` and `src/vulkan_forwarders.c` are generated from the
native loader's dynamic symbol table; regenerate them with
`scripts/generate-vulkan-forwarders.py` when the loader changes.

### Extension translation

1. `vkEnumerateInstanceExtensionProperties` appends
   `VK_KHR_wayland_surface` when the native driver has
   `VK_KHR_surface` + `VK_KHR_android_surface` but not Wayland.
2. `vkCreateInstance` removes `VK_KHR_wayland_surface` from the enabled list
   and enables `VK_KHR_android_surface` instead.
3. `vkCreateWaylandSurfaceKHR` obtains an `ANativeWindow` and calls the
   native `vkCreateAndroidSurfaceKHR`.

### Client-side window

`src/wayland_window.zig` implements the AOSP `ANativeWindow` C ABI directly.
It is not a wrapper around a Java/Surface object.

* `dequeueBuffer` allocates an `AHardwareBuffer` matching the requested
  width/height/format/usage and returns its `ANativeWindowBuffer`.
* `queueBuffer` waits on the driver's sync fence, exports the AHB with
  `android_wlegl`, attaches the resulting `wl_buffer`, requests a
  `wl_surface.frame` callback, and commits the `wl_surface`.
* The private queue is dispatched until the frame callback arrives, so
  `queueBuffer` returns at most once per compositor vsync.  This is what
  replaces Android's normal buffer-queue throttling.
* If a frame callback times out after callbacks have previously arrived, the
  window is treated as suspended.  `dequeueBuffer` parks until the compositor
  sends another callback, which TAWC does when the activity becomes visible
  again.
* `wl_buffer.release` puts the buffer back into the pool.
* `dequeueBuffer` blocks on the private Wayland event queue until a release or
  another event arrives.
* All private protocol objects (registry, `android_wlegl`, buffers, frame
  callbacks) use a private `wl_event_queue` and proxy wrappers, so the app's
  default queue and its existing `wl_surface` listeners are untouched.

Android's WSI swapchain only accepts buffers that it dequeued while the
swapchain was being created.  The shim wraps `vkCreateSwapchainKHR`, records
the buffers dequeued during the native call, and marks only those as
registered.  A normal acquire never returns an unregistered pool buffer;
returning one makes `vkAcquireNextImageKHR` report
`VK_ERROR_OUT_OF_DATE_KHR` (and cancel the buffer), which can recreate the
swapchain every frame after a window is resumed.  Surplus buffers from an old
swapchain stay alive until the compositor releases them, then are retired.

The surface extent tracks the client's Wayland window size, clamped into the
native driver's valid range.  The native driver still calls
`ANativeWindow.perform(SET_BUFFERS_DIMENSIONS)` before the first buffer is
dequeued.  Set `VKWL_WIDTH` and/or `VKWL_HEIGHT` to pin an extent instead.
Reporting a defined extent also avoids one vkcube failure mode: after a
suboptimal present it compares `currentExtent` with its swapchain size, and the
undefined sentinel differs from every real size.

The driver calls the variadic `ANativeWindow.perform` slot through a
fixed-argument ABI on Adreno, so `src/native_window_shim.c` provides a matching
fixed-argument thunk.  See the comments in that file before changing it.

## Build

Requirements:

* Zig 0.16+
* Termux `ndk-sysroot` and `ndk-multilib`
* `wayland` and `wayland-egl` development files
* A compositor that advertises `android_wlegl` and can import the exported
  AHB handles (TAWC does).

```sh
git clone https://github.com/Nikitf777/libwayland-ahb.git
cd libwayland-ahb
zig build -Doptimize=ReleaseSmall
```

`build.zig` creates `.zig-cache/libc-kit/<triple>/` by symlinking Android CRT
objects and bionic linker stubs, then tells Zig to use that kit.  This produces
a shared object with normal bionic `DT_NEEDED` entries and no dependency on the
build device's `/system/lib64`.

Override the Termux prefix with:

```sh
zig build -Doptimize=ReleaseSmall -Dandroid-prefix=/path/to/prefix
```

The vendored `android_wlegl` client files can be regenerated with:

```sh
./scripts/generate-protocols.sh
```

## Run

`scripts/vkwl-run` is a generic environment wrapper.  It puts
`runtime/libvulkan.so` (a symlink to `zig-out/lib/libvkwl.so`) first in
`LD_LIBRARY_PATH`, then `exec`s the command.  It has no compositor-specific
logic.

```sh
./scripts/vkwl-run vulkaninfo --summary
./scripts/vkwl-run vkcube --c 10
```

It can wrap either the final client or a compositor's launcher.  If the
launcher preserves its environment across the socket hand-off, both orders
work:

```sh
./scripts/vkwl-run <launcher> vkcube
<launcher> ./scripts/vkwl-run vkcube
```

Without a Wayland display, `vulkaninfo` still prints
`'DISPLAY' environment variable not set... skipping surface info`.  That is
normal; the extension list is the important part.

### Environment variables

| Variable | Meaning |
| --- | --- |
| `VKWL_LOG=1` | Print shim diagnostics to stderr. |
| `VKWL_NATIVE_LOADER=/path/to/libvulkan.so` | Use a different native loader. |
| `VKWL_WIDTH=<pixels>` | Pin the surface width. |
| `VKWL_HEIGHT=<pixels>` | Pin the surface height. |

For example, to pin a 640x480 surface and log buffer setup:

```sh
VKWL_LOG=1 VKWL_WIDTH=640 VKWL_HEIGHT=480 \
  ./scripts/vkwl-run vkcube --c 10
```

## Layout

| File | Purpose |
| --- | --- |
| `src/main.zig` | Exported Vulkan entry points |
| `src/wrapper.zig` | Extension injection, surface translation, caps/swapchain hooks |
| `src/bridge.zig` | Provider hook and client-side window creation |
| `src/wayland_window.zig` | `ANativeWindow` vtable, AHB pool, `android_wlegl` export |
| `src/native_window.zig` | Exact AOSP `ANativeWindow` / `ANativeWindowBuffer` ABI |
| `src/native_window_shim.c` | Fixed-argument `ANativeWindow.perform` thunk |
| `src/ahb.zig` | `AHardwareBuffer` bindings and native-handle helpers |
| `src/wl.zig` | Wayland `@cImport`, proxy wrappers, private queues |
| `src/native.zig` | Native loader discovery |
| `src/dlfcn.zig` | Minimal `dlopen`/`dlsym` bindings |
| `src/vk.zig` | Minimal Vulkan ABI types |
| `src/vulkan_forwarders.S` | Generated direct-call stubs for native entry points |
| `src/vulkan_forwarders.c` | Generated constructor that resolves forwarder slots |
| `src/protocol/` | Generated `android_wlegl` client protocol |
| `protocols/android_wlegl.xml` | Source protocol definition |
| `scripts/vkwl-run` | Run an executable with the shim in `LD_LIBRARY_PATH` |
| `scripts/generate-protocols.sh` | Regenerate the vendored protocol files |
| `scripts/generate-vulkan-forwarders.py` | Regenerate direct-call forwarders |

## ABI notes

* **Do not cast `ANativeWindow*` back to the Zig struct.**  Zig may reorder
  regular struct fields; use `@fieldParentPtr("base", ...)`.
* `ANativeWindow.perform` is variadic in AOSP headers but fixed-argument when
  called by the Adreno driver.  The C thunk matches the vendor ABI.
* `sizeof(ANativeWindow) == 192` and `sizeof(ANativeWindowBuffer) == 168` on
  64-bit Android.  Compile-time assertions in `src/native_window.zig` keep the
  layout honest.
* The shim uses `std.heap.c_allocator` for windows and the surface map, while
  extension enumeration uses fixed stack storage.
* The `android_wlegl` v2 wire format carries usage as a 32-bit signed value;
  only the low 32 AHB usage bits survive that hop.

## Current limitations

* The compositor must implement `android_wlegl` and import client-allocated
  AHB buffers.  A compositor without it (for example headless Weston) makes
  window creation fail with `NoAndroidWlegl`; the shim does not fall back to
  shared memory.
* No EGL/GLES integration yet.  Only Vulkan clients that use
  `VK_KHR_wayland_surface` are covered.
* Presentation uses `wl_surface.frame` callbacks.  A compositor that never
  answers one makes the shim fall back to release-based pacing after a 200 ms
  timeout; such a client is not vsync-limited.
* The swapchain hooks are installed through this shim's
  `vkGetInstanceProcAddr` / `vkGetDeviceProcAddr` and its direct exports of the
  surface-capability and create/destroy-swapchain entry points.  A client that
  loads the native loader itself and resolves native device commands there will
  not notify the shim about swapchain creation, so buffer registration and
  extent rewriting will not apply.  The capability and `perform` paths do not
  depend on that.
* The fixed `perform` ABI is required by the Adreno driver.  A different vendor
  driver may use the normal variadic calling convention and need a different
  thunk.
* Each Vulkan surface gets its own client-side window.  The app must keep the
  original `wl_surface` alive until the Vulkan surface is destroyed, and should
  not create multiple Vulkan surfaces for the same `wl_surface`.
