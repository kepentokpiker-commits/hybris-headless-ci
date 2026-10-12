#!/usr/bin/env bash
set -euo pipefail
TAG="$1"; OUT="$2"; S="$OUT/src"
B=https://android.googlesource.com/platform
mkdir -p "$S" "$OUT/include" "$OUT/bionic-include"
for r in bionic system/core system/libbase system/logging system/media \
  frameworks/native hardware/libhardware; do
  git clone --depth 1 --branch "$TAG" "$B/$r" "$S/${r//\//_}" \
    || echo "gagal clone $r (dilewati)"
done
for d in hardware_libhardware/include system_core/libcutils/include \
  system_core/liblog/include system_core/libutils/include \
  system_core/libsystem/include system_core/libsync/include \
  system_libbase/include system_logging/liblog/include \
  system_media/audio/include system_media/audio_utils/include \
  frameworks_native/libs/nativewindow/include \
  frameworks_native/libs/arect/include frameworks_native/opengl/include \
  frameworks_native/libs/nativebase/include \
  frameworks_native/libs/ui/include \
  frameworks_native/vulkan/include; do
  [ -d "$S/$d" ] && cp -a "$S/$d/." "$OUT/include/" || echo "skip $d"
done
cp -a "$S/bionic/libc/include/." "$OUT/bionic-include/"
