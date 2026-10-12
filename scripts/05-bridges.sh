#!/usr/bin/env bash
set -euo pipefail
: "${STAGE:?}"
MA=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
HYB="$STAGE/libhybris-root"
DMA="$STAGE/dmabuf-root"
OUT="$STAGE/bridges-root"
SRC="$STAGE/bridges-src"
LIBDIR="$OUT/usr/lib/$MA"
W="${GITHUB_WORKSPACE:-$PWD}"
mkdir -p "$LIBDIR" "$SRC" logs
: > "$STAGE/bridges-missing.txt"

apt-get install -y -qq patchelf libglvnd-dev libegl-dev libgles-dev \
  libvulkan-dev ocl-icd-opencl-dev libva-dev libvdpau-dev libgbm-dev >/dev/null

# bridge <nama>: 0 = terbangun, 2 = source belum ada, gagal build = script berhenti
bridge() {
  local n=$1 d="$W/bridges/$1"
  if [ -x "$d/build.sh" ]; then
    echo "== jembatan $n"
    ( cd "$d" && OUT="$OUT" LIBDIR="$LIBDIR" MA="$MA" HYB="$HYB" DMA="$DMA" \
        SRC_DIR="$d" ./build.sh ) 2>&1 | tee "logs/bridge-$n.log" \
      || { echo "GAGAL membangun jembatan $n"; exit 1; }
    return 0
  fi
  echo "BELUM ADA: bridges/$n/build.sh" | tee -a "$STAGE/bridges-missing.txt"
  return 2
}

# ---------- 1. EGL/GLES/GL: vendor libglvnd ----------
if [ "$API_EGL_GLES" = true ]; then
  E="$SRC/egl"; mkdir -p "$E" "$OUT/usr/share/glvnd/egl_vendor.d"

  real=$(find "$HYB" -name 'libEGL.so.1*' -type f | head -n1)
  [ -n "$real" ] || { echo "GAGAL: libEGL milik libhybris tidak ditemukan"; exit 1; }
  # libEGL hybris disalin dengan soname lain supaya tidak bentrok dengan libEGL glvnd
  cp "$real" "$LIBDIR/libEGL_hybris_impl.so.1"
  patchelf --set-soname libEGL_hybris_impl.so.1 "$LIBDIR/libEGL_hybris_impl.so.1"

  cat > "$E/egl_vendor.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdint.h>
#include <stdlib.h>
#include <EGL/egl.h>
#include <EGL/eglext.h>
#include <glvnd/libeglabi.h>

#define PUBLIC __attribute__((visibility("default")))

static void *impl;
static EGLDisplay (*p_getDisplay)(EGLNativeDisplayType);
static void *(*p_getProc)(const char *);

static int load(void) {
  if (impl) return 1;
  const char *path = getenv("HYBRIS_EGL_IMPL");
  impl = dlopen(path ? path : "libEGL_hybris_impl.so.1", RTLD_NOW | RTLD_LOCAL);
  if (!impl) return 0;
  p_getDisplay = (EGLDisplay (*)(EGLNativeDisplayType))dlsym(impl, "eglGetDisplay");
  p_getProc = (void *(*)(const char *))dlsym(impl, "eglGetProcAddress");
  return p_getDisplay && p_getProc;
}

static EGLDisplay v_getPlatformDisplay(EGLenum platform, void *native,
                                       const EGLAttrib *attribs) {
  (void)platform; (void)attribs;
  /* HYBRIS_EGL_DISABLE=1 -> serahkan ke Mesa (jalur CPU) */
  if (getenv("HYBRIS_EGL_DISABLE") || !load()) return EGL_NO_DISPLAY;
  return p_getDisplay((EGLNativeDisplayType)native);
}
static EGLBoolean v_getSupportsAPI(EGLenum api) { return api == EGL_OPENGL_ES_API; }
static const char *v_getVendorString(int name) { return name == EGL_VENDOR ? "libhybris" : NULL; }
static void *v_getProcAddress(const char *n) { return load() ? p_getProc(n) : NULL; }
static void *v_getDispatchAddress(const char *n) { return load() ? p_getProc(n) : NULL; }
static void v_setDispatchIndex(const char *n, int i) { (void)n; (void)i; }

PUBLIC EGLBoolean __egl_Main(uint32_t version, const __EGLapiExports *exports,
                             __EGLvendorInfo *vendor, __EGLapiImports *imports) {
  (void)exports; (void)vendor;
  if (EGL_VENDOR_ABI_GET_MAJOR_VERSION(version) != EGL_VENDOR_ABI_MAJOR_VERSION)
    return EGL_FALSE;
  if (!load()) return EGL_FALSE;
  imports->getPlatformDisplay = v_getPlatformDisplay;
  imports->getSupportsAPI     = v_getSupportsAPI;
  imports->getVendorString    = v_getVendorString;
  imports->getProcAddress     = v_getProcAddress;
  imports->getDispatchAddress = v_getDispatchAddress;
  imports->setDispatchIndex   = v_setDispatchIndex;
  return EGL_TRUE;
}
C
  clang -O2 -fPIC -Wall -shared -fvisibility=hidden \
    -Wl,-soname,libEGL_hybris.so.0 \
    -o "$LIBDIR/libEGL_hybris.so.0" "$E/egl_vendor.c" -ldl
  nm -D --defined-only "$LIBDIR/libEGL_hybris.so.0" | grep -q __egl_Main \
    || { echo "GAGAL: __egl_Main tidak diekspor"; exit 1; }

  cat > "$OUT/usr/share/glvnd/egl_vendor.d/10_hybris.json" <<'J'
{
  "file_format_version" : "1.0.0",
  "ICD" : { "library_path" : "libEGL_hybris.so.0" }
}
J
fi

# ---------- 2. Vulkan: ICD HAL via libhybris ----------
if [ "$API_VULKAN" = true ] && [ "$DRV_HAL_ICD" = true ]; then
  rc=0; bridge vulkan-icd || rc=$?
  if [ "$rc" = 0 ]; then
    mkdir -p "$OUT/usr/share/vulkan/icd.d"
    cat > "$OUT/usr/share/vulkan/icd.d/hybris_icd.$(uname -m).json" <<'J'
{
  "file_format_version" : "1.0.0",
  "ICD" : { "library_path" : "libvulkan_hybris.so", "api_version" : "1.1.0" }
}
J
  fi
fi

# ---------- 3. Jembatan lain ----------
[ "$API_OPENCL" = true ] && { bridge opencl-icd || true; }
if [ "$API_MEDIA" = true ]; then
  bridge vaapi || true
  bridge vdpau || true
fi
if [ "$API_GRALLOC" = true ] || [ "$API_EGL_GLES" = true ]; then
  bridge gbm || true
fi

# ---------- 4. Ringkasan ----------
echo "=== Terpasang di $OUT"
find "$OUT" -type f | sed "s|$OUT||" | sort
if [ -s "$STAGE/bridges-missing.txt" ]; then
  echo "=== Jembatan yang belum punya source:"
  cat "$STAGE/bridges-missing.txt"
  [ "${STRICT_BRIDGES:-false}" = true ] && exit 1
fi
exit 0
