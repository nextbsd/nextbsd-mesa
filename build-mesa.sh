#!/usr/bin/env bash
# =============================================================================
# build-mesa.sh — cross-build driver for nextbsd-mesa
# =============================================================================
#
# Builds libglvnd, Mesa and libGLU, which NextBSD ships in base (E23, plan
# steps 7-8), for ONE architecture, from pinned upstream release tarballs, into
# the /usr/X11 prefix with upstream sonames.
#
# For each component, in COMPONENTS order:
#   1. fetch:   download the tarball named in sources.lock, refuse it unless
#               its SHA-256 matches, unpack it under .build/src/;
#   2. patch:   apply patches/<name>/series in order (each patch must state
#               its Origin:);
#   3. build:   upstream meson with cross/meson/<arch>.ini, out of tree,
#               installed with DESTDIR into .build/<name>-root-<arch>/;
#   4. stage:   check and tidy that install, then copy it into $SYSROOT (so
#               later components find its headers, .pc files and libraries)
#               and into $DESTDIR (the published artifact).
#
# Upstream build systems are used as they are, with NextBSD's options; nothing
# is rewritten as a hand-made makefile. Nothing here uses FreeBSD packages, the
# ports tree or ports tools, and nothing links against nextbsd-userland.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-kernel-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, pkgconf, bison, flex, python3 with mako and
#   yaml), with $SYSROOT holding compat's `continuous` base and nextbsd-xlibs'
#   `continuous` artifact (libdrm, the X client libraries, expat in /usr/X11),
#   and $LLVM_STATIC holding nextbsd-toolchain's static LLVM 19.1.7 for this
#   arch. $SYSROOT is scratch: this script installs every component into its
#   /usr/X11 as it goes.
#
# USAGE
#   ./build-mesa.sh               every component, in COMPONENTS order
#   ./build-mesa.sh mesa          named components only (their dependencies
#                                 must already be in $SYSROOT/usr/X11)
# =============================================================================

set -euo pipefail

# ---- required environment ----------------------------------------------------
: "${T:?set T to the target (amd64 / arm64)}"
: "${TA:?set TA to the target_arch (amd64 / aarch64)}"
: "${SYSROOT:?set SYSROOT to the staged NextBSD base with nextbsd-xlibs in /usr/X11}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${LLVM_STATIC:?set LLVM_STATIC to the unpacked llvm-19-nextbsd-<arch> tree}"
: "${DESTDIR:=/stage}"
# Host libraries for Intel's mesa_clc (nextbsd-toolchain#11), in the toolchain
# image once it is rebuilt with them. See build_mesa and README "Intel".
: "${MESA_CLC_HOST:=/opt/mesa-clc}"
# auto: build iris and crocus when $MESA_CLC_HOST is there, skip them (with a
# note) when it isn't; on: require it; off: never.
: "${INTEL_DRIVERS:=auto}"

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
BUILD="$ROOT/.build"
DL="$BUILD/dl"
LOCK="$ROOT/sources.lock"
PATCHES="$ROOT/patches"
MESA_CROSS="$ROOT/cross"

# Install prefix (E23 D4). .pc files are gathered in $X_PREFIX/lib/pkgconfig
# whatever the upstream default, so one directory goes on pkgconf's path.
X_PREFIX=/usr/X11

# The pinned LLVM (E23 D2): the static LLVM must be this release.
LLVM_VERSION=19.1.7

case "$T" in
    amd64) CROSS_TRIPLE=x86_64-unknown-freebsd ;;
    arm64) CROSS_TRIPLE=aarch64-unknown-freebsd ;;
    *)     echo "FAIL: unsupported T=$T (amd64 / arm64)" >&2; exit 1 ;;
esac

SYSROOT="$(cd "$SYSROOT" && pwd)"
LLVM_STATIC="$(cd "$LLVM_STATIC" && pwd)"
LLVM_CONFIG="$LLVM_STATIC/bin/llvm-config"
export SYSROOT DESTDIR CROSS_BINDIR

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# lock_field <name> <version|sha256|url>: a component's pin from sources.lock.
lock_field() {
    local name="$1" field="$2" col
    case "$field" in
        version) col=2 ;;
        sha256)  col=3 ;;
        url)     col=4 ;;
        *)       fail "lock_field: unknown field $field" ;;
    esac
    awk -v n="$name" -v c="$col" '$1 == n && $1 !~ /^#/ { print $c; found=1 } END { exit !found }' "$LOCK" \
        || fail "$name is not pinned in sources.lock"
}

