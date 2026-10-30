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
