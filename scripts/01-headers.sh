#!/usr/bin/env bash
set -euo pipefail
: "${STAGE:?}" "${ANDROID_VERSION:?}"

AOSP=https://android.googlesource.com
OUT="$STAGE/android-headers"     # layout: hardware/ cutils/ system/ log/ ...
BIONIC="$STAGE/bionic-include"
SRC="$STAGE/aosp-src"
mkdir -p "$OUT" "$BIONIC" "$SRC" logs

# Tag rilis terbaru untuk versi Android yang dipilih
tag=$(git ls-remote --tags --refs "$AOSP/platform/manifest" \
        "refs/tags/android-${ANDROID_VERSION}.0.0_r*" \
      | sed 's|.*refs/tags/||' | sort -V | tail -n1)
[ -n "$tag" ] || { echo "Tag Android $ANDROID_VERSION tidak ditemukan"; exit 1; }
echo "$tag" > "$STAGE/android-tag"
echo "Memakai tag: $tag"

# fetch <repo> <path...> : clone dangkal (sparse bila bisa)
fetch() {
  local repo=$1; shift
  local dir="$SRC/${repo//\//_}"
  if [ ! -d "$dir" ]; then
    git clone -q --depth 1 --branch "$tag" --filter=blob:none --sparse \
        "$AOSP/$repo" "$dir" 2>/dev/null \
      || git clone -q --depth 1 --branch "$tag" "$AOSP/$repo" "$dir" \
      || { echo "WARN: $repo tidak ada di $tag"; return 1; }
  fi
  git -C "$dir" sparse-checkout set --no-cone "$@" 2>/dev/null || true
}

# copy <repo> <subpath> <tujuan relatif OUT>
copy() {
  local repo=$1 sub=$2 dest=$3 dir="$SRC/${repo//\//_}"
  [ -d "$dir/$sub" ] || return 1
  mkdir -p "$OUT/$dest"
  cp -a "$dir/$sub/." "$OUT/$dest/"
}

# --- libhardware (gralloc, hwcomposer, hwvulkan, dll.)
fetch platform/hardware/libhardware include
copy platform/hardware/libhardware include/hardware hardware

# --- system/core (path berubah antar versi, coba semua kandidat)
fetch platform/system/core libcutils libsystem libutils libsync liblog include
for pair in "libcutils/include/cutils:cutils" "include/cutils:cutils" \
            "libsystem/include/system:system" "include/system:system" \
            "libutils/include/utils:utils" "include/utils:utils" \
            "libsync/include/sync:sync" "include/sync:sync" \
            "liblog/include/log:log" "include/log:log"; do
  copy platform/system/core "${pair%%:*}" "${pair##*:}" || true
done

# --- liblog dipindah ke repo logging sejak Android 11
if fetch platform/system/logging liblog 2>/dev/null; then
  copy platform/system/logging liblog/include/log log || true
fi

# --- frameworks/native (nativewindow, EGL/GLES, Vulkan)
fetch platform/frameworks/native libs/nativewindow libs/arect libs/nativebase \
      opengl/include vulkan/include libs/ui
copy platform/frameworks/native libs/nativewindow/include/android android || true
copy platform/frameworks/native libs/arect/include/android android || true
copy platform/frameworks/native libs/nativebase/include/nativebase nativebase || true
copy platform/frameworks/native libs/ui/include/ui ui || true
for d in EGL GLES GLES2 GLES3 KHR; do
  copy platform/frameworks/native "opengl/include/$d" "$d" || true
done
copy platform/frameworks/native vulkan/include/vulkan vulkan || true
copy platform/frameworks/native vulkan/include/vndk vndk || true

# --- header bionic (dipakai linker q, dipasang lewat -idirafter)
fetch platform/bionic libc/include
cp -a "$SRC/platform_bionic/libc/include/." "$BIONIC/"

# --- pemeriksaan wajib
for f in hardware/gralloc.h hardware/hardware.h cutils/native_handle.h; do
  [ -e "$OUT/$f" ] || { echo "GAGAL: $f tidak ada di header $tag"; exit 1; }
done
echo "Header siap: $(find "$OUT" -type f | wc -l) file"
