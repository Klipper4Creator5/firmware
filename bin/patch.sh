#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# pkgs/lib.sh for FOUR functions, and pkg_out is no longer one of them. This
# file used to run every recipe and copy its build tree into the payload, so
# it needed to name where a recipe puts its output; it now installs the
# packages those recipes produced, so it needs to name the recipes
# (pkg_recipes), find their .ipk (pkg_ipk), build the opkg that installs them
# (pkg_buildopkg) and fail the way the rest of the packaging does (pkg_die).
# Nothing here reads work/pkg any more, and qa/static/test_ipk.py asserts it.
# Sourcing costs nothing else -- lib.sh defines functions and sets no build
# state until a recipe calls pkg_begin.
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
# PAYLOAD_ROOT / PAYLOAD_DIR come from bin/common.sh: three other files delete
# this tree and one of them tars it, so where it is cannot be a local answer.
#
# THE WHOLE ROOT GOES, not just the payload inside it, and that is load-bearing
# rather than tidiness. A surviving var/lib/opkg would make opkg believe the
# packages it is about to install are already installed, so it would take its
# upgrade path and remove files from a tree it is in the middle of building.
rm -rf "$PAYLOAD_ROOT" "$SOFTWARE_DIR/mod"   # $SOFTWARE_DIR/mod: leftover from an older layout
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
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/lib" "$PAYLOAD_DIR/libexec" \
         "$PAYLOAD_DIR/nginx" \
         "$PAYLOAD_DIR/www" "$PAYLOAD_DIR/config" "$PAYLOAD_DIR/etc/s6"

# ------------------------------------------------- 0. the payload, installed
# THE PAYLOAD IS THE FEED, INSTALLED. Every file bound for $MODDIR comes from
# a package, put there by a real opkg running against a staging root. What
# used to be here -- eight sections that each ran a recipe and then cp -a'd
# its build tree into place -- was a second description of what the .ipk
# already contained, which is the same duplication the recipes removed one
# level down. `opkg list-installed` now answers "what does this release
# install?" and it answers it off the payload itself.
#
# THE SET IS DERIVED FROM THE RECIPES, NOT LISTED HERE. pkg_recipes is already
# PKG_WHEN-gated, so BUILD_HELIX, BUILD_MAINSAIL, BUILD_MOONRAKER,
# BUILD_TOOLCHANGE and BUILD_KLIPPER are read in exactly one place -- the
# pkg.conf that owns each -- instead of being restated by an `if` here that
# could drift from it. A flag turned off means the recipe is absent from
# pkg_recipes, its .ipk is pruned from the feed by bin/build-packages.sh, and
# nothing below has to know.
#
# -dev IS THE FILTER, AND IT FILTERS ON THE PACKAGE NAME rather than on the
# recipe, because the two ways of being build-time-only look nothing alike
# from here. execline, s6 and CPython ship BOTH halves -- a runtime package
# and a -dev variant split out of one build by PKG_DEV_FILES -- and pkg_ipk
# with no second argument names the runtime one. zlib, openssl, sqlite, expat,
# libffi, xz, bzip2, libarchive and skalibs ship ONLY a dev package and say so
# by setting PKG_NAME=anvil-<x>-dev outright, so pkg_ipk hands back the -dev
# file itself and there is no runtime half to ask for. Asking "does this
# recipe have a runtime half" gets the second group wrong and quietly installs
# nine packages of headers and static archives; asking what the package is
# CALLED gets both right. Measured: 32 runtime packages and 9 dev-named ones
# across the 41 recipes, every one of which resolves to a file that exists.
#
# This is what replaces the hand-written PKG_DEV_FILES deletion this script
# used to perform on the staged CPython, and it is why bin/verify.sh's "no
# headers in the payload" check now passes because they were never installed
# rather than because they were removed again afterwards.
say "payload: installing the feed into $PAYLOAD_ROOT"
pkg_buildopkg

