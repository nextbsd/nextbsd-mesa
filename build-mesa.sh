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
#               and into $DESTDIR (the core artifact) or $DESTDIR_X11 (the X
#               artifact).
#
# Two artifacts (nextbsd-mesa#10, E25 audit 4 option C):
#   $DESTDIR      the core: X-free. libglvnd's EGL, GLES, OpenGL and dispatch
#                 libraries, Mesa's core build (libgallium, libEGL_mesa_core,
#                 libgbm, dri_gbm, libdril and the DRI links) and libGLU;
#   $DESTDIR_X11  Mesa's X parts: libglvnd's libGL and libGLX, and from
#                 Mesa's X build only libGLX_mesa, libGLX_indirect, libEGL_mesa
#                 and 50_mesa.json, which run against the core's libgallium.
# No file is in both.
#
# Upstream build systems are used as they are, with NextBSD's options; nothing
# is rewritten as a hand-made makefile. Nothing here uses FreeBSD packages, the
# ports tree or ports tools, and nothing links against nextbsd-userland.
#
# EXECUTION CONTEXT (set up by CI before this runs)
#   Inside the nextbsd-toolchain container (pinned clang/lld 19.1.7 in
#   $CROSS_BINDIR, meson, ninja, pkgconf, bison, flex, python3 with mako and
#   yaml), with $SYSROOT holding, in this order, compat's `continuous` base,
#   nextbsd-displayserver-support's `continuous` artifact (libdrm, expat and
#   the other shared display-server libraries in /usr, .pc files in
#   /usr/libdata/pkgconfig) and nextbsd-xlibs' `continuous` artifact (the X
#   client libraries in /usr/X11), and $LLVM_STATIC holding
#   nextbsd-toolchain's static LLVM 19.1.7 for this arch. $SYSROOT is scratch:
#   this script installs every component into its /usr/X11 as it goes.
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
: "${SYSROOT:?set SYSROOT to the staged NextBSD base with nextbsd-displayserver-support and nextbsd-xlibs}"
: "${CROSS_BINDIR:?set CROSS_BINDIR to the dir holding the cross clang/lld}"
: "${LLVM_STATIC:?set LLVM_STATIC to the unpacked llvm-19-nextbsd-<arch> tree}"
: "${DESTDIR:=/stage}"
: "${DESTDIR_X11:=/stage-x11}"
# Host libraries for Intel's mesa_clc (nextbsd-toolchain#11), in the toolchain
# image. See build_mesa and README "Intel".
: "${MESA_CLC_HOST:=/opt/mesa-clc}"
# amd64 only. on (default): build iris and crocus, and fail if $MESA_CLC_HOST
# is missing; auto: skip them (with a note) when it is missing; off: never.
: "${INTEL_DRIVERS:=on}"

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
export SYSROOT DESTDIR DESTDIR_X11 CROSS_BINDIR

# What goes into the X artifact, relative to $X_PREFIX (globs). Everything
# else libglvnd installs is the core's; everything else Mesa's X build
# installs (its libgallium, libgbm, dri_gbm, DRI links, drirc.d, headers and
# .pc files) is discarded in favour of the core build's.
GLVND_X11_FILES="lib/libGL.so* lib/libGLX.so* include/GL/glx.h include/GL/glxext.h
    include/glvnd/libglxabi.h lib/pkgconfig/gl.pc lib/pkgconfig/glx.pc"
MESA_X11_FILES="lib/libGLX_mesa.so* lib/libGLX_indirect.so.0 lib/libEGL_mesa.so*
    share/glvnd/egl_vendor.d/50_mesa.json"

# pkgconf's search path inside the sysroot, in the cross files' order:
# /usr/libdata/pkgconfig (the base and nextbsd-displayserver-support) before
# $X_PREFIX/lib/pkgconfig, so libdrm and expat come from /usr even while
# nextbsd-xlibs still ships copies in /usr/X11 (E25 plan, migration step 2).
PC_PATH="$SYSROOT/usr/libdata/pkgconfig:$SYSROOT$X_PREFIX/lib/pkgconfig"

# ---- helpers -----------------------------------------------------------------
comp() { echo; echo "==> [$T/$TA] $*"; }
note() { echo "    - $*"; }
fail() { echo "FAIL: $*" >&2; exit 1; }

# in_x11 <cmd>...: run a check against the X artifact ($DESTDIR_X11) instead
# of the core one.
in_x11() { local DESTDIR="$DESTDIR_X11"; "$@"; }

# needed_of <obj>: its DT_NEEDED entries, space-separated.
needed_of() {
    "$CROSS_BINDIR/llvm-readelf" -d "$1" | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p' | tr '\n' ' '
}

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

# The files already in the sysroot (compat's base, nextbsd-displayserver-
# support's and nextbsd-xlibs' artifacts, which CI stages over it), listed
# while the sysroot doesn't yet hold anything from this repo, so stage can
# refuse a component that would overwrite one. A later partial run reuses the
# list.
base_list() {
    BASE_LIST="$BUILD/base-files-$T.list"
    mkdir -p "$BUILD"
    [ -f "$SYSROOT/usr/libdata/pkgconfig/libdrm.pc" ] && [ -f "$SYSROOT/usr/libdata/pkgconfig/libinput.pc" ] \
        || fail "nextbsd-displayserver-support is not staged in $SYSROOT/usr (no libdrm.pc/libinput.pc in /usr/libdata/pkgconfig)"
    [ -f "$SYSROOT$X_PREFIX/lib/pkgconfig/x11.pc" ] \
        || fail "nextbsd-xlibs is not staged in $SYSROOT$X_PREFIX (no x11.pc)"
    if [ ! -e "$SYSROOT$X_PREFIX/lib/pkgconfig/libglvnd.pc" ]; then
        (cd "$SYSROOT" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort) > "$BASE_LIST"
    elif [ ! -f "$BASE_LIST" ]; then
        fail "$SYSROOT already holds this repo's files but $BASE_LIST is missing; start from a fresh sysroot"
    fi
}

