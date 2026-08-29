#!/usr/bin/env bash
# Klipper -- the fork's klippy tree, with c_helper.so built from the chelper
# sources that ship inside it.
#
# THE .so IS BUILT FROM THE TREE THAT SHIPS, and that is the whole reason this
# recipe compiles anything rather than shipping a prebuilt object. cffi
# resolves symbols LAZILY, so a c_helper.so built from older sources than the
# klippy beside it imports cleanly, passes an ABI check, installs, boots --
# and dies at "Unhandled exception during connect" on the printer. That
# happened: a .so built four days before kin_extruder.c gained
# extruder_stepper_free shipped and bricked klippy startup on hardware. One
# source verb means one tree, so the failure is unrepresentable here.
#
# NO CACHE OF ITS OWN. bin/patch.sh kept a $FORK/.version stamp and an
# `is the .so older than any .c` mtime test, both of which pkg_begin's stamp
# replaces -- the stamp is the pinned commit and the toolchain filename, so a
# bump to either rebuilds and nothing else does.
set -euo pipefail
. ./bin/common.sh
. pkgs/lib.sh

pkg_begin klipper || exit 0
pkg_toolchain
pkg_unpack "$KLIPPER_TGZ"

# GitHub's generated tarball wraps the repository in klipper-<sha>/, and the
# unpack keeps that wrapper rather than hiding the shape of the archive behind
# --strip-components -- the same choice pkgs/moonraker makes and for the same
# reason. The guard is bin/patch.sh's, kept: a tarball whose shape changed
# under us would build nothing, which looks like a clean build and a printer
# that cannot move.
_top="klipper-$KLIPPER_VERSION"
[ -f "$PKG_WORK/src/$_top/klippy/chelper/__init__.py" ] || pkg_die \
    "klipper: no klippy/chelper/__init__.py in $(basename "$KLIPPER_TGZ")"

# THE LINK LINE IS KLIPPER'S OWN. Every flag below is copied from COMPILE_ARGS
# in klippy/chelper/__init__.py -- what the printer would use if it could
# compile, which it cannot: the stock rootfs has no cc, which is why klippy's
# usual first-run build never happens here. -shared -fPIC and $CC come from
# pkg_build, so the ABI is the wrapper's and not this file's.
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
# dirname(klippy.py)/extras/<name>.py and nothing else. Being inside the tree
# is the whole reason these can be a package member at all.
#
# NOT gated on BUILD_TOOLCHANGE. An extra is inert until a config section
# instantiates it and those sections are anvil-klipper-config's, where the
# flag still applies -- so gating here bought nothing and cost the mismatch
# that kept these five files on /usr/prog: this recipe answers to
# BUILD_KLIPPER, they answered to BUILD_TOOLCHANGE, and a package cannot hold
# files with a different gate from its own.
for _e in "$PKG_DIR"/payload/klipper/klippy/extras/ff_*.py; do
    pkg_stage "$_e" "klipper/klippy/extras/$(basename "$_e")"
done

# The __pycache__ sweep that used to be here is pkg_ship's now. It was
# written twice, here and in pkgs/moonraker, and the recipe that needed it
# most did not have it: anvil-core stages a directory of .py helpers and was
# shipping bytecode whenever a test had imported one of them.
pkg_ship "klipper"

# ------------------------------------------------------------------ the gates
# Both run over $PKG_OUT rather than over the staging tree, so they read the
# bytes that actually ship -- pkg_ship strips ELF on the way out, and a gate
# that checked the unstripped object would be checking a file no printer gets.
#
# ABI first: the kernel refuses anything that is not o32/nan2008/mips32r2, and
# it refuses it with ENOEXEC, three layers below anything that says MIPS.
# bin/build-packages.sh gates every package the same way at the boundary, but
# this tree is ALSO staged into the SOFTWARE component by bin/patch.sh, which
# never puts it through the payload gate -- so the check belongs here, where
# both vehicles are downstream of it.
_gated=$(mips_abi_gate "$PKG_OUT/klipper/klippy/chelper/c_helper.so") || exit 1
pkg_say "klipper: c_helper.so is nan2008/o32/mips32r2 ($_gated ELF object)"

# Symbols second, and this is the check the ABI one cannot make: a .so with a
# perfect header and a missing symbol is exactly the stale build described at
# the top of this file. It moved here from bin/patch.sh for the reason the s6
# presence checks did -- it now runs on `make packages` too, so a bad object
# fails the build that produced the .ipk rather than only a full firmware run.
python3 "$ROOT/test/test-chelper.py" "$PKG_OUT/klipper" || pkg_die \
    "klipper: c_helper.so does not export everything the shipped klippy declares"

pkg_end