# The model is the one fact opkg cannot work out for itself: both chamber
# configs are built on every build, they own the same
# config/printer.chamber.cfg, and they declare Conflicts on each other. opkg
# would refuse the pair -- correctly, and with exit 255 -- so the choice has
# to be made here, from the machine this package is being built for.
case "$TARGET_MACHINE" in
    Creator5)    MODEL_PKG=klipper-creator5-config ;;
    Creator5Pro) MODEL_PKG=klipper-creator5pro-config ;;
    *) echo "no chamber-config package for TARGET_MACHINE=$TARGET_MACHINE" >&2
       exit 1 ;;
esac

MOD_IPKS=""
MOD_NPKG=0
for _r in $(LC_ALL=C pkg_recipes | LC_ALL=C sort); do
    case "$_r" in
        klipper-creator5-config|klipper-creator5pro-config)
            [ "$_r" = "$MODEL_PKG" ] || continue ;;
    esac
    _ipk=$(pkg_ipk "$_r")
    [ -f "$_ipk" ] || pkg_die \
        "no .ipk for recipe '$_r' at $_ipk -- run ./bin/build-packages.sh"
    case "${_ipk##*/}" in
        *-dev_*) continue ;;   # headers and static archives; see above
    esac
    MOD_IPKS="$MOD_IPKS $_ipk"
    MOD_NPKG=$((MOD_NPKG + 1))
done
[ "$MOD_NPKG" -gt 0 ] || { echo "no runtime packages selected -- every recipe is gated off?" >&2; exit 1; }

# THE CONFIG IS GENERATED, not carried in the repo, because two of its four
# lines are paths only this script knows.
#
#   offline_root  where opkg unpacks to. It does NOT change where opkg keeps
#                 its database: that is compiled in (see pkg_buildopkg), and
#                 offline_root is prefixed to it.
#   ignore_uid    clears libarchive's EXTRACT_OWNER. The build lane runs as
#                 the invoking user by design -- see the Makefile -- so
#                 without this every one of the ~3000 entries warns that it
#                 could not be chowned to root. Ownership in the payload has
#                 never meant anything: bin/pack.sh's tar records whoever
#                 built it and installer/run-append.sh extracts as root.
#   arch          the anti-OpenWrt gate, restated where opkg reads it. A
#                 mipsel_24kc package -- same ISA, same ABI, musl libc -- has
#                 no priority here and is refused before it is unpacked.
MOD_OPKG_CONF="$PAYLOAD_ROOT/.opkg.conf"
mkdir -p "$PAYLOAD_ROOT"
cat > "$MOD_OPKG_CONF" <<EOF
dest root /
option offline_root $PAYLOAD_ROOT
option ignore_uid 1
arch all 1
arch $IPK_ARCH 10
EOF

# ONE INVOCATION WITH THE WHOLE SET, so opkg orders it and checks it. Handing
# packages over one at a time would make this script responsible for
# dependency order, which is the job being delegated.
#
# --force-postinstall, because "unpacked" would be a lie about the machine
# this payload describes. opkg skips configuration under offline_root -- it
# assumes someone will finish the job on the target -- and leaves every
# package Status: install user unpacked. But nothing runs opkg on the printer
# after installer/run-append.sh extracts the tarball: the extraction IS the
# install, the files are exactly in place, and a database saying otherwise
# would make the first real `opkg upgrade` argue with the filesystem. No
# recipe defines a maintainer script today, so this runs nothing; when one
# appears, note that opkg 0.7.0 sets no IPKG_INSTROOT and it would run HERE,
# against the staging root. See docs/notes/85-packaging.md.
# shellcheck disable=SC2086
"$HOSTOPKG" --conf "$MOD_OPKG_CONF" --force-postinstall install $MOD_IPKS \
    > "$PAYLOAD_ROOT/.opkg-install.log" 2>&1 \
    || { sed 's/^/   /' "$PAYLOAD_ROOT/.opkg-install.log" >&2
         echo "opkg could not install the feed -- see $PAYLOAD_ROOT/.opkg-install.log" >&2
         exit 1; }