# stage <name> [dest]: tidy and check $COMP_ROOT, then copy it into $SYSROOT
# (for the components after this one) and into [dest] (default $DESTDIR, the
# core artifact; $DESTDIR_X11 for the X one).
#   - everything must be under /usr/X11, and nothing may replace a file of the
#     base, nextbsd-displayserver-support or nextbsd-xlibs;
#   - libtool .la files and docs are dropped (man pages are kept);
#   - .pc files from share/pkgconfig and libdata/pkgconfig move to
#     lib/pkgconfig;
#   - no .pc file may name /usr/local or a build-host path, and no symlink may
#     point outside the install.
stage() {
    local name="$1" dest="${2:-$DESTDIR}" x="$COMP_ROOT$X_PREFIX" stray f d clash bad
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
    [ -z "$clash" ] || fail "$name would replace files of the NextBSD base, nextbsd-displayserver-support or nextbsd-xlibs: $clash"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    mkdir -p "$dest"
    (cd "$COMP_ROOT" && tar -cf - .) | (cd "$dest" && tar -xf -)
    note "staged $(cd "$COMP_ROOT" && find . ! -type d | wc -l) files, $(du -sk "$COMP_ROOT" | cut -f1) KiB, into $dest"
}

# to_x11 <glob>...: move staged files (relative to $X_PREFIX) from the core
# artifact to the X artifact. Each glob must match.
to_x11() {
    local g f rel n
    for g in "$@"; do
        n=0
        for f in "$DESTDIR$X_PREFIX"/$g; do
            [ -e "$f" ] || [ -L "$f" ] || continue
            rel="${f#"$DESTDIR"}"
            mkdir -p "$(dirname "$DESTDIR_X11$rel")"
            mv "$f" "$DESTDIR_X11$rel"
            n=$((n + 1))
        done
        [ "$n" -gt 0 ] || fail "to_x11: nothing staged matches $X_PREFIX/$g"
    done
    find "$DESTDIR$X_PREFIX" -type d -empty -delete
    note "moved to the X artifact: $(cd "$DESTDIR_X11$X_PREFIX" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | tr '\n' ' ')"
}

# keep_only <root> <glob>...: delete every file under <root>$X_PREFIX that
# matches none of the globs (relative to $X_PREFIX); each glob must match.
# Prints what was discarded.
keep_only() {
    local root="$1" f rel g keep gone= hit
    shift
    for g in "$@"; do
        hit=0
        for f in "$root$X_PREFIX"/$g; do
            if [ -e "$f" ] || [ -L "$f" ]; then hit=1; fi
        done
        [ "$hit" = 1 ] || fail "keep_only: the X build installed nothing matching $X_PREFIX/$g"
    done
    while IFS= read -r f; do
        rel="${f#"$root$X_PREFIX/"}"
        keep=0
        for g in "$@"; do
            # shellcheck disable=SC2053 # $g is a glob on purpose
            if [[ "$rel" == $g ]]; then keep=1; break; fi
        done
        if [ "$keep" = 0 ]; then
            rm -f "$f"
            gone="$gone $rel"
        fi
    done < <(find "$root$X_PREFIX" ! -type d | LC_ALL=C sort)
    find "$root$X_PREFIX" -type d -empty -delete
    note "discarded from the X build:$gone"
}

