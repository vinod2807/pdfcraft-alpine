#!/bin/sh
# Builds PdfCraft for Alpine Linux (x86_64, musl) inside a rust:alpine container.
# Invoked by .github/workflows/build.yml. Everything here runs *inside* the container.
#
# Environment (set by the workflow):
#   UPSTREAM          owner/name of the upstream repository to build
#   REF               branch name or commit SHA to build
#   CRAFT_FONTS_REF   optional storytold/craft-fonts commit (empty to skip)
#   PDFCRAFT_BUILD_LABEL  build label compiled into `--version`
#   CARGO_HOME, CARGO_TARGET_DIR  point at bind mounts on the host (for caching)
set -eu

UPSTREAM="${UPSTREAM:?UPSTREAM is required}"
REF="${REF:?REF is required}"
CRAFT_FONTS_REF="${CRAFT_FONTS_REF:-}"

WORK=/github/work
SRC="$WORK/src"
OUT=/github/out
STAGE="$WORK/stage"

echo "=== container ==="
echo "alpine: $(cat /etc/alpine-release)"
rustc -V
cargo -V

echo "=== installing build dependencies ==="
# curl is not in the rust:alpine image and `cargo xtask models` shells out to it.
apk add --no-cache \
  build-base binutils cmake perl pkgconf git ca-certificates curl \
  linux-headers \
  wayland-dev wayland-protocols libxkbcommon-dev \
  libx11-dev libxrandr-dev libxi-dev libxcursor-dev \
  mesa-dev

echo "=== fetching $UPSTREAM @ $REF ==="
# Reuse a cached checkout when possible: a fresh clone gives every source file a
# new mtime, which makes cargo rebuild the whole graph and throws the target
# cache away. Reusing it keeps mtimes stable, so only real changes recompile.
EXPECTED_REMOTE="https://github.com/${UPSTREAM}.git"
if [ -d "$SRC/.git" ] && [ "$(git -C "$SRC" remote get-url origin 2>/dev/null || true)" = "$EXPECTED_REMOTE" ]; then
  echo "reusing the cached checkout"
else
  rm -rf "$SRC"
  mkdir -p "$SRC"
  git init -q "$SRC"
  git -C "$SRC" remote add origin "$EXPECTED_REMOTE"
fi
if ! git -C "$SRC" fetch --depth 1 -q origin "$REF"; then
  echo "ERROR: could not fetch '$REF' from $UPSTREAM" >&2
  exit 1
fi
git -C "$SRC" checkout -q FETCH_HEAD
if [ -n "$(git -C "$SRC" status --porcelain)" ]; then
  echo "WARNING: the cached checkout was dirty; resetting it" >&2
  git -C "$SRC" reset -q --hard FETCH_HEAD
  git -C "$SRC" clean -qfd
fi
UPSTREAM_SHA="$(git -C "$SRC" rev-parse HEAD)"
echo "upstream commit: $UPSTREAM_SHA"

# Optional craft-fonts build input (public repo): embeds Japanese/Arabic faces.
if [ -n "$CRAFT_FONTS_REF" ]; then
  CF="$WORK/craft-fonts"
  CF_REMOTE=https://github.com/storytold/craft-fonts.git
  # Reused for the same mtime reason as the source checkout above.
  if [ -d "$CF/.git" ] && [ "$(git -C "$CF" remote get-url origin 2>/dev/null || true)" = "$CF_REMOTE" ]; then
    echo "reusing the cached craft-fonts checkout"
  else
    rm -rf "$CF"
    mkdir -p "$CF"
    git init -q "$CF"
    git -C "$CF" remote add origin "$CF_REMOTE"
  fi
  if git -C "$CF" fetch --depth 1 -q origin "$CRAFT_FONTS_REF"; then
    git -C "$CF" checkout -q FETCH_HEAD
    CRAFT_FONTS_DIR="$CF"
    export CRAFT_FONTS_DIR
    echo "craft-fonts: $(git -C "$CF" rev-parse HEAD)"
  else
    echo "WARNING: craft-fonts fetch failed; building without the Japanese/Arabic faces" >&2
  fi
fi

VERSION="$(awk '/^\[/ { in_pkg = ($0 == "[workspace.package]"); next } in_pkg && $1 == "version" { gsub(/[" ]/, "", $3); print $3; exit }' "$SRC/Cargo.toml")"
[ -n "$VERSION" ] || { echo "ERROR: could not read the version from Cargo.toml" >&2; exit 1; }
echo "version: $VERSION"

echo "=== cargo build (release, musl) ==="
cd "$SRC"
cargo build --release --locked -p pdfcraft -p pdfcraft-cli

BIN="${CARGO_TARGET_DIR:-$SRC/target}/release"
[ -x "$BIN/pdfcraft" ] || { echo "ERROR: $BIN/pdfcraft was not produced" >&2; exit 1; }
[ -x "$BIN/pdfcraft-cli" ] || { echo "ERROR: $BIN/pdfcraft-cli was not produced" >&2; exit 1; }