# INSTALLED-TIME IS THE CLOCK, AND THE CLOCK IS NOT REPRODUCIBLE. opkg calls
# time() for it (libopkg/opkg_install.c) and honours SOURCE_DATE_EPOCH only
# for a man-page date at configure time, so two builds of one commit differ by
# one line per package. Normalised rather than patched around: upstream is
# right that an installed-time is a real install's timestamp, and this is not
# a real install -- it is an image being baked, and the same argument that
# puts --clamp-mtime in pkg_ship applies to the database it produces.
sed -i "s/^Installed-Time: .*/Installed-Time: ${SOURCE_DATE_EPOCH:-1}/" \
    "$PAYLOAD_DIR/var/lib/opkg/status"

rm -f "$MOD_OPKG_CONF" "$PAYLOAD_ROOT/.opkg-install.log"
say "payload: $MOD_NPKG packages installed ($MODEL_PKG for $TARGET_MACHINE)"

# The one file whose absence is silent and fatal: printer.base.cfg includes
# printer.chamber.cfg unconditionally, so a payload without it is a printer
# whose klippy will not start. Asked of the payload rather than of the feed,
# because what ships is what was installed.
if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
    [ -f "$PAYLOAD_DIR/config/printer.chamber.cfg" ] || pkg_die \
        "no config/printer.chamber.cfg in the payload -- anvil-$MODEL_PKG did not install"
fi

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
    # THE TREE COMES OUT OF THE PAYLOAD, which is to say out of the installed
    # anvil-klipper package -- not out of the recipe's build directory. That
    # is the last place this script reached into work/pkg, and removing it is
    # what makes "the tarball and the .ipk contain the same klippy" true by
    # construction instead of by two copies of one cp -a agreeing.
    _kl="$PAYLOAD_DIR/klipper"
    [ -d "$_kl/klippy" ] || pkg_die \
        "BUILD_KLIPPER=fork but the payload has no $MODDIR/klipper/klippy -- anvil-klipper is gated on BUILD_KLIPPER too (pkgs/klipper/pkg.conf), so the two disagree"

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

    # THE .cfg FILES ARE NOT HERE ANY MORE. anvil-klipper-config carries the
    # ff-*.cfg and the chosen anvil-klipper-creator5*-config carries
    # printer.chamber.cfg; both were installed into the payload by section 0,
    # which is also where the model is chosen and where the gate on the result
    # now lives. What is left in this section is the residue that cannot be a
    # package: two paths under /usr/prog.
else
    skip "Toolchange"
fi

# ------------------------------------------------------- 3. the user's seams
# Mainsail, Moonraker, HelixScreen, s6, CPython, libsodium and anvil-core each
# had a section here that ran a recipe and copied its build tree into the
# payload. All of them are packages installed by section 0. What is left is
# the short list of files that are IN the payload and in NO package, and each
# one is here because being a package member would be wrong rather than
# because nobody has got to it yet.
#
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
    && cp -f pkgs/moonraker/seed/moonraker-custom.conf "$PAYLOAD_DIR/config/moonraker-custom.conf"

