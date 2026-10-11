#!/usr/bin/env bash
set -euo pipefail
A="$1"; ROOT="$PWD"; W="$ROOT/work"; H="$W/headers"; P="$W/pkg"
git clone --depth 1 "$LIBHYBRIS_URL" "$W/libhybris"
cd "$W/libhybris/hybris"
find . -name Makefile.am -exec sed -i 's/-std=gnu++11/-std=gnu++17/g' {} +
export CC=clang CXX=clang++
export CPPFLAGS="-I$H/include -idirafter $H/bionic-include"
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
cat > "$H/include/android-config.h" <<EOF
#ifndef ANDROID_CONFIG_H
#define ANDROID_CONFIG_H
#define ANDROID_VERSION_MAJOR $A
#define ANDROID_VERSION_MINOR 0
#define ANDROID_VERSION_PATCH 0
#endif
EOF
autoreconf -fi
./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu \
  --enable-arch=arm64 --enable-property-cache --disable-wayland \
  --with-android-headers="$H/include" \
  --with-default-hybris-ld-library-path=/system/lib64:/odm/lib64:/vendor/lib64 \
  || { tail -60 config.log; exit 1; }
  make -j"$(nproc)" || {
  echo "=== ERROR DETAIL ==="
  make -j1 2>&1 | grep -B3 -A8 "error:" | head -100
  exit 1
}
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
