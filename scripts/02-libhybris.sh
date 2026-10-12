#!/usr/bin/env bash
set -euo pipefail
: "${STAGE:?}" "${ANDROID_VERSION:?}"

HDR="$STAGE/android-headers"
BIONIC="$STAGE/bionic-include"
SRC="$STAGE/libhybris-src"
DEST="$STAGE/libhybris-root"
mkdir -p "$DEST" logs

git clone --depth 1 https://github.com/libhybris/libhybris "$SRC"

# Patch dari repo (hasil patch lama disimpan di patches/libhybris/*.patch)
for p in "$GITHUB_WORKSPACE"/patches/libhybris/*.patch; do
  if [ -e "$p" ]; then
    echo "Patch: $p"
    patch -p1 -d "$SRC" < "$p"
  fi
done

cd "$SRC/hybris"

# Linker q butuh std::string_view, jadi paksa C++17
grep -rl -- '-std=gnu++11' --include=Makefile.am --include=configure.ac . \
  | xargs -r sed -i 's/-std=gnu++11/-std=gnu++17/g'

"$GITHUB_WORKSPACE/scripts/patch-libhybris.sh" "$SRC/hybris"

autoreconf -fi 2>&1 | tee ../../logs/libhybris-autoreconf.log

export CC=clang CXX=clang++
# -idirafter: header glibc/libstdc++ diprioritaskan, bionic hanya cadangan
export CPPFLAGS="-idirafter $BIONIC -idirafter $HDR"
export CXXFLAGS="-std=gnu++17 -Wno-error"

./configure \
  --prefix=/usr \
  --libdir=/usr/lib/aarch64-linux-gnu \
  --enable-arch=arm64 \
  --enable-property-cache \
  --enable-experimental \
  --with-android-headers="$HDR" \
  --with-default-hybris-ld-library-path=/system/lib64:/odm/lib64:/vendor/lib64 \
  2>&1 | tee ../../logs/libhybris-configure.log

make -j"$(nproc)" 2>&1 | tee ../../logs/libhybris-make.log
make install DESTDIR="$DEST" 2>&1 | tee ../../logs/libhybris-install.log

# pemeriksaan hasil
compgen -G "$DEST/usr/lib/aarch64-linux-gnu/libhybris-common.so*" >/dev/null \
  || { echo "GAGAL: libhybris-common tidak terbentuk"; exit 1; }
echo "libhybris terpasang di $DEST"
find "$DEST" -name '*.so*' | sort
