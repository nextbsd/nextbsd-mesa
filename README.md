# nextbsd-mesa

libglvnd, Mesa and libGLU that NextBSD ships in base, built from pinned
upstream release tarballs into **`/usr/X11`**. It is the second of the three X
repos in E23
([plan](https://github.com/nextbsd/nextbsd-userland/wiki/E23-Display-Server-Graphics-Stack-Plan),
epic nextbsd/nextbsd#561), built by hand in this order:

```
nextbsd-toolchain   clang/lld 19.1.7 (+ the tiny static LLVM for llvmpipe)
        │
nextbsd-xlibs       libdrm + the X client libraries
        │
nextbsd-mesa        Mesa + libglvnd (+ libGLU)                <- this repo
        │
nextbsd-xlibre      the XLibre server, drivers, input stack, xkb, tools
```

It follows the
[source repo conventions](https://github.com/nextbsd/nextbsd-userland/wiki/Source-Repo-Conventions)
(the nextbsd-xlibs layout).

## Rules

1. **Pinned upstream sources only.** Every component is a release tarball
   listed in `sources.lock` with its version, URL and SHA-256. Not FreeBSD
   packages, not the ports tree or ports tools. Those, and FreeBSD's port
   patches, may be read as references.
2. **Upstream build systems as they are** (meson), driven with NextBSD's
   options and cross files. Never rewritten as hand-made makefiles.
3. **NextBSD's changes are patch files** in `patches/<component>/`, never
   edits to an unpacked tree, each with its provenance.
4. **Everything installs under `/usr/X11`** (E23 D4) with **upstream sonames**
   (`libGL.so.1`, `libEGL.so.1`, `libgbm.so.1`). Mesa's DRI, GBM and GLVND
   paths are absolute under `/usr/X11`, so a FreeBSD Mesa in `/usr/local` can
   never mix in. Nothing goes in `/usr/local`, and nothing here ships `/etc`.
5. **Inputs:** compat's `continuous` base, nextbsd-xlibs' `continuous`
   artifact and nextbsd-toolchain's static LLVM; never `nextbsd-userland`.
   Build tools come from the toolchain image and never ship.
6. **pkgconf, never freedesktop's GPL pkg-config.** No D-Bus, Avahi, Wayland
   or udev.

## Layout

```
build-mesa.sh                cross-build driver: every component, or some by name
sources.lock                 name, version, SHA-256, URL of every upstream tarball
patches/<name>/series        the patches for <name>, in the order applied
patches/<name>/*.patch       one change each, with an Origin: header
cross/meson/<arch>.ini       meson cross files (host_machine system = 'freebsd', llvm-config)
.github/workflows/build.yml  CI: build both arches, publish `continuous`
NOTICE.md                    per-component provenance and licence
```

Nothing upstream is committed. `build-mesa.sh` downloads into `.build/dl/`,
unpacks into `.build/src/` and builds out of tree under `.build/`.

## Build model

`build-mesa.sh` runs inside the `nextbsd-kernel-toolchain` container (the
pinned clang/lld 19.1.7, meson, ninja, pkgconf, bison, flex, Python with mako
and yaml). CI stages the sysroot and the LLVM first:

| Input | From | Where |
|---|---|---|
| NextBSD base | `nextbsd-freebsd-compat` release `continuous`, `nextbsd-base-<arch>.tar.gz` | `$SYSROOT` |
| libdrm, X client libraries, `libxshmfence`, expat | `nextbsd-xlibs` release `continuous`, `nextbsd-xlibs-<arch>.tar.gz` | `$SYSROOT/usr/X11` |
| static LLVM 19.1.7 | `nextbsd-toolchain` release `llvm-static-19.1.7`, `nextbsd-llvm-static-19.1.7-<arch>.tar.xz`, checked against its `.sha256` | `$LLVM_STATIC` (`/opt/llvm-19-nextbsd-<arch>`) |

| Variable | Meaning |
|---|---|
| `T` | target: `amd64` or `arm64` |
| `TA` | FreeBSD `TARGET_ARCH`: `amd64` or `aarch64` |
| `SYSROOT` | the staged base with nextbsd-xlibs in `/usr/X11`; scratch, since each component is installed into it |
| `LLVM_STATIC` | the unpacked static LLVM; its `bin/llvm-config` is a build-host program that answers for the target |
| `CROSS_BINDIR` | the toolchain's clang, lld and LLVM binutils (set by the container image) |
| `DESTDIR` | where to stage the artifact; default `/stage` |
| `INTEL_DRIVERS` | `auto` (default), `on` or `off`; see [Intel](#intel-iris-and-crocus) |

For each component, in `COMPONENTS` order, it downloads and checks the
tarball, applies `patches/<name>/series`, runs meson with two cross files (one
generated per run with the sysroot, clang and `llvm-config` paths, then
`cross/meson/<arch>.ini`), installs with `DESTDIR`, then checks and stages the
install exactly as nextbsd-xlibs does: all of it under `/usr/X11`; nothing
that would replace a file of the base or of nextbsd-xlibs; no `.la` files or
docs; `.pc` files in `lib/pkgconfig`, none naming `/usr/local` or a build
path; no absolute symlinks. Then it checks sonames, `DT_NEEDED` entries
(`llvm-readelf -d`), compiled-in paths and `.pc` resolution through pkgconf.

```
./build-mesa.sh                 # every component
./build-mesa.sh mesa            # one component; its dependencies must already
                                # be in $SYSROOT/usr/X11
```

## Components

| Component | Version | Installs | Ticket |
|---|---|---|---|
| `libglvnd` | 1.7.0 | `libGL.so.1`, `libGLX.so.0`, `libOpenGL.so.0`, `libEGL.so.1`, `libGLESv1_CM.so.1`, `libGLESv2.so.2`, `libGLdispatch.so.0`; GL, GLES, EGL and KHR headers | nextbsd/nextbsd-mesa#1 |
| `mesa` | 26.2.5 | `libGLX_mesa.so.0` (+ `libGLX_indirect.so.0` link), `libEGL_mesa.so.0` + `share/glvnd/egl_vendor.d/50_mesa.json`, `libgbm.so.1` + `lib/gbm/dri_gbm.so`, `libgallium-26.2.5.so`, `lib/dri/*_dri.so` (links to `libdril_dri.so`), `share/drirc.d` | nextbsd/nextbsd-mesa#1 |
| `glu` | 9.0.3 | `libGLU.so.1`, `GL/glu.h` (E24: Gershwin's ItemFlow and Player, libs-quartzcore) | nextbsd/nextbsd-mesa#1 |

Installed size (first CI build, iris and crocus not built):

| Arch | `/usr/X11` from this repo | of which `libgallium-26.2.5.so` (LLVM inside) | artifact (`.tar.gz`) |
|---|---|---|---|
| amd64 | 84 MiB | 77 MiB | 26 MiB |
| arm64 | 77 MiB | 68 MiB | 23 MiB |

Licences are per component; see `NOTICE.md`. The top-level `LICENSE` (BSD-2)
covers only this repo's harness. freeglut is not built: nothing calls GLUT.

### Mesa configuration (E23 D5–D8, D15)

```
-Dplatforms=x11 -Dglx=dri -Degl=enabled -Dgbm=enabled -Dglvnd=enabled
-Dllvm=enabled -Dshared-llvm=disabled -Damd-use-llvm=false -Dvulkan-drivers=
-Dopengl=true -Dgles1=disabled -Dgles2=enabled
-Ddri-drivers-path=/usr/X11/lib/dri -Dgbm-backends-path=/usr/X11/lib/gbm
```

| Arch | Gallium drivers | DRI names |
|---|---|---|
| amd64 | `radeonsi` (ACO only), `r600`, `virgl`, `llvmpipe`, `softpipe`; `iris`, `crocus` when the mesa_clc tools are present | `radeonsi`, `r600`, `virtio_gpu`, `swrast`, `kms_swrast` (+ `iris`, `crocus`) |
| arm64 | `v3d`, `vc4`, `virgl`, `llvmpipe`, `softpipe` | `v3d`, `vc4` and the kmsro display names, `virtio_gpu`, `swrast`, `kms_swrast` |

- **LLVM** is linked statically into `libgallium` only (D3); no `libLLVM`
  ships, and `libgbm.so.1` (all NVIDIA uses) links neither LLVM nor
  `libgallium`. `patches/mesa/0002` stops meson demanding LLVM's `amdgpu`
  component when radeonsi uses ACO (D8).
- **GLVND:** Mesa is a vendor (`mesa`). libglvnd looks for EGL vendor JSONs in
  `/usr/X11/etc/glvnd/egl_vendor.d`, then `/usr/X11/share/glvnd/egl_vendor.d`
  (Mesa's `50_mesa.json`). `libGLX_indirect.so.0` points at `libGLX_mesa.so.0`
  for servers that name no vendor, as FreeBSD does with libmap.
- **GBM backends** are looked up in `/usr/X11/lib/gbm`: Mesa's `dri_gbm.so`,
  and NVIDIA's `nvidia-drm_gbm.so` once `nvidia-activate.sh` links into
  `/usr/X11` instead of `/usr/local` (D15,
  nextbsd/nextbsd-kernel-extensions-nvidia#2). `GBM_BACKENDS_PATH` still
  overrides it.
- **Off:** Vulkan, lavapipe, zink (phase 2, nextbsd/nextbsd-mesa#2), Wayland,
  udev, VA, rusticl, valgrind, libunwind, lm_sensors, zstd (base's is
  private), tools, tests and docs. zlib and libelf come from the base, expat
  from nextbsd-xlibs.

### Intel (iris and crocus)

iris and crocus compile Intel's internal shaders while Mesa builds, with
`mesa_clc` and `vtn_bindgen2`, two build-host programs that link clang, LLVM,
SPIRV-LLVM-Translator and SPIRV-Tools (D7). nextbsd-toolchain#11 puts those
host libraries in the toolchain image at `/opt/mesa-clc`.

`build-mesa.sh` checks for `/opt/mesa-clc/bin/llvm-config`:

- **present:** it builds `mesa_clc` and `vtn_bindgen2` natively from the same
  patched Mesa tree (no drivers or platforms), then cross-builds Mesa with
  `-Dmesa-clc=system` and `iris,crocus` added to the amd64 drivers;
- **absent:** it skips iris and crocus with a note in the log. Intel GPUs then
  fall back to llvmpipe.

The image CI uses today predates nextbsd-toolchain#11, so **iris and crocus
are not built yet**; the next published toolchain image turns them on with
no change here. `INTEL_DRIVERS=on` makes their absence an error,
`INTEL_DRIVERS=off` skips them. The Intel patches (`0006`, `0007`) are
applied already and are compiled once the drivers are on.

### Patches

`patches/mesa/`, in `series` order. The nextbsd-ports ones are its
`graphics/mesa-dri/files` (E23 D11), converted to `-p1`:

| Patch | Origin | Why |
|---|---|---|
| `0001-meson-nextbsd-os-name` | nextbsd-ports | `nextbsd` treated as `freebsd` in meson.build; inert here, where the cross files say `freebsd` (D12), and kept for native builds |
| `0002-meson-radeonsi-no-amdgpu-llvm-component` | NextBSD | D8 |
| `0003`–`0005` v3d | nextbsd-ports | fail a BO map instead of `abort()` (nextbsd/nextbsd#451), and its NULL check; no `texture_barrier` on a tiler |
| `0006-intel-userptr-unsynchronized-fallback` | nextbsd-ports (FreeBSD) | drm-kmod's i915 has no MMU-notifier userptr |
| `0007-intel-xe-clock-boottime-alias` | nextbsd-ports (FreeBSD) | `CLOCK_BOOTTIME == CLOCK_MONOTONIC` |
| `0008-renderdoc-app-cc-freebsd` | nextbsd-ports (FreeBSD) | build fix |

Dropped: the POWER8 meson hunk and the llvmpipe altivec patch (PowerPC), the
panfrost clock patch (panfrost isn't built), the Wayland WSI patch (no
Wayland), and the `kwin_x11` driconf file.

## CI, artifact, package

The workflow builds both arches on every pull request. On a push to `main`, or
a manual run from `main`, it also publishes `nextbsd-mesa-<arch>.tar.gz` to the
`continuous` release, rooted at `/`.

The artifact holds the whole `/usr/X11` install of this repo: libraries,
drivers, data, and the headers and `.pc` files that `nextbsd-xlibre` stages
into its sysroot (glamor needs `gbm` and `egl`, GLX needs `dri.pc`). Splitting
runtime from development files is `nextbsd-pkg`'s job (E23 D13,
`NextBSD-mesa`).

Until the toolchain image carries Python's `packaging` (nextbsd-toolchain#11),
the workflow installs `python3-packaging` in the container: Mesa's meson
needs it, and Ubuntu 24.04's Python has no distutils.

Nothing is dispatched from here, and nothing dispatches here. `nextbsd-xlibre`
and `nextbsd-pkg` are run by hand once this build is known good. There is no
boot lane: CI proves the cross build, and hardware checks are manual.

## Adding a component

1. Pin it in `sources.lock`: name, version, SHA-256, URL of the upstream
   release tarball (check the hash against the release announcement or a
   second source).
2. Write `build_<name>()` in `build-mesa.sh`: `fresh_dirs`, `fetch`,
   `meson_build` with NextBSD's options, `stage`, then checks (`so_check`,
   `lib_needs`, `pc_check`). Append `<name>` to `COMPONENTS` in build order.
3. If it needs changes, add `patches/<name>/series` and the `.patch` files,
   each with a DEP-3-style `Description:` and `Origin:` header.
   `build-mesa.sh` refuses a patch without `Origin:` or missing from `series`.
4. A row in `NOTICE.md` and in the table above.
