#!/bin/sh
# Builds PdfCraft for Alpine Linux (x86_64, musl) inside a rust:alpine container.
# Invoked by .github/workflows/build.yml. Everything here runs *inside* the container.
#
# Environment (set by the workflow):
#   UPSTREAM          owner/name of the upstream repository to build
#   REF               branch name or commit SHA to build
#   TRACK_UPSTREAM_PR build PR_NUMBER while it is open, else the latest BASE_REPO release
#   BASE_REPO         upstream repository whose latest release is tracked
#   PR_NUMBER         pull request whose head is built while it is open
#   CRAFT_FONTS_REF   optional storytold/craft-fonts commit (empty to skip)
#   PDFCRAFT_BUILD_LABEL  build label compiled into `--version`
#   CARGO_HOME, CARGO_TARGET_DIR  point at bind mounts on the host (for caching)
set -eu

UPSTREAM="${UPSTREAM:?UPSTREAM is required}"
REF="${REF:?REF is required}"
TRACK_UPSTREAM_PR="${TRACK_UPSTREAM_PR:-false}"
BASE_REPO="${BASE_REPO:-storytold/pdfcraft}"
PR_NUMBER="${PR_NUMBER:-2808}"
CRAFT_FONTS_REF="${CRAFT_FONTS_REF:-}"
# Resolved by the workflow's plan job; empty for a standalone run.
BASE_TAG="${BASE_TAG:-}"
PR_SHA="${PR_SHA:-}"
PR_REPO="${PR_REPO:-}"
PR_REF="${PR_REF:-}"
PR_OPEN="${PR_OPEN:-false}"

# Authenticate API requests when a token is available: the unauthenticated
# limit (60 requests/hour per IP) is regularly exhausted on shared runners.
api_get() {
  if [ -n "${GH_TOKEN:-}" ]; then
    curl -fsSL -H "Authorization: Bearer $GH_TOKEN" "$1"
  else
    curl -fsSL "$1"
  fi
}

