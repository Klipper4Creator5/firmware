#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# pkgs/lib.sh for pkg_out ALONE. This file runs recipes and stages what they
# produced, and it has to be able to name where a recipe puts its output. The
# alternative is a $SOMETHING_BUILD variable in bin/common.sh for every recipe,
# which is what the three legacy aliases there are and what that file's own
# comment says not to grow: pkg_out derives the path from the recipe name, so a
# new recipe needs no edit anywhere. Sourcing it costs nothing else -- lib.sh
# defines functions and sets no build state until a recipe calls pkg_begin.
. "$ROOT/pkgs/lib.sh"

SOFTWARE_DIR=work/software
[ -d "$SOFTWARE_DIR" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

# THE FEED IS A PREREQUISITE OF THIS SCRIPT, AND HAS BEEN FOR LONGER THAN IT
# HAS BEEN SAID OUT LOUD. Section 5c runs pkgs/3rdparty/python/build.sh, whose
# PKG_BUILD_DEPENDS is "openssl sqlite zlib libffi xz bzip2 expat" -- and this
# file builds none of those seven. pkg_deps fills that recipe's sysroot by
# unpacking their .ipk files out of $PKG_FEED and dies if they are not there.
# So a cold checkout has never been able to run bin/patch.sh; it just failed
# two hundred lines further down, inside a recipe, naming a file rather than
# the command that makes it.
#
# Checked here so the failure names the fix, and checked by counting .ipk
# rather than by testing for the directory: a $PKG_FEED that exists and is
# empty is the state a cleaned tree is in, and it is the one that used to
# produce the confusing error.
if [ -z "$(ls "$PKG_FEED"/*.ipk 2>/dev/null)" ]; then
    echo "no package feed at $PKG_FEED" >&2
    echo "  the recipes this script runs build against it -- run 'make packages' first." >&2
    exit 1
fi

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# $MODDIR -- /usr/data/anvil, the one directory on the DATA partition
# everything we add lives under -- now comes from bin/common.sh, because the
# package recipes under pkgs/ need the same value and cannot be allowed to
# disagree with this file about it. The comment that used to be here is there.
#
# The mod payload is built OUTSIDE the software component on purpose. The
# software component is extracted to /usr/prog/PROGRAM/software/<ver>/ -- the
# firmware partition, of which the installer keeps only one version. Mainsail and
# HelixScreen are ~100MB and would overflow it. They ride in the outer package
# instead, land in /usr/data/update/ (data partition), and are moved to
# /usr/data/anvil from there.
# MOD_PAYLOAD comes from bin/common.sh: three other files delete this tree and
# one of them tars it, so where it is cannot be a local answer.
rm -rf "$MOD_PAYLOAD" "$SOFTWARE_DIR/mod"   # $SOFTWARE_DIR/mod: leftover from an older layout
# libexec/ is here because $MODDIR is a --prefix root, not a junk drawer: it
# holds helper programs that other programs exec and users do not, which for
# now means s6-ftrigrd. It has to be a sibling of bin/ and spelled exactly
# this way -- s6 resolves it from the --prefix baked into its binaries at
# compile time, so the directory name is part of the ABI, not a preference.
# etc/ is the same idea one directory further on: a --prefix root keeps the
# mod's own configuration in etc/, and etc/s6/ is the s6 SCANDIR -- the
# directory s6-svscan watches, one subdirectory per supervised service. It is
# created here rather than at runtime by anvil-core's init.d/S40s6, and the reason
# is the install manifest: the manifest is read off this staged tree, so a
# directory that only ever appeared on the printer would be a path the mod
# creates and no update can ever account for. It was empty when S40s6 first
# landed and is not any more -- the service directories themselves are copied
# in further down, next to init.d -- but the mkdir stays, because a payload
# that happens to ship no services still needs somewhere for the scanner to
# look. S40s6 still does its own
# mkdir -p on top of this -- see the comment there -- because the manifest
# pass runs BEFORE the new tarball is extracted, and because hand-made
# installs exist.
#
# lib/ completes the prefix root and is CPython's, in the same way libexec/ is
# s6's: `--prefix=/usr/data/anvil` puts the interpreter in bin/ and its whole
# stdlib in lib/python3.13/, so the two directories are one install, not two
# packages sharing a namespace. It is created here rather than only by the
# python step below for the manifest's sake -- the same argument as etc/s6/
# above -- so that a payload which somehow shipped without the interpreter
# still names the directory it would have used.
mkdir -p "$MOD_PAYLOAD/bin" "$MOD_PAYLOAD/lib" "$MOD_PAYLOAD/libexec" \
         "$MOD_PAYLOAD/nginx" \
         "$MOD_PAYLOAD/www" "$MOD_PAYLOAD/config" "$MOD_PAYLOAD/etc/s6"

# ---------------------------------------------------------------- 1. Klipper
# BUILD_KLIPPER=fork (the default) ships the creator5 Klipper tree; =stock
# keeps FlashForge's, and has to be asked for by name. There is no silent
# middle: a "fork" build quietly falling back to stock is exactly what
# shipped as v20260824-nova-kakhovka -- KLIPPER_FORK was empty in CI, this
# block skipped itself, and the stock 0.12-era overlay half-overwrote the
# v0.13 tree on already-modded printers. klippy died at connect with
# "'void(*)(struct stepper_kinematics *, double, double, double)' expects 4
# arguments, got 3": a v0.12 extruder.py calling the v0.13 chelper cdef
# (upstream c84d78f3f widened extruder_set_pressure_advance). KLIPPER_FORK is
# gone -- the local-checkout seam it named would have been a second source for
# a recipe that is allowed exactly one -- so "fork" now means the commit
# pinned in versions.env and nothing else, and there is no configuration under
# which this section can produce a tree it did not build.
#
# THE BUILD LIVES IN pkgs/klipper NOW, and this section stages what it
# produced -- the arrangement sections 3, 4, 5 and 5d have had since each
# became a recipe, and for the same reason: the .ipk and the tarball have to
# contain the same klippy tree and the same c_helper.so, or they are two
# different Klippers wearing one version number and no test can tell which a
# printer got. What was here -- an unpacked toolchain, a hand-written gcc
# line, an mtime cache and two gates -- is in pkgs/klipper/build.sh, where
# `make packages` runs it too.
case "${BUILD_KLIPPER:-fork}" in
fork)
    bash pkgs/klipper/build.sh
    _kl="$(pkg_out klipper)/klipper"

    # THE FORK GOES TO THE SOFTWARE COMPONENT, not to $MODDIR, and that is why
    # this is a copy rather than a line in the payload loop below. klippy is
    # started by the stock /usr/prog/klipper/klipperDaemon, so it has to be
    # where that binary looks. The package installs the same tree under
    # $MODDIR/klipper, which is inert until phase 7 of
    # docs/notes/80-s6-migration.md moves Klipper there and this mod starts it
    # itself; see pkgs/klipper/pkg.conf.
    #
    # Stock ships only a handful of klippy files as an overlay; the fork is a
    # different Klipper generation, so the WHOLE tree replaces it.
    rm -rf "$SOFTWARE_DIR/klipper/klippy"
    mkdir -p "$SOFTWARE_DIR/klipper"
    cp -a "$_kl/klippy" "$SOFTWARE_DIR/klipper/klippy"

    # chelper.tar IS THE STOCK INSTALLER'S VEHICLE, not a second build. The
    # software component's run.sh ends with
    # `tar -xf $WORK_DIR/klipper/chelper.tar -C /usr/prog/klipper/klippy/`
    # (see test/integration/make-stock-fixture.sh), so a package without it
    # extracts nothing over the .so already inside klippy/ -- harmless today,
    # and a missing file the moment FlashForge's installer stops copying
    # klippy/ wholesale. bin/verify.sh fails a fork package that lacks it.
    # Packing it here rather than in the recipe keeps it out of the .ipk,
    # where a tarball of a file the package already contains would be 30KB of
    # the same object under a second name.
    rm -rf work/.chelper
    mkdir -p work/.chelper/chelper
    cp -f "$_kl/klippy/chelper/c_helper.so" work/.chelper/chelper/c_helper.so
    tar -cf "$SOFTWARE_DIR/klipper/chelper.tar" -C work/.chelper chelper
    rm -rf work/.chelper

    # klippy/ now contains the fork's own extras+kinematics, so the stock
    # overlay dirs would only re-inject 0.12-era files on top. Drop them.
    # extras/ is recreated empty because section 2 puts ff_*.py in it.
    rm -rf "$SOFTWARE_DIR/klipper/extras" "$SOFTWARE_DIR/klipper/kinematics"
    mkdir -p "$SOFTWARE_DIR/klipper/extras"
    say "Klipper: fork tree from pinned commit ${KLIPPER_VERSION:0:8}"
    ;;