# Assert a staged object links a given library (a cross `readelf -d` check; we
# cannot exec target binaries on the runner).
needed_check() {
    local obj="$1" want="$2"
    "$CROSS_BINDIR/llvm-readelf" -d "$obj" 2>/dev/null | grep -q "NEEDED.*\[$want" \
        || fail "$obj missing DT_NEEDED $want"
    note "DT_NEEDED ok: $(basename "$obj") -> $want"
}

# not_needed <obj> <regex>: a staged object links nothing matching <regex>.
not_needed() {
    local obj="$1" re="$2"
    if "$CROSS_BINDIR/llvm-readelf" -d "$obj" 2>/dev/null | grep -E "NEEDED.*\[($re)"; then
        fail "$(basename "$obj") links $re"
    fi
    note "no DT_NEEDED on $re: $(basename "$obj")"
}

# Assert a staged shared library carries the upstream soname.
soname_check() {
    local lib="$1" want="$2"
    "$CROSS_BINDIR/llvm-readelf" -d "$lib" 2>/dev/null | grep -q "SONAME.*\[$want\]" \
        || fail "$lib does not have SONAME $want"
    note "SONAME ok: $want"
}

# so_check <soname>...: each staged $X_PREFIX/lib/<soname> exists and carries
# that soname.
so_check() {
    local s
    for s in "$@"; do
        [ -e "$DESTDIR$X_PREFIX/lib/$s" ] || fail "$X_PREFIX/lib/$s not staged"
        soname_check "$DESTDIR$X_PREFIX/lib/$s" "$s"
    done
}

# lib_needs <soname> <needed>...: a staged library links each <needed>.
lib_needs() {
    local lib="$DESTDIR$X_PREFIX/lib/$1" n
    shift
    for n in "$@"; do needed_check "$lib" "$n"; done
}

# has_string <file> <string>: a staged binary has <string> compiled in (paths
# baked in at configure time).
has_string() {
    grep -q -a -F -- "$2" "$1" || fail "$(basename "$1") does not contain '$2'"
    note "$(basename "$1") has '$2'"
}

# fetch <name>: download (cached in .build/dl), verify and unpack the pinned
# tarball, apply the patch series. Sets SRC_DIR and VERSION.
fetch() {
    local name="$1" url sha file got
    VERSION=$(lock_field "$name" version)
    url=$(lock_field "$name" url)
    sha=$(lock_field "$name" sha256)
    file="$DL/$(basename "$url")"
    mkdir -p "$DL"
    if [ ! -f "$file" ]; then
        note "fetch $url"
        curl -fsSL --retry 3 -o "$file.part" "$url"
        mv "$file.part" "$file"
    fi
    got=$(sha256sum "$file" | cut -d' ' -f1)
    [ "$got" = "$sha" ] || { rm -f "$file"; fail "$name: SHA-256 mismatch for $(basename "$file") (got $got, sources.lock has $sha)"; }
    note "$name $VERSION, sha256 ok"
    SRC_DIR="$BUILD/src/$name-$VERSION"
    rm -rf "$SRC_DIR"
    mkdir -p "$SRC_DIR"
    tar -xf "$file" -C "$SRC_DIR" --strip-components=1
    apply_patches "$name"
}

