#!/usr/bin/env bash
set -euo pipefail

A="$1"
ROOT="$PWD"
W="$ROOT/work"
H="$W/headers"
P="$W/pkg"

# 1. Ambil source libhybris
git clone --depth 1 "${LIBHYBRIS_URL:-https://github.com/libhybris/libhybris}" "$W/libhybris"
cd "$W/libhybris/hybris"

# 2. Paksa C++17 (android-base butuh std::string_view)
find . -name Makefile.am -exec sed -i 's/-std=gnu++11/-std=gnu++17/g' {} +

# 3. Patch linker.cpp (common/q)
L=common/q/linker.cpp

# 3a. fungsi bantu pengganti Join, disisipkan setelah #include pertama
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

# 3b. bungkus argumen vector<string> di TRACE
sed -i -E '/TRACE\(/s/((ns|needed_by)->get_(ld_library_paths|default_library_paths|dt_runpath)\(\))/hybris_join_paths_(\1, ":").c_str()/g' "$L"

# 3c. aktifkan include android-base/strings.h bila masih dikomentari
sed -i 's|^//[[:space:]]*#include "android-base/strings.h"|#include "android-base/strings.h"|' "$L"

# 3d. std::string_view butuh header ini
S=common/q/bionic/libc/include/android-base/strings.h
if [ -f "$S" ] && ! grep -q '<string_view>' "$S"; then
  sed -i '0,/#include/s//#include <string_view>\n#include/' "$S"
fi
grep -n "hybris_join_paths_" "$L" | head

# 4. Penanda versi Android yang diminta configure
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

# 5. Configure
export CC=clang CXX=clang++
export CPPFLAGS="-I$H/include -idirafter $H/bionic-include"

cat > /tmp/hybris_chk.h <<'EOF'
#include <stdio.h>
#include <stdarg.h>
#include <stddef.h>
extern int __vsprintf_chk(char *, int, size_t, const char *, va_list);
extern int __vsnprintf_chk(char *, size_t, int, size_t, const char *, va_list);
EOF
export CFLAGS="-g -O2 -include /tmp/hybris_chk.h -Wno-error=implicit-function-declaration"

autoreconf -fi
./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu \
  --enable-arch=arm64 --enable-property-cache --disable-wayland \
  --with-android-headers="$H/include" \
  --with-default-hybris-ld-library-path=/system/lib64:/odm/lib64:/vendor/lib64 \
  || { tail -60 config.log; exit 1; }

# 6. Compile
make -j"$(nproc)" || {
  echo "=== ERROR DETAIL ==="
  make -j1 2>&1 | grep -B3 -A8 "error:" | head -100
  exit 1
}

# 7. Install ke staging lalu bungkus .deb
make install DESTDIR="$P"
mkdir -p "$P/DEBIAN" "$ROOT/dist"
cat > "$P/DEBIAN/control" <<EOF
Package: libhybris-headless-android$A
Version: 0.1
Architecture: arm64
Maintainer: you
Description: libhybris headless (tanpa hwcomposer/wayland) untuk Android $A
EOF
dpkg-deb --build "$P" "$ROOT/dist/libhybris-headless-android${A}_0.1_arm64.deb"
