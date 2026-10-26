# Upstream sources & licences

`nextbsd-mesa` builds third-party libraries NextBSD ships in base under
`/usr/X11`, each **under its own upstream licence**. Their sources are not kept
in this repo: `build-mesa.sh` downloads the release tarballs pinned in
`sources.lock` and checks their SHA-256. The licence files and headers in those
tarballs are authoritative; this table records provenance and does not
relicense anything.

NextBSD's changes to upstream code live in `patches/<component>/`. Each patch is
under the licence of the file it changes, and says where it came from in its
`Origin:` line.

The top-level **`LICENSE` (BSD 2-Clause)** covers only what this repo authors:
`build-mesa.sh`, `sources.lock`, `cross/`, `.github/workflows/`, this
`NOTICE.md` and `README.md`.

Both published artifacts, `nextbsd-mesa-<arch>` (core) and
`nextbsd-mesa-x11-<arch>` (X), are built from the sources below: libglvnd's
libraries are split between them, and Mesa is built twice from the same
patched tarball (README, "Mesa configuration"). The X artifact links no LLVM;
the LLVM note below applies to the core's `libgallium-26.2.5.so`.

| Component | Upstream | Version | Licence |
|---|---|---|---|
| `libglvnd` | freedesktop.org, `glvnd/libglvnd` | 1.7.0 | MIT-style (end of `README.md`; per-file headers). The Khronos headers it installs are Apache-2.0 / MIT (per header) |
| `mesa` | freedesktop.org, `mesa/mesa` | 26.2.5 | MIT for the code built here (`docs/license.rst`); some files are under other permissive licences per their headers (BSD, SGI Free Software License B, Apache-2.0 with LLVM exception in vendored parts) |
| `glu` | freedesktop.org, `mesa/glu` | 9.0.3 | SGI Free Software License B 2.0 (per-file headers) |

Linked in but not shipped on its own: **LLVM 19.1.7** (nextbsd-toolchain's
static libraries, statically linked into `libgallium-26.2.5.so`), under
Apache-2.0 with LLVM exceptions.