# apply_patches <name>: patches/<name>/series lists the patches in order, one
# per line (# comments allowed). Every *.patch in the directory must be listed,
# and every patch must say where it came from in an `Origin:` header line
# (DEP-3 style: upstream commit or MR, nextbsd-ports, a FreeBSD port file used
# as a reference, or "NextBSD" for our own).
apply_patches() {
    local name="$1" dir="$PATCHES/$1" p n=0
    [ -d "$dir" ] || return 0
    [ -f "$dir/series" ] || fail "patches/$name has no series file"
    for p in "$dir"/*.patch; do
        [ -e "$p" ] || continue
        grep -qx "$(basename "$p")" "$dir/series" || fail "patches/$name/$(basename "$p") is not listed in series"
    done
    while read -r p; do
        case "$p" in ''|'#'*) continue ;; esac
        [ -f "$dir/$p" ] || fail "patches/$name/series lists missing $p"
        grep -q '^Origin:' "$dir/$p" || fail "patches/$name/$p has no Origin: line"
        patch -d "$SRC_DIR" -p1 --forward --batch --quiet < "$dir/$p" || fail "patches/$name/$p does not apply"
        note "patch $p"
        n=$((n + 1))
    done < "$dir/series"
    note "$n patch(es) applied"
}

# Fresh out-of-tree build and install-root directories for a component.
fresh_dirs() {
    local name="$1"
    COMP_BUILD="$BUILD/$name-$T"
    COMP_ROOT="$BUILD/$name-root-$T"
    rm -rf "$COMP_BUILD" "$COMP_ROOT"
    mkdir -p "$COMP_BUILD" "$COMP_ROOT"
}

# meson_build [meson options...]: configure, build and install $SRC_DIR into
# $COMP_ROOT with the arch's cross file. The first cross file is generated here
# and carries the paths of this run; the second is the checked-in one. Extra
# --native-file arguments may be passed among the options.
meson_build() {
    local paths="$BUILD/cross/paths-$T.ini"
    mkdir -p "$BUILD/cross"
    cat > "$paths" <<EOF
[constants]
sysroot = '$SYSROOT'
llvm_bindir = '$CROSS_BINDIR'
llvm_config = '$LLVM_CONFIG'
EOF
    meson setup "$COMP_BUILD" "$SRC_DIR" \
        --cross-file "$paths" --cross-file "$MESA_CROSS/meson/$T.ini" \
        --prefix="$X_PREFIX" --libdir=lib --buildtype=release \
        -Ddefault_library=shared --wrap-mode=nodownload \
        "$@"
    meson compile -C "$COMP_BUILD"
    DESTDIR="$COMP_ROOT" meson install -C "$COMP_BUILD" --no-rebuild
}

# The files already in the sysroot (compat's base plus nextbsd-xlibs'
# artifact, which CI stages under it), listed while the sysroot doesn't yet
# hold anything from this repo, so stage can refuse a component that would
# overwrite one. A later partial run reuses the list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    mkdir -p "$BUILD"
    [ -f "$SYSROOT$X_PREFIX/lib/pkgconfig/x11.pc" ] \
        || fail "nextbsd-xlibs is not staged in $SYSROOT$X_PREFIX (no x11.pc)"
    if [ ! -e "$SYSROOT$X_PREFIX/lib/pkgconfig/libglvnd.pc" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh sysroot"
    fi
}

# stage <name>: tidy and check $COMP_ROOT, then copy it into $SYSROOT (for the
# components after this one) and $DESTDIR (the artifact).
#   - everything must be under /usr/X11, and nothing may replace a file of the
#     base or of nextbsd-xlibs;
#   - libtool .la files and docs are dropped (man pages are kept);
#   - .pc files from share/pkgconfig and libdata/pkgconfig move to
#     lib/pkgconfig;
#   - no .pc file may name /usr/local or a build-host path, and no symlink may
#     point outside the install.
stage() {
    local name="$1" x="$COMP_ROOT$X_PREFIX" stray f d clash bad
    [ -d "$x" ] || fail "$name installed nothing under $X_PREFIX"
    stray=$(cd "$COMP_ROOT" && find . -mindepth 1 ! -path ./usr ! -path ".$X_PREFIX" ! -path ".$X_PREFIX/*")
    [ -z "$stray" ] || fail "$name installed outside $X_PREFIX: $stray"
    find "$x" -name '*.la' -delete
    rm -rf "$x/share/doc"
    # meson puts a library's .pc in libdata/pkgconfig when host_machine is
    # freebsd (the base layout), arch-independent ones in share/pkgconfig.
    for d in share/pkgconfig libdata/pkgconfig; do
        [ -d "$x/$d" ] || continue
        mkdir -p "$x/lib/pkgconfig"
        mv "$x/$d"/*.pc "$x/lib/pkgconfig/"
        rmdir "$x/$d"
    done
    for f in "$x"/lib/pkgconfig/*.pc; do
        [ -e "$f" ] || continue
        grep -q "^prefix=$X_PREFIX\$" "$f" || fail "$(basename "$f"): prefix is not $X_PREFIX"
        if grep -n -F -e /usr/local -e "$ROOT" -e "$SYSROOT" "$f"; then
            fail "$(basename "$f") names /usr/local or a build-host path"
        fi
    done
    bad=$(find "$x" -type l -lname '/*')
    [ -z "$bad" ] || fail "$name installed absolute symlinks: $bad"
    # No RPATH/RUNPATH naming a build-host path (meson's build rpaths must
    # have been stripped at install).
    for f in $(find "$x" -type f -name '*.so*'); do
        if "$CROSS_BINDIR/llvm-readelf" -d "$f" 2>/dev/null | grep -E '\((RPATH|RUNPATH)\)'; then
            fail "$(basename "$f") carries an RPATH/RUNPATH"
        fi
    done
    find "$x" -type d -empty -delete
    clash=$(cd "$COMP_ROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base or nextbsd-xlibs: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files, $(du -sk "$COMP_ROOT" | cut -f1) KiB"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components (and nextbsd-xlibre) will see it.
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig:$SYSROOT/usr/libdata/pkgconfig" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
          pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}

# The static LLVM (nextbsd-toolchain release llvm-static-19.1.7) is the
# pinned release, built for this target, static, with RTTI (Mesa's cpp_rtti
# default must match).
llvm_check() {
    [ -x "$LLVM_CONFIG" ] || fail "$LLVM_CONFIG not found (unpack nextbsd-llvm-static-$LLVM_VERSION-$T.tar.xz)"
    [ "$("$LLVM_CONFIG" --version)" = "$LLVM_VERSION" ] || fail "static LLVM is $("$LLVM_CONFIG" --version), not $LLVM_VERSION"
    case "$("$LLVM_CONFIG" --host-target)" in
        "$CROSS_TRIPLE"*) ;;
        *) fail "static LLVM is for $("$LLVM_CONFIG" --host-target), not $CROSS_TRIPLE" ;;
    esac
    [ "$("$LLVM_CONFIG" --shared-mode)" = static ] || fail "LLVM at $LLVM_STATIC is not static"
    [ "$("$LLVM_CONFIG" --has-rtti)" = YES ] || fail "LLVM at $LLVM_STATIC is built without RTTI"
    note "static LLVM $LLVM_VERSION for $("$LLVM_CONFIG" --host-target) ($("$LLVM_CONFIG" --targets-built))"
}

# =============================================================================
# Components, in build order: libglvnd, then Mesa (its GLVND vendor libraries
# need libglvnd's headers and .pc files), then libGLU (against libglvnd's
# libOpenGL).
# =============================================================================

# libglvnd — the GL Vendor-Neutral Dispatch library (E23 D6): libGL, libGLX,
# libEGL, libGLESv1_CM, libGLESv2, libOpenGL and libGLdispatch, plus the GL,
# GLES and EGL headers. NVIDIA's libGLX_nvidia/libEGL_nvidia are GLVND vendors,
# so Mesa is built as one too. meson; host_machine freebsd gives the x86_64
# TLS dispatch stubs (aarch64: TSD stubs). EGL vendor JSONs are searched in
# /usr/X11/etc/glvnd/egl_vendor.d then /usr/X11/share/glvnd/egl_vendor.d.
# No Haiku GL; the upstream test programs are built but not installed.
build_libglvnd() {
    comp "libglvnd [meson cross]"
    fresh_dirs libglvnd
    fetch libglvnd
    meson_build -Dasm=enabled -Dx11=enabled -Dglx=enabled -Degl=true \
        -Dgles1=true -Dgles2=true -Dheaders=true -Dhgl=false \
        -Dtls=true -Ddispatch-tls=true -Dentrypoint-patching=enabled
    stage libglvnd
    local x="$DESTDIR$X_PREFIX"
    test -f "$x/include/GL/gl.h" || fail "GL/gl.h not staged"
    test -f "$x/include/EGL/egl.h" || fail "EGL/egl.h not staged"
    test -f "$x/include/KHR/khrplatform.h" || fail "KHR/khrplatform.h not staged"
    so_check libGLdispatch.so.0 libGL.so.1 libGLX.so.0 libOpenGL.so.0 libEGL.so.1 \
             libGLESv1_CM.so.1 libGLESv2.so.2
    lib_needs libGL.so.1 libGLdispatch.so.0 libGLX.so.0
    lib_needs libGLX.so.0 libGLdispatch.so.0 libX11.so.6
    has_string "$x/lib/libEGL.so.1" "$X_PREFIX/etc/glvnd/egl_vendor.d:$X_PREFIX/share/glvnd/egl_vendor.d"
    pc_check libglvnd "$VERSION"
    pc_check gl
    pc_check opengl
    pc_check glx
    pc_check egl
    pc_check glesv2
}

# Intel's internal shaders are compiled at build time by mesa_clc and
# vtn_bindgen2, two build-host programs (E23 D7). Their host libraries (clang,
# LLVM, SPIRV-LLVM-Translator, SPIRV-Tools for x86_64 Linux) are in the
# toolchain image at $MESA_CLC_HOST once it is rebuilt with nextbsd-toolchain#11.
# When they are there, build the two tools natively from the same patched Mesa
# tree (the E23 audit's option (b); nextbsd-toolchain mesa-clc/README.md):
# no drivers, no platforms, nothing that needs target libraries. The cross
# build then runs them with -Dmesa-clc=system. Sets INTEL_ON and CLC_NATIVE.
host_mesa_clc() {
    INTEL_ON=0
    CLC_NATIVE=
    case "$INTEL_DRIVERS" in
        off)
            note "INTEL_DRIVERS=off: iris and crocus not built"
            return 0 ;;
        on|auto) ;;
        *) fail "INTEL_DRIVERS must be auto, on or off (got $INTEL_DRIVERS)" ;;
    esac
    if [ "$T" != amd64 ]; then
        return 0
    fi
    if [ ! -x "$MESA_CLC_HOST/bin/llvm-config" ]; then
        [ "$INTEL_DRIVERS" = on ] && fail "INTEL_DRIVERS=on but $MESA_CLC_HOST/bin/llvm-config is missing"
        note "NOTE: $MESA_CLC_HOST is not in this toolchain image (nextbsd-toolchain#11 not"
        note "      published yet): iris and crocus are NOT built; Intel GPUs fall back"
        note "      to llvmpipe (E23 D7). The next image turns them on with no change here."
        return 0
    fi
    comp "mesa_clc + vtn_bindgen2 [meson native, build host only]"
    local nb="$BUILD/mesa-clc-build" host="$BUILD/mesa-clc-host" nf="$BUILD/cross/mesa-clc-native.ini"
    rm -rf "$nb" "$host"
    mkdir -p "$BUILD/cross"
    cat > "$nf" <<EOF
[binaries]
llvm-config = '$MESA_CLC_HOST/bin/llvm-config'

[built-in options]
pkg_config_path = '$MESA_CLC_HOST/lib/pkgconfig'
EOF
    meson setup "$nb" "$SRC_DIR" --native-file "$nf" --prefix="$host" \
        --buildtype=release --wrap-mode=nodownload \
        -Dmesa-clc=enabled -Dinstall-mesa-clc=true \
        -Dllvm=enabled -Dshared-llvm=enabled \
        -Dgallium-drivers= -Dvulkan-drivers= -Dplatforms= \
        -Dglx=disabled -Degl=disabled -Dgbm=disabled -Dopengl=false \
        -Dgles1=disabled -Dgles2=disabled \
        -Dzlib=disabled -Dexpat=disabled -Dxmlconfig=disabled
    meson compile -C "$nb"
    meson install -C "$nb" --no-rebuild
    [ -x "$host/bin/mesa_clc" ] && [ -x "$host/bin/vtn_bindgen2" ] \
        || fail "native build did not install mesa_clc and vtn_bindgen2"
    CLC_NATIVE="$BUILD/cross/mesa-clc-tools.ini"
    cat > "$CLC_NATIVE" <<EOF
[binaries]
mesa_clc = '$host/bin/mesa_clc'
vtn_bindgen2 = '$host/bin/vtn_bindgen2'
EOF
    INTEL_ON=1
    note "mesa_clc and vtn_bindgen2 built from $MESA_CLC_HOST ($("$MESA_CLC_HOST/bin/llvm-config" --version))"
}

# Mesa — OpenGL, GLX, EGL and GBM, and the Gallium DRI drivers (E23 D5-D8,
# D15). meson. As a GLVND vendor: libGLX_mesa.so.0, libEGL_mesa.so.0 +
# 50_mesa.json; plus libgbm.so.1 with dri_gbm.so, libgallium-<version>.so and
# the dri/*_dri.so links to libdril_dri.so (the X server's GLX loads them).
#
# Drivers (E23 D6):
#   amd64  radeonsi (ACO only, -Damd-use-llvm=false), r600, virgl, llvmpipe,
#          softpipe; iris and crocus when the mesa_clc host tools are present
#          (host_mesa_clc)
#   arm64  v3d, vc4 (with kmsro), virgl, llvmpipe, softpipe
# No nouveau, no Vulkan, lavapipe or zink (phase 2, nextbsd-mesa#2).
#
# LLVM: nextbsd-toolchain's static LLVM 19.1.7 (llvm-config in the cross
# file), linked into libgallium only (E23 D3); nothing LLVM ships.
# patches/mesa 0002 stops radeonsi demanding the AMDGPU component (D8).
#
# Paths are absolute under /usr/X11, so a FreeBSD Mesa in /usr/local never
# mixes in (D4): DRI drivers in /usr/X11/lib/dri, GBM backends in
# /usr/X11/lib/gbm. That one directory is also where NVIDIA's backend
# (nvidia-drm_gbm.so) is linked once nvidia-activate.sh targets /usr/X11
# instead of /usr/local (D15, nextbsd-kernel-extensions-nvidia#2).
#
# Off: Wayland, udev, valgrind, libunwind, lm_sensors, zstd (base's is
# private), VA, rusticl, tools, tests, docs. expat (driconf) is nextbsd-xlibs';
# zlib and libelf are the base's.
build_mesa() {
    comp "Mesa [meson cross]"
    fresh_dirs mesa
    fetch mesa
    llvm_check
    host_mesa_clc
    local drivers clc=()
    case "$T" in
        amd64) drivers=radeonsi,r600,virgl,llvmpipe,softpipe ;;
        arm64) drivers=v3d,vc4,virgl,llvmpipe,softpipe ;;
    esac
    if [ "$INTEL_ON" = 1 ]; then
        drivers="iris,crocus,$drivers"
        clc=(--native-file "$CLC_NATIVE" -Dmesa-clc=system)
    fi
    note "gallium drivers: $drivers"
    # -Db_lundef=false: meson's default --no-undefined can't hold for
    # libgallium with LLVM linked in statically. LLVMSupport's Program.cpp
    # uses `environ`, which NextBSD (like FreeBSD) defines in crt1.o, i.e. in
    # the executable, not in libc.so; it resolves when a program loads
    # libgallium. (A shared libLLVM, as FreeBSD ports use, is linked without
    # --no-undefined for the same reason.)
    meson_build "${clc[@]}" -Db_lundef=false \
        -Dplatforms=x11 -Dglx=dri -Degl=enabled -Dgbm=enabled -Dglvnd=enabled \
        -Dgallium-drivers="$drivers" -Dvulkan-drivers= \
        -Dllvm=enabled -Dshared-llvm=disabled -Ddraw-use-llvm=true -Damd-use-llvm=false \
        -Dopengl=true -Dgles1=disabled -Dgles2=enabled -Dglx-direct=true \
        -Ddri-drivers-path="$X_PREFIX/lib/dri" -Dgbm-backends-path="$X_PREFIX/lib/gbm" \
        -Dxlib-lease=disabled -Dgallium-va=disabled -Dgallium-rusticl=false \
        -Dmicrosoft-clc=disabled -Dvalgrind=disabled -Dlibunwind=disabled \
        -Dlmsensors=disabled -Dzstd=disabled -Dzlib=enabled -Dexpat=enabled \
        -Dxmlconfig=enabled -Ddisplay-info=disabled -Dvideo-codecs= \
        -Dtools= -Dbuild-tests=false -Dhtml-docs=disabled
    # GLX falls back to the "indirect" vendor when the server names none
    # (libglvnd's libglxmapping.c); point it at Mesa, as FreeBSD does with
    # libmap. NVIDIA overrides it with its own libmap entry.
    ln -s libGLX_mesa.so.0 "$COMP_ROOT$X_PREFIX/lib/libGLX_indirect.so.0"
    stage mesa
    local x="$DESTDIR$X_PREFIX" d gallium
    gallium="$x/lib/libgallium-$VERSION.so"
    so_check libGLX_mesa.so.0 libEGL_mesa.so.0 libgbm.so.1
    soname_check "$gallium" "libgallium-$VERSION.so"
    [ "$(readlink "$x/lib/libGLX_indirect.so.0")" = libGLX_mesa.so.0 ] || fail "libGLX_indirect.so.0 link wrong"
    test -f "$x/share/glvnd/egl_vendor.d/50_mesa.json" || fail "50_mesa.json not staged"
    grep -q libEGL_mesa.so.0 "$x/share/glvnd/egl_vendor.d/50_mesa.json" || fail "50_mesa.json does not name libEGL_mesa.so.0"
    test -f "$x/lib/gbm/dri_gbm.so" || fail "gbm/dri_gbm.so not staged"
    test -f "$x/include/gbm.h" || fail "gbm.h not staged"
    # The DRI drivers: links to libdril_dri.so (the shim the server's GLX and
    # older loaders open), one per driver, plus swrast and kms_swrast.
    local want="swrast kms_swrast virtio_gpu"
    case "$T" in
        amd64) want="$want radeonsi r600" ;;
        arm64) want="$want v3d vc4" ;;
    esac
    [ "$INTEL_ON" = 1 ] && want="$want iris crocus"
    for d in $want; do
        [ -e "$x/lib/dri/${d}_dri.so" ] || fail "dri/${d}_dri.so not staged"
    done
    note "DRI drivers: $(cd "$x/lib/dri" && ls | sed 's/_dri\.so$//' | tr '\n' ' ')"
    for d in nouveau i915 zink panfrost; do
        [ ! -e "$x/lib/dri/${d}_dri.so" ] || fail "dri/${d}_dri.so built but not wanted"
    done
    # Absolute paths compiled in (D4, D15).
    has_string "$x/lib/libgbm.so.1" "$X_PREFIX/lib/gbm"
    # llvmpipe is in, with LLVM linked statically: no libLLVM is needed by
    # anything, and libgbm (which NVIDIA uses alone) stays free of LLVM and
    # libgallium.
    has_string "$gallium" "llvmpipe"
    not_needed "$gallium" 'libLLVM|libclang|libwayland|libudev|libzstd'
    not_needed "$x/lib/libgbm.so.1" 'libLLVM|libgallium|libwayland'
    lib_needs libgbm.so.1 libdrm.so.2
    lib_needs libGLX_mesa.so.0 libX11.so.6 libxcb-dri3.so.0
    case "$T" in
        amd64) needed_check "$gallium" libdrm_amdgpu.so.1 ;;
    esac
    needed_check "$gallium" libexpat.so.1
    note "libgallium-$VERSION.so: $(du -k "$gallium" | cut -f1) KiB, NEEDED:" \
        "$("$CROSS_BINDIR/llvm-readelf" -d "$gallium" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' ')"
    pc_check dri "$VERSION"
    [ "$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig" pkgconf --variable=dridriverdir dri)" = "$X_PREFIX/lib/dri" ] \
        || fail "dri.pc dridriverdir is not $X_PREFIX/lib/dri"
    note "dri.pc: dridriverdir=$X_PREFIX/lib/dri"
    pc_check gbm "$VERSION"
}

# libGLU — the OpenGL utility library (mesa/glu). Gershwin's ItemFlow and
# Player and libs-quartzcore use it (E24, nextbsd/nextbsd#574). meson, against
# libglvnd's libOpenGL (gl_provider=glvnd). freeglut is not built: nothing
# calls GLUT.
build_glu() {
    comp "libGLU [meson cross]"
    fresh_dirs glu
    fetch glu
    meson_build -Dgl_provider=glvnd
    stage glu
    test -f "$DESTDIR$X_PREFIX/include/GL/glu.h" || fail "GL/glu.h not staged"
    so_check libGLU.so.1
    lib_needs libGLU.so.1 libOpenGL.so.0
    pc_check glu "$VERSION"
}

# =============================================================================
# driver
# =============================================================================
# Add a component: pin it in sources.lock, write build_<name>() above (hyphens
# in the name become underscores in the function), put its patches, if any, in
# patches/<name>/ with a series file, and add <name> here, one per line, in
# build order.
COMPONENTS="
    libglvnd
    mesa
    glu
"

if [ $# -gt 0 ]; then
    for c in "$@"; do
        case " $(echo $COMPONENTS) " in
            *" $c "*) ;;
            *) fail "unknown component '$c' (known: $(echo $COMPONENTS))" ;;
        esac
    done
    COMPONENTS="$*"
fi

echo "nextbsd-mesa: building [$(echo $COMPONENTS)] for $T/$TA into $DESTDIR$X_PREFIX"
mkdir -p "$DESTDIR"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

echo
echo "==> staged into $DESTDIR:"
( cd "$DESTDIR" && find . ! -type d | sort | sed 's#^\.##' )
echo
echo "==> installed size: $(du -sk "$DESTDIR$X_PREFIX" | cut -f1) KiB in $DESTDIR$X_PREFIX"