stock)
    skip "Klipper: keeping stock tree (BUILD_KLIPPER=stock)"
    ;;
*)
    echo "BUILD_KLIPPER must be 'fork' or 'stock' (got '${BUILD_KLIPPER:-}')" >&2
    exit 1
    ;;
esac

# ----------------------------------------------------------- 2. Toolchanger
# Lives in this repo, under the recipes that own each half -- it used to be
# the separate creator5-toolchange checkout, pointed at by TOOLCHANGE= in
# config.env.
#
# THE CONFIG IS THREE PACKAGES NOW and this section stages what they built,
# the same arrangement sections 3, 4 and 5d have: anvil-klipper-config for the
# ff-*.cfg, and one of anvil-klipper-creator5-config /
# anvil-klipper-creator5pro-config for printer.chamber.cfg. Both model
# packages are BUILT on every build; this picks the one this tarball is for.
# The model stopped being a property of the build -- two builds of one commit
# used to produce different bytes under one version number, with nothing in
# the feed or on the printer recording which machine they were for.
#
# WHAT IS STILL prog/ AND WHY. klippy's extras and printer.base.cfg go to
# /usr/prog, beside FlashForge's own Klipper tree, which is a filesystem no
# package of ours may write -- every path in one lands under $MODDIR. prog/ is
# that residue, and it empties out when a postinst places them from a staging
# root instead. See docs/notes/85-packaging.md phase 2.
#
# printer.chamber.cfg LEFT prog/ WITH THE MODEL PACKAGES, and that is a change
# in where it lands: it used to be copied to /usr/prog/klipper/config beside
# printer.base.cfg and reach /usr/data/config only because the stock run.sh
# copies that whole directory. It now installs to $MODDIR/config like the
# ff-*.cfg, and installer/run-append.sh copies it into /usr/data/config on the
# same mod-owned terms. The include in printer.base.cfg is bare and relative,
# so it resolves either way -- and this way the file is in a package that can
# be installed and upgraded on its own.
if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
    say "Toolchange: ff_*.py + configs"
    mkdir -p "$SOFTWARE_DIR/klipper/extras"
    cp -f pkgs/klipper/prog/klippy/extras/ff_*.py "$SOFTWARE_DIR/klipper/extras/"

    # Our printer.base.cfg is FlashForge's with the chamber block replaced by
    # [include printer.chamber.cfg] -- Klipper can override an option but
    # cannot un-declare a section, and the plain Creator 5 has no chamber
    # heating element, so its heater has to be absent rather than neutralised.
    # NOTE: this cp is why the stock-drift check lives in bin/unpack.sh and
    # not in a test -- it overwrites the pristine copy, and the test that used
    # to read it afterwards was comparing our file against itself.
    cp -f pkgs/klipper-config/prog/config/printer.base.cfg "$SOFTWARE_DIR/klipper/config/printer.base.cfg"

    # BOTH MODEL RECIPES RUN, and one of them is staged. Building both costs
    # two text files and keeps the feed the same on every machine, which is
    # what makes "install either" true rather than aspirational -- a package
    # that only exists when TARGET_MACHINE names it is a package the other
    # model's printer can never install. It also keeps these three named
    # literally here rather than through a variable, which is what
    # qa/static/test_ipk.py reads to prove the payload and the .ipk come from
    # one build.
    bash pkgs/klipper-config/build.sh
    bash pkgs/klipper-creator5-config/build.sh
    bash pkgs/klipper-creator5pro-config/build.sh

    cp -a "$(pkg_out klipper-config)/config/." "$MOD_PAYLOAD/config/"

    # The model. TARGET_MACHINE names a package rather than selecting a file
    # suffix; an unknown value is a build that stops rather than a payload
    # with no chamber config in it, which is a printer whose klippy will not
    # start (printer.base.cfg includes it unconditionally).
    case "$TARGET_MACHINE" in
        Creator5)    MODEL_PKG=klipper-creator5-config ;;
        Creator5Pro) MODEL_PKG=klipper-creator5pro-config ;;
        *) echo "no chamber-config package for TARGET_MACHINE=$TARGET_MACHINE" >&2
           exit 1 ;;
    esac
    cp -a "$(pkg_out "$MODEL_PKG")/config/." "$MOD_PAYLOAD/config/"
    say "Model: printer.chamber.cfg from anvil-$MODEL_PKG"

    # The gate the suffixed-variant loop used to carry, kept and moved to
    # where the file now is. A broken build, not a silent default.
    [ -f "$MOD_PAYLOAD/config/printer.chamber.cfg" ] \
        || { echo "no printer.chamber.cfg staged for TARGET_MACHINE=$TARGET_MACHINE" >&2; exit 1; }