# Upstream downloads its OCR models from an S3 bucket that now answers 403
# AccessDenied. Fetch the exact pinned files from mirrors instead, verify each
# against the SHA-256 in ATTRIBUTION.toml, and point the manifest at the
# verified local copies. `cargo xtask models` still checks the same hashes, so
# a mirror cannot substitute different weights.
prefetch_ocr_models() {
  _src="$1"
  _cache="$2"
  _upstream="${3:-}"
  _version="${4:-}"
  mkdir -p "$_cache"
  awk '
    /^\[\[fetched\]\]/ { file=""; sha=""; url=""; kind=""; inblk=1; next }
    inblk && /^file = /   { v=$0; sub(/^file = "/, "", v);   sub(/"$/, "", v); file=v }
    inblk && /^url = /    { v=$0; sub(/^url = "/, "", v);    sub(/"$/, "", v); url=v }
    inblk && /^sha256 = / { v=$0; sub(/^sha256 = "/, "", v); sub(/"$/, "", v); sha=v }
    inblk && /^kind = /   { v=$0; sub(/^kind = "/, "", v);   sub(/"$/, "", v); kind=v }
    inblk && /^$/ { if (kind == "model" && file != "" && sha != "") printf "%s\t%s\t%s\n", file, sha, url; inblk=0 }
    END { if (inblk && kind == "model" && file != "" && sha != "") printf "%s\t%s\t%s\n", file, sha, url }
  ' "$_src/ATTRIBUTION.toml" >"$_cache/.entries"
  if [ ! -s "$_cache/.entries" ]; then
    echo "error: no OCR model entries in $_src/ATTRIBUTION.toml" >&2
    return 1
  fi
  while IFS="$(printf '\t')" read -r _file _sha _url; do
    _dest="$_cache/$_file"
    if [ -f "$_dest" ] && [ "$(sha256sum "$_dest" | cut -d' ' -f1)" = "$_sha" ]; then
      _ok=1
    else
      _ok=0
      for _u in "$_url" \
        "https://github.com/deeplabua/deepocr/releases/download/models-v1/$_file" \
        "https://raw.githubusercontent.com/baras-app/ocr-models/main/$_file"; do
        echo "fetching $_file from $_u"
        if curl -fsSL --retry 2 --max-time 300 -o "$_dest.part" "$_u"; then
          if [ "$(sha256sum "$_dest.part" | cut -d' ' -f1)" = "$_sha" ]; then
            mv "$_dest.part" "$_dest"
            _ok=1
            break
          fi
          echo "warning: $_u: SHA-256 mismatch, ignoring" >&2
        fi
        rm -f "$_dest.part"
      done
      if [ "$_ok" != "1" ] && [ -n "$_upstream" ] && [ -n "$_version" ]; then
        # Last resort: the models shipped in the official release tarball for
        # this version. It is large, so the small mirrors are tried first.
        _tar="$WORK/pdfcraft-$_version-linux-x86_64.tar.gz"
        _tar_dir="$WORK/release-models"
        mkdir -p "$WORK"
        if [ ! -f "$_tar" ]; then
          echo "fetching the release tarball for its OCR models: $_tar"
          curl -fsSL --retry 2 --max-time 900 -o "$_tar" \
            "https://github.com/$_upstream/releases/download/v$_version/pdfcraft-$_version-linux-x86_64.tar.gz" \
            || rm -f "$_tar"
        fi
        if [ -f "$_tar" ]; then
          rm -rf "$_tar_dir"
          mkdir -p "$_tar_dir"
          if tar -xzf "$_tar" -C "$_tar_dir" "pdfcraft-$_version-linux-x86_64/share/pdfcraft/models/$_file" 2>/dev/null; then
            _from="$_tar_dir/pdfcraft-$_version-linux-x86_64/share/pdfcraft/models/$_file"
            if [ -f "$_from" ] && [ "$(sha256sum "$_from" | cut -d' ' -f1)" = "$_sha" ]; then
              mv "$_from" "$_dest"
              _ok=1
            fi
          fi
        fi
      fi
    fi
    if [ "$_ok" != "1" ]; then
      echo "error: could not fetch $_file (expected SHA-256 $_sha)" >&2
      return 1
    fi
    sed -i "s|^url = \".*/$_file\"$|url = \"file://$_dest\"|" "$_src/ATTRIBUTION.toml"
  done <"$_cache/.entries"
  rm -f "$_cache/.entries"
  rm -rf "$WORK/release-models"
  rm -f "$WORK/pdfcraft-$_version-linux-x86_64.tar.gz"
}

WORK=/github/work
SRC="$WORK/src"
OUT=/github/out
STAGE="$WORK/stage"

echo "=== container ==="
echo "alpine: $(cat /etc/alpine-release)"
rustc -V
cargo -V

echo "=== installing build dependencies ==="
# curl   : not in the rust:alpine image, and `cargo xtask models` shells out to it
# tar    : GNU tar; BusyBox tar cannot emit the POSIX/ustar archives apk wants
# gzip   : GNU gzip, for reproducible -n -9 streams
# abuild : only for abuild-tar, the filter that builds the .apk control/data streams
apk add --no-cache \
  build-base binutils cmake perl pkgconf git ca-certificates curl jq \
  tar gzip abuild \
  linux-headers \
  wayland-dev wayland-protocols libxkbcommon-dev \
  libx11-dev libxrandr-dev libxi-dev libxcursor-dev \
  mesa-dev

