#!/bin/sh
# Build the upstream PdfCraft source and produce its Debian and RPM packages.
# This runs inside a glibc-based Rust container from build-debian.yml.
set -eu

UPSTREAM="${UPSTREAM:-storytold/pdfcraft}"
REF="${REF:-main}"
TRACK_UPSTREAM_PR="${TRACK_UPSTREAM_PR:-false}"
BASE_REPO="${BASE_REPO:-storytold/pdfcraft}"
PR_NUMBER="${PR_NUMBER:-2808}"
CRAFT_FONTS_REF="${CRAFT_FONTS_REF:-}"
BUILD_LABEL="${PDFCRAFT_BUILD_LABEL:-debian}"
# Resolved by the workflow's plan job; empty for a standalone run.
BASE_TAG="${BASE_TAG:-}"
PR_SHA="${PR_SHA:-}"
PR_REPO="${PR_REPO:-}"
PR_REF="${PR_REF:-}"
PR_OPEN="${PR_OPEN:-false}"
WORK=/github/work
SRC="$WORK/src"
OUT=/github/out

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
#
# Some upstream versions list models as .onnx but mirrors/release tarballs have
# .rten files (or vice versa). Try alternative extensions when the primary
# name fails.
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
    _actual_file="$_file"
    if [ -f "$_dest" ] && [ "$(sha256sum "$_dest" | cut -d' ' -f1)" = "$_sha" ]; then
      _ok=1
    else
      _ok=0
      # Generate alternative file names by swapping extensions
      _alts=""
      case "$_file" in
        *.onnx) _alts="${_file%.onnx}.rten" ;;
        *.rten) _alts="${_file%.rten}.onnx" ;;
      esac
      for _try_file in "$_file" $_alts; do
        _try_dest="$_cache/$_try_file"
        for _u in "$_url" \
          "https://github.com/deeplabua/deepocr/releases/download/models-v1/$_try_file" \
          "https://raw.githubusercontent.com/baras-app/ocr-models/main/$_try_file"; do
          echo "fetching $_try_file from $_u"
          if curl -fsSL --retry 2 --max-time 300 -o "$_try_dest.part" "$_u"; then
            if [ "$(sha256sum "$_try_dest.part" | cut -d' ' -f1)" = "$_sha" ]; then
              mv "$_try_dest.part" "$_try_dest"
              # If we used an alternative name, rename to the expected name
              if [ "$_try_file" != "$_file" ]; then
                mv "$_try_dest" "$_dest"
              fi
              _actual_file="$_try_file"
              _ok=1
              break 2
            fi
            echo "warning: $_u: SHA-256 mismatch, ignoring" >&2
          fi
          rm -f "$_try_dest.part"
        done
        if [ "$_ok" = "1" ] && [ -n "$_upstream" ] && [ -n "$_version" ]; then
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
            if tar -xzf "$_tar" -C "$_tar_dir" "pdfcraft-$_version-linux-x86_64/share/pdfcraft/models/$_try_file" 2>/dev/null; then
              _from="$_tar_dir/pdfcraft-$_version-linux-x86_64/share/pdfcraft/models/$_try_file"
              if [ -f "$_from" ] && [ "$(sha256sum "$_from" | cut -d' ' -f1)" = "$_sha" ]; then
                mv "$_from" "$_dest"
                _actual_file="$_try_file"
                _ok=1
                break
              fi
            fi
          fi
        fi
      done
    fi
    if [ "$_ok" != "1" ]; then
      echo "error: could not fetch $_file (expected SHA-256 $_sha)" >&2
      return 1
    fi
    # Update ATTRIBUTION.toml: replace the URL and the file name if we used an alternative
    if [ "$_actual_file" != "$_file" ]; then
      sed -i "s|^file = \"$_file\"$|file = \"$_actual_file\"|" "$_src/ATTRIBUTION.toml"
      sed -i "s|^url = \".*/$_file\"$|url = \"file://$_dest\"|" "$_src/ATTRIBUTION.toml"
    else
      sed -i "s|^url = \".*/$_file\"$|url = \"file://$_dest\"|" "$_src/ATTRIBUTION.toml"
    fi
  done <"$_cache/.entries"
  rm -f "$_cache/.entries"
  rm -rf "$WORK/release-models"
  rm -f "$WORK/pdfcraft-$_version-linux-x86_64.tar.gz"
}