else
    skip "Toolchange"
fi

# -------------------------------------------------------------- 3. Mainsail
# THE BUILD LIVES IN pkgs/3rdparty/mainsail/build.sh, and this section stages what it
# produced -- the same arrangement section 5d has had since libsodium became a
# recipe, and for the same reason: the .ipk and the tarball have to contain
# the same bytes or they are two different Mainsails wearing one version
# number, and no test can tell which a printer got.
if [ "${BUILD_MAINSAIL:-1}" = "1" ]; then
    bash pkgs/3rdparty/mainsail/build.sh
    mkdir -p "$MOD_PAYLOAD/www"
    cp -a "$(pkg_out mainsail)/www/mainsail" "$MOD_PAYLOAD/www/mainsail"
    du -sh "$MOD_PAYLOAD/www/mainsail" | awk '{print "   "$1}'
else
    skip "Mainsail"
fi
# nginx.conf and moonraker.conf USED TO BE COPIED HERE and are shipped by
# packages now -- nginx.conf by pkgs/anvil-core, moonraker.conf by
# pkgs/moonraker with the server it configures. Copying them here as well
# would put two of the same file in the payload from two places, which is the
# arrangement this migration exists to remove.
#
# moonraker-custom.conf is the exception and stays: it is a USER SEAM.
# moonraker.conf includes it by name, and run-append.sh creates it only when
# it is missing -- never overwrites it. A package member is overwritten on
# every upgrade by definition, so putting this in anvil-core would destroy a
# printer's own Moonraker settings the first time it was upgraded.
[ -f pkgs/moonraker/seed/moonraker-custom.conf ] \
    && cp -f pkgs/moonraker/seed/moonraker-custom.conf "$MOD_PAYLOAD/config/moonraker-custom.conf"

