#!/bin/bash
# Build the iPhone/iPad libraries from pinned source releases for macOS 13, so
# the app runs on macOS 13 or later. Homebrew's bottles target the macOS
# version of the machine that built them and would raise the app's minimum.
#
# Installs into .build/deps (or $CITRUS_DEPS_PREFIX) for the host architecture.
# build-app.sh and Package.swift use that prefix when it exists.
set -euo pipefail
cd "$(dirname "$0")/.."

PREFIX="${CITRUS_DEPS_PREFIX:-$PWD/.build/deps}"
TARGET="${CITRUS_MIN_MACOS:-13.0}"
ARCH="$(uname -m)"
JOBS="$(sysctl -n hw.ncpu)"

# name|version|URL|SHA-256|license files
DEPENDENCIES=(
    "openssl|4.0.3|https://github.com/openssl/openssl/releases/download/openssl-4.0.3/openssl-4.0.3.tar.gz|325b5c806167c13b40b1ffeadfe0248197c00eccc4cf123ec1e28d2d2fd216d9|LICENSE.txt"
    "libplist|2.8.0|https://github.com/libimobiledevice/libplist/releases/download/2.8.0/libplist-2.8.0.tar.bz2|b1f59f7634c58b2481325a23ff4e3bf51574a42d868cbe466d2b39b04550752a|COPYING COPYING.LESSER"
    "libimobiledevice-glue|1.3.3|https://github.com/libimobiledevice/libimobiledevice-glue/releases/download/1.3.3/libimobiledevice-glue-1.3.3.tar.bz2|920ce01382a32695f49b23292b4979a03f0afd16c58e8755d8b7f41804acc1a9|COPYING"
    "libusbmuxd|2.1.1|https://github.com/libimobiledevice/libusbmuxd/releases/download/2.1.1/libusbmuxd-2.1.1.tar.bz2|5546f1aba1c3d1812c2b47d976312d00547d1044b84b6a461323c621f396efce|COPYING"
    "libtatsu|1.0.5|https://github.com/libimobiledevice/libtatsu/releases/download/1.0.5/libtatsu-1.0.5.tar.bz2|536fa228b14f156258e801a7f4d25a3a9dd91bb936bf6344e23171403c57e440|COPYING"
    "libimobiledevice|1.4.0|https://github.com/libimobiledevice/libimobiledevice/releases/download/1.4.0/libimobiledevice-1.4.0.tar.bz2|23cc0077e221c7d991bd0eb02150a0d49199bcca1ddf059edccee9ffd914939d|COPYING COPYING.LESSER"
)

# A rebuild only happens when this script (versions, flags) changes.
STAMP="$PREFIX/.citrus-deps-$(shasum -a 256 "$0" | cut -c1-16)-$ARCH-$TARGET"
if [ -f "$STAMP" ]; then
    echo "Dependencies up to date in $PREFIX"
    exit 0
fi
rm -rf "$PREFIX"
mkdir -p "$PREFIX"

export MACOSX_DEPLOYMENT_TARGET="$TARGET"
export CFLAGS="-mmacosx-version-min=$TARGET -arch $ARCH -O2"
export CXXFLAGS="$CFLAGS"
export LDFLAGS="-mmacosx-version-min=$TARGET -arch $ARCH"
# Only our own prefix: never pick up Homebrew's copies of these libraries.
export PKG_CONFIG_LIBDIR="$PREFIX/lib/pkgconfig"
unset PKG_CONFIG_PATH

WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT

for entry in "${DEPENDENCIES[@]}"; do
    IFS='|' read -r name version url sha licenses <<< "$entry"
    archive="$WORK/$(basename "$url")"
    echo "==> $name $version"
    curl --fail --location --silent --show-error --proto '=https' --output "$archive" "$url"
    echo "$sha  $archive" | shasum -a 256 --check --quiet
    mkdir "$WORK/$name"
    tar -xf "$archive" -C "$WORK/$name" --strip-components 1
    pushd "$WORK/$name" >/dev/null
    case "$name" in
        openssl)
            ./Configure "darwin64-$ARCH-cc" shared no-tests no-docs no-apps \
                --prefix="$PREFIX" --libdir=lib "-mmacosx-version-min=$TARGET" >/dev/null
            make -j"$JOBS" >/dev/null
            make install_sw >/dev/null
            ;;
        libtatsu)
            # macOS ships libcurl without a pkg-config file.
            libcurl_CFLAGS="-I$(xcrun --show-sdk-path)/usr/include" libcurl_LIBS="-lcurl" ./configure --prefix="$PREFIX" --disable-static \
                --disable-silent-rules >/dev/null
            make -j"$JOBS" >/dev/null
            make install >/dev/null
            ;;
        *)
            ./configure --prefix="$PREFIX" --disable-static --without-cython \
                --disable-silent-rules >/dev/null
            make -j"$JOBS" >/dev/null
            make install >/dev/null
            ;;
    esac

    # License notices and an SPDX source record, read by build-app.sh and
    # collect-release-sources.py for the release's source archive.
    notices="$PREFIX/share/citrus-notices/$name-$version"
    mkdir -p "$notices"
    for file in $licenses; do cp "$file" "$notices/"; done
    cat > "$notices/sbom.spdx.json" <<JSON
{
  "spdxVersion": "SPDX-2.3",
  "name": "$name-$version",
  "packages": [
    {
      "SPDXID": "SPDXRef-Archive-$name-src",
      "name": "$name",
      "versionInfo": "$version",
      "downloadLocation": "$url",
      "checksums": [{ "algorithm": "SHA256", "checksumValue": "$sha" }]
    }
  ]
}
JSON
    popd >/dev/null
done

# Install names must be absolute paths into the prefix so build-app.sh can find
# and bundle each library.
for lib in "$PREFIX"/lib/*.dylib; do
    [ -L "$lib" ] || install_name_tool -id "$lib" "$lib"
done

touch "$STAMP"
echo "Built dependencies for macOS $TARGET ($ARCH) in $PREFIX"
