/*
 * C shim for ANativeWindow.perform().
 *
 * ANativeWindow.perform is declared variadic in AOSP's system/window.h, and
 * a normal caller therefore passes the trailing arguments on the stack under
 * AAPCS64.  The Adreno Vulkan driver, however, calls the vtable slot through
 * a fixed-argument prototype, so the arguments arrive in x2..x7.  Keep this
 * entry point fixed-argument: it is the ABI the vendor driver actually uses,
 * and it also lets Zig 0.16 avoid @cVaStart (which is disabled for aarch64).
 *
 * The first six varying arguments cover every operation the driver uses.
 */

#include <stddef.h>
#include <stdint.h>

int vkwl_perform_usage(void *window, uint64_t usage);
int vkwl_perform_dimensions(void *window, int width, int height);
int vkwl_perform_format(void *window, int format);
int vkwl_perform_buffer_count(void *window, size_t count);
int vkwl_perform_geometry(void *window, int width, int height, int format);
int vkwl_perform_transform(void *window, int transform);
int vkwl_perform_dataspace(void *window, int dataspace);
int vkwl_perform_ignore(void *window, int operation);

int vkwl_native_window_perform(void *window, int operation,
                               uint64_t a1, uint64_t a2, uint64_t a3,
                               uint64_t a4, uint64_t a5, uint64_t a6)
{
    (void)a4;
    (void)a5;
    (void)a6;

    switch (operation) {
    case 0: /* NATIVE_WINDOW_SET_USAGE */
        return vkwl_perform_usage(window, (uint32_t)a1);
    case 30: /* NATIVE_WINDOW_SET_USAGE64 */
        return vkwl_perform_usage(window, a1);
    case 8: /* NATIVE_WINDOW_SET_BUFFERS_DIMENSIONS */
        return vkwl_perform_dimensions(window, (int)a1, (int)a2);
    case 9: /* NATIVE_WINDOW_SET_BUFFERS_FORMAT */
        return vkwl_perform_format(window, (int)a1);
    case 4: /* NATIVE_WINDOW_SET_BUFFER_COUNT */
        return vkwl_perform_buffer_count(window, (size_t)a1);
    case 5: /* NATIVE_WINDOW_SET_BUFFERS_GEOMETRY */
        return vkwl_perform_geometry(window, (int)a1, (int)a2, (int)a3);
    case 6: /* NATIVE_WINDOW_SET_BUFFERS_TRANSFORM */
        return vkwl_perform_transform(window, (int)a1);
    case 19: /* NATIVE_WINDOW_SET_BUFFERS_DATASPACE */
        return vkwl_perform_dataspace(window, (int)a1);
    default:
        return vkwl_perform_ignore(window, operation);
    }
}