# pc_check <module> [version]: the staged .pc resolves through pkgconf the way
# later components (and nextbsd-xlibre) will see it.
pc_check() {
    local mod="$1" want="${2:-}" got
    got=$(PKG_CONFIG_LIBDIR="$PC_PATH" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" \
          pkgconf --modversion "$mod") || fail "pkgconf cannot resolve $mod"
    [ -z "$want" ] || [ "$got" = "$want" ] || fail "$mod.pc is version $got, expected $want"
    note "pkgconf ok: $mod $got"
}

# pc_from_usr <module>...: pkgconf, searching the cross files' path, finds
# each module's .pc in /usr/libdata/pkgconfig (nextbsd-displayserver-support),
# not in $X_PREFIX/lib/pkgconfig (nextbsd-xlibs' copies, until
# nextbsd-xlibs#9).
pc_from_usr() {
    local mod pc
    for mod in "$@"; do
        pc=$(PKG_CONFIG_LIBDIR="$PC_PATH" PKG_CONFIG_SYSROOT_DIR="$SYSROOT" pkgconf --path "$mod") \
            || fail "pkgconf cannot resolve $mod"
        [ "$pc" = "$SYSROOT/usr/libdata/pkgconfig/$mod.pc" ] \
            || fail "$mod resolves to ${pc#"$SYSROOT"}, not /usr/libdata/pkgconfig/$mod.pc"
        note "pkgconf: $mod -> /usr/libdata/pkgconfig/$mod.pc" \
            "($(PKG_CONFIG_LIBDIR="$PC_PATH" pkgconf --modversion "$mod"))"
    done
}

# meson_deps_from_usr <regex>: every external dependency of the configured
# $COMP_BUILD whose name matches <regex> was found, and none of its compile or
# link arguments points into $X_PREFIX (so the headers and libraries meson
# uses are the /usr copies). Prints what meson recorded.
meson_deps_from_usr() {
    meson introspect "$COMP_BUILD" --dependencies | python3 -I -c '
import json, re, sys
pat, sysroot, xp = sys.argv[1], sys.argv[2], sys.argv[3]
deps = [d for d in json.load(sys.stdin) if re.fullmatch(pat, d["name"])]
if not deps:
    sys.exit("FAIL: meson found no dependency matching " + pat)
bad = 0
for d in deps:
    args = [a.replace(sysroot, "<sysroot>") for a in d.get("compile_args", []) + d.get("link_args", [])]
    print("    - meson dep %s %s: %s" % (d["name"], d.get("version", "?"), " ".join(args) or "(no args)"))
    if any(xp + "/" in a for a in args):
        print("FAIL: meson dependency %s uses %s" % (d["name"], xp), file=sys.stderr)
        bad = 1
sys.exit(bad)
' "$1" "$SYSROOT" "$X_PREFIX" || fail "meson dependencies matching $1 do not all come from /usr"
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
#
# One build, split between the artifacts: the GLX side (libGL, libGLX, which
# link libX11, the GLX headers, gl.pc and glx.pc) goes into the X artifact,
# the rest (libEGL, libGLdispatch, libOpenGL, libGLES*, the GL, EGL, GLES and
# KHR headers) into the core one.
build_libglvnd() {
    comp "libglvnd [meson cross]"
    fresh_dirs libglvnd
    fetch libglvnd
    meson_build -Dasm=enabled -Dx11=enabled -Dglx=enabled -Degl=true \
        -Dgles1=true -Dgles2=true -Dheaders=true -Dhgl=false \
        -Dtls=true -Ddispatch-tls=true -Dentrypoint-patching=enabled
    stage libglvnd
    # shellcheck disable=SC2086 # word-splitting the glob list is intended
    to_x11 $GLVND_X11_FILES
    local x="$DESTDIR$X_PREFIX"
    test -f "$x/include/GL/gl.h" || fail "GL/gl.h not staged"
    test -f "$x/include/EGL/egl.h" || fail "EGL/egl.h not staged"
    test -f "$x/include/KHR/khrplatform.h" || fail "KHR/khrplatform.h not staged"
    test -f "$DESTDIR_X11$X_PREFIX/include/GL/glx.h" || fail "GL/glx.h not in the X artifact"
    so_check libGLdispatch.so.0 libOpenGL.so.0 libEGL.so.1 libGLESv1_CM.so.1 libGLESv2.so.2
    in_x11 so_check libGL.so.1 libGLX.so.0
    in_x11 lib_needs libGL.so.1 libGLdispatch.so.0 libGLX.so.0
    in_x11 lib_needs libGLX.so.0 libGLdispatch.so.0 libX11.so.6
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
# toolchain image at $MESA_CLC_HOST (nextbsd-toolchain#11). Build the two
# tools natively from the same patched Mesa tree (the E23 audit's option (b);
# nextbsd-toolchain mesa-clc/README.md): no drivers, no platforms, nothing that needs target libraries. The cross
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
        note "NOTE: INTEL_DRIVERS=auto and $MESA_CLC_HOST is not in this toolchain"
        note "      image: iris and crocus are NOT built; Intel GPUs fall back to"
        note "      llvmpipe (E23 D7)."
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
    # Not into $DESTDIR (exported for the cross build): these tools never ship.
    env -u DESTDIR meson install -C "$nb" --no-rebuild
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

# Mesa — OpenGL, EGL and GBM, GLX, and the Gallium DRI drivers (E23 D5-D8,
# D15). meson. Built twice from the same patched tree (nextbsd-mesa#10, E25
# audit 4 option C), sharing one X-free libgallium:
#
#   core  -Dplatforms= -Dglx=disabled, GLVND vendor `mesa_core`. Ships
#         libgallium-<version>.so, libEGL_mesa_core.so.0 + 50_mesa_core.json,
#         libgbm.so.1 + gbm/dri_gbm.so, dri/libdril_dri.so and the
#         dri/*_dri.so links (the X server's GLX loads them), drirc.d, gbm.h,
#         dri.pc and gbm.pc. Nothing in it links an X library. EGL has the
#         drm (GBM), surfaceless and device platforms.
#   X     the options this repo always used (-Dplatforms=x11 -Dglx=dri,
#         vendor `mesa`). Only libGLX_mesa.so.0 (+ libGLX_indirect.so.0),
#         libEGL_mesa.so.0 and 50_mesa.json are kept, for the X artifact;
#         its libgallium, libgbm, dri_gbm and the rest are discarded. They
#         run against the core's libgallium: patches/mesa 0010 builds the
#         DRI3 helper into these frontends instead of into libgallium, so the
#         two builds' libgallium export the same symbols (checked).
#
# GLVND: libglvnd reads the vendor JSONs in strcmp order (libeglvendor.c), so
# with both artifacts installed 50_mesa.json sorts before 50_mesa_core.json
# and the X vendor answers first, as before the split; with the core alone,
# 50_mesa_core.json is the only Mesa vendor.
#
# Drivers (E23 D6), the same in both builds:
#   amd64  iris, crocus (their shaders compiled by the build-host mesa_clc,
#          host_mesa_clc), radeonsi (ACO only, -Damd-use-llvm=false), r600,
#          virgl, llvmpipe, softpipe
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
# private), VA, rusticl, tools, tests, docs. libdrm and expat (driconf) are
# nextbsd-displayserver-support's, in /usr; zlib and libelf are the base's.
# displayserver-support's libudev is found by meson but only Vulkan's WSI uses
# it, so nothing here links it (checked on libgallium below).
build_mesa() {
    comp "Mesa [meson cross]"
    fresh_dirs mesa
    fetch mesa
    llvm_check
    # libdrm and expat resolve to nextbsd-displayserver-support's .pc files.
    pc_from_usr libdrm expat
    if [ "$T" = amd64 ]; then
        pc_from_usr libdrm_amdgpu libdrm_radeon
    fi
    host_mesa_clc
    local drivers clc=() common
    case "$T" in
        amd64) drivers=radeonsi,r600,virgl,llvmpipe,softpipe ;;
        arm64) drivers=v3d,vc4,virgl,llvmpipe,softpipe ;;
    esac
    if [ "$INTEL_ON" = 1 ]; then
        drivers="iris,crocus,$drivers"
        clc=(--native-file "$CLC_NATIVE" -Dmesa-clc=system)
    fi
    note "gallium drivers: $drivers"
    # Options both builds share.
    # -Db_lundef=false: meson's default --no-undefined can't hold for
    # libgallium with LLVM linked in statically. LLVMSupport's Program.cpp
    # uses `environ`, which NextBSD (like FreeBSD) defines in crt1.o, i.e. in
    # the executable, not in libc.so; it resolves when a program loads
    # libgallium. (A shared libLLVM, as FreeBSD ports use, is linked without
    # --no-undefined for the same reason.)
    common=("${clc[@]}" -Db_lundef=false
        -Degl=enabled -Dgbm=enabled -Dglvnd=enabled
        -Dgallium-drivers="$drivers" -Dvulkan-drivers=
        -Dllvm=enabled -Dshared-llvm=disabled -Ddraw-use-llvm=true -Damd-use-llvm=false
        -Dopengl=true -Dgles1=disabled -Dgles2=enabled
        -Ddri-drivers-path="$X_PREFIX/lib/dri" -Dgbm-backends-path="$X_PREFIX/lib/gbm"
        -Dxlib-lease=disabled -Dgallium-va=disabled -Dgallium-rusticl=false
        -Dmicrosoft-clc=disabled -Dvalgrind=disabled -Dlibunwind=disabled
        -Dlmsensors=disabled -Dzstd=disabled -Dzlib=enabled -Dexpat=enabled
        -Dxmlconfig=enabled -Ddisplay-info=disabled -Dvideo-codecs=
        -Dtools= -Dbuild-tests=false -Dhtml-docs=disabled)

    # ---- core build: no X platform, no GLX; vendor mesa_core ----
    comp "Mesa core build (no X) [meson cross]"
    meson_build "${common[@]}" \
        -Dplatforms= -Dglx=disabled -Dglvnd-vendor-name=mesa_core
    # libdrm (and libdrm_amdgpu/libdrm_radeon on amd64) and expat are
    # nextbsd-displayserver-support's in /usr, not nextbsd-xlibs' /usr/X11
    # copies (E25 plan, migration step 2). Same versions and sonames, so the
    # result runs the same against either.
    meson_deps_from_usr 'libdrm(_.*)?|expat'
    stage mesa
    MESA_CORE_BUILD="$COMP_BUILD"

    # ---- X build: the options from before the split; vendor mesa ----
    comp "Mesa X build (GLX, x11 EGL vendor) [meson cross]"
    fresh_dirs mesa-x11
    meson_build "${common[@]}" \
        -Dplatforms=x11 -Dglx=dri -Dglx-direct=true
    meson_deps_from_usr 'libdrm(_.*)?|expat'
    MESA_X11_BUILD="$COMP_BUILD"
    # GLX falls back to the "indirect" vendor when the server names none
    # (libglvnd's libglxmapping.c); point it at Mesa, as FreeBSD does with
    # libmap. NVIDIA overrides it with its own libmap entry.
    ln -s libGLX_mesa.so.0 "$COMP_ROOT$X_PREFIX/lib/libGLX_indirect.so.0"
    # libdril_dri.so and the dri/*_dri.so links (what the X server's GLX and
    # older loaders open) go into the core artifact: upstream builds them only
    # with GLX or the x11 platform (src/meson.build), but libdril links only
    # libgbm and runs against the core's libgallium through it (check 2).
    local dril="$BUILD/mesa-dril-$T" clash
    rm -rf "$dril"
    mkdir -p "$dril$X_PREFIX/lib"
    mv "$COMP_ROOT$X_PREFIX/lib/dri" "$dril$X_PREFIX/lib/dri"
    clash=$(cd "$dril" && find . ! -type d | sed 's#^\./##' | LC_ALL=C sort | LC_ALL=C comm -12 - "$BASE_LIST")
    [ -z "$clash" ] || fail "dri/ would replace files of the sysroot inputs: $clash"
    (cd "$dril" && tar -cf - .) | (cd "$SYSROOT" && tar -xf -)
    (cd "$dril" && tar -cf - .) | (cd "$DESTDIR" && tar -xf -)
    note "from the X build into the core: $(cd "$dril$X_PREFIX/lib" && find dri ! -type d | LC_ALL=C sort | tr '\n' ' ')"
    # Keep the X build's libgallium aside for the symbol checks, then drop
    # everything but the X frontends.
    MESA_X11_GALLIUM="$BUILD/mesa-x11-discarded-$T/libgallium-$VERSION.so"
    mkdir -p "$(dirname "$MESA_X11_GALLIUM")"
    cp "$COMP_ROOT$X_PREFIX/lib/libgallium-$VERSION.so" "$MESA_X11_GALLIUM"
    # shellcheck disable=SC2086 # word-splitting the glob list is intended
    keep_only "$COMP_ROOT" $MESA_X11_FILES
    stage mesa-x11 "$DESTDIR_X11"
    mesa_core_checks
    if [ "$INTEL_ON" = 1 ]; then intel_checks; fi
    mesa_x11_checks
    mesa_split_checks
    no_clc_host_files
}

# The core build's install, in $DESTDIR.
mesa_core_checks() {
    local x="$DESTDIR$X_PREFIX" d f gallium
    gallium="$x/lib/libgallium-$VERSION.so"
    so_check libEGL_mesa_core.so.0 libgbm.so.1
    soname_check "$gallium" "libgallium-$VERSION.so"
    test -f "$x/lib/gbm/dri_gbm.so" || fail "gbm/dri_gbm.so not staged"
    test -f "$x/include/gbm.h" || fail "gbm.h not staged"
    for f in libGLX_mesa.so.0 libEGL_mesa.so.0 libGLX_indirect.so.0; do
        [ ! -e "$x/lib/$f" ] || fail "the core build installed $f"
    done
    # The DRI drivers: links to libdril_dri.so (the shim the server's GLX and
    # older loaders open), one per driver, plus swrast and kms_swrast.
    local want="swrast kms_swrast virtio_gpu"
    case "$T" in
        amd64) want="$want radeonsi r600" ;;
        arm64) want="$want v3d vc4" ;;
    esac
    if [ "$INTEL_ON" = 1 ]; then want="$want iris crocus"; fi
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
    not_needed "$gallium" 'libLLVM|libclang|libSPIRV|libwayland|libudev|libzstd'
    not_needed "$x/lib/libgbm.so.1" 'libLLVM|libgallium|libwayland'
    lib_needs libgbm.so.1 libdrm.so.2
    case "$T" in
        amd64) needed_check "$gallium" libdrm_amdgpu.so.1 ;;
    esac
    needed_check "$gallium" libexpat.so.1
    pc_check dri "$VERSION"
    [ "$(PKG_CONFIG_LIBDIR="$SYSROOT$X_PREFIX/lib/pkgconfig" pkgconf --variable=dridriverdir dri)" = "$X_PREFIX/lib/dri" ] \
        || fail "dri.pc dridriverdir is not $X_PREFIX/lib/dri"
    note "dri.pc: dridriverdir=$X_PREFIX/lib/dri"
    pc_check gbm "$VERSION"
    egl_core_checks
    no_x_in_core
    for f in "libgallium-$VERSION.so" libEGL_mesa_core.so.0 gbm/dri_gbm.so dri/libdril_dri.so libEGL.so.1; do
        note "core $f ($(du -kL "$x/lib/$f" | cut -f1) KiB) NEEDED: $(needed_of "$x/lib/$f")"
    done
}

