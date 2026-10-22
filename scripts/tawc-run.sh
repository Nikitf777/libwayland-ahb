#!/bin/sh
# Run a Wayland client through the shim inside TAWC.
#
# Example:
#   scripts/tawc-run.sh vkcube --c 10
#
# TAWC's wayland-run starts the client with WAYLAND_SOCKET and deliberately
# clears LD_LIBRARY_PATH.  Run the client through a shell so the shim path is
# restored after that hand-off.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib="$root/zig-out/lib/libvkwl.so"
runtime="$root/runtime"
runner="${TAWC_WAYLAND_RUN:-/data/data/com.termux/files/home/projects/rust/tawc/termux-wayland/wayland-run}"
shell="${TAWC_SHELL:-/data/data/com.termux/files/usr/bin/sh}"

if [ ! -f "$lib" ]; then
    echo "missing $lib; run 'zig build' first" >&2
    exit 1
fi
if [ ! -x "$runner" ]; then
    echo "missing TAWC wayland-run at $runner" >&2
    echo "set TAWC_WAYLAND_RUN to its path" >&2
    exit 1
fi
if [ "$#" -eq 0 ]; then
    echo "usage: $0 <command> [args...]" >&2
    exit 2
fi

mkdir -p "$runtime"
ln -sf "$lib" "$runtime/libvulkan.so"
ln -sf "$lib" "$runtime/libvulkan.so.1"

# wayland-run execs this shell with the WAYLAND_SOCKET fd already open.  Export
# the shim path here, after wayland-run's own LD_LIBRARY_PATH cleanup.
exec "$runner" "$shell" -c '
    export LD_LIBRARY_PATH="$1"
    shift
    exec "$@"
' sh "$runtime" "$@"
