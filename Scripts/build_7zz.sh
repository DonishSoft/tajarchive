#!/bin/bash
# Builds a universal (arm64 + x86_64) 7zz from the vendored 7-Zip source
# and installs it into the app bundle's Resources.
#
# The vendored source lives in Vendor/7zip-25.01-src (extracted from
# Vendor/7z2501-src.tar.xz, downloaded from https://www.7-zip.org/a/7z2501-src.tar.xz).
# Keeping it in-tree is also what LGPL requires of us: anyone receiving the app
# must be able to obtain the exact source of the bundled 7zz.

set -euo pipefail

PROJECT_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC_DIR="$PROJECT_ROOT/Vendor/7zip-25.01-src"
ALONE2="$SRC_DIR/CPP/7zip/Bundles/Alone2"
DEST="$PROJECT_ROOT/7-Zip/7-Zip/Resources/7zz"
TARBALL="$PROJECT_ROOT/Vendor/7z2501-src.tar.xz"
TARBALL_SHA256="ed087f83ee789c1ea5f39c464c55a5c9d4008deb0efe900814f2df262b82c36e"

die() { echo "❌ $*" >&2; exit 1; }

# Re-extract from the tarball if the source tree is missing
if [ ! -d "$ALONE2" ]; then
    [ -f "$TARBALL" ] || die "Neither source tree nor tarball found. Download it with:
    curl -O https://www.7-zip.org/a/7z2501-src.tar.xz   # into $PROJECT_ROOT/Vendor/"
    echo "📦 Extracting vendored source…"
    actual="$(shasum -a 256 "$TARBALL" | awk '{print $1}')"
    [ "$actual" = "$TARBALL_SHA256" ] || die "Tarball checksum mismatch.
    expected $TARBALL_SHA256
    actual   $actual"
    mkdir -p "$SRC_DIR"
    tar -xf "$TARBALL" -C "$SRC_DIR"
fi

cd "$ALONE2"
rm -rf b

# CFLAGS_WARN is emptied because upstream builds with -Weverything -Werror, and
# clang releases newer than the source add warnings (e.g. -Wswitch-default) that
# upstream code does not satisfy. This only relaxes warnings, not codegen.
echo "🔨 Building arm64…"
make -f ../../cmpl_mac_arm64.mak -j"$(sysctl -n hw.ncpu)" CFLAGS_WARN= > /tmp/7zz_arm64.log 2>&1 \
    || die "arm64 build failed — see /tmp/7zz_arm64.log"

echo "🔨 Building x86_64…"
make -f ../../cmpl_mac_x64.mak -j"$(sysctl -n hw.ncpu)" CFLAGS_WARN= > /tmp/7zz_x64.log 2>&1 \
    || die "x86_64 build failed — see /tmp/7zz_x64.log"

[ -f b/m_arm64/7zz ] || die "arm64 binary missing after build"
[ -f b/m_x64/7zz ] || die "x86_64 binary missing after build"

echo "🔗 Creating universal binary…"
lipo -create -output "$DEST" b/m_arm64/7zz b/m_x64/7zz
chmod +x "$DEST"
rm -rf b

echo "✅ Installed universal 7zz:"
lipo -info "$DEST"
"$DEST" | head -2
