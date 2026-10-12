#!/usr/bin/env bash
set -uo pipefail
PKGS="${PKGS:?isi PKGS}"
OUT="${OUT:-$PWD/out-ubuntu}"
SUFFIX="+hybris1"
mkdir -p "$OUT" /tmp/rb
cd /tmp/rb

if [ -f /etc/apt/sources.list.d/ubuntu.sources ]; then
  sed -i 's/^Types: deb$/Types: deb deb-src/' /etc/apt/sources.list.d/ubuntu.sources
else
  sed -i 's/^# *deb-src/deb-src/' /etc/apt/sources.list
fi
apt-get update
apt-get install -y --no-install-recommends devscripts build-essential \
  fakeroot equivs ca-certificates lsb-release || exit 1

build_one() {
  local p="$1" d ver
  rm -rf "/tmp/rb/$p" && mkdir -p "/tmp/rb/$p" && cd "/tmp/rb/$p" || return 1
  apt-get source "$p" || return 1
  d=$(find . -maxdepth 1 -mindepth 1 -type d | head -1)
  [ -n "$d" ] || return 1
  (cd "$d" && mk-build-deps -i -r -t "apt-get -y --no-install-recommends" debian/control) || return 1
  cd "$d" || return 1
  ver=$(dpkg-parsechangelog -S Version)
  dch -b -v "${ver}${SUFFIX}" -D "$(lsb_release -sc)" "Rebuild CI (stack render hybris)" || return 1
  DEB_BUILD_OPTIONS="nocheck parallel=$(nproc)" dpkg-buildpackage -us -uc -b || return 1
  cd .. && cp ./*.deb "$OUT"/ || return 1
  apt-get install -y --allow-downgrades ./*.deb || true
}

GAGAL=""
for p in $PKGS; do
  echo "=== $p ==="
  ( build_one "$p" ) || { echo "GAGAL: $p"; GAGAL="$GAGAL $p"; }
done
ls -lh "$OUT"
[ -z "$GAGAL" ] || { echo "Paket gagal:$GAGAL"; exit 1; }