echo "=== installing build dependencies ==="
apt-get update
DEBIAN_FRONTEND=noninteractive apt-get install -y --no-install-recommends \
  ca-certificates curl jq git build-essential cmake pkg-config rpm \
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
  git -C "$SRC" remote add origin "https://github.com/$UPSTREAM.git"
  git -C "$SRC" fetch --depth 1 -q origin "$REF"
  git -C "$SRC" checkout -q FETCH_HEAD
  SOURCE_REF="$REF"
fi

VERSION="$(awk '/^\[/ { in_pkg = ($0 == "[workspace.package]"); next } in_pkg && $1 == "version" { gsub(/[" ]/, "", $3); print $3; exit }' "$SRC/Cargo.toml")"
[ -n "$VERSION" ] || { echo "error: could not read the version from Cargo.toml" >&2; exit 1; }
UPSTREAM_SHA="$(git -C "$SRC" rev-parse HEAD)"
# The tree identifies the built content across merges: the carrier branch gets a new
# commit each time it is rewritten, even when the merged result is unchanged.
UPSTREAM_TREE="$(git -C "$SRC" rev-parse 'HEAD^{tree}')"
echo "building PdfCraft $VERSION from $UPSTREAM @ $SOURCE_REF ($UPSTREAM_SHA)"

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

echo "=== refreshing Cargo.lock for merged upstream/PR source ==="
cd "$SRC"
cargo generate-lockfile

echo "=== fetching OCR models (Scan & OCR) ==="
prefetch_ocr_models "$SRC" "$WORK/ocr-models" "$UPSTREAM" "$VERSION" \
  || { echo "ERROR: failed to fetch OCR models" >&2; exit 1; }

echo "=== building Debian and RPM packages for $UPSTREAM @ $SOURCE_REF ==="
packaging/linux/package.sh --formats "deb rpm"

echo "=== verifying packages ==="
DEB="$(find "$OUT" -maxdepth 1 -type f -name '*.deb' -print -quit)"
[ -n "$DEB" ] || { echo "error: no .deb was produced" >&2; exit 1; }
dpkg-deb --info "$DEB"
dpkg-deb --contents "$DEB" | grep -q '/usr/bin/pdfcraft$'
dpkg-deb --contents "$DEB" | grep -q '/usr/bin/pdfcraft-cli$'

RPM="$(find "$OUT" -maxdepth 1 -type f -name '*.rpm' -print -quit)"
[ -n "$RPM" ] || { echo "error: no .rpm was produced" >&2; exit 1; }
rpm -qp --queryformat 'rpm: %{NAME} %{VERSION}-%{RELEASE} %{ARCH}\n' "$RPM"
rpm -qpl "$RPM" | grep -q '/usr/bin/pdfcraft$'
rpm -qpl "$RPM" | grep -q '/usr/bin/pdfcraft-cli$'

# The .rpm is published as a workflow artifact only, so it is not listed here.
(cd "$OUT" && sha256sum "$(basename "$DEB")" > SHA256SUMS)

{
  echo "PdfCraft $VERSION — unofficial Debian/Ubuntu (amd64) build"
  echo
  echo "upstream : https://github.com/$UPSTREAM"
  echo "ref      : $SOURCE_REF"
  echo "commit   : $UPSTREAM_SHA"
  echo "tree     : $UPSTREAM_TREE"
  echo "built on : $(date -u +%Y-%m-%dT%H:%M:%SZ)"
  echo "label    : $BUILD_LABEL"
  echo "packages : .deb (release asset), .rpm (workflow artifact only)"
} > "$OUT/BUILD-INFO.txt"

ls -lh "$OUT"