echo "=== fetching source ==="
rm -rf "$SRC"
mkdir -p "$SRC"
git init -q "$SRC"
git config --global --add safe.directory "$SRC"
git -C "$SRC" config user.name "PdfCraft build bot"
git -C "$SRC" config user.email "41898282+github-actions[bot]@users.noreply.github.com"
if [ "$TRACK_UPSTREAM_PR" = "true" ]; then
  # The workflow's plan job resolves the target with an authenticated API
  # call and passes it in; only a standalone run needs to query GitHub here.
  if [ -z "${BASE_TAG:-}" ] || [ -z "${PR_SHA:-}" ]; then
    BASE_TAG="$(api_get "https://api.github.com/repos/$BASE_REPO/releases/latest" | jq -r .tag_name)"
    PR_JSON="$(api_get "https://api.github.com/repos/$BASE_REPO/pulls/$PR_NUMBER")"
    PR_OPEN="$(printf '%s\n' "$PR_JSON" | jq -r 'if .state == "open" and .merged == false then "true" else "false" end')"
    PR_SHA="$(printf '%s\n' "$PR_JSON" | jq -r .head.sha)"
    PR_REPO="$(printf '%s\n' "$PR_JSON" | jq -r .head.repo.clone_url)"
    PR_REF="$(printf '%s\n' "$PR_JSON" | jq -r .head.ref)"
  fi
  # PR #2808 conflicts with the newest release, and merging it produces code
  # that does not compile. While the PR is open, build its head as-is: it is
  # self-consistent and carries the fix. Once the PR is merged or closed,
  # build the newest release tag, which then contains the fix.
  if [ "$PR_OPEN" = "true" ]; then
    echo "PR #$PR_NUMBER: open, building head $PR_SHA"
    git -C "$SRC" fetch --no-tags -q "$PR_REPO" "refs/heads/$PR_REF"
    git -C "$SRC" checkout -q --detach "$PR_SHA"
    SOURCE_REF="PR #$PR_NUMBER ($PR_SHA)"
  else
    echo "PR #$PR_NUMBER: not open, building release $BASE_TAG"
    git -C "$SRC" remote add release "https://github.com/$BASE_REPO.git"
    git -C "$SRC" fetch --no-tags -q release "refs/tags/$BASE_TAG"
    BASE_SHA="$(git -C "$SRC" rev-list -n 1 FETCH_HEAD)"
    git -C "$SRC" checkout -q --detach "$BASE_SHA"
    SOURCE_REF="$BASE_TAG"
  fi
  UPSTREAM="$BASE_REPO"
else
  EXPECTED_REMOTE="https://github.com/${UPSTREAM}.git"
  git -C "$SRC" remote add origin "$EXPECTED_REMOTE"
  if ! git -C "$SRC" fetch --depth 1 -q origin "$REF"; then
    echo "ERROR: could not fetch '$REF' from $UPSTREAM" >&2
    exit 1
  fi
  git -C "$SRC" checkout -q FETCH_HEAD
  SOURCE_REF="$REF"
fi
UPSTREAM_SHA="$(git -C "$SRC" rev-parse HEAD)"
UPSTREAM_TREE="$(git -C "$SRC" rev-parse 'HEAD^{tree}')"
echo "source commit: $UPSTREAM_SHA"
echo "source tree:   $UPSTREAM_TREE"

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

echo "=== refreshing Cargo.lock for merged upstream/PR source ==="
cd "$SRC"
cargo generate-lockfile

echo "=== cargo build (release, musl) ==="
# Rust's *-linux-musl targets link statically by default, but musl's dlopen()
# refuses to load libraries from a static binary ("Dynamic loading not
# supported") - and winit opens libX11/libxkbcommon/Vulkan with dlopen. A static
# build therefore yields a working CLI with no window at all. Disable crt-static
# so the binaries are linked against the system musl, the way Alpine builds its
# own Rust packages.
export RUSTFLAGS="${RUSTFLAGS:-} -C target-feature=-crt-static"
echo "RUSTFLAGS: $RUSTFLAGS"
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
prefetch_ocr_models "$SRC" "$WORK/ocr-models" "$UPSTREAM" "$VERSION" \
  || echo "WARNING: could not prefetch the OCR models; trying the upstream URL" >&2
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
  echo "ref      : $SOURCE_REF"
  echo "commit   : $UPSTREAM_SHA"
  echo "tree     : $UPSTREAM_TREE"
  echo "built on : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "rustc    : $(rustc -V)"
  echo "alpine   : $(cat /etc/alpine-release)"
  echo "libc     : musl, dynamically linked (like every Alpine binary; dlopen works)"
  echo
  echo "release assets:"
  echo "  pdfcraft-$VERSION-r0.apk             Alpine package (unsigned; see INSTALL.txt)"
  echo "  pdfcraft-$VERSION-alpine-x86_64.tar.gz   plain filesystem tree for /"
  echo "  pdfcraft-$VERSION-alpine-x86_64          the GUI binary alone"
  echo "  pdfcraft-cli-$VERSION-alpine-x86_64      the headless CLI alone"
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
tar -C "$ROOT" -czf "$OUT/$PKG.tar.gz" usr BUILD-INFO.txt INSTALL.txt