# ------------------------------------------------------------- 4. Moonraker
# WHY THIS EXISTS -- the stock Moonraker is a 2022 build (it reports API
# 1.0.5) and it does NOT come from the update package at all: it ships on the
# factory image only, at /usr/prog/moonraker/moonraker/. Old enough that the
# current Mainsail quietly drops features it cannot see. The camera is the one
# you notice: Moonraker only grew the webcam "enabled" flag in April 2023, and
# Mainsail filters its webcam list on exactly that field, so every [webcam]
# entry is discarded and the panel disappears -- with the stream itself
# perfectly healthy behind nginx. No amount of config fixes that; the server
# has to be newer.
#
# WHERE IT LIVES, AND WHAT IS LEFT ALONE. The tree staged below rides in the
# mod payload and is installed BY BEING EXTRACTED: the payload unpacks to
# /usr/data/anvil, so the entry point ends up at
# /usr/data/anvil/moonraker/moonraker.py and the mod's init script starts it
# straight from there. Nothing is written to /usr/prog. FlashForge's own tree
# at /usr/prog/moonraker/moonraker/ is left exactly where it is; it is simply
# never used again.
#
# run-append.sh used to copy this same tree over /usr/prog/moonraker as well,
# and that copy is gone. It put a second, byte-identical Moonraker on the one
# partition with no room to spare -- the only step of the install that could
# fail on disk space, failing as "no working web UI" -- and because /usr/prog
# is what a stock FlashForge flash overwrites while /usr/data/anvil survives
# one, it made "which Moonraker is this printer running?" depend on what was
# flashed last. The two things thought to require that location turned out not
# to: the moonraker-env virtualenv beside it is not on sys.path at all
# (imports resolve from /usr/prog/Python-3.8.2/lib/python3.8/site-packages --
# checked by running the printer's own interpreter on the real image), and
# moonrakerDaemon, the thing that did exec the tree by absolute path, is never
# invoked.
#
# What IS reused is FlashForge's python 3.8.2 and the site-packages next to
# it. No virtualenv is built and no wheel is compiled, because the pinned
# build runs on what the printer already has:
#
#   tornado 6.1, jinja2 3.1.2, distro 1.5.0, libnacl 1.7.2,
#   streaming-form-data 1.8.1, inotify-simple 1.3.5, importlib_metadata 5.1.0,
#   dbus-next 0.2.3, lmdb 1.3.0
#
# -- verified by booting it against exactly those versions on python 3.8,
# started the way the init script starts it (moonraker/moonraker.py -d), with
# _sqlite3 removed from the interpreter to match the printer. Nothing needs a
# MIPS wheel built: the only native module it imports is
# streaming_form_data._parser, and the installed 1.8.1 already exports every
# name it asks of it (StreamingFormDataParser, ParseFailedException,
# FileTarget, ValueTarget, SHA256Target).
#
# WHY A COMMIT AND NOT A RELEASE. FlashForge built python 3.8.2 without the
# _sqlite3 module -- there is no _sqlite3*.so in lib-dynload and no libsqlite3
# anywhere on the image, only the pure-python sqlite3/ wrapper that cannot
# work without it. Moonraker moved its database from lmdb to sqlite in v0.9.0,
# so every release from there on gets as far as loading the database component
# and dies:
#
#   ModuleNotFoundError: No module named '_sqlite3'
#
# The last release still on lmdb is v0.8.0 (Feb 2023), which predates the
# webcam flag (Apr 2023). No release has both, so versions.env pins the newest
# commit that does. This was not caught by reasoning about it -- v0.9.3 was
# built, shipped and tried on the printer first, and this is what it said.
#
# The database is NOT converted: the pinned build uses the same lmdb store the
# stock server uses, so Mainsail's settings carry over untouched and going
# back to stock is a clean round trip.
#
# WHY IT RIDES IN THE MOD PAYLOAD AND NOT THE SOFTWARE COMPONENT. The stock
# run.sh does not extract the software component over /usr/prog -- it copies a
# hand-written list of paths out of it (app_startup.sh, klipper/klippy/*,
# firmwareExe, ...). A moonraker/ directory dropped in beside them would be
# unpacked to /usr/prog/PROGRAM/software/<ver>/ and then simply sat there.
# So it travels with the rest of the payload instead, and unpacking the
# payload IS the installation: run-append.sh has no Moonraker step left at
# all, and nothing about getting Moonraker onto the printer can fail
# separately from the extraction itself.
# THE TREE IS BUILT BY pkgs/moonraker/build.sh, which is where the tarball
# shape guard and the tests/__pycache__ trims went. They did not change; they
# moved to the one place that produces this tree, so the .ipk and the payload
# cannot end up containing different Moonrakers.
#
# MOONRAKER.CONF COMES WITH IT NOW, which is why this stages the whole package
# rather than reaching for its moonraker/ directory. It used to be shipped by
# anvil-core, unconditionally, which meant a BUILD_MOONRAKER=0 build still
# overwrote the printer's moonraker.conf with one written for a server it was
# not going to install -- [webcam anvil] and all. The flag is documented as
# "leaves the stock server alone" (docs/building.md) and now it does.
if [ "${BUILD_MOONRAKER:-1}" = "1" ]; then
    bash pkgs/moonraker/build.sh
    rm -rf "$MOD_PAYLOAD/moonraker"
    cp -a "$(pkg_out moonraker)/." "$MOD_PAYLOAD/"
    rm -f "$MOD_PAYLOAD/.version"
    du -sh "$MOD_PAYLOAD/moonraker" | awk '{print "   "$1}'
else
    skip "Moonraker: keeping the stock 2022 build (and its config)"
fi

# ----------------------------------------------------------- 5. HelixScreen
# pkgs/helixscreen/build.sh unpacks upstream's release and merges this repo's
# printer-database entry and the optional platform hook into it, so all three
# of those now happen once rather than here and again in the packager.
#
# IT IS ALSO ABI-GATED NOW, which it never was here: bin/build-packages.sh
# runs mips_abi_gate over every package tree, and until this became a recipe
# the three mipsel binaries in the largest thing we ship had never been
# checked. They pass -- measured, 3 objects, nan2008/o32/mips32r2 -- so this
# is a gate gained, not a gate that had been quietly failing.
if [ "${BUILD_HELIX:-1}" = "1" ]; then
    bash pkgs/helixscreen/build.sh
    rm -rf "$MOD_PAYLOAD/helixscreen"
    cp -a "$(pkg_out helixscreen)/helixscreen" "$MOD_PAYLOAD/helixscreen"
    du -sh "$MOD_PAYLOAD/helixscreen" | awk '{print "   "$1}'
else
    skip "HelixScreen"
fi

# mips_abi_gate -- the nan2008/o32/mips32r2 check every cross-built ELF in
# this file passes before it ships -- now lives in bin/common.sh, because
# bin/build-packages.sh gates the same objects on the way into an .ipk and a
# second copy of that rule is a second chance to get it wrong. The comment
# explaining the two expected e_flags words went with it.

# --------------------------------------------- 5b. s6 / execline / s6-rc
# The supervision stack, staged from four recipes.
#
# THIS SECTION USED TO BE 235 LINES AND BUILT TWO LIBRARIES. It unpacked a
# musl cross-toolchain, wrote its own compiler wrappers, gated their ABI,
# cross-built skalibs into a private sysroot, cross-built s6 against it,
# harvested thirteen binaries out of a DESTDIR and stamped a cache directory
# that only this file and the fetcher knew the shape of. All of that is now
# four pkgs/ recipes with versions, stamps and packages of their own, and what
# is left here is what this file is for: putting the result in the payload.
#
# THE TOOLCHAIN AND THE LINK MODE BOTH CHANGED, and the reasons are recorded
# in versions.env beside the pins rather than here. Briefly: one libc, the
# printer's own glibc 2.29, linked dynamically -- so the second toolchain in
# this tree is gone. Measured, s6 alone is smaller this way than the static
# musl build it replaces (696K against ~930K); the stack is larger only
# because it now also carries execline and s6-rc, which it did not before.
#
# NOTHING STARTS s6-rc YET. As with s6 before it, shipping the binaries is a
# separate change from using them -- see docs/notes/80-s6-migration.md. This
# step only puts them in the payload.
bash pkgs/3rdparty/skalibs/build.sh   # dev-only; nothing of it reaches the payload
bash pkgs/3rdparty/execline/build.sh
bash pkgs/3rdparty/s6/build.sh
bash pkgs/3rdparty/s6-rc/build.sh