# EGL platforms (E25 D8, audit 2 R1, audit 4). The core build has no platform
# option at all: Mesa's meson adds `surfaceless` whenever EGL is built and
# `drm` (the GBM platform) whenever GBM is too, so -Degl=enabled
# -Dgbm=enabled provide EGL on GBM, with EGL_KHR_platform_gbm /
# EGL_MESA_platform_gbm, EGL_MESA_platform_surfaceless and
# EGL_EXT_platform_device, and no x11 platform. libglvnd's libEGL.so.1 (what
# an EGL-only client such as the WindowServer links) needs nothing from X.
egl_core_checks() {
    local x="$DESTDIR$X_PREFIX" p f nj="$MESA_CORE_BUILD/build.ninja"
    for p in DRM SURFACELESS; do
        grep -q -F -- "-DHAVE_${p}_PLATFORM" "$nj" \
            || fail "core Mesa configured without the ${p,,} EGL platform (no -DHAVE_${p}_PLATFORM)"
    done
    for p in X11 XCB; do
        if grep -q -F -- "-DHAVE_${p}_PLATFORM" "$nj"; then
            fail "core Mesa configured with the ${p,,} platform"
        fi
    done
    for f in platform_drm.c platform_surfaceless.c platform_device.c; do
        grep -q -F "src/egl/drivers/dri2/$f" "$nj" || fail "core EGL $f not built"
    done
    for f in platform_x11.c platform_x11_dri3.c loader_dri3_helper.c; do
        if grep -q -F "/$f" "$nj"; then fail "core build compiles $f"; fi
    done
    note "core EGL platforms built: drm (GBM), surfaceless, device; no x11, no xcb"
    for p in EGL_KHR_platform_gbm EGL_MESA_platform_gbm EGL_MESA_platform_surfaceless EGL_EXT_platform_device; do
        has_string "$x/lib/libEGL_mesa_core.so.0" "$p"
    done
    lib_needs libEGL_mesa_core.so.0 libgbm.so.1 libdrm.so.2 "libgallium-$VERSION.so"
    not_needed "$x/lib/libEGL.so.1" 'libX11|libxcb'
}

