#!/bin/sh
# Regenerate the vendored android_wlegl client protocol.
set -eu

root=$(CDPATH= cd -- "$(dirname -- "$0")/.." && pwd)
xml="$root/protocols/android_wlegl.xml"
out="$root/src/protocol"

command -v wayland-scanner >/dev/null 2>&1 || {
    echo "wayland-scanner not found" >&2
    exit 1
}

wayland-scanner client-header "$xml" "$out/android_wlegl_client.h"
wayland-scanner private-code "$xml" "$out/android_wlegl_client.c"