# bin/ and libexec/ from each, merged into the one prefix root they all
# configured themselves for. cp -a of the CONTENTS and not of the directory,
# for the same reason section 5c does it: python's interpreter and libsodium's
# .so land in these same two directories and must survive.
for _p in execline s6 s6-rc; do
    cp -a "$(pkg_out "$_p")/bin/." "$MOD_PAYLOAD/bin/"
    [ -d "$(pkg_out "$_p")/libexec" ] \
        && cp -a "$(pkg_out "$_p")/libexec/." "$MOD_PAYLOAD/libexec/"
done
chmod +x "$MOD_PAYLOAD/bin"/s6-* "$MOD_PAYLOAD/bin"/execlineb "$MOD_PAYLOAD/libexec"/*

# The gate, over the payload rather than over any one build tree, and the same
# gate 5c and 5d use. A cross-build that silently produced a host object, or
# one legacy-NaN object because a flag did not reach one link line, looks like
# a clean build here and like a printer that cannot exec its own supervisor
# there -- the kernel says ENOEXEC, or worse, execs it with the wrong FPU mode,
# and explains neither.
#
# The per-binary presence checks that used to live here moved INTO the
# recipes, next to the ship lists they check. That is strictly better: they now
# run on `make packages` too, so a missing s6-ftrigrd fails the build that
# produced the .ipk rather than only a full firmware build.
S6_ELF=$(mips_abi_gate "$MOD_PAYLOAD/bin" "$MOD_PAYLOAD/libexec") || exit 1
say "s6 + execline + s6-rc: $S6_ELF ELF objects are nan2008/o32/mips32r2 -- good"
du -sh "$MOD_PAYLOAD/bin"     | awk '{print "   "$1"\tbin/"}'
du -sh "$MOD_PAYLOAD/libexec" | awk '{print "   "$1"\tlibexec/"}'

# -------------------------------------------------- 5c. CPython 3.13 (shipped)
# A second Python for the printer. pkgs/3rdparty/python builds the interpreter and the
# eighteen pkgs/3rdparty/python-* recipes build what goes in its site-packages -- one
# recipe and one .ipk each. This section runs them and stages what they
# produce. Everything about HOW they are built lives with them now
# (pkgs/3rdparty/python/build.sh, and pkg_buildpython / pkg_pytarget / pkg_pywheel in
# pkgs/lib.sh); every reason WHY is in the pkg.conf beside each one.
#
# ############################################################################
# # FF_PYTHON POINTS HERE. anvil-core's anvil-env.sh names this interpreter  #
# # Moonraker, ff-startup.py, ffscreen.py and ff_mcu_bringup.py, and every   #
# # third-party C extension those need is one of the packages below.         #
# # Moonraker has been measured SERVING on it through the real boot path on  #
# # the replica (test/integration/printer/case-moonraker313-s6.sh): S40s6's  #
# # scandir, S62moonraker, readiness gating on :7125 actually listening, a   #
# # kill -9 respawn, and a stop that stays stopped.                          #
# #                                                                          #
# # klippy is NOT among FF_PYTHON's callers and does not run on this         #
# # interpreter -- it is started separately, by FlashForge's own             #
# # /usr/prog/klipper/start.sh, hardcoded to 3.8.2 (see init.d/S70klipper).  #
# # klippy's numpy gap is therefore a separate, smaller item, not a          #
# # precondition of this switch.                                             #
# ############################################################################
#
# WHY IT IS WORTH SHIPPING. FlashForge built 3.8.2 without _sqlite3, and that
# single omission is what pins MOONRAKER_VERSION to a 2023 commit: every
# Moonraker from v0.9.0 on keeps its database in sqlite. This interpreter has a
# working sqlite3 (measured on the replica, create/insert/select/reopen --
# test/integration/printer/case-python.sh), which is what eventually unpins it.
#
# NINETEEN RECIPES RATHER THAN THE 800-LINE SECTION THAT USED TO BE HERE, and
# what that buys is not tidiness. It is that a package pin can move without
# rebuilding CPython. The old arrangement had one cache directory and two
# stamps and said so out loud: a bumped Pillow rebuilt the interpreter and all
# eighteen packages, because a wheel could only be cross-built during the few
# minutes when an untrimmed staging tree, a private sysroot of static libraries
# and a throwaway x86-64 build-python all happened to exist at once. Those
# three are now the feed's anvil-python-dev package, each recipe's own sysroot,
# and pkg_buildpython's shared cache -- none of which is a passing moment. So
# `make packages PKG=python-pillow` is a Pillow build, and nothing else.
say "python: CPython $PY_VERSION and $(echo $PYPKG_LIST | wc -w) packages"
bash pkgs/3rdparty/python/build.sh
# PYPKG_LIST IS STILL THE LIST, and it is checked against the recipes rather
# than trusted: versions.env carries the pins and bin/fetch-assets.sh downloads
# from the same list, so an entry added there and nowhere else would otherwise
# be fetched, hashed and silently never built.
for p in $PYPKG_LIST; do
    [ -d "pkgs/3rdparty/python-$p" ] || {
        echo "   !! PYPKG_LIST names '$p' and there is no pkgs/3rdparty/python-$p recipe" >&2
        exit 1; }
    bash "pkgs/3rdparty/python-$p/build.sh"
done

# Staged into the SAME bin/ and lib/ as everything else in this prefix root,
# which is why these copy the CONTENTS of the directories and not the
# directories: s6's binaries are already in $MOD_PAYLOAD/bin and must stay
# there, and eighteen packages all merge into one site-packages.
cp -a "$(pkg_out python)/bin/." "$MOD_PAYLOAD/bin/"
mkdir -p "$MOD_PAYLOAD/lib"
cp -a "$(pkg_out python)/lib/." "$MOD_PAYLOAD/lib/"
for p in $PYPKG_LIST; do
    cp -a "$(pkg_out "python-$p")/lib/." "$MOD_PAYLOAD/lib/"
done
chmod +x "$MOD_PAYLOAD/bin/python$PY_MM"

# THE DEV HALF DOES NOT SHIP. work/pkg/python is the WHOLE build: the split
# into anvil-python and anvil-python-dev happens where the .ipk files are made,
# so the tree just copied from still carries the headers and the build
# configuration that only a build machine opens. Which files those are is
# pkgs/3rdparty/python/pkg.conf's business and is read from there -- a second list here
# would be the same set of paths spelled twice, and the half that got forgotten
# would be 3MB of headers on every printer.
#
# A SUBSHELL because pkg_conf sets PKG_* for whatever it read last, and this
# file goes on to stage four more recipes after this one.
( pkg_conf python
  # shellcheck disable=SC2086
  for g in $PKG_DEV_FILES; do rm -rf "$MOD_PAYLOAD"/$g; done )

# The gates, asked of the TREE THAT SHIPS rather than of a build -- so a cached
# recipe from an older, wronger build is checked too, and so the answer comes
# from the bytes the printer will execute. pkgs/3rdparty/python/build.sh gates the
# interpreter's own stdlib modules when it runs; these run every time.
#
# Two claims about site-packages, because they fail differently. A
# site-packages with no EXTENSION MODULES in it is a build where every native
# package quietly fell back to something pure -- it imports on the build host
# and loses lmdb, cffi and greenlet on the printer. A site-packages missing a
# NAMED package is a list that changed without anyone noticing; the three named
# here are the three whose absence takes Moonraker or klippy down completely
# rather than costing a feature.
PY_SQLITE=$(ls "$MOD_PAYLOAD/lib/python$PY_MM/lib-dynload/"_sqlite3*.so 2>/dev/null | head -n1)
[ -n "$PY_SQLITE" ] \
    || { echo "   !! python: NO _sqlite3 MODULE -- the one module this" >&2
         echo "      interpreter exists for. Delete work/pkg/python and rebuild." >&2
         exit 1; }
PY_SP="$MOD_PAYLOAD/lib/python$PY_MM/site-packages"
for m in lmdb tornado cffi; do
    [ -e "$PY_SP/$m" ] || [ -e "$PY_SP/$m.py" ] \
        || { echo "   !! python: no '$m' in site-packages -- pkgs/3rdparty/python-$m" >&2
             echo "      produced nothing. Delete work/pkg/python-$m and rebuild." >&2
             exit 1; }
done
PY_EXT=$(find "$PY_SP" -name '*.so' | wc -l)
[ "$PY_EXT" -ge 12 ] \
    || { echo "   !! python: only $PY_EXT extension modules in site-packages," >&2
         echo "      expected at least 12. A native package fell back to a" >&2
         echo "      pure-python build; check work/.pkg-python-*/wheel-*.log." >&2
         exit 1; }
