#!/usr/bin/env bash
set -euo pipefail

A="$1"
ROOT="$PWD"
W="$ROOT/work"
H="$W/headers"
P="$W/pkg"

git clone --depth 1 "${LIBHYBRIS_URL:-https://github.com/libhybris/libhybris}" "$W/libhybris"
cd "$W/libhybris/hybris"

find . -name Makefile.am -exec sed -i 's/-std=gnu++11/-std=gnu++17/g' {} +

L=common/q/linker.cpp
cat > /tmp/join_helper.txt <<'EOF'
#include <string>
#include <vector>
static inline std::string hybris_join_paths_(const std::vector<std::string>& v, const char* sep = ":") {
  std::string r;
  for (size_t i = 0; i < v.size(); ++i) { if (i) r += sep; r += v[i]; }
  return r;
}
EOF
N=$(grep -n '^#include' "$L" | head -1 | cut -d: -f1)
sed -i "${N}r /tmp/join_helper.txt" "$L"
sed -i -E '/TRACE\(/s/((ns|needed_by)->get_(ld_library_paths|default_library_paths|dt_runpath)\(\))/hybris_join_paths_(\1, ":").c_str()/g' "$L"
sed -i 's|^//[[:space:]]*#include "android-base/strings.h"|#include "android-base/strings.h"|' "$L"

S=common/q/bionic/libc/include/android-base/strings.h
if [ -f "$S" ] && ! grep -q '<string_view>' "$S"; then
  sed -i '0,/#include/s//#include <string_view>\n#include/' "$S"
fi
grep -n "hybris_join_paths_" "$L" | head

for f in $(find . -name hooks.c); do
  if grep -q '__vsprintf_chk' "$f" && ! grep -q 'hybris_chk_decl' "$f"; then
    sed -i '1i /* hybris_chk_decl */\nextern int __vsprintf_chk(char *, int, unsigned long, const char *, __builtin_va_list);\nextern int __vsnprintf_chk(char *, unsigned long, int, unsigned long, const char *, __builtin_va_list);' "$f"
  fi
done

cat > "$H/include/android-config.h" <<EOF
#ifndef ANDROID_CONFIG_H
#define ANDROID_CONFIG_H
#define ANDROID_VERSION_MAJOR $A
#define ANDROID_VERSION_MINOR 0
#define ANDROID_VERSION_PATCH 0
#endif
EOF

cat > "$H/include/android-version.h" <<EOF
#ifndef ANDROID_VERSION_H
#define ANDROID_VERSION_H
#ifndef ANDROID_VERSION_MAJOR
#define ANDROID_VERSION_MAJOR $A
#endif
#ifndef ANDROID_VERSION_MINOR
#define ANDROID_VERSION_MINOR 0
#endif
#ifndef ANDROID_VERSION_PATCH
#define ANDROID_VERSION_PATCH 0
#endif
#endif
EOF

mkdir -p "$H/include/sys"
cat > "$H/include/sys/cdefs.h" <<'EOF'
#include_next <sys/cdefs.h>
#ifndef __INTRODUCED_IN
#define __INTRODUCED_IN(x)
#define __INTRODUCED_IN_32(x)
#define __INTRODUCED_IN_64(x)
#define __INTRODUCED_IN_ARM(x)
#define __INTRODUCED_IN_X86(x)
#define __DEPRECATED_IN(...)
#define __REMOVED_IN(...)
#define __BIONIC_AVAILABILITY_GUARD(x) 1
#endif
EOF

export CC=clang CXX=clang++
export CPPFLAGS="-I$H/include -idirafter $H/bionic-include \
  -DEGL_WAYLAND_BUFFER_WL=0x31D5 -DEGL_TEXTURE_EXTERNAL_WL=0x31DA"
export CFLAGS="-g -O2 -Wno-error=implicit-function-declaration"

autoreconf -fi
./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu \
  --enable-arch=arm64 --enable-property-cache --enable-wayland \
  --with-android-headers="$H/include" \
  --with-default-hybris-ld-library-path=/system/lib64:/odm/lib64:/vendor/lib64 \
  || { tail -60 config.log; exit 1; }

make -j"$(nproc)" || {
  echo "=== ERROR DETAIL ==="
  make -j1 -k 2>&1 | grep -E "error:|fatal error|undefined reference|cannot find" | sort -u | head -40
  exit 1
}

make install DESTDIR="$P"
mkdir -p "$P/DEBIAN" "$ROOT/dist"
cat > "$P/DEBIAN/control" <<EOF
Package: libhybris-headless-android$A
Version: 0.1
Architecture: arm64
Maintainer: you
Description: libhybris headless untuk Android $A
EOF
dpkg-deb --build "$P" "$ROOT/dist/libhybris-headless-android${A}_0.1_arm64.deb"
