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
  * `wl_surface.frame` callbacks pace presentation to the compositor's vsync.
* Surface capability patching and swapchain-extent handling.
* A provider override for compositors/embedders
  (`vkwlSetWaylandWindowProvider` or an exported
  `vkwl_wayland_to_android_window`).

Not implemented yet:

* An EGL/GLES shim (step 4).
* Device-dispatch wrapping for every swapchain call.  `vkCreateSwapchainKHR`
  and `vkDestroySwapchainKHR` are intercepted when the app resolves them
  through this shim, but the native `vkCreateDevice` path may bypass them.  The
  surface extent still flows through `vkGetPhysicalDeviceSurfaceCapabilitiesKHR`
  and `ANativeWindow.perform(SET_BUFFERS_DIMENSIONS)`.
* Unconditional vsync.  If the compositor does not answer a frame callback
  within 200 ms, the shim disables the wait for that window and falls back to
  buffer-release/pool backpressure.

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
* `wl_buffer.release` puts the buffer back into the pool.
* `dequeueBuffer` blocks on the private Wayland event queue until a release or
  another event arrives.
* All private protocol objects (registry, `android_wlegl`, buffers, frame
  callbacks) use a private `wl_event_queue` and proxy wrappers, so the app's
  default queue and its existing `wl_surface` listeners are untouched.

The surface extent is reported as the standard "undefined"
(`currentExtent = 0xFFFFFFFF`) so Wayland clients can choose their own size.
The native driver then calls `ANativeWindow.perform(SET_BUFFERS_DIMENSIONS)`
with that size before the first buffer is dequeued.  Set `VKWL_WIDTH` and/or
`VKWL_HEIGHT` to pin an extent instead.

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
cd /data/data/com.termux/files/home/projects/zig/libwayland-ahb
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

### Vulkan information

```sh
./scripts/vulkaninfo-wrapper.sh --summary
```

The wrapper puts `runtime/libvulkan.so` (a symlink to `zig-out/lib/libvkwl.so`)
first in `LD_LIBRARY_PATH`, so `vulkaninfo` loads the shim.  It should list
`VK_KHR_wayland_surface : extension revision 6` alongside
`VK_KHR_android_surface`, with the native Adreno driver.

Without a Wayland display, `vulkaninfo` still prints
`'DISPLAY' environment variable not set... skipping surface info`.  That is
normal; the extension list is the important part.

### A client under TAWC

```sh
./scripts/tawc-run.sh vkcube --c 10
```

The script uses
`/data/data/com.termux/files/home/projects/rust/tawc/termux-wayland/wayland-run`
by default.  Override it with `TAWC_WAYLAND_RUN=/path/to/wayland-run`.

TAWC's launcher deliberately clears `LD_LIBRARY_PATH` before handing the
Wayland socket to the client.  `tawc-run.sh` therefore starts the client
through a POSIX shell and restores the shim path after that hand-off.

### Environment variables

| Variable | Meaning |
| --- | --- |
| `VKWL_LOG=1` | Print shim diagnostics to stderr. |
| `VKWL_NATIVE_LOADER=/path/to/libvulkan.so` | Use a different native loader. |
| `VKWL_WIDTH=<pixels>` | Pin the surface width. |
| `VKWL_HEIGHT=<pixels>` | Pin the surface height. |
| `TAWC_WAYLAND_RUN=/path` | Override the TAWC `wayland-run` path. |
| `TAWC_SHELL=/path/sh` | Override the shell used by `tawc-run.sh`. |

For example, to pin a 640x480 surface and log buffer setup:

```sh
VKWL_LOG=1 VKWL_WIDTH=640 VKWL_HEIGHT=480 \
  ./scripts/tawc-run.sh vkcube --c 10
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
| `src/protocol/` | Generated `android_wlegl` client protocol |
| `protocols/android_wlegl.xml` | Source protocol definition |
| `scripts/tawc-run.sh` | Run a client under TAWC with the shim |
| `scripts/vulkaninfo-wrapper.sh` | Run `vulkaninfo` with the shim |
| `scripts/generate-protocols.sh` | Regenerate the vendored protocol files |

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
* The swapchain hooks are not guaranteed to run for every app, because the
  native loader may resolve device commands directly from the native device.
  The capability and `perform` paths are the reliable ones.
* The fixed `perform` ABI is required by the Adreno driver.  A different vendor
  driver may use the normal variadic calling convention and need a different
  thunk.
* Each Vulkan surface gets its own client-side window.  The app must keep the
  original `wl_surface` alive until the Vulkan surface is destroyed, and should
  not create multiple Vulkan surfaces for the same `wl_surface`.