PY_ELF=$(mips_abi_gate "$MOD_PAYLOAD/bin/python$PY_MM" "$MOD_PAYLOAD/lib/python$PY_MM") || exit 1
say "python: $PY_ELF ELF objects staged, all nan2008/o32/mips32r2;" \
    "$(basename "$PY_SQLITE") present; $PY_EXT extension modules in site-packages"
du -sh "$MOD_PAYLOAD/lib/python$PY_MM" | awk '{print "   "$1"\tlib/python'"$PY_MM"'/"}'
du -sh "$PY_SP" | awk '{print "   "$1"\tlib/python'"$PY_MM"'/site-packages/"}'

# ---------------------------------------------------- 5d. libsodium (shipped)
# The one library of ours that ships as a .so, and the LAST /usr/prog string
# in the phase-6 picture.
#
# WHY IT CANNOT BE STATIC, when the interpreter's seven dependencies all are.
# libnacl is pure python: it reaches libsodium through
# ctypes.cdll.LoadLibrary, which is dlopen, and you cannot dlopen an archive.
# Moonraker's `authorization` component signs its JWTs with the ed25519 pair
# libnacl exposes, so this is on the startup path of the web UI rather than
# beside it.
#
# WHY IT COSTS anvil-env.sh NOTHING, which is worth stating because it looks
# like it should need a library path entry. libnacl's third fallback is
# __file__[0:__file__.find("lib")+3] + "/libsodium.so", and __file__ here is
# $MODDIR/lib/python3.13/site-packages/libnacl/__init__.py -- so it resolves
# $MODDIR/lib/libsodium.so BY ABSOLUTE PATH, measured working in the replica
# with LD_LIBRARY_PATH unset entirely. That works because this prefix happens
# to contain the string "lib"; a prefix without it would break silently, which
# is a thing to remember if $MODDIR ever moves. It is also why the plain
# `libsodium.so` symlink is not a development leftover to be trimmed: it is
# the FIRST name libnacl asks for, and the only one that fallback constructs.
#
# THE BUILD ITSELF NOW LIVES IN pkgs/3rdparty/libsodium/build.sh, and this is the first
# step of the packaging migration rather than a tidy-up: the .ipk that
# bin/build-packages.sh emits has to be built by the same configure line as the
# copy in the tarball, or the two ship different libraries under one version
# number and no test can tell. Moving the block out and calling it from both
# sides is what makes that impossible. See docs/notes/85-packaging.md.
#
# It is still CACHED ON THE VERSION, like s6 and unlike c_helper.so -- the
# stamp is inside work/.sodium and the recipe checks it, so a warm cache costs
# a process spawn. 24 seconds is not the reason for the cache; bin/fetch-assets.sh
# is: an uncached build drags the ~203MB Ingenic toolchain download along
# behind it on every build of a checkout that has nothing else to compile.
#
# A SUBPROCESS AND NOT A SOURCE, deliberately. The recipe exports a
# cross-compiler PATH and half a dozen build variables, and this file goes on
# to build nine more things after it; the process boundary is the same
# guarantee the 5b/5c/5d subshells were already buying, made explicit.
bash pkgs/3rdparty/libsodium/build.sh

