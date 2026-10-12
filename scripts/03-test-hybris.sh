#!/usr/bin/env bash
set -euo pipefail
: "${STAGE:?}"
MA=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
ROOT="$STAGE/libhybris-root"
LIBDIR="$ROOT/usr/lib/$MA"
T="$STAGE/tests"
mkdir -p "$T" logs
fail=0

# --- 1. Daftar simbol yang diekspor semua .so hasil build
: > "$T/exports.txt"
while IFS= read -r so; do
  nm -D --defined-only "$so" 2>/dev/null \
    | awk -v f="$(basename "$so")" '$2 ~ /^[TWDBR]$/ {print $3" "f}' >> "$T/exports.txt"
done < <(find "$ROOT" -name '*.so*' -type f)
echo "Simbol terekspor: $(wc -l < "$T/exports.txt")"

need() { # need <flag> <wajib|opsional> <simbol...>
  local flag=$1 level=$2; shift 2
  if [ "$flag" != "true" ]; then echo "lewati (flag mati): $*"; return 0; fi
  local s
  for s in "$@"; do
    if grep -q "^$s " "$T/exports.txt"; then
      echo "OK    $s  <- $(grep -m1 "^$s " "$T/exports.txt" | cut -d' ' -f2)"
    elif [ "$level" = wajib ]; then
      echo "GAGAL $s tidak diekspor"; fail=1
    else
      echo "WARN  $s tidak diekspor"
    fi
  done
}

need true               wajib   android_dlopen android_dlsym android_dlclose android_dlerror
need "$API_GRALLOC"     wajib   hybris_gralloc_initialize hybris_gralloc_allocate \
                                hybris_gralloc_release hybris_gralloc_import_buffer \
                                hybris_gralloc_lock hybris_gralloc_unlock \
                                hybris_gralloc_deinitialize
need "$API_EGL_GLES"    wajib   eglGetDisplay eglInitialize eglGetProcAddress \
                                eglCreateContext eglSwapBuffers glGetString
need "$API_VULKAN"      opsional vkGetInstanceProcAddr vkCreateInstance
# OpenCL dan media tidak punya pembungkus di libhybris; ditangani jembatan di 05

# --- 2. Kebergantungan library yang tidak ketemu
export LD_LIBRARY_PATH="$LIBDIR"
while IFS= read -r so; do
  ldd "$so" 2>/dev/null | grep 'not found' | sed "s|^|WARN  $(basename "$so"): |" || true
done < <(find "$ROOT" -name '*.so*' -type f)

# --- 3. Binary self-test untuk device
cat > "$T/hybris-selftest.c" <<'C'
#define _GNU_SOURCE
#include <dlfcn.h>
#include <stdio.h>
#include <string.h>
#include <sys/wait.h>
#include <unistd.h>

typedef void *(*dlopen_fn)(const char *, int);
typedef const char *(*dlerr_fn)(void);
typedef void *(*egl_gd_fn)(void *);
typedef unsigned (*egl_in_fn)(void *, int *, int *);

/* Tiap langkah jalan di proses anak: crash ketahuan, tidak menutupi langkah lain */
static int step(const char *name, int (*fn)(const char *), const char *arg) {
  fflush(stdout);
  pid_t p = fork();
  if (p == 0) { int r = fn(arg); fflush(stdout); _exit(r); }
  int st = 0; waitpid(p, &st, 0);
  if (WIFSIGNALED(st)) {
    printf("GAGAL %-34s sinyal %d (%s)\n", name, WTERMSIG(st), strsignal(WTERMSIG(st)));
    return 1;
  }
  if (WEXITSTATUS(st)) { printf("GAGAL %-34s kode %d\n", name, WEXITSTATUS(st)); return 1; }
  printf("OK    %s\n", name);
  return 0;
}

static int t_common(const char *a) {
  (void)a;
  void *h = dlopen("libhybris-common.so.1", RTLD_NOW);
  if (!h) { fprintf(stderr, "%s\n", dlerror()); return 2; }
  return dlsym(h, "android_dlopen") ? 0 : 3;
}
static int t_vendor(const char *path) {
  void *h = dlopen("libhybris-common.so.1", RTLD_NOW);
  if (!h) return 2;
  dlopen_fn ao = (dlopen_fn)dlsym(h, "android_dlopen");
  dlerr_fn ae = (dlerr_fn)dlsym(h, "android_dlerror");
  if (!ao) return 3;
  if (!ao(path, 2 /* RTLD_NOW */)) { fprintf(stderr, "%s\n", ae ? ae() : "?"); return 4; }
  return 0;
}
static int t_egl(const char *a) {
  (void)a;
  void *h = dlopen("libEGL.so.1", RTLD_NOW);
  if (!h) { fprintf(stderr, "%s\n", dlerror()); return 2; }
  egl_gd_fn gd = (egl_gd_fn)dlsym(h, "eglGetDisplay");
  egl_in_fn in = (egl_in_fn)dlsym(h, "eglInitialize");
  if (!gd || !in) return 3;
  void *d = gd(NULL);
  if (!d) return 4;
  int ma = 0, mi = 0;
  if (!in(d, &ma, &mi)) return 5;
  printf("      EGL %d.%d\n", ma, mi);
  return 0;
}

int main(int argc, char **argv) {
  if (argc > 1 && !strcmp(argv[1], "--common"))
    return step("libhybris-common dapat dimuat", t_common, NULL) ? 1 : 0;
  int f = step("libhybris-common dapat dimuat", t_common, NULL);
  for (int i = 1; i < argc; i++) {
    char n[300]; snprintf(n, sizeof n, "vendor %s", argv[i]);
    f += step(n, t_vendor, argv[i]);
  }
  f += step("libEGL hybris: eglInitialize", t_egl, NULL);
  return f ? 1 : 0;
}
C
clang -O2 -Wall -o "$T/hybris-selftest" "$T/hybris-selftest.c" -ldl

cat > "$T/run-on-device.sh" <<'SH'
#!/bin/sh
# Jalankan di device: sh run-on-device.sh [/vendor/lib64/egl/libGLES_mali.so ...]
D=$(cd "$(dirname "$0")/.." && pwd)
export LD_LIBRARY_PATH="$D/libhybris-root/usr/lib/aarch64-linux-gnu:${LD_LIBRARY_PATH:-}"
export HYBRIS_LD_LIBRARY_PATH=/system/lib64:/odm/lib64:/vendor/lib64
exec "$D/tests/hybris-selftest" "$@"
SH
chmod +x "$T/run-on-device.sh"

# --- 4. Muat libhybris-common di CI (tidak memblokir rantai)
if "$T/hybris-selftest" --common 2>&1 | tee "$T/ci-common.log"; then
  echo "libhybris-common termuat di CI"
else
  echo "WARN: libhybris-common gagal dimuat di CI, lihat tests/ci-common.log"
fi

[ "$fail" = 0 ] || { echo "Tes simbol gagal. Cek tests/exports.txt"; exit 1; }
echo "Tes lapisan libhybris lulus"
