#!/usr/bin/env bash
set -euo pipefail
: "${STAGE:?}"
MA=$(dpkg-architecture -qDEB_HOST_MULTIARCH)
SRC="$STAGE/dmabuf-src"
ROOT="$STAGE/dmabuf-root"
INC="$ROOT/usr/include"
LIB="$ROOT/usr/lib/$MA"
mkdir -p "$SRC" "$INC" "$LIB/pkgconfig" logs

cat > "$SRC/hybris-dmabuf.h" <<'H'
#ifndef HYBRIS_DMABUF_H
#define HYBRIS_DMABUF_H
#include <stddef.h>
#include <stdint.h>
#ifdef __cplusplus
extern "C" {
#endif

/* Tata letak sama dengan native_handle_t Android */
typedef struct hdb_native_handle {
  int version, numFds, numInts;
  int data[];
} hdb_native_handle;

typedef struct hdb_buffer {
  int fd;                 /* dma-buf fd, dimiliki struct ini */
  uint32_t width, height;
  uint32_t stride_bytes;
  uint32_t hal_format;    /* HAL_PIXEL_FORMAT_* */
  uint32_t fourcc;        /* DRM_FORMAT_* */
  size_t size;
} hdb_buffer;

uint32_t hdb_fourcc_from_hal(uint32_t hal_format);   /* 0 bila tidak dikenal */
uint32_t hdb_bpp_from_fourcc(uint32_t fourcc);       /* byte per piksel */

/* Salin (dup) fd ke-idx dari native handle gralloc. Lebar, tinggi, stride
 * (dalam piksel) dan format dari hasil alokasi HAL: layout private handle
 * itu spesifik vendor, jadi tidak ditebak di sini. Mengembalikan 0 / -errno. */
int  hdb_from_native_handle(const hdb_native_handle *h, int fd_index,
                            uint32_t width, uint32_t height,
                            uint32_t stride_pixels, uint32_t hal_format,
                            hdb_buffer *out);

void *hdb_map(const hdb_buffer *b, int for_write);   /* NULL bila gagal */
int   hdb_unmap(const hdb_buffer *b, void *p, int for_write);

/* Tunggu sync_file fence. fd < 0 berarti sudah signaled. 0 / -ETIME / -errno */
int   hdb_wait_fence(int sync_fd, int timeout_ms);
void  hdb_close(hdb_buffer *b);

#ifdef __cplusplus
}
#endif
#endif
H

cat > "$SRC/hybris-dmabuf.c" <<'C'
#define _GNU_SOURCE
#include "hybris-dmabuf.h"
#include <errno.h>
#include <fcntl.h>
#include <linux/dma-buf.h>
#include <poll.h>
#include <sys/ioctl.h>
#include <sys/mman.h>
#include <unistd.h>

#define FCC(a,b,c,d) ((uint32_t)(a)|((uint32_t)(b)<<8)|((uint32_t)(c)<<16)|((uint32_t)(d)<<24))

uint32_t hdb_fourcc_from_hal(uint32_t f) {
  switch (f) {
  case 0x01: return FCC('A','B','2','4'); /* RGBA_8888    -> ABGR8888 */
  case 0x02: return FCC('X','B','2','4'); /* RGBX_8888    -> XBGR8888 */
  case 0x03: return FCC('B','G','2','4'); /* RGB_888      -> BGR888 */
  case 0x04: return FCC('R','G','1','6'); /* RGB_565      -> RGB565 */
  case 0x05: return FCC('A','R','2','4'); /* BGRA_8888    -> ARGB8888 */
  case 0x16: return FCC('A','B','4','H'); /* RGBA_FP16    -> ABGR16161616F */
  case 0x2b: return FCC('A','B','3','0'); /* RGBA_1010102 -> ABGR2101010 */
  default:   return 0;
  }
}

uint32_t hdb_bpp_from_fourcc(uint32_t c) {
  if (c == FCC('A','B','4','H')) return 8;
  if (c == FCC('B','G','2','4')) return 3;
  if (c == FCC('R','G','1','6')) return 2;
  if (c == FCC('A','B','2','4') || c == FCC('X','B','2','4') ||
      c == FCC('A','R','2','4') || c == FCC('A','B','3','0')) return 4;
  return 0;
}

int hdb_from_native_handle(const hdb_native_handle *h, int idx,
                           uint32_t w, uint32_t ht, uint32_t stride_px,
                           uint32_t fmt, hdb_buffer *out) {
  if (!h || !out || idx < 0 || idx >= h->numFds || !w || !ht || stride_px < w)
    return -EINVAL;
  uint32_t fcc = hdb_fourcc_from_hal(fmt);
  if (!fcc) return -ENOTSUP;
  int fd = fcntl(h->data[idx], F_DUPFD_CLOEXEC, 0);
  if (fd < 0) return -errno;
  off_t sz = lseek(fd, 0, SEEK_END);
  lseek(fd, 0, SEEK_SET);
  out->fd = fd;
  out->width = w;
  out->height = ht;
  out->hal_format = fmt;
  out->fourcc = fcc;
  out->stride_bytes = stride_px * hdb_bpp_from_fourcc(fcc);
  out->size = sz > 0 ? (size_t)sz : (size_t)out->stride_bytes * ht;
  return 0;
}