# --------------------------------------------- 4. what used to stand here
# Moonraker, HelixScreen and the s6 / execline / s6-rc stack each had a
# section of their own: run the recipe, copy its build tree into the payload,
# report a size. Section 0 installs all three as packages. The reasoning that
# was here has gone to the thing it is about -- pkgs/moonraker/pkg.conf for
# why we ship a newer Moonraker than the factory image carries,
# pkgs/helixscreen for the UI, versions.env for how the supervision stack is
# pinned -- which is where someone changing one of them will be standing.
#
# Two facts were written down only here, and are kept because nothing else
# says them:
#
# BUILD_MOONRAKER=0 LEAVES THE STOCK SERVER ALONE, INCLUDING ITS CONFIG. The
# stock Moonraker is a 2022 build reporting API 1.0.5, and it does not come
# from the update package at all -- it is on the factory image only, at
# /usr/prog/moonraker/moonraker/, so a reflash cannot put it back once
# replaced. moonraker.conf is shipped by pkgs/moonraker, with the server it
# configures, and not by anvil-core: shipped unconditionally it meant a
# BUILD_MOONRAKER=0 build still overwrote the printer's moonraker.conf with
# one written for a server it was not going to install.
#
# THE PAYLOAD IS ABI-GATED ONCE, further down, over the finished tree instead
# of three times over three subsets of it. mips_abi_gate lives in
# bin/common.sh because bin/build-packages.sh applies the same rule on the way
# into an .ipk, and a second copy of a rule is a second chance to get it
# wrong.

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
#
# THE DEV HALF IS NOT INSTALLED, WHICH IS WHY IT NEED NOT BE DELETED. This
# section used to copy work/pkg/python wholesale -- that tree is the WHOLE
# build, headers and all, because the split into anvil-python and
# anvil-python-dev happens where the .ipk files are made -- and then re-apply
# the split by hand, reading PKG_DEV_FILES back out of the recipe's pkg.conf
# through a subshell so the globs could not drift from it. Section 0 asks for
# the runtime half by name and the question does not arise: bin/verify.sh's
# "no headers in the payload" check now passes because they were never put
# there.

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
PY_SQLITE=$(ls "$PAYLOAD_DIR/lib/python$PY_MM/lib-dynload/"_sqlite3*.so 2>/dev/null | head -n1)
[ -n "$PY_SQLITE" ] \
    || { echo "   !! python: NO _sqlite3 MODULE -- the one module this" >&2
         echo "      interpreter exists for. Rebuild anvil-python: delete its build" >&2
         echo "      tree and rerun ./bin/build-packages.sh, then patch again." >&2
         exit 1; }
PY_SP="$PAYLOAD_DIR/lib/python$PY_MM/site-packages"
for m in lmdb tornado cffi; do
    [ -e "$PY_SP/$m" ] || [ -e "$PY_SP/$m.py" ] \
        || { echo "   !! python: no '$m' in site-packages -- pkgs/3rdparty/python-$m" >&2
             echo "      produced nothing. Rebuild it with ./bin/build-packages.sh" >&2
             echo "      python-$m, then patch again." >&2
             exit 1; }
done
PY_EXT=$(find "$PY_SP" -name '*.so' | wc -l)
[ "$PY_EXT" -ge 12 ] \
    || { echo "   !! python: only $PY_EXT extension modules in site-packages," >&2
         echo "      expected at least 12. A native package fell back to a" >&2
         echo "      pure-python build; check work/.pkg-python-*/wheel-*.log." >&2
         exit 1; }
say "python: $(basename "$PY_SQLITE") present;" \
    "$PY_EXT extension modules in site-packages"
du -sh "$PAYLOAD_DIR/lib/python$PY_MM" | awk '{print "   "$1"\tlib/python'"$PY_MM"'/"}'
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
# THE THREE NAMES ARE TWO SYMLINKS AND A FILE, and section 0 is now what has
# to preserve that: libsodium.so -> libsodium.so.26 -> libsodium.so.26.2.0,
# where the first is the name libnacl constructs and the second is the SONAME
# the loader then asks for. The staging copy here was `cp -a` for exactly this
# reason; the check below is kept because it is now also a check on the
# packaging round trip -- opkg-build has to put a symlink in the archive and
# opkg has to restore it as one, and nothing else on the release path asserts
# that either of them does.
[ -L "$PAYLOAD_DIR/lib/libsodium.so" ] \
    || { echo "   !! libsodium: lib/libsodium.so is not a symlink -- libnacl's" >&2
         echo "      dlopen fallback asks for that exact name." >&2; exit 1; }
# The gate, over the payload, with the same rule and the same function 5c
# uses: this is a DYN, so 0x70001407, and a legacy-NaN or big-endian libsodium
# would import perfectly on a build host and fail only inside libnacl's
# ctypes call on the printer -- which surfaces as Moonraker's authorization
# component failing to load, three layers away from anything that says MIPS.
#
# Aimed at the resolved object rather than at $PAYLOAD_DIR/lib, which would
# be the tidier-looking line: lib/ is also where the interpreter's whole
# stdlib lives and 5c has just walked all of it, and re-walking two thousand
# files to reach one is a gate that gets deleted the first time somebody times
# a build.
SODIUM_SO=$(readlink -f "$PAYLOAD_DIR/lib/libsodium.so")
say "libsodium: $SODIUM_VERSION in lib/ --" \
    "$(readelf -d "$SODIUM_SO" | awk '/SONAME/{gsub(/[][]/,"",$5); print $5}')," \
    "$(du -h "$SODIUM_SO" | cut -f1)"