# Staged into the prefix's shared lib/, beside lib/python3.13 -- one prefix,
# one library directory. cp -a and not cp: two of these three names are
# SYMLINKS (libsodium.so -> libsodium.so.26 -> libsodium.so.26.2.0), the first
# is the name libnacl constructs and the second is the SONAME the loader then
# asks for, so a copy that dereferenced them would ship three identical 406KB
# files and still work -- until someone wondered why the payload had grown.
cp -a "$SODIUM_BUILD/lib/"libsodium.so* "$MOD_PAYLOAD/lib/"
[ -L "$MOD_PAYLOAD/lib/libsodium.so" ] \
    || { echo "   !! libsodium: lib/libsodium.so is not a symlink -- libnacl's" >&2
         echo "      dlopen fallback asks for that exact name." >&2; exit 1; }
# The gate, over the payload, with the same rule and the same function 5c
# uses: this is a DYN, so 0x70001407, and a legacy-NaN or big-endian libsodium
# would import perfectly on a build host and fail only inside libnacl's
# ctypes call on the printer -- which surfaces as Moonraker's authorization
# component failing to load, three layers away from anything that says MIPS.
#
# Aimed at the resolved object rather than at $MOD_PAYLOAD/lib, which would
# be the tidier-looking line: lib/ is also where the interpreter's whole
# stdlib lives and 5c has just walked all of it, and re-walking two thousand
# files to reach one is a gate that gets deleted the first time somebody times
# a build.
SODIUM_SO=$(readlink -f "$MOD_PAYLOAD/lib/libsodium.so")
SODIUM_ELF=$(mips_abi_gate "$SODIUM_SO") || exit 1
say "libsodium: $SODIUM_VERSION staged into lib/ --" \
    "$SODIUM_ELF object, nan2008/o32/mips32r2," \
    "$(readelf -d "$SODIUM_SO" | awk '/SONAME/{gsub(/[][]/,"",$5); print $5}')," \
    "$(du -h "$SODIUM_SO" | cut -f1)"

# ------------------------------------------------------------------- 6. SSH
# Nothing to install. The stock rootfs (kernel-*.tar.xz -> rootfs.squashfs)
# already ships /usr/sbin/dropbear, /usr/bin/dropbearkey AND an enabled
# /etc/init.d/S50dropbear that busybox init runs at every boot. SSH is
# therefore ALREADY LISTENING on port 22 of a stock printer.
#
# The only thing missing is a root password anyone knows: stock /etc/shadow
# carries an unpublished hash. Setting ROOT_PW_HASH below is the entire
# "enable ssh" feature -- no cross-compiled binaries, no init script.
if [ "${MOD_SSH:-1}" = "1" ]; then
    if [ -n "${ROOT_PW_HASH:-}" ]; then
        say "SSH: stock dropbear is already running; setting a known root password"
    else
        say "SSH: no ROOT_PW_HASH -- the installer will pick a random root password"
        say "     and write it to anvil-password.txt on the USB stick."
        say "     Set ROOT_PW_HASH to choose your own instead."
    fi
else
    skip "SSH"
fi
if [ -n "${BUSYBOX_BIN:-}" ] && [ -f "$BUSYBOX_BIN" ]; then
    cp -f "$BUSYBOX_BIN" "$MOD_PAYLOAD/bin/busybox"; chmod +x "$MOD_PAYLOAD/bin/busybox"
fi

# --------------------------------------------------------- 7. root password
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "Accounts: setting root password hash"
    # /etc is a bind mount of /usr/prog/etc (app_startup.sh), and this file is
    # what dropbear reads at authentication time -- so this is the live shadow
    # even though dropbear started earlier from the read-only squashfs.
    awk -v h="$ROOT_PW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
        "$SOFTWARE_DIR/shadow" > "$SOFTWARE_DIR/shadow.new" && mv -f "$SOFTWARE_DIR/shadow.new" "$SOFTWARE_DIR/shadow"
else
    skip "root password (set ROOT_PW_HASH)"
fi

# ------------------------------------------------ 8. start.sh (web stack on)
say "start.sh: enabling nginx + moonraker"
cp -f pkgs/klipper/prog/start.sh "$SOFTWARE_DIR/start.sh"
chmod +x "$SOFTWARE_DIR/start.sh"

# ------------------------------------- 9. firmwareExe -> our wrapper script
# The stock chain is rcS -> S99factory_test_shell -> app_startup.sh ->
# firmwareExe, and firmwareExe is also what starts Klipper. Replacing this
# one file is therefore enough to own the whole userspace boot, which means
# app_startup.sh, rcS and the init chain are left COMPLETELY STOCK.
#
# The genuine binary is replaced, not kept aside: HelixScreen is the only UI,
# and the installer wipes the software dir before run.sh anyway, so nothing
# here could ever be a reliable backup. Flashing the stock FlashForge package
# -- which still ships the binary -- is the uninstall.
say "firmwareExe: installing wrapper (replaces the stock binary)"
cp -f pkgs/anvil-core/prog/firmwareExe "$SOFTWARE_DIR/firmwareExe"
chmod +x "$SOFTWARE_DIR/firmwareExe"