# CI check 2 (nextbsd-mesa#10, audit 4 §2 C): libgallium, libEGL_mesa_core,
# dri_gbm.so and libdril link no X library, and libgallium has no undefined
# xcb, xshmfence or DRI3-helper symbol left for lazy binding to trip over.
no_x_in_core() {
    local x="$DESTDIR$X_PREFIX" f und
    echo "    [check 2] no libX11/libxcb/libxshmfence in the core's Mesa libraries"
    for f in "libgallium-$VERSION.so" libEGL_mesa_core.so.0 gbm/dri_gbm.so dri/libdril_dri.so; do
        not_needed "$x/lib/$f" 'libX11|libxcb|libxshmfence'
    done
    und=$("$CROSS_BINDIR/llvm-readelf" --dyn-syms --wide "$x/lib/libgallium-$VERSION.so" \
        | awk '$NF ~ /^\([0-9]+\)$/ { NF-- } NF >= 8 && $(NF-1) == "UND" { print $NF }' | grep -E '^(xcb_|xshmfence_|loader_dri3_)' || true)
    [ -z "$und" ] || fail "core libgallium still references $(echo $und)"
    note "core libgallium: no undefined xcb_*, xshmfence_* or loader_dri3_* symbols"
}

# The X build's kept install, in $DESTDIR_X11.
mesa_x11_checks() {
    local x="$DESTDIR_X11$X_PREFIX" p f nj="$MESA_X11_BUILD/build.ninja"
    in_x11 so_check libGLX_mesa.so.0 libEGL_mesa.so.0
    [ "$(readlink "$x/lib/libGLX_indirect.so.0")" = libGLX_mesa.so.0 ] || fail "libGLX_indirect.so.0 link wrong"
    for p in DRM SURFACELESS X11 XCB; do
        grep -q -F -- "-DHAVE_${p}_PLATFORM" "$nj" \
            || fail "X Mesa configured without the ${p,,} EGL platform (no -DHAVE_${p}_PLATFORM)"
    done
    for f in platform_drm.c platform_surfaceless.c platform_device.c platform_x11.c; do
        grep -q -F "src/egl/drivers/dri2/$f" "$nj" || fail "X EGL $f not built"
    done
    note "X EGL platforms built: drm (GBM), surfaceless, device, x11, xcb"
    for p in EGL_KHR_platform_gbm EGL_MESA_platform_gbm EGL_MESA_platform_surfaceless EGL_EXT_platform_device; do
        has_string "$x/lib/libEGL_mesa.so.0" "$p"
    done
    in_x11 lib_needs libEGL_mesa.so.0 libgbm.so.1 libdrm.so.2 "libgallium-$VERSION.so"
    in_x11 lib_needs libGLX_mesa.so.0 libX11.so.6 libxcb-dri3.so.0 "libgallium-$VERSION.so"
    for f in libEGL_mesa.so.0 libGLX_mesa.so.0 libGLX.so.0 libGL.so.1; do
        note "x11 $f NEEDED: $(needed_of "$x/lib/$f")"
    done
}

