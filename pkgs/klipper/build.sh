#!/usr/bin/env bash
# Klipper -- the fork's klippy tree, with c_helper.so built from the chelper
# sources that ship inside it.
#
# THE .so IS BUILT FROM THE TREE THAT SHIPS, which is why this recipe compiles
# anything rather than shipping a prebuilt object. cffi resolves symbols
# LAZILY, so a c_helper.so built from older sources than the klippy beside it
# imports cleanly, passes an ABI check, installs, boots -- and dies at
# "Unhandled exception during connect" on the printer. That happened. One
# source verb means one tree, so the failure is unrepresentable here.
#
# NO CACHE OF ITS OWN: pkg_begin's stamp is the pinned commit and the
# toolchain filename, so a bump to either rebuilds and nothing else does.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin klipper || exit 0
pkg_toolchain
pkg_unpack "$KLIPPER_TGZ"

# GitHub's generated tarball wraps the repository in klipper-<sha>/, and the
# unpack keeps that wrapper rather than hiding the archive's shape behind
# --strip-components. The guard is bin/patch.sh's, kept: a tarball whose shape
# changed under us would build nothing, which looks like a clean build and a
# printer that cannot move.
_top="klipper-$KLIPPER_VERSION"
[ -f "$PKG_WORK/src/$_top/klippy/chelper/__init__.py" ] || pkg_die \
    "klipper: no klippy/chelper/__init__.py in $(basename "$KLIPPER_TGZ")"

# THE LINK LINE IS KLIPPER'S OWN. Every flag is copied from COMPILE_ARGS in
# klippy/chelper/__init__.py -- what the printer would use if it could
# compile, which it cannot: the stock rootfs has no cc. -shared -fPIC and $CC
# come from pkg_build, so the ABI is the wrapper's and not this file's.
PKG_CC_SHARED='-Wall -g -O2 -flto -fwhole-program -fno-use-linker-plugin
               -o klippy/chelper/c_helper.so klippy/chelper/*.c'
pkg_build "$_top"

# Stock ships only a handful of klippy files as an overlay; this is a
# different Klipper generation (v0.13 against FlashForge's v0.12), so the
# WHOLE tree ships -- a half-overwritten mixture is what shipped as
# v20260824-nova-kakhovka and killed klippy at connect with a cffi arg-count
# error. See docs/notes/20-klipper-fork.md.
pkg_stage "$PKG_WORK/src/$_top/klippy" "klipper/klippy"

# The toolchanger extras, ON TOP of the fork's own -- the order stock run.sh
# used, kept because klippy has no search path: it resolves an extra as
# dirname(klippy.py)/extras/<name>.py and nothing else.
#
# NOT gated on BUILD_TOOLCHANGE. An extra is inert until a config section
# instantiates it, and those sections are anvil-klipper-config's, where the
# flag still applies -- so gating here bought nothing and cost the mismatch
# that kept these five files on /usr/prog.
for _e in "$PKG_DIR"/payload/klipper/klippy/extras/ff_*.py; do
    pkg_stage "$_e" "klipper/klippy/extras/$(basename "$_e")"
done

# The __pycache__ sweep that used to be here is pkg_ship's now. It was written
# twice, here and in pkgs/moonraker, and the recipe that needed it most did
# not have it.
pkg_ship "klipper"

# ------------------------------------------------------------------- the gate
# Over $PKG_OUT rather than the staging tree, so it reads the bytes that
# actually ship -- pkg_ship strips ELF on the way out.
#
# The ABI of this .so is NOT checked here: that question is asked once, of the
# installed filesystem, in qa/replica/test_abi.py, which covers both vehicles
# this tree travels on instead of only the one a build.sh can see.
#
# Symbols are a check the ABI one cannot make: a .so with a perfect header and
# a missing symbol is exactly the stale build described at the top of this
# file. Running it here fails the build that produced the .ipk rather than
# only a full firmware run.
python3 "$ROOT/test/test-chelper.py" "$PKG_OUT/klipper" || pkg_die \
    "klipper: c_helper.so does not export everything the shipped klippy declares"

pkg_end