# ----------------------------------------------------- 10. mod service dir
# THE MOD'S OWN FILES COME FROM pkgs/anvil-core NOW: the shared environment and
# service libraries every init script sources, the init scripts themselves,
# the helper programs, the nginx and Moonraker config, the toolchanger's
# Klipper includes, and the s6 scandir. What used to be eight copies and three
# chmods here is one copy of a tree that a recipe assembled and checked -- and
# because bin/build-packages.sh packages the same tree, what a printer gets
# from the tarball and what it would get from `opkg install anvil-core` cannot
# drift apart.
#
# ANVIL.CONF IS NOT IN THAT PACKAGE and is still written below. It is
# templated from config.env and then preserved across updates by
# run-append.sh, which makes it user state rather than a package member: a
# package would overwrite a printer's settings on the first upgrade. See the
# header of pkgs/anvil-core/build.sh.
bash pkgs/anvil-core/build.sh
cp -a "$(pkg_out anvil-core)/." "$MOD_PAYLOAD/"
rm -f "$MOD_PAYLOAD/.version"
sed -e "s/^MOD_WEB=.*/MOD_WEB=${MOD_WEB:-1}/" \
    -e "s/^MOD_CAM=.*/MOD_CAM=${MOD_CAM:-1}/" \
    -e "s/^MOD_UI=.*/MOD_UI=${MOD_UI:-1}/" \
    -e "s/^MOD_SSH=.*/MOD_SSH=${MOD_SSH:-1}/" \
    -e "s/^MOD_WIFI=.*/MOD_WIFI=${MOD_WIFI:-1}/" \
    -e "s/^NICE_MOONRAKER=.*/NICE_MOONRAKER=${NICE_MOONRAKER:-5}/" \
    -e "s/^NICE_CAM=.*/NICE_CAM=${NICE_CAM:-10}/" \
    pkgs/anvil-core/seed/anvil.conf.in > "$MOD_PAYLOAD/anvil.conf"

# ------------------------------------------------ 10b. the install manifest
# The list of every path this payload installs, shipped inside the payload
# itself so that the NEXT update can delete exactly what this one left behind.
#
# What it replaces: run-append.sh used to `rm -rf` seven whole directories --
# bin, www, nginx, helixscreen, config, moonraker, init.d -- before
# extracting. That is correct only while every single file under them is
# ours, and it stops being correct the moment anything else lives there. A
# supervisor binary in $MODDIR/bin, a Python, anything a user put there by
# hand: all of it was destroyed on every update, silently, by the installer.
#
# It has to keep the property the rm -rf was written for, though. The
# installed set must end up exactly the shipped set, or a RENAMED init script
# leaves a stale twin behind and firmwareExe runs both -- see the comment in
# installer/run-append.sh, which is where that bill came due. A manifest gives
# that property for free: a file the last payload shipped and this one does
# not is still named in the list the last payload wrote, so it still goes.
#
# GENERATED, never hand-maintained. A hand-written list is wrong one release
# after somebody adds a directory, and wrong here means either a file that
# never goes away or a file that should have stayed. So it is read off the
# staged tree, at the last moment before bin/pack.sh turns that tree into
# anvil.tar.xz -- everything above this line has finished staging.
#
# Format: one path per line, relative to $MODDIR, directories listed as well
# as files so the emptied ones can be rmdir'd afterwards. Sorted, so a diff
# between two releases reads as a changelog. The manifest names ITSELF,
# because it too is a file this payload installs and the next update must be
# free to replace it.
#
# Written to a temp file and moved into place: a redirection straight into
# the payload would create the target before `find` walked the tree, and find
# would then list the half-written manifest as one more payload path.
MOD_MANIFEST=.install-manifest
{ ( cd "$MOD_PAYLOAD" && find . -mindepth 1 | sed 's|^\./||' )
  echo "$MOD_MANIFEST"
} | LC_ALL=C sort -u > work/.install-manifest
mv -f work/.install-manifest "$MOD_PAYLOAD/$MOD_MANIFEST"
say "install manifest: $(wc -l < "$MOD_PAYLOAD/$MOD_MANIFEST") paths -> $MODDIR/$MOD_MANIFEST"

# --------------------------------------------------- 11. run.sh install step
say "run.sh: injecting mod install blocks (pre + post)"
POST=work/.run-post.sh
# 1 only when ssh is on and nothing was baked in: a package is one file that
# many people flash, so a baked-in default would be the same password on every
# printer. The installer picks a random per-machine one instead and writes it
# onto the USB stick it was flashed from.
if [ "${MOD_SSH:-1}" = "1" ] && [ -z "${ROOT_PW_HASH:-}" ]; then
    PW_AUTO=1
else
    PW_AUTO=0
fi
sed -e "s/^MOD_PW_AUTO=.*/MOD_PW_AUTO=$PW_AUTO/" \
    installer/run-append.sh > "$POST"
python3 - "$SOFTWARE_DIR/run.sh" installer/run-pre.sh "$POST" <<'PY'
import sys, re
run, pre_f, post_f = sys.argv[1], sys.argv[2], sys.argv[3]
B1, E1 = "# >>> anvil pre >>>",  "# <<< anvil pre <<<"
B2, E2 = "# >>> anvil begin >>>", "# <<< anvil end <<<"
src = open(run, encoding='utf-8', errors='surrogateescape').read()
# idempotent: strip any previous injection
for b, e in ((B1, E1), (B2, E2)):
    src = re.sub(re.escape(b) + r".*?" + re.escape(e) + r"\n?", "", src, flags=re.S)

pre  = B1 + "\n" + open(pre_f,  encoding='utf-8').read() + E1 + "\n"
post = B2 + "\n" + open(post_f, encoding='utf-8').read() + E2 + "\n\n"

# The pre-block must land AFTER WORK_DIR is defined (it uses $WORK_DIR's
# siblings) but BEFORE the first cp into /usr/prog.
m = re.search(r"^WORK_DIR=.*$", src, flags=re.M)
if not m:
    raise SystemExit("run.sh has no WORK_DIR assignment -- cannot place the pre-block")
i = m.end()
src = src[:i] + "\n\n" + pre + src[i:]
print("   pre-block inserted after WORK_DIR")

m = list(re.finditer(r"^exit 0\s*$", src, flags=re.M))
j = m[-1].start() if m else len(src)
src = src[:j] + post + src[j:]
print("   post-block inserted before exit")
open(run, 'w', encoding='utf-8', errors='surrogateescape').write(src)
PY
chmod +x "$SOFTWARE_DIR/run.sh"
rm -f "$POST"

echo
echo "Patched."
echo "  software component: $(du -sh "$SOFTWARE_DIR" | cut -f1)  (-> /usr/prog, firmware partition)"
echo "  mod payload:        $(du -sh "$MOD_PAYLOAD" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "Now run ./bin/pack.sh"
