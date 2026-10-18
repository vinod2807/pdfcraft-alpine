#!/bin/sh
# Build the upstream PdfCraft source and produce its Debian/Ubuntu package.
# This runs inside a glibc-based Rust container from build-debian.yml.
set -eu

UPSTREAM="${UPSTREAM:-storytold/pdfcraft}"
REF="${REF:-main}"
CRAFT_FONTS_REF="${CRAFT_FONTS_REF:-}"
BUILD_LABEL="${PDFCRAFT_BUILD_LABEL:-debian}"
WORK=/github/work
SRC="$WORK/src"
OUT=/github/out

echo "=== installing build dependencies ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl git build-essential cmake pkg-config \
  libwayland-dev libxkbcommon-dev libx11-dev libxrandr-dev libxi-dev \
  libxcursor-dev libegl1-mesa-dev libvulkan-dev
rm -rf /var/lib/apt/lists/*

echo "=== installing nfpm ==="
NFPM_VERSION="${NFPM_VERSION:-2.43.0}"
curl -fsSL "https://github.com/goreleaser/nfpm/releases/download/v${NFPM_VERSION}/nfpm_${NFPM_VERSION}_Linux_x86_64.tar.gz" \
  | tar -xz -C /usr/local/bin nfpm

mkdir -p "$WORK" "$OUT"
rm -rf "$SRC"
mkdir -p "$SRC"
git -C "$SRC" init -q
git -C "$SRC" remote add origin "https://github.com/$UPSTREAM.git"
git config --global --add safe.directory "$SRC"
git -C "$SRC" fetch --depth 1 -q origin "$REF"
git -C "$SRC" checkout -q FETCH_HEAD

if [ -n "$CRAFT_FONTS_REF" ]; then
  CRAFT_FONTS_DIR="$WORK/craft-fonts"
  git clone --depth 1 "https://github.com/storytold/craft-fonts.git" "$CRAFT_FONTS_DIR"
  git config --global --add safe.directory "$CRAFT_FONTS_DIR"
  git -C "$CRAFT_FONTS_DIR" fetch --depth 1 origin "$CRAFT_FONTS_REF"
  git -C "$CRAFT_FONTS_DIR" checkout -q FETCH_HEAD
  export CRAFT_FONTS_DIR
fi

export PDFCRAFT_BUILD_LABEL="$BUILD_LABEL"
export DIST="$OUT"
export CARGO_TARGET_DIR="$WORK/target"
mkdir -p "$CARGO_TARGET_DIR"

echo "=== building Debian package for $UPSTREAM @ $REF ==="
cd "$SRC"
packaging/linux/package.sh --formats deb

echo "=== verifying package ==="
DEB="$(find "$OUT" -maxdepth 1 -type f -name '*.deb' -print -quit)"
[ -n "$DEB" ] || { echo "error: no .deb was produced" >&2; exit 1; }
dpkg-deb --info "$DEB"
dpkg-deb --contents "$DEB" | grep -q '/usr/bin/pdfcraft$'
dpkg-deb --contents "$DEB" | grep -q '/usr/bin/pdfcraft-cli$'
sha256sum "$DEB" > "$OUT/SHA256SUMS"
ls -lh "$OUT"