# ---------------------------------------------------------------------------
# The .apk is gzip(control tar) immediately followed by gzip(data tar).
# apk is strict about the details, all of them verified against apk-tools 3.0.8:
#   * the control tar must NOT carry the end-of-archive record
#     (abuild-tar --cut): apk's tar reader runs straight from the control block
#     into the data block, so a terminator there ends the package with
#     "unexpected end of file";
#   * every regular file needs an APK-TOOLS.checksum.SHA1 pax record
#     (abuild-tar --hash), otherwise installation fails with "file format is
#     obsolete (e.g. missing embedded checksum)";
#   * an unsigned package must carry `datahash` = sha256 of the *compressed*
#     data stream, else apk reports a v2 package format error.
# The archives must be POSIX/ustar + pax, hence GNU tar --format=posix.
# ---------------------------------------------------------------------------
PKGVER="$VERSION-r0"
APKFILE="$OUT/pdfcraft-$PKGVER.apk"
APKROOT="$WORK/apkroot"
CTRLDIR="$WORK/apkcontrol"
rm -rf "$APKROOT" "$CTRLDIR"
mkdir -p "$APKROOT/usr/share/doc/pdfcraft" "$CTRLDIR"
cp -a "$ROOT/usr/." "$APKROOT/usr/"
cp "$OUT/BUILD-INFO.txt" /github/scripts/INSTALL.txt "$APKROOT/usr/share/doc/pdfcraft/"

# Normalise timestamps so rebuilds are byte-identical.
SOURCE_DATE_EPOCH="$(git -C "$SRC" log -1 --format=%ct)"
export SOURCE_DATE_EPOCH

# The same tar invocation abuild uses (apk_tar in abuild's functions.sh).
posix_tar() {
  tar --format=posix \
      --pax-option=exthdr.name=%d/PaxHeaders/%f,atime:=0,ctime:=0 \
      --mtime="@$SOURCE_DATE_EPOCH" --no-recursion --null -f - -c -T -
}

echo "=== building the .apk ==="
PKGSIZE="$(find "$APKROOT" -type f -exec stat -c%s {} + | awk '{s+=$1} END {print s+0}')"

( cd "$APKROOT" && find usr -print0 | LC_ALL=C sort -z | posix_tar ) \
  | abuild-tar --hash=sha1 | gzip -n -9 > "$WORK/data.tar.gz"
DATAHASH="$(sha256sum "$WORK/data.tar.gz" | cut -d' ' -f1)"

cat > "$CTRLDIR/.PKGINFO" <<EOF
# Generated by the PdfCraft Alpine build harness (unofficial build)
pkgname = pdfcraft
pkgver = $PKGVER
pkgdesc = Unofficial Alpine (musl) build of PdfCraft $VERSION
url = https://github.com/$UPSTREAM
builddate = $SOURCE_DATE_EPOCH
packager = vinod2807 <https://github.com/vinod2807>
size = $PKGSIZE
arch = x86_64
origin = pdfcraft
maintainer = vinod2807
license = MIT AND Apache-2.0
datahash = $DATAHASH
EOF

( cd "$CTRLDIR" && printf '.PKGINFO\0' | posix_tar ) \
  | abuild-tar --cut | gzip -n -9 > "$WORK/control.tar.gz"

cat "$WORK/control.tar.gz" "$WORK/data.tar.gz" > "$APKFILE"
rm -f "$WORK/control.tar.gz" "$WORK/data.tar.gz"

echo "=== installing the .apk in this container to prove it works ==="
apk add --allow-untrusted "$APKFILE"
pdfcraft-cli --version
apk info -L pdfcraft | head -n 4
apk del pdfcraft

cd "$OUT"
sha256sum "$PKG.tar.gz" "pdfcraft-$VERSION-alpine-x86_64" \
  "pdfcraft-cli-$VERSION-alpine-x86_64" "pdfcraft-$PKGVER.apk" > SHA256SUMS
echo "=== done ==="
ls -l
cat SHA256SUMS