echo "=== smoke test (does the musl binary run?) ==="
"$BIN/pdfcraft-cli" --version

echo "=== staging the install tree ==="
rm -rf "$STAGE" "$OUT"
PKG="pdfcraft-$VERSION-alpine-x86_64"
ROOT="$STAGE/$PKG"
mkdir -p "$ROOT/usr/bin" \
         "$ROOT/usr/share/applications" \
         "$ROOT/usr/share/mime/packages" \
         "$ROOT/usr/share/metainfo" \
         "$ROOT/usr/share/icons" \
         "$ROOT/usr/share/doc/pdfcraft" \
         "$ROOT/usr/share/pdfcraft/models"

cp "$BIN/pdfcraft" "$BIN/pdfcraft-cli" "$ROOT/usr/bin/"
strip "$ROOT/usr/bin/pdfcraft" "$ROOT/usr/bin/pdfcraft-cli" 2>/dev/null || true
chmod 755 "$ROOT/usr/bin/pdfcraft" "$ROOT/usr/bin/pdfcraft-cli"

cp "$SRC/packaging/linux/ai.storyteller.pdfcraft.desktop" \
   "$ROOT/usr/share/applications/ai.storyteller.pdfcraft.desktop"
cp "$SRC/packaging/linux/ai.storyteller.pdfcraft.mime.xml" \
   "$ROOT/usr/share/mime/packages/ai.storyteller.pdfcraft.xml"
sed -e "s/@VERSION@/$VERSION/g" -e "s/@DATE@/$(date -u +%Y-%m-%d)/g" \
   "$SRC/packaging/linux/ai.storyteller.pdfcraft.metainfo.xml.in" \
   > "$ROOT/usr/share/metainfo/ai.storyteller.pdfcraft.metainfo.xml"
cp -R "$SRC/assets/app-icon/hicolor" "$ROOT/usr/share/icons/hicolor"

for f in README.md LICENSE LICENSE-MIT LICENSE-APACHE NOTICE ATTRIBUTION.md; do
  [ -f "$SRC/$f" ] && cp "$SRC/$f" "$ROOT/usr/share/doc/pdfcraft/"
done
if [ -n "${CRAFT_FONTS_DIR:-}" ]; then
  for f in "$CRAFT_FONTS_DIR"/fonts/*/OFL.txt; do
    [ -f "$f" ] || continue
    cp "$f" "$ROOT/usr/share/doc/pdfcraft/OFL-$(basename "$(dirname "$f")").txt"
  done
fi

echo "=== fetching OCR models (Scan & OCR) ==="
if (cd "$SRC" && cargo run --release -p xtask -- models "$ROOT/usr/share/pdfcraft/models"); then
  rm -f "$ROOT/usr/share/pdfcraft/models"/*.part
else
  echo "WARNING: OCR model download failed; Scan & OCR will be unavailable" >&2
  rmdir "$ROOT/usr/share/pdfcraft/models" 2>/dev/null || true
fi

echo "=== build info ==="
mkdir -p "$OUT"
{
  echo "PdfCraft $VERSION — unofficial Alpine Linux (musl) build"
  echo
  echo "upstream : https://github.com/$UPSTREAM"
  echo "ref      : $REF"
  echo "commit   : $UPSTREAM_SHA"
  echo "built on : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rustc    : $(rustc -V)"
  echo "alpine   : $(cat /etc/alpine-release)"
  echo "libc     : musl (statically linked against musl; system libs are loaded at runtime)"
  echo
  echo "ELF dependencies of usr/bin/pdfcraft:"
  readelf -d "$ROOT/usr/bin/pdfcraft" | grep NEEDED || true
  echo
  echo "ELF dependencies of usr/bin/pdfcraft-cli:"
  readelf -d "$ROOT/usr/bin/pdfcraft-cli" | grep NEEDED || true
} > "$OUT/BUILD-INFO.txt"
cp "$OUT/BUILD-INFO.txt" "$ROOT/BUILD-INFO.txt"
cp /github/scripts/INSTALL.txt "$ROOT/INSTALL.txt"

echo "=== packaging ==="
cp "$ROOT/usr/bin/pdfcraft" "$OUT/pdfcraft-$VERSION-alpine-x86_64"
cp "$ROOT/usr/bin/pdfcraft-cli" "$OUT/pdfcraft-cli-$VERSION-alpine-x86_64"
tar -C "$STAGE" -czf "$OUT/$PKG.tar.gz" "$PKG"

cd "$OUT"
sha256sum "$PKG.tar.gz" "pdfcraft-$VERSION-alpine-x86_64" "pdfcraft-cli-$VERSION-alpine-x86_64" > SHA256SUMS
echo "=== done ==="
ls -l
cat SHA256SUMS