/* ENOTTY/EINVAL = fd bukan dma-buf (mis. memfd saat tes): tidak dianggap galat */
static int dsync(int fd, uint64_t flags) {
  struct dma_buf_sync s = { .flags = flags };
  int r;
  do r = ioctl(fd, DMA_BUF_IOCTL_SYNC, &s); while (r < 0 && errno == EINTR);
  if (r < 0 && errno != ENOTTY && errno != EINVAL) return -errno;
  return 0;
}

void *hdb_map(const hdb_buffer *b, int w) {
  void *p = mmap(NULL, b->size, PROT_READ | (w ? PROT_WRITE : 0), MAP_SHARED, b->fd, 0);
  if (p == MAP_FAILED) return NULL;
  dsync(b->fd, DMA_BUF_SYNC_START | (w ? DMA_BUF_SYNC_RW : DMA_BUF_SYNC_READ));
  return p;
}

int hdb_unmap(const hdb_buffer *b, void *p, int w) {
  dsync(b->fd, DMA_BUF_SYNC_END | (w ? DMA_BUF_SYNC_RW : DMA_BUF_SYNC_READ));
  return munmap(p, b->size);
}

int hdb_wait_fence(int fd, int ms) {
  if (fd < 0) return 0;
  struct pollfd p = { .fd = fd, .events = POLLIN };
  int r;
  do r = poll(&p, 1, ms); while (r < 0 && errno == EINTR);
  if (r == 0) return -ETIME;
  return r < 0 ? -errno : 0;
}

void hdb_close(hdb_buffer *b) {
  if (b && b->fd >= 0) close(b->fd);
  if (b) b->fd = -1;
}
C

cat > "$SRC/hdb-test.c" <<'C'
#define _GNU_SOURCE
#include "hybris-dmabuf.h"
#include <errno.h>
#include <fcntl.h>
#include <stdio.h>
#include <string.h>
#include <sys/mman.h>
#include <unistd.h>

#define CHECK(x) do { if (!(x)) { printf("GAGAL: %s (baris %d)\n", #x, __LINE__); return 1; } } while (0)

int main(void) {
  int mfd = memfd_create("hdb-test", MFD_CLOEXEC);
  CHECK(mfd >= 0);
  CHECK(ftruncate(mfd, 64 * 32 * 4) == 0);

  int raw[4] = { 0, 1, 0, mfd };               /* version, numFds, numInts, data[0] */
  const hdb_native_handle *h = (const hdb_native_handle *)raw;
  hdb_buffer b;
  CHECK(hdb_from_native_handle(h, 0, 64, 32, 64, 1, &b) == 0);
  CHECK(b.fd != mfd && b.stride_bytes == 256 && b.size == 8192);
  CHECK(b.fourcc == (uint32_t)('A' | 'B' << 8 | '2' << 16 | '4' << 24));

  unsigned char *w = hdb_map(&b, 1);
  CHECK(w != NULL);
  for (size_t i = 0; i < b.size; i++) w[i] = (unsigned char)(i * 7);
  CHECK(hdb_unmap(&b, w, 1) == 0);

  const unsigned char *r = hdb_map(&b, 0);
  CHECK(r != NULL);
  for (size_t i = 0; i < b.size; i++) CHECK(r[i] == (unsigned char)(i * 7));
  CHECK(hdb_unmap(&b, (void *)r, 0) == 0);

  CHECK(hdb_from_native_handle(h, 0, 64, 32, 64, 0x7fff, &b) == -ENOTSUP);
  CHECK(hdb_from_native_handle(h, 3, 64, 32, 64, 1, &b) == -EINVAL);
  CHECK(hdb_wait_fence(-1, 0) == 0);

  hdb_buffer c;
  CHECK(hdb_from_native_handle(h, 0, 64, 32, 64, 4, &c) == 0 && c.stride_bytes == 128);
  hdb_close(&c);
  hdb_close(&b);
  CHECK(b.fd == -1);
  printf("OK: dma-buf helper lulus tes\n");
  return 0;
}
C

CC=${CC:-clang}
$CC -O2 -fPIC -Wall -Wextra -I"$SRC" -shared -Wl,-soname,libhybris-dmabuf.so.1 \
    -o "$LIB/libhybris-dmabuf.so.1.0.0" "$SRC/hybris-dmabuf.c"
ln -sf libhybris-dmabuf.so.1.0.0 "$LIB/libhybris-dmabuf.so.1"
ln -sf libhybris-dmabuf.so.1     "$LIB/libhybris-dmabuf.so"
cp "$SRC/hybris-dmabuf.h" "$INC/"

cat > "$LIB/pkgconfig/hybris-dmabuf.pc" <<EOF
prefix=/usr
libdir=\${prefix}/lib/$MA
includedir=\${prefix}/include
Name: hybris-dmabuf
Description: Jembatan buffer gralloc ke dma-buf untuk jalur libhybris
Version: 1.0.0
Libs: -L\${libdir} -lhybris-dmabuf
Cflags: -I\${includedir}
EOF

$CC -O2 -Wall -I"$SRC" -o "$SRC/hdb-test" "$SRC/hdb-test.c" -L"$LIB" -lhybris-dmabuf
LD_LIBRARY_PATH="$LIB" "$SRC/hdb-test" | tee logs/dmabuf-test.log
echo "libhybris-dmabuf terpasang di $ROOT"
