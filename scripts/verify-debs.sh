#!/usr/bin/env bash
set -euo pipefail
DIR="${1:?folder .deb}"
fail=0

for f in "$DIR"/*.deb; do
  echo "--- $(basename "$f")"
  # 1. arsitektur harus arm64
  arch=$(dpkg-deb -f "$f" Architecture)
  [[ "$arch" == "arm64" || "$arch" == "all" ]] || { echo "ARSITEKTUR SALAH: $arch"; fail=1; }

  # 2. versi harus memuat +hybris
  ver=$(dpkg-deb -f "$f" Version)
  [[ "$ver" == *+hybris* ]] || { echo "VERSI TANPA +hybris: $ver"; fail=1; }

  # 3. tidak boleh ada file di luar path yang diharapkan
  dpkg-deb -c "$f" | awk '{print $6}' | grep -vE '^\./(usr|etc|lib)/' \
    && { echo "PATH ANEH"; fail=1; } || true
done

# 4. cek stack setelah dipasang
apt-get install -y "$DIR"/*.deb
ldconfig
for l in libEGL.so.1 libGLX.so.0 libgbm.so.1 libdrm.so.2 libvulkan.so.1; do
  ldconfig -p | grep -q "$l" || { echo "HILANG: $l"; fail=1; }
done
# 5. driver CPU harus ada
ls /usr/lib/aarch64-linux-gnu/dri/ | grep -q swrast_dri || { echo "swrast_dri HILANG"; fail=1; }
ls /usr/lib/aarch64-linux-gnu/dri/ | grep -q kms_swrast || { echo "kms_swrast HILANG"; fail=1; }
# 6. dpkg tidak boleh rusak
dpkg --audit && echo "dpkg OK" || fail=1

exit $fail
