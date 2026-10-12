#!/usr/bin/env bash
# Rebuild paket render Ubuntu dari source Ubuntu sendiri, versi dinaikkan (+hybris1)
set -euo pipefail

PKGS="${PKGS:-libdrm libglvnd mesa}"
OUT="${OUT:-$PWD/out-ubuntu}"
SUFFIX="+hybris1"
mkdir -p "$OUT" /tmp/rb && cd /tmp/rb

# deb-src harus aktif
if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
else
  sed -i 's/^# *deb-src/deb-src/' /etc/apt/sources.list
fi
apt-get update
apt-get install -y --no-install-recommends devscripts build-essential \
  fakeroot equivs ca-certificates

for p in $PKGS; do
  echo "=== $p ==="
  rm -rf "$p-src" && mkdir "$p-src" && cd "$p-src"
  apt-get source "$p"
  d=$(find . -maxdepth 1 -mindepth 1 -type d | head -1)
  mk-build-deps -i -r -t "apt-get -y --no-install-recommends" "$d/debian/control"
  cd "$d"
  ver=$(dpkg-parsechangelog -S Version)
  dch -b -v "${ver}${SUFFIX}" -D "$(lsb_release -sc)" \
    "Rebuild di CI untuk stack render hybris (GPU + CPU)."
  # Mesa: matikan test berat agar CI tidak kehabisan waktu
  export DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)"
  dpkg-buildpackage -us -uc -b
  cd ../..
  cp "$p-src"/*.deb "$OUT"/ 2>/dev/null || true
  # paket -dev/-dbgsym ikut agar dependensi build berikutnya terpenuhi
  apt-get install -y "$OUT"/*.deb || true
done
ls -lh "$OUT"
