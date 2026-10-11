#!/usr/bin/env bash
set -euo pipefail
A="$1"; ROOT="$PWD"; W="$ROOT/work"; H="$W/headers"; P="$W/pkg"
git clone --depth 1 "$LIBHYBRIS_URL" "$W/libhybris"
cd "$W/libhybris/hybris"
find . -name Makefile.am -exec sed -i 's/-std=gnu++11/-std=gnu++17/g' {} +
export CC=clang CXX=clang++
export CPPFLAGS="-I$H/include -idirafter $H/bionic-include"
autoreconf -fi
./configure --prefix=/usr --libdir=/usr/lib/aarch64-linux-gnu \
  --enable-arch=arm64 --enable-property-cache --disable-wayland \
  --with-android-headers="$H/include" \
  --with-default-hybris-ld-library-path=/system/lib64:/odm/lib64:/vendor/lib64 \
  || { tail -60 config.log; exit 1; }
make -j"$(nproc)"
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