# The checks that make one libgallium safe for both builds (nextbsd-mesa#10,
# audit 4 §2 C, checks 3-5), and the GLVND vendor layout.
mesa_split_checks() {
    local core_g="$DESTDIR$X_PREFIX/lib/libgallium-$VERSION.so" nj
    echo "    [checks 3, 4] X frontends against the core libgallium"
    python3 -I - "$CROSS_BINDIR/llvm-readelf" "$core_g" "$MESA_X11_GALLIUM" \
        "$SYSROOT" "$X_PREFIX" "$DESTDIR$X_PREFIX/lib" "$DESTDIR_X11$X_PREFIX/lib" \
        "$DESTDIR_X11$X_PREFIX/lib/libGLX_mesa.so.0" "$DESTDIR_X11$X_PREFIX/lib/libEGL_mesa.so.0" <<'PY' \
        || fail "the X frontends do not fit the core libgallium"
import os, re, subprocess, sys
readelf, core_g, x_g, sysroot, xp, core_lib, x11_lib, *fronts = sys.argv[1:]

def run(*a):
    return subprocess.run([readelf, *a], check=True, capture_output=True, text=True).stdout

def dynsyms(path):
    """(defined, undefined non-weak) dynamic symbol names, versions kept."""
    d, u = set(), set()
    for line in run("--dyn-syms", "--wide", path).splitlines():
        f = line.split()
        if f and re.fullmatch(r"\(\d+\)", f[-1]):
            f = f[:-1]  # "name@VER (2)": drop the version index
        if len(f) < 8 or not f[0].rstrip(":").isdigit():
            continue
        bind, ndx, name = f[4], f[-2], f[-1]
        if bind == "LOCAL":
            continue
        if ndx == "UND":
            if bind != "WEAK":
                u.add(name.split("@")[0])
        else:
            d.add(name)
    return d, u

def needed(path):
    return [l.split("[", 1)[1].rstrip("]") for l in run("-d", path).splitlines() if "(NEEDED)" in l]

def find(soname):
    if soname.startswith("libgallium-"):
        return core_g  # the shipped one, never the X build's
    for d in (core_lib, x11_lib, sysroot + "/lib", sysroot + "/usr/lib", sysroot + xp + "/lib"):
        p = os.path.join(d, soname)
        if os.path.exists(p):
            return p
    return None

bare = lambda names: {n.split("@")[0] for n in names}
core_exp, _ = dynsyms(core_g)
x_exp, _ = dynsyms(x_g)
bad = 0

# Check 4: the discarded X-build libgallium exports exactly what the core's does.
if core_exp != x_exp:
    print("FAIL [check 4]: core and X-build libgallium export different symbols", file=sys.stderr)
    for n in sorted(core_exp - x_exp): print("    only core: " + n, file=sys.stderr)
    for n in sorted(x_exp - core_exp): print("    only X:    " + n, file=sys.stderr)
    bad = 1
else:
    print("    - [check 4] X-build libgallium exports exactly the core's %d symbols" % len(core_exp))

# Check 3: every undefined symbol of the X frontends that libgallium provides
# is exported by the core libgallium, and every other one by a library in
# the frontend's DT_NEEDED closure (core, X artifact, sysroot inputs).
core_bare, x_bare = bare(core_exp), bare(x_exp)
crt = {"environ", "__progname"}  # defined in crt1.o, by the executable
for fr in fronts:
    name = os.path.basename(fr)
    _, und = dynsyms(fr)
    helper = sorted(s for s in und if s.startswith("loader_dri3_"))
    if helper:
        print("FAIL [check 3]: %s still imports %s (patch 0010 not effective)" % (name, " ".join(helper)), file=sys.stderr)
        bad = 1
    from_g = und & (x_bare | core_bare)
    missing = sorted(from_g - core_bare)
    if missing:
        print("FAIL [check 3]: %s needs from libgallium, but the core's lacks: %s" % (name, " ".join(missing)), file=sys.stderr)
        bad = 1
    provided, seen, todo = set(), set(), list(needed(fr))
    while todo:
        so = todo.pop()
        if so in seen:
            continue
        seen.add(so)
        p = find(so)
        if p is None:
            print("FAIL [check 3]: %s: DT_NEEDED %s not found" % (name, so), file=sys.stderr)
            bad = 1
            continue
        dd, _ = dynsyms(p)
        provided |= bare(dd)
        todo += needed(p)
    unresolved = sorted(und - provided - crt)
    if unresolved:
        print("FAIL [check 3]: %s: undefined and in no DT_NEEDED library: %s" % (name, " ".join(unresolved)), file=sys.stderr)
        bad = 1
    print("    - [check 3] %s: %d undefined symbols, %d from libgallium (all exported by the core's), "
          "%d unresolved; loader_dri3_* imports: %d" % (name, len(und), len(from_g), len(unresolved), len(helper)))
sys.exit(bad)
PY
    # Check 5: zink's Vulkan WSI defines VK_USE_PLATFORM_XCB_KHR, which changes
    # struct dri_drawable (dri_drawable.h) between an X and an X-free build, and
    # kopper.c calls the DRI3 helper from inside libgallium. Until that is
    # handled (audit 4 §1.4, nextbsd-mesa#2), neither build may define it.
    echo "    [check 5] VK_USE_PLATFORM_XCB_KHR"
    for nj in "$MESA_CORE_BUILD/build.ninja" "$MESA_X11_BUILD/build.ninja"; do
        if grep -q -F -- '-DVK_USE_PLATFORM_XCB_KHR' "$nj"; then
            fail "VK_USE_PLATFORM_XCB_KHR is defined in $(basename "$(dirname "$nj")") (zink): one libgallium no longer fits both builds"
        fi
    done
    note "VK_USE_PLATFORM_XCB_KHR is defined in neither build"
    glvnd_layout_checks
}

