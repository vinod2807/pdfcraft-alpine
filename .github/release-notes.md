PdfCraft for Alpine Linux (musl) — unofficial build
===================================================

Unofficial musl build of PdfCraft for Alpine Linux (x86_64), compiled in an
Alpine container from upstream source at a pinned commit.

This build targets PdfCraft pull request #2808 (issue #79): a signature widget
whose stored appearance says "Signature Not Verified" now draws its real
validation state on the page — a green tick and "Signature valid" once the
signer is trusted — instead of the baked-in yellow "?" image. Display, print and
export show the new state; the saved file is never rewritten.

Assets
------
  pdfcraft-<version>-alpine-x86_64.tar.gz      install tree (binaries, icons,
                                               desktop entry, licences, OCR models)
  pdfcraft-<version>-alpine-x86_64             the GUI binary alone
  pdfcraft-cli-<version>-alpine-x86_64         the headless CLI alone
  SHA256SUMS                                   checksums
  BUILD-INFO.txt                               exact commit, toolchain, ELF deps

Install
-------
  sudo tar -xzf pdfcraft-<version>-alpine-x86_64.tar.gz -C /
  apk add libxkbcommon libx11 libxcursor libxrandr libxi vulkan-loader mesa-vulkan-swrast
  pdfcraft some.pdf

See INSTALL.txt inside the tarball for Wayland, OpenGL and printing notes.

Licence
-------
PdfCraft is Copyright the PdfCraft contributors, licensed MIT OR Apache-2.0.
This is a third-party rebuild derived from https://github.com/storytold/pdfcraft
(the fix is by @chiranjeevi-max). Not affiliated with or endorsed by the PdfCraft
authors. Full licences and attribution ship in usr/share/doc/pdfcraft/.
