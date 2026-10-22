#!/bin/sh
# Run vulkaninfo through the wrapper.
#
# vulkaninfo dlopen()s "libvulkan.so"; putting our symlink first in
# LD_LIBRARY_PATH makes it load the shim, which in turn loads the real
# Android loader from /system/lib64/libvulkan.so.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
lib="$root/zig-out/lib/libvkwl.so"
runtime="$root/runtime"

if [ ! -f "$lib" ]; then
    echo "missing $lib; run 'zig build' first" >&2
    exit 1
fi

mkdir -p "$runtime"
ln -sf "$lib" "$runtime/libvulkan.so"
ln -sf "$lib" "$runtime/libvulkan.so.1"

LD_LIBRARY_PATH="$runtime${LD_LIBRARY_PATH:+:$LD_LIBRARY_PATH}"
export LD_LIBRARY_PATH

exec vulkaninfo "$@"