# GLVND vendors: with the core alone, libglvnd's libEGL.so.1 finds exactly
# one Mesa vendor, 50_mesa_core.json -> libEGL_mesa_core.so.0 (EGL on GBM,
# surfaceless and device). The X artifact adds 50_mesa.json ->
# libEGL_mesa.so.0, which libglvnd's strcmp-sorted scan (LC_ALL=C sort here)
# puts first, so with both the X vendor answers first, as before the split.
glvnd_layout_checks() {
    local cd="$DESTDIR$X_PREFIX/share/glvnd/egl_vendor.d" xd="$DESTDIR_X11$X_PREFIX/share/glvnd/egl_vendor.d" first
    [ "$(ls "$cd")" = 50_mesa_core.json ] || fail "core egl_vendor.d is not just 50_mesa_core.json: $(ls "$cd" | tr '\n' ' ')"
    grep -q '"libEGL_mesa_core.so.0"' "$cd/50_mesa_core.json" || fail "50_mesa_core.json does not name libEGL_mesa_core.so.0"
    [ "$(ls "$xd")" = 50_mesa.json ] || fail "X egl_vendor.d is not just 50_mesa.json: $(ls "$xd" | tr '\n' ' ')"
    grep -q '"libEGL_mesa.so.0"' "$xd/50_mesa.json" || fail "50_mesa.json does not name libEGL_mesa.so.0"
    [ -e "$DESTDIR$X_PREFIX/lib/libEGL.so.1" ] || fail "libglvnd's libEGL.so.1 is not in the core"
    first=$(printf '%s\n' 50_mesa_core.json 50_mesa.json | LC_ALL=C sort | head -n 1)
    [ "$first" = 50_mesa.json ] || fail "50_mesa.json does not sort before 50_mesa_core.json"
    note "GLVND: core alone -> 50_mesa_core.json (libEGL_mesa_core.so.0); with the X artifact" \
        "50_mesa.json (libEGL_mesa.so.0) is read first"
}

