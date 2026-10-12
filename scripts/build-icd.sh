#!/usr/bin/env bash
set -euo pipefail

A="$1"
ROOT="$PWD"
W="$ROOT/work"
H="$W/headers"
P="$W/pkg"
PI="$W/pkg-icd"
LIBDIR=usr/lib/aarch64-linux-gnu

mkdir -p "$PI/$LIBDIR" "$PI/usr/share/vulkan/icd.d" "$PI/DEBIAN" "$ROOT/dist"

ls "$P/$LIBDIR" | grep -i hardware || true
clang -shared -fPIC -O2 -Wall -I"$H/include" "$ROOT/icd/icd.c" \
  -o "$PI/$LIBDIR/libvulkan_hybris.so" \
  -L"$P/$LIBDIR" -Wl,-rpath-link,"$P/$LIBDIR" -lhardware

cat > "$PI/usr/share/vulkan/icd.d/hybris.json" <<'EOF'
{"file_format_version":"1.0.0","ICD":{"library_path":"libvulkan_hybris.so","api_version":"1.1.0"}}
EOF

cat > "$PI/DEBIAN/control" <<EOF
Package: libvulkan-hybris-icd-android$A
Version: 0.1
Architecture: arm64
Depends: libhybris-headless-android$A, libvulkan1
Maintainer: you
Description: ICD Vulkan glibc untuk HAL hwvulkan Android $A via libhybris
EOF

dpkg-deb --build "$PI" "$ROOT/dist/libvulkan-hybris-icd-android${A}_0.1_arm64.deb"
