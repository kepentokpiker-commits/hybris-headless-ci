#!/usr/bin/env bash
set -euo pipefail
TAG="$1"; OUT="$2"; S="$OUT/src"
B=https://android.googlesource.com/platform
mkdir -p "$S" "$OUT/include" "$OUT/bionic-include"

for r in bionic system/core system/libbase frameworks/native hardware/libhardware; do
  git clone --depth 1 --branch "$TAG" "$B/$r" "$S/${r//\//_}"
done

for d in hardware_libhardware/include system_core/libcutils/include \
  system_core/liblog/include system_core/libutils/include \
  system_core/libsystem/include system_core/libsync/include \
  system_libbase/include frameworks_native/libs/nativewindow/include \
  frameworks_native/libs/arect/include frameworks_native/opengl/include \
  frameworks_native/libs/nativebase/include \
  frameworks_native/libs/ui/include; do
  [ -d "$S/$d" ] && cp -a "$S/$d/." "$OUT/include/" || echo "skip $d"
done

cp -a "$S/bionic/libc/include/." "$OUT/bionic-include/"