# iris and crocus (E23 D6/D7) are compiled into the core libgallium: their
# sources are in the build, their shaders were compiled by the build-host
# mesa_clc (Mesa would otherwise have built its own), and libgallium carries
# Intel code.
intel_checks() {
    local d nj="$MESA_CORE_BUILD/build.ninja"
    for d in iris crocus; do
        grep -q -F "src/gallium/drivers/$d/" "$nj" || fail "$d is not in the build"
    done
    has_string "$DESTDIR$X_PREFIX/lib/libgallium-$VERSION.so" INTEL_DEBUG
    grep -q -F "$BUILD/mesa-clc-host/bin/mesa_clc" "$nj" \
        || fail "the cross build does not run the build-host mesa_clc"
    if grep -q -E 'src/compiler/clc/mesa_clc\b|build mesa_clc:' "$nj"; then
        fail "the cross build compiles its own mesa_clc"
    fi
    note "iris and crocus built; Intel shaders compiled by the build-host mesa_clc"
}

# needed_closure <label> <with_xlibs: 0|1> <artifact>...: every DT_NEEDED of
# every ELF object in the first <artifact> resolves to a library in one of the
# <artifact>s' $X_PREFIX/lib, or to the sysroot inputs (a file listed in
# $BASE_LIST under /lib or /usr/lib: the base and
# nextbsd-displayserver-support; with <with_xlibs> 1 also /usr/X11/lib:
# nextbsd-xlibs).
needed_closure() {
    local label="$1" withx="$2" own="$3" f n d ok bad=0 all=
    shift 2
    for f in $(find "$own$X_PREFIX" -type f \( -name '*.so' -o -name '*.so.*' \)); do
        for n in $("$CROSS_BINDIR/llvm-readelf" -d "$f" 2>/dev/null | sed -n 's/.*NEEDED.*\[\(.*\)\]/\1/p'); do
            ok=0
            for d in "$@"; do
                if [ -e "$d$X_PREFIX/lib/$n" ]; then ok=1; break; fi
            done
            if [ "$ok" = 0 ] && grep -q -x -e "lib/$n" -e "usr/lib/$n" "$BASE_LIST"; then
                ok=1
            fi
            if [ "$ok" = 0 ] && [ "$withx" = 1 ] && grep -q -x "usr/X11/lib/$n" "$BASE_LIST"; then
                ok=1
            fi
            if [ "$ok" = 0 ]; then
                echo "FAIL: [$label] ${f#"$own"} needs $n, which is not in the allowed inputs" >&2
                bad=1
            fi
            all="$all $n"
        done
    done
    [ "$bad" = 0 ] || fail "[$label] unresolved DT_NEEDED entries"
    note "[$label] every DT_NEEDED resolves:" "$(printf '%s\n' $all | LC_ALL=C sort -u | tr '\n' ' ')"
}

# Nothing of the build-host mesa_clc toolchain ships in either artifact: no
# mesa_clc or vtn_bindgen2, no LLVM, clang or SPIR-V library, no
# $MESA_CLC_HOST or build-host tool path compiled in.
no_clc_host_files() {
    local bad dest
    for dest in "$DESTDIR" "$DESTDIR_X11"; do
        [ -d "$dest" ] || continue
        bad=$(cd "$dest" && find . \( -name 'mesa_clc*' -o -name 'vtn_bindgen*' -o -name 'libLLVM*' \
            -o -name 'libclang*' -o -name '*SPIRV*' -o -name '*spirv-tools*' \) -print)
        [ -z "$bad" ] || fail "build-host mesa_clc files staged in $dest: $bad"
        bad=$(grep -r -l -a -F -e "$MESA_CLC_HOST" -e "$BUILD/mesa-clc-host" "$dest" || true)
        [ -z "$bad" ] || fail "staged files name the build-host mesa_clc toolchain: $bad"
    done
    note "nothing from the build-host mesa_clc toolchain ($MESA_CLC_HOST) is staged"
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

echo "nextbsd-mesa: building [$(echo $COMPONENTS)] for $T/$TA into $DESTDIR$X_PREFIX (core) and $DESTDIR_X11$X_PREFIX (X)"
mkdir -p "$DESTDIR" "$DESTDIR_X11"
base_list
for c in $COMPONENTS; do
    "build_$(printf '%s' "$c" | tr - _)"
done

# Both artifacts, as published (nextbsd-mesa#10).
comp "artifact checks"
# Check 1: the core resolves with the base and nextbsd-displayserver-support
# alone, without nextbsd-xlibs (or the X artifact).
echo "    [check 1] core DT_NEEDED closure without nextbsd-xlibs"
needed_closure core 0 "$DESTDIR"
if [ -n "$(find "$DESTDIR_X11" ! -type d -print -quit)" ]; then
    needed_closure x11 1 "$DESTDIR_X11" "$DESTDIR"
    # No path is in both artifacts (each is one package, nextbsd-pkg#34).
    overlap=$(LC_ALL=C comm -12 <(cd "$DESTDIR" && find . ! -type d | LC_ALL=C sort) \
                                <(cd "$DESTDIR_X11" && find . ! -type d | LC_ALL=C sort))
    [ -z "$overlap" ] || fail "paths in both the core and the X artifact: $(echo $overlap)"
    note "no path is in both artifacts"
fi

for d in "$DESTDIR" "$DESTDIR_X11"; do
    echo
    echo "==> staged into $d:"
    ( cd "$d" && find . ! -type d | LC_ALL=C sort | sed 's#^\.##' )
done
echo
echo "==> installed size: core $(du -sk "$DESTDIR$X_PREFIX" | cut -f1) KiB in $DESTDIR$X_PREFIX," \
    "X $( [ -d "$DESTDIR_X11$X_PREFIX" ] && du -sk "$DESTDIR_X11$X_PREFIX" | cut -f1 || echo 0) KiB in $DESTDIR_X11$X_PREFIX"
