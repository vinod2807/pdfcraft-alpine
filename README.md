# PdfCraft for Alpine Linux (musl)

An **unofficial, third-party** build of [PdfCraft](https://github.com/storytold/pdfcraft)
for **Alpine Linux (x86_64, musl libc)**, produced by the GitHub Actions workflow in
this repository.

Upstream ships Linux builds as glibc-only AppImage/`.deb`/`.rpm`/`.tar.gz`, which do
not run on Alpine. This project compiles the same source against musl in an Alpine
container and publishes a plain binary (plus an install-tree tarball) that runs on
Alpine.

## What it builds

By default it builds **upstream PdfCraft v0.10.1** with
[PR #2808](https://github.com/storytold/pdfcraft/pull/2808) merged on top, carried by
the [`vinod2807/pdfcraft`](https://github.com/vinod2807/pdfcraft) branch
`m9/79-on-v0.10.1`. That branch is a merge commit of the upstream `v0.10.1` tag and
the PR head, so the build carries both the latest release and the fix for
[issue #79](https://github.com/storytold/pdfcraft/issues/79): signed PDFs whose stored
appearance says "Signature Not Verified" now get the real state drawn on the page
(green tick and "Signature valid" once the signer is trusted), matching Adobe Acrobat.
The saved file is never modified — only what is displayed, printed and exported.

The fork branch is only a carrier for the merge; the code still comes from
`storytold/pdfcraft` and the PR author. To move to a newer upstream release, merge its
tag into `m9/79-on-v0.10.1` and push; the workflow follows the branch. Both workflows
also accept `upstream` and `ref` inputs for one-off builds.

Both executables are built:

| Binary | What it is |
| --- | --- |
| `pdfcraft` | the desktop application (egui/wgpu GUI) |
| `pdfcraft-cli` | the headless CLI / MCP server |

The **Build PdfCraft for Debian and Ubuntu** workflow also produces an amd64
`.deb` from glibc-based Debian 12 (and Ubuntu 22.04+) compatible binaries. It
uses the upstream `packaging/linux/package.sh` staging and dependency metadata,
so the package installs the desktop entry, MIME association, icons, OCR models,
and both executables. It is independent of the Alpine `.apk` build.

Install the Debian/Ubuntu asset with:

```sh
sudo apt install ./pdfcraft-<version>-debian-linux-x86_64.deb
```

## Download & install

Grab the assets from the [latest release](../../releases). You want
`pdfcraft-<version>-alpine-x86_64.tar.gz` (install-tree tarball) or the raw
`pdfcraft-<version>-alpine-x86_64` binary.

```sh
# install-tree tarball (contains /usr/bin/pdfcraft, icons, desktop entry, licences)
sudo tar -xzf pdfcraft-<version>-alpine-x86_64.tar.gz -C /
pdfcraft some.pdf
```

Runtime libraries are loaded with `dlopen`, so install what your session needs:

```sh
# X11 session
apk add libxkbcommon libx11 libxcursor libxrandr libxi
# Wayland session
apk add libxkbcommon wayland-libs-client
# GPU — software Vulkan works everywhere, or pick your hardware driver
apk add vulkan-loader mesa-vulkan-swrast
# apk add mesa-vulkan-intel mesa-vulkan-ati mesa-vulkan-nouveau
# optional: OpenGL fallback, CUPS printing, native file dialogs
apk add mesa-gl mesa-egl mesa-dri-gallium cups-client cups-libs xdg-desktop-portal
```

If the GPU stack does not come up, try `PDFCRAFT_RENDERER=gl pdfcraft some.pdf`.
See the `INSTALL.txt` inside the tarball for the full notes.

> This is not a distribution package: it is a musl-linked binary built on
> `rust:1.99-alpine3.24`. It works on Alpine; it will **not** run on glibc distributions,
> and the official builds will **not** run on Alpine.

Both executables are linked against the system musl (`crt-static` disabled), which is
what Alpine does for its own Rust packages. Rust's musl target links statically by
default, but musl's `dlopen()` refuses to load libraries from a static binary
("Dynamic loading not supported"), and winit opens libX11 / libxkbcommon / Vulkan with
`dlopen` — a static build starts the CLI but never opens a window. musl itself is part
of every Alpine; only the libraries listed above need installing.

Verified on Alpine 3.24 (x86_64): `pdfcraft-cli` reports the upstream version with its
`(alpine)` label (`0.10.1` for the current build), the CLI parses/text-extracts/renders
a real PDF, and the GUI opens on an X11 session.
(An earlier static build of this harness could not start the GUI at all — see the
`crt-static` note in `scripts/build-alpine.sh`.)

## Rebuild it yourself

Actions → **Build PdfCraft for Alpine Linux (musl)** → **Run workflow**. Inputs let
you change the upstream repository, the branch/commit, the `craft-fonts` commit and
the release tag. Pushing to `main` also triggers a build.

The compile needs roughly 5 GB of disk and 30–90 minutes; that happens entirely on
the GitHub runner. The published download is ~80–120 MB.

## How it works

1. `docker run rust:alpine` — a pinned Alpine + Rust toolchain.
2. `apk add` the build dependencies (build-base, cmake, wayland/xkb/X11 dev, mesa dev).
3. `git fetch` the upstream commit by SHA, plus the optional `storytold/craft-fonts`
   input (Japanese/Arabic faces).
4. `cargo build --release --locked -p pdfcraft -p pdfcraft-cli` → a musl binary.
5. `pdfcraft-cli --version` smoke test, then stage an FHS tree, download the OCR
   models, and publish the binaries, the tarball and `SHA256SUMS`.

The workflow only fetches and compiles upstream source. This repository contains no
upstream code.

## Licence & attribution

PdfCraft is Copyright the PdfCraft contributors and licensed under
**MIT OR Apache-2.0**. This build is derived from
[storytold/pdfcraft](https://github.com/storytold/pdfcraft), created by
Storytold / Learning Machines LLC, and from the fix by
[@chiranjeevi-max](https://github.com/chiranjeevi-max). Bundled fonts come from
[storytold/craft-fonts](https://github.com/storytold/craft-fonts); OCR models come from
[ocrs-models](https://github.com/robertknight/ocrs-models) (CC-BY-SA-4.0). The full
licences and `NOTICE`/`ATTRIBUTION` files are included in the tarball under
`usr/share/doc/pdfcraft/`.

This repository is **not affiliated with or endorsed by** the PdfCraft authors. It is
an independent rebuild for a platform they do not currently package for. Please report
problems with PdfCraft itself upstream, not here — but do report build issues here.
