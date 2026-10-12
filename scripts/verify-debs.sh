#!/usr/bin/env bash
set -euo pipefail
DIR="${1:?folder .deb}"
PKGS="${PKGS:-}"
fail=0
has() { case " $PKGS " in *" $1 "*) return 0;; *) return 1;; esac; }

for f in "$DIR"/*.deb; do
  echo "--- $(basename "$f")"
  arch=$(dpkg-deb -f "$f" Architecture)
  [[ "$arch" == "arm64" || "$arch" == "all" ]] || { echo "ARSITEKTUR SALAH: $arch"; fail=1; }
  ver=$(dpkg-deb -f "$f" Version)
  [[ "$ver" == *+hybris* ]] || { echo "VERSI TANPA +hybris: $ver"; fail=1; }
  if dpkg-deb -c "$f" | awk '$1 !~ /^d/ {print $6}' | grep -vE '^\./(usr|etc|lib)/'; then
    echo "PATH ANEH"; fail=1
  fi
done

apt-get install -y "$DIR"/*.deb
ldconfig

has libdrm && { ldconfig -p | grep -q libdrm.so.2 || { echo "HILANG: libdrm.so.2"; fail=1; }; }
if has libglvnd; then
  for l in libEGL.so.1 libGLX.so.0 libOpenGL.so.0; do
    ldconfig -p | grep -q "$l" || { echo "HILANG: $l"; fail=1; }
  done
fi
if has mesa; then
  ldconfig -p | grep -q libgbm.so.1 || { echo "HILANG: libgbm.so.1"; fail=1; }
  ls /usr/lib/aarch64-linux-gnu/dri/ | grep -q swrast_dri || { echo "swrast_dri HILANG"; fail=1; }
  ls /usr/lib/aarch64-linux-gnu/dri/ | grep -q kms_swrast || { echo "kms_swrast HILANG"; fail=1; }
fi
has libx11 && { ldconfig -p | grep -q libX11.so.6 || { echo "HILANG: libX11.so.6"; fail=1; }; }
has libxcb && { ldconfig -p | grep -q libxcb.so.1 || { echo "HILANG: libxcb.so.1"; fail=1; }; }
has vulkan-loader && { ldconfig -p | grep -q libvulkan.so.1 || { echo "HILANG: libvulkan.so.1"; fail=1; }; }
has ocl-icd && { ldconfig -p | grep -q libOpenCL.so.1 || { echo "HILANG: libOpenCL.so.1"; fail=1; }; }
has libva && { ldconfig -p | grep -q libva.so.2 || { echo "HILANG: libva.so.2"; fail=1; }; }
has libvdpau && { ldconfig -p | grep -q libvdpau.so.1 || { echo "HILANG: libvdpau.so.1"; fail=1; }; }

dpkg --audit && echo "dpkg OK" || fail=1
exit $fail