# ------------------------------------------------------- 5e. the ABI gate
# ONE GATE, OVER THE WHOLE PAYLOAD. There used to be three -- s6's over bin/
# and libexec/, CPython's over the interpreter and its stdlib, libsodium's
# over one resolved .so -- each run immediately after the copy it was checking
# and each covering only what that copy had put there. Three subsets with
# gaps between them: moonraker/, helixscreen/ and klipper/ were never walked
# by any of them, and neither was anything a future section might add.
#
# It can be one gate now because there is one moment when the payload is
# finished, which is what section 0 created. mips_abi_gate walks for ELF and
# ignores everything else, so pointing it at the root costs a readelf per file
# and answers the question that actually matters: is every object THAT SHIPS
# nan2008/o32/mips32r2. A legacy-NaN or big-endian object gets ENOEXEC from
# the kernel, or worse the wrong FPU mode, and explains neither.
#
# bin/build-packages.sh runs the same rule on the way into every .ipk, so this
# is belt and braces. It is kept because it checks the bytes that ship rather
# than the bytes a package was built from, and because it is the only gate
# that sees files no package put here.
PAYLOAD_ELF=$(mips_abi_gate "$PAYLOAD_DIR") || exit 1
say "payload: $PAYLOAD_ELF ELF objects, all nan2008/o32/mips32r2"

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
    cp -f "$BUSYBOX_BIN" "$PAYLOAD_DIR/bin/busybox"; chmod +x "$PAYLOAD_DIR/bin/busybox"
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

# ---------------------------------------------------------- 10. anvil.conf
# THE MOD'S OWN FILES ARE anvil-core, INSTALLED BY SECTION 0: the shared
# environment and service libraries every init script sources, the init
# scripts themselves, the helper programs, the nginx config and the s6
# scandir. What used to be eight copies and three chmods here, and then one
# copy of a recipe's build tree, is now a line in a package list.
#
# ANVIL.CONF IS NOT IN THAT PACKAGE, and this is the whole of what is left
# here. It is templated from config.env and then preserved across updates by
# run-append.sh, which makes it user state rather than a package member: a
# package would overwrite a printer's settings on the first upgrade. See the
# header of pkgs/anvil-core/build.sh.
sed -e "s/^MOD_WEB=.*/MOD_WEB=${MOD_WEB:-1}/" \
    -e "s/^MOD_CAM=.*/MOD_CAM=${MOD_CAM:-1}/" \
    -e "s/^MOD_UI=.*/MOD_UI=${MOD_UI:-1}/" \
    -e "s/^MOD_SSH=.*/MOD_SSH=${MOD_SSH:-1}/" \
    -e "s/^MOD_WIFI=.*/MOD_WIFI=${MOD_WIFI:-1}/" \
    -e "s/^NICE_MOONRAKER=.*/NICE_MOONRAKER=${NICE_MOONRAKER:-5}/" \
    -e "s/^NICE_CAM=.*/NICE_CAM=${NICE_CAM:-10}/" \
    pkgs/anvil-core/seed/anvil.conf.in > "$PAYLOAD_DIR/anvil.conf"

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
{ ( cd "$PAYLOAD_DIR" && find . -mindepth 1 | sed 's|^\./||' )
  echo "$MOD_MANIFEST"
} | LC_ALL=C sort -u > work/.install-manifest
mv -f work/.install-manifest "$PAYLOAD_DIR/$MOD_MANIFEST"
say "install manifest: $(wc -l < "$PAYLOAD_DIR/$MOD_MANIFEST") paths -> $MODDIR/$MOD_MANIFEST"

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
echo "  mod payload:        $(du -sh "$PAYLOAD_DIR" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "Now run ./bin/pack.sh"
