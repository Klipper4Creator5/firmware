#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# pkg/lib.sh for pkg_out ALONE: this file runs recipes and stages what they
# produced, so it has to name where a recipe puts its output. Sourcing it costs
# nothing else -- lib.sh defines functions and sets no build state until a
# recipe calls pkg_begin.
. "$ROOT/pkg/lib.sh"

SOFTWARE_DIR=work/software
[ -d "$SOFTWARE_DIR" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# The mod payload is built OUTSIDE the software component on purpose. The
# software component is extracted to /usr/prog/PROGRAM/software/<ver>/ -- the
# firmware partition, of which the installer keeps only one version. Mainsail and
# HelixScreen are ~100MB and would overflow it. They ride in the outer package
# instead, land in /usr/data/update/ (data partition), and are moved to
# /usr/data/anvil from there.
MOD_PAYLOAD=work/modpayload
rm -rf "$MOD_PAYLOAD" "$SOFTWARE_DIR/mod"
# libexec/ holds helper programs that other programs exec and users do not
# (s6-ftrigrd). It has to be a sibling of bin/ and spelled exactly this way:
# s6 resolves it from the --prefix baked into its binaries at compile time, so
# the name is part of the ABI, not a preference. lib/ is CPython's for the same
# reason -- --prefix puts the interpreter in bin/ and its stdlib in
# lib/python3.13/.
#
# etc/s6/ is the s6 SCANDIR, the directory s6-svscan watches, one subdirectory
# per supervised service. These are created HERE rather than at runtime because
# the install manifest is read off this staged tree: a directory that only ever
# appeared on the printer would be a path the mod creates and no update can
# account for. S40s6 still does its own mkdir -p on top -- the manifest pass
# runs BEFORE the new tarball is extracted, and hand-made installs exist.
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
# (upstream c84d78f3f widened extruder_set_pressure_advance).
case "${BUILD_KLIPPER:-fork}" in
fork)
    if [ -d "${KLIPPER_FORK:-}/klippy" ]; then
        # A local checkout, for working on the fork itself.
        FORK="$KLIPPER_FORK"
        say "Klipper: fork tree from local checkout $FORK"
    else
        # No checkout: the commit pinned in versions.env, fetched into
        # vendor/ by bin/fetch-assets.sh. This is the path releases take.
        [ -f "${KLIPPER_TGZ:-}" ] || {
            echo "   !! BUILD_KLIPPER=fork but no fork tree:" >&2
            echo "      KLIPPER_FORK is not a checkout and $KLIPPER_TGZ is missing." >&2
            echo "      Run ./bin/fetch-assets.sh (or set KLIPPER_FORK in config.env)." >&2
            exit 1; }
        FORK=work/klipper-fork
        if [ ! -f "$FORK/.version" ] \
           || [ "$(cat "$FORK/.version")" != "$KLIPPER_VERSION" ]; then
            rm -rf "$FORK"
            mkdir -p "$FORK"
            tar -xzf "$KLIPPER_TGZ" -C "$FORK" --strip-components=1
            echo "$KLIPPER_VERSION" > "$FORK/.version"
        fi
        say "Klipper: fork tree from pinned commit ${KLIPPER_VERSION:0:8}"
    fi

    # c_helper.so is built HERE, from the same sources that ship, whenever it
    # is missing or older than any chelper source. A prebuilt .so that merely
    # exists is not trusted with the tree's freshness: one that outlived its
    # sources is how a v0.12-generation binary once shipped under a v0.13
    # klippy (see test/test-chelper.py's docstring).
    CHELPER="$FORK/klippy/chelper/c_helper.so"
    if [ ! -f "$CHELPER" ] || [ -n "$(find "$FORK/klippy/chelper" \
           \( -name '*.c' -o -name '*.h' \) -newer "$CHELPER" -print -quit)" ]; then
        GCC="work/.mips-toolchain/mips-gcc720-glibc229/bin/mips-linux-gnu-gcc"
        if [ ! -x "$GCC" ]; then
            [ -f "${MIPS_TOOLCHAIN_TGZ:-}" ] || {
                echo "   !! c_helper.so needs (re)building and there is no toolchain:" >&2
                echo "      $MIPS_TOOLCHAIN_TGZ is missing. Run ./bin/fetch-assets.sh." >&2
                exit 1; }
            say "Klipper: unpacking the Ingenic MIPS toolchain"
            mkdir -p work/.mips-toolchain
            tar -xzf "$MIPS_TOOLCHAIN_TGZ" -C work/.mips-toolchain
        fi
        say "Klipper: cross-compiling c_helper.so from the fork's sources"
        # Flags mirror COMPILE_ARGS in klippy/chelper/__init__.py: what the
        # printer would use if it could compile, which it cannot.
        "$GCC" -Wall -g -O2 -shared -fPIC \
            -flto -fwhole-program -fno-use-linker-plugin \
            -o "$CHELPER" "$FORK"/klippy/chelper/*.c
    fi

    # The gates. ABI: the kernel refuses anything but MIPS32r2/nan2008/o32.
    # Symbols: cffi resolves lazily, so a stale .so dies at connect on the
    # printer instead of at import in the build -- catch it here.
    if ! readelf -h "$CHELPER" 2>/dev/null | grep -q nan2008; then
        echo "   !! c_helper.so is NOT nan2008 -- the kernel will refuse it" >&2
        exit 1
    fi
    say "Klipper: c_helper.so is nan2008 MIPS32r2 -- good"
    python3 test/test-chelper.py "$FORK" || exit 1

    # Stock ships only a handful of klippy files as an overlay; the fork is a
    # different Klipper generation (v0.13 vs v0.12), so ship the WHOLE tree.
    rm -rf "$SOFTWARE_DIR/klipper/klippy"
    mkdir -p "$SOFTWARE_DIR/klipper/klippy"
    ( cd "$FORK/klippy" && tar -cf - \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='chelper/*.o' . ) \
      | tar -xf - -C "$SOFTWARE_DIR/klipper/klippy"
    mkdir -p work/.chelper/chelper
    cp -f "$CHELPER" work/.chelper/chelper/c_helper.so
    tar -cf "$SOFTWARE_DIR/klipper/chelper.tar" -C work/.chelper chelper
    rm -rf work/.chelper
    # klippy/ now contains the fork's own extras+kinematics, so the stock
    # overlay dirs would only re-inject 0.12-era files on top. Drop them.
    rm -rf "$SOFTWARE_DIR/klipper/extras" "$SOFTWARE_DIR/klipper/kinematics"
    mkdir -p "$SOFTWARE_DIR/klipper/extras"
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
# Lives in this repo under payload/klipper/.
if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
    say "Toolchange: ff_*.py + configs"
    mkdir -p "$SOFTWARE_DIR/klipper/extras"
    cp -f payload/klipper/extras/ff_*.py "$SOFTWARE_DIR/klipper/extras/"
    # .cfg files belong on the data partition. These are mod-owned: run.sh
    # overwrites them on every update (test_config_ownership.py enforces it).
    # User changes go in printer.cfg, which no flash ever writes.
    cp -f payload/klipper/config/ff-*.cfg "$MOD_PAYLOAD/config/"
    # Our printer.base.cfg is FlashForge's with the chamber block replaced by
    # [include printer.chamber.cfg] -- Klipper can override an option but
    # cannot un-declare a section, and the plain Creator 5 has no chamber
    # heating element, so its heater has to be absent rather than neutralised.
    # NOTE: this cp is why the stock-drift check lives in bin/unpack.sh and
    # not in a test -- it overwrites the pristine copy, and the test that used
    # to read it afterwards was comparing our file against itself.
    cp -f payload/klipper/config/printer.base.cfg "$SOFTWARE_DIR/klipper/config/printer.base.cfg"

    # Anything that differs between models exists once per model, named
    # <file>.creator5 / <file>.creator5pro, and the matching one is installed
    # under its real name. Nothing is edited: the suffixed file IS the
    # difference. printer.*.cfg belongs beside printer.base.cfg on the program
    # partition; ff-*.cfg belongs on the data partition with the rest.
    SUFFIX=$(printf '%s' "$TARGET_MACHINE" | tr 'A-Z' 'a-z')
    for variant in payload/klipper/config/*."$SUFFIX"; do
        [ -e "$variant" ] || continue
        base=$(basename "$variant" ".$SUFFIX")
        case "$base" in
            printer.*) dest="$SOFTWARE_DIR/klipper/config/$base" ;;
            *)         dest="$MOD_PAYLOAD/config/$base" ;;
        esac
        cp -f "$variant" "$dest"
        say "Model: $base for $TARGET_MACHINE"
    done
    # printer.base.cfg includes it unconditionally, so without it klippy will
    # not start at all. A broken build, not a silent default.
    [ -f "$SOFTWARE_DIR/klipper/config/printer.chamber.cfg" ] \
        || { echo "no printer.chamber.cfg.$SUFFIX for TARGET_MACHINE=$TARGET_MACHINE" >&2; exit 1; }
else
    skip "Toolchange"
fi

# -------------------------------------------------------------- 3. Mainsail
# THE BUILD LIVES IN pkg/mainsail/build.sh and this section stages what it
# produced: the .ipk and the tarball have to contain the same bytes, or they
# are two different Mainsails wearing one version number and no test can tell
# which a printer got.
if [ "${BUILD_MAINSAIL:-1}" = "1" ]; then
    bash pkg/mainsail/build.sh
    mkdir -p "$MOD_PAYLOAD/www"
    cp -a "$(pkg_out mainsail)/www/mainsail" "$MOD_PAYLOAD/www/mainsail"
    du -sh "$MOD_PAYLOAD/www/mainsail" | awk '{print "   "$1}'
else
    skip "Mainsail"
fi
# nginx.conf and moonraker.conf ship in pkg/anvil-core, with the rest of the
# configuration this repo writes; copying them here too would put the same file
# in the payload from two places.
#
# moonraker-custom.conf is the exception and stays here: it is a USER SEAM.
# moonraker.conf includes it by name and run-append.sh creates it only when
# missing, never overwrites it. A package member is overwritten on every
# upgrade by definition, so anvil-core would destroy a printer's own Moonraker
# settings the first time it was upgraded.
[ -f assets/moonraker-custom.conf ] \
    && cp -f assets/moonraker-custom.conf "$MOD_PAYLOAD/config/moonraker-custom.conf"

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
# Nothing is copied to /usr/prog/moonraker: the moonraker-env virtualenv there
# is not on sys.path at all (imports resolve from
# /usr/prog/Python-3.8.2/lib/python3.8/site-packages), and moonrakerDaemon, the
# thing that execs that tree by absolute path, is never invoked.
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
# commit that does.
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
# THE TREE IS BUILT BY pkg/moonraker/build.sh, which also holds the tarball
# shape guard and the tests/__pycache__ trims, so the .ipk and the payload
# cannot end up containing different Moonrakers.
if [ "${BUILD_MOONRAKER:-1}" = "1" ]; then
    bash pkg/moonraker/build.sh
    rm -rf "$MOD_PAYLOAD/moonraker"
    cp -a "$(pkg_out moonraker)/moonraker" "$MOD_PAYLOAD/moonraker"
    du -sh "$MOD_PAYLOAD/moonraker" | awk '{print "   "$1}'
else
    skip "Moonraker: keeping the stock 2022 build"
fi

# ----------------------------------------------------------- 5. HelixScreen
# pkg/helixscreen/build.sh unpacks upstream's release and merges this repo's
# printer-database entry and the optional platform hook into it. Its three
# mipsel binaries are ABI-gated by bin/build-packages.sh like every other
# package tree.
if [ "${BUILD_HELIX:-1}" = "1" ]; then
    bash pkg/helixscreen/build.sh
    rm -rf "$MOD_PAYLOAD/helixscreen"
    cp -a "$(pkg_out helixscreen)/helixscreen" "$MOD_PAYLOAD/helixscreen"
    du -sh "$MOD_PAYLOAD/helixscreen" | awk '{print "   "$1}'
else
    skip "HelixScreen"
fi

# --------------------------------------------- 5b. s6 / execline / s6-rc
# The supervision stack, staged from four recipes. One libc -- the printer's
# own glibc 2.29, linked dynamically; the reasons sit in versions.env beside
# the pins.
#
# NOTHING STARTS s6-rc YET: shipping the binaries is a separate change from
# using them, see docs/notes/80-s6-migration.md. This step only puts them in
# the payload.
bash pkg/skalibs/build.sh   # dev-only; nothing of it reaches the payload
bash pkg/execline/build.sh
bash pkg/s6/build.sh
bash pkg/s6-rc/build.sh

# bin/ and libexec/ from each, merged into the one prefix root they all
# configured themselves for. cp -a of the CONTENTS and not of the directory,
# because python's interpreter and libsodium's .so land in these same two
# directories and must survive.
for _p in execline s6 s6-rc; do
    cp -a "$(pkg_out "$_p")/bin/." "$MOD_PAYLOAD/bin/"
    [ -d "$(pkg_out "$_p")/libexec" ] \
        && cp -a "$(pkg_out "$_p")/libexec/." "$MOD_PAYLOAD/libexec/"
done
chmod +x "$MOD_PAYLOAD/bin"/s6-* "$MOD_PAYLOAD/bin"/execlineb "$MOD_PAYLOAD/libexec"/*

# The gate, over the payload rather than over any one build tree. A cross-build
# that silently produced a host object, or one legacy-NaN object because a flag
# did not reach one link line, looks like a clean build here and like a printer
# that cannot exec its own supervisor there -- the kernel says ENOEXEC, or
# execs it with the wrong FPU mode, and explains neither. The per-binary
# presence checks live in the recipes, next to the ship lists they check.
S6_ELF=$(mips_abi_gate "$MOD_PAYLOAD/bin" "$MOD_PAYLOAD/libexec") || exit 1
say "s6 + execline + s6-rc: $S6_ELF ELF objects are nan2008/o32/mips32r2 -- good"
du -sh "$MOD_PAYLOAD/bin"     | awk '{print "   "$1"\tbin/"}'
du -sh "$MOD_PAYLOAD/libexec" | awk '{print "   "$1"\tlibexec/"}'

# -------------------------------------------------- 5c. CPython 3.13 (shipped)
# A second Python for the printer. pkg/python builds the interpreter and the
# pkg/python-* recipes build what goes in its site-packages -- one recipe and
# one .ipk each. This section runs them and stages what they produce.
# Everything about HOW they are built lives with them (pkg/python/build.sh, and
# pkg_buildpython / pkg_pytarget / pkg_pywheel in pkg/lib.sh); every reason WHY
# is in the pkg.conf beside each one.
#
# ############################################################################
# # FF_PYTHON POINTS HERE. payload/anvil-env.sh names this interpreter for   #
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
# ONE RECIPE PER PACKAGE, so a package pin can move without rebuilding
# CPython: the untrimmed staging tree, the sysroot of static libraries and the
# x86-64 build-python a wheel needs are the feed's anvil-python-dev package,
# each recipe's own sysroot, and pkg_buildpython's shared cache. So
# `make packages PKG=python-pillow` is a Pillow build and nothing else.
say "python: CPython $PY_VERSION and $(echo $PYPKG_LIST | wc -w) packages"
bash pkg/python/build.sh
# PYPKG_LIST IS STILL THE LIST, and it is checked against the recipes rather
# than trusted: versions.env carries the pins and bin/fetch-assets.sh downloads
# from the same list, so an entry added there and nowhere else would otherwise
# be fetched, hashed and silently never built.
for p in $PYPKG_LIST; do
    [ -d "pkg/python-$p" ] || {
        echo "   !! PYPKG_LIST names '$p' and there is no pkg/python-$p recipe" >&2
        exit 1; }
    bash "pkg/python-$p/build.sh"
done

# Staged into the SAME bin/ and lib/ as everything else in this prefix root,
# which is why these copy the CONTENTS of the directories and not the
# directories: s6's binaries are already in $MOD_PAYLOAD/bin and must stay
# there, and every python package merges into one site-packages.
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
# pkg/python/pkg.conf's business and is read from there -- a second list here
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
# from the bytes the printer will execute. pkg/python/build.sh gates the
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
        || { echo "   !! python: no '$m' in site-packages -- pkg/python-$m" >&2
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
# THE BUILD LIVES IN pkg/libsodium/build.sh and is called from both sides: the
# .ipk bin/build-packages.sh emits has to come off the same configure line as
# the copy in the tarball, or the two ship different libraries under one
# version number and no test can tell.
#
# Cached on the stamp the recipe writes, which matters less for the 24 seconds
# than for bin/fetch-assets.sh: an uncached build drags the ~203MB Ingenic
# toolchain download behind it on a checkout with nothing else to compile.
#
# A SUBPROCESS AND NOT A SOURCE: the recipe exports a cross-compiler PATH and
# half a dozen build variables, and this file builds nine more things after
# it.
bash pkg/libsodium/build.sh

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
# The gate, over the payload: a legacy-NaN or big-endian libsodium imports
# perfectly on a build host and fails only inside libnacl's ctypes call on the
# printer, surfacing as Moonraker's authorization component failing to load --
# three layers from anything that says MIPS.
#
# Aimed at the resolved object rather than at $MOD_PAYLOAD/lib, because lib/
# also holds the interpreter's whole stdlib and re-walking two thousand files
# to reach one is a gate somebody deletes the first time they time a build.
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
cp -f payload/start.sh "$SOFTWARE_DIR/start.sh"
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
cp -f payload/firmwareExe "$SOFTWARE_DIR/firmwareExe"
chmod +x "$SOFTWARE_DIR/firmwareExe"

# ----------------------------------------------------- 10. mod service dir
# THE MOD'S OWN FILES COME FROM pkg/anvil-core: the shared environment and
# service libraries every init script sources, the init scripts, the helper
# programs, the nginx and Moonraker config, the toolchanger's Klipper includes
# and the s6 scandir. bin/build-packages.sh packages the same tree, so what a
# printer gets from the tarball and what it would get from
# `opkg install anvil-core` cannot drift apart.
#
# ANVIL.CONF IS NOT IN THAT PACKAGE and is written below: it is templated from
# config.env and preserved across updates by run-append.sh, which makes it user
# state rather than a package member. See pkg/anvil-core/build.sh.
bash pkg/anvil-core/build.sh
cp -a "$(pkg_out anvil-core)/." "$MOD_PAYLOAD/"
rm -f "$MOD_PAYLOAD/.version"
sed -e "s/^MOD_WEB=.*/MOD_WEB=${MOD_WEB:-1}/" \
    -e "s/^MOD_CAM=.*/MOD_CAM=${MOD_CAM:-1}/" \
    -e "s/^MOD_UI=.*/MOD_UI=${MOD_UI:-1}/" \
    -e "s/^MOD_SSH=.*/MOD_SSH=${MOD_SSH:-1}/" \
    -e "s/^MOD_WIFI=.*/MOD_WIFI=${MOD_WIFI:-1}/" \
    -e "s/^NICE_MOONRAKER=.*/NICE_MOONRAKER=${NICE_MOONRAKER:-5}/" \
    -e "s/^NICE_CAM=.*/NICE_CAM=${NICE_CAM:-10}/" \
    payload/anvil.conf > "$MOD_PAYLOAD/anvil.conf"

# ------------------------------------------------ 10b. the install manifest
# The list of every path this payload installs, shipped inside the payload
# itself so that the NEXT update can delete exactly what this one left behind.
#
# Deleting whole directories before extracting would be correct only while
# every file under them is ours -- a supervisor binary in $MODDIR/bin, a
# Python, anything a user put there by hand would go with them. The manifest
# still gives the property that mattered: the installed set ends up exactly the
# shipped set, because a file the last payload shipped and this one does not is
# still named in the list the last payload wrote. Without that a RENAMED init
# script leaves a stale twin behind and firmwareExe runs both -- see
# payload/run-append.sh.
#
# GENERATED, never hand-maintained: wrong here means either a file that never
# goes away or a file that should have stayed. Read off the staged tree at the
# last moment before bin/pack.sh turns it into anvil.tar.xz -- everything above
# this line has finished staging.
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
    payload/run-append.sh > "$POST"
python3 - "$SOFTWARE_DIR/run.sh" payload/run-pre.sh "$POST" <<'PY'
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
