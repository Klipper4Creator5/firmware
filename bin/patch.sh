#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# lib.sh for pkg_recipes, pkg_ipk, pkg_buildopkg and pkg_die. Not pkg_out:
# nothing here reads work/pkg, and qa/static/test_ipk.py asserts it.
. "$ROOT/pkgs/lib.sh"

SOFTWARE_DIR=work/software
[ -d "$SOFTWARE_DIR" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

# The payload is installed from the feed, so the feed has to exist. Counting
# .ipk rather than testing for the directory: a cleaned tree leaves $PKG_FEED
# present and empty, which is the case that used to fail obscurely inside a
# recipe two hundred lines down.
if [ -z "$(ls "$PKG_FEED"/*.ipk 2>/dev/null)" ]; then
    echo "no package feed at $PKG_FEED" >&2
    echo "  the recipes this script runs build against it -- run 'make packages' first." >&2
    exit 1
fi

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# The payload is built OUTSIDE the software component: that component goes to
# /usr/prog on the firmware partition, which keeps one version and would
# overflow on ~100MB of Mainsail and HelixScreen. The payload rides in the
# outer package instead and lands on /usr/data.
#
# THE WHOLE ROOT GOES, not just the payload inside it. A surviving
# var/lib/opkg would make opkg think these packages are already installed and
# take its upgrade path, removing files from a tree it is still building.
rm -rf "$PAYLOAD_ROOT" "$SOFTWARE_DIR/mod"   # $SOFTWARE_DIR/mod: leftover from an older layout
# The prefix root's directories, created here rather than left to whichever
# package happens to fill them -- FOR THE MANIFEST'S SAKE. The manifest is a
# find over this tree, so a directory that only ever appeared on the printer
# would be one no update can account for. libexec/ and etc/s6/ are spelled
# exactly this way because s6 resolves both from the --prefix baked into its
# binaries: the names are ABI, not preference.
mkdir -p "$PAYLOAD_DIR/bin" "$PAYLOAD_DIR/lib" "$PAYLOAD_DIR/libexec" \
         "$PAYLOAD_DIR/nginx" \
         "$PAYLOAD_DIR/www" "$PAYLOAD_DIR/config" "$PAYLOAD_DIR/etc/s6"

# ------------------------------------------------- 0. the payload, installed
# Every file bound for $MODDIR comes from a package, installed by a real opkg
# out of the feed bin/build-packages.sh indexed. `opkg list-installed` answers
# "what does this release install?" off the payload itself.
say "payload: installing the feed into $PAYLOAD_ROOT"
pkg_buildopkg

# The model is the one fact opkg cannot work out for itself: both chamber
# configs own config/printer.chamber.cfg and Conflict, so opkg refuses the
# pair (exit 255) and the choice has to be made here.
case "$TARGET_MACHINE" in
    Creator5)    MODEL_PKG=anvil-klipper-creator5-config ;;
    Creator5Pro) MODEL_PKG=anvil-klipper-creator5pro-config ;;
    *) echo "no chamber-config package for TARGET_MACHINE=$TARGET_MACHINE" >&2
       exit 1 ;;
esac

# WHAT THE RELEASE IS, not the closure of it. Depends brings the rest, and
# whether it does is the same question an `opkg install anvil-moonraker` on a
# printer asks -- so the metadata is exercised on every build instead of only
# when somebody tries it. Naming the closure by hand would have hidden that.
#
# A root with no .ipk in the feed is skipped, which is how the PKG_WHEN gates
# reach here: BUILD_KLIPPER=stock builds no anvil-klipper, so there is nothing
# to install and no flag restated in this file. A missing DEPENDENCY is still
# an error, and opkg raises it.
#
# The four loose python packages are Recommends, which opkg has no field for:
# pillow and preprocess-cancellation are Moonraker's thumbnail path
# (pkgs/moonraker argues them out of Depends), greenlet and cffi are klippy's,
# which pkgs/klipper cannot declare while klippy still runs under
# FlashForge's interpreter.
MOD_ROOTS="anvil-core anvil-opkg anvil-s6-rc anvil-klipper $MODEL_PKG
           anvil-moonraker anvil-python-pillow anvil-python-preprocess-cancellation
           anvil-python-greenlet anvil-python-cffi
           anvil-mainsail anvil-helixscreen"

# Named, not versioned: opkg reads the index and picks. The one version that
# cannot be left to it is anvil-core's -- PKG_VERSION is MOD_VER, which
# defaults to today's date, so a feed built yesterday installs yesterday's
# anvil-core without complaint.
[ -f "$(pkg_ipk anvil-core)" ] || pkg_die \
    "the feed has no $(basename "$(pkg_ipk anvil-core)") -- rerun ./bin/build-packages.sh"

MOD_INSTALL=""
for _p in $MOD_ROOTS; do
    for _f in "$PKG_FEED/${_p}_"*.ipk; do
        if [ -f "$_f" ]; then MOD_INSTALL="$MOD_INSTALL $_p"; fi
        break
    done
done

# Generated, because four of its lines are paths only this script knows.
#
#   offline_root  where opkg unpacks to. NOT where it keeps its database --
#                 that is compiled in (pkg_buildopkg), with this prefixed.
#   lists_dir     offline_root-relative too, so it and cache_dir are put
#                 outside $MODDIR: bin/pack.sh tars $PAYLOAD_DIR, so scratch
#                 parked beside it cannot ship and needs no cleaning up.
#   ignore_uid    clears libarchive's EXTRACT_OWNER. The build lane runs as
#                 the invoking user, so without this all ~3000 entries warn
#                 that they could not be chowned to root. Payload ownership
#                 has never meant anything: run-append.sh extracts as root.
#   arch          the anti-OpenWrt gate where opkg reads it -- a mipsel_24kc
#                 package has no priority here and is refused unopened.
#   src           file: is answered before curl is reached at all
#                 (libopkg/opkg_download.c:134), which is why the host opkg
#                 can be built --disable-curl and still resolve a feed.
MOD_OPKG_CONF="$PAYLOAD_ROOT/.opkg.conf"
mkdir -p "$PAYLOAD_ROOT"
cat > "$MOD_OPKG_CONF" <<EOF
dest root /
option offline_root $PAYLOAD_ROOT
option lists_dir /.opkg-lists
option cache_dir /.opkg-cache
option ignore_uid 1
arch all 1
arch $IPK_ARCH 10
src anvil file:$PKG_FEED
EOF

mod_opkg() {
    "$HOSTOPKG" --conf "$MOD_OPKG_CONF" "$@" \
        >> "$PAYLOAD_ROOT/.opkg.log" 2>&1 && return 0
    sed 's/^/   /' "$PAYLOAD_ROOT/.opkg.log" >&2
    echo "opkg failed: $* -- see $PAYLOAD_ROOT/.opkg.log" >&2
    exit 1
}
mod_opkg update
# --force-postinstall: under offline_root opkg skips configuration and leaves
# everything Status: unpacked. Extracting the tarball IS the install, so the
# database has to say installed. It runs no script: there are none.
# shellcheck disable=SC2086
mod_opkg --force-postinstall install $MOD_INSTALL

# The one clock left in the payload: opkg stamps Installed-Time from time(),
# where bin/build-packages.sh builds every .ipk with SOURCE_DATE_EPOCH=1.
# Normalised so two builds of one commit can be diffed.
sed -i "s/^Installed-Time: .*/Installed-Time: ${SOURCE_DATE_EPOCH:-1}/" \
    "$PAYLOAD_DIR/var/lib/opkg/status"

say "payload: $(grep -c '^Package:' "$PAYLOAD_DIR/var/lib/opkg/status") packages installed ($MODEL_PKG for $TARGET_MACHINE)"

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
# THE BUILD LIVES IN pkgs/klipper, and this section copies what it
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
# The configs are three packages, installed by section 0: anvil-klipper-config
# for the ff-*.cfg and one of the two model packages for printer.chamber.cfg.
# What is left here is the residue that cannot be a package -- klippy's extras
# and printer.base.cfg go to /usr/prog, beside FlashForge's own Klipper tree,
# and every path in a package of ours lands under $MODDIR.
if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
    say "Toolchange: ff_*.py + configs"
    # OUT OF THE PAYLOAD, like section 1's klippy tree and for the same
    # reason: anvil-klipper carries these now, so copying them from the
    # recipe directory would be a second source for a file a package already
    # holds. They ride the fork, so BUILD_KLIPPER=stock has none to copy --
    # said out loud rather than left as five files silently missing from a
    # printer that would then fail at klippy's first [ff_toolchange].
    _ffx="$PAYLOAD_DIR/klipper/klippy/extras"
    [ -d "$_ffx" ] || pkg_die \
        "BUILD_TOOLCHANGE=1 needs the ff_*.py extras and BUILD_KLIPPER=${BUILD_KLIPPER:-fork} built no anvil-klipper to carry them. Set BUILD_TOOLCHANGE=0, or BUILD_KLIPPER=fork"
    mkdir -p "$SOFTWARE_DIR/klipper/extras"
    # Named by the recipe, not globbed out of the payload: the fork ships an
    # ff_eddy.py of its own and `ff_*.py` cannot tell it from ours. It rides
    # the klippy tree section 1 copied either way, so sweeping it up here
    # would put the same file in the component twice.
    for _f in pkgs/klipper/payload/klipper/klippy/extras/ff_*.py; do
        cp -f "$_ffx/$(basename "$_f")" "$SOFTWARE_DIR/klipper/extras/"
    done

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
# What is in the payload and in NO package, because being a package member
# would be wrong. moonraker.conf includes moonraker-custom.conf by name and
# run-append.sh creates it only when missing; a package member is overwritten
# on every upgrade by definition, which would destroy a printer's own
# Moonraker settings.
[ -f pkgs/moonraker/seed/moonraker-custom.conf ] \
    && cp -f pkgs/moonraker/seed/moonraker-custom.conf "$PAYLOAD_DIR/config/moonraker-custom.conf"

# BUILD_MOONRAKER=0 LEAVES THE STOCK SERVER ALONE, INCLUDING ITS CONFIG. The
# stock Moonraker is a 2022 build (API 1.0.5) that ships on the factory image
# only, so a reflash cannot put it back once replaced. moonraker.conf is
# shipped by pkgs/moonraker with the server it configures, not by anvil-core:
# shipped unconditionally, a BUILD_MOONRAKER=0 build still overwrote the
# printer's config with one written for a server it was not installing.

# -------------------------------------------------- 5c. CPython 3.13 (shipped)
# A second Python for the printer, installed by section 0 as anvil-python plus
# the eighteen anvil-python-* packages. How they are built is in
# pkgs/3rdparty/python*/ and in pkg_buildpython / pkg_pytarget / pkg_pywheel.
#
# FF_PYTHON POINTS HERE: anvil-env.sh names this interpreter for Moonraker,
# ff-startup.py, ffscreen.py and ff_mcu_bringup.py. klippy is NOT one of its
# callers -- FlashForge's own /usr/prog/klipper/start.sh runs it on 3.8.2
# (init.d/S70klipper) -- so klippy's numpy gap is a separate, smaller item.
#
# WHY IT IS WORTH SHIPPING: FlashForge built 3.8.2 without _sqlite3, and that
# omission is what pins MOONRAKER_VERSION to a 2023 commit -- every Moonraker
# from v0.9.0 on keeps its database in sqlite. This one has a working sqlite3,
# measured on the replica (case-python.sh).
#
# The dev half is not installed, so the PKG_DEV_FILES deletion this section
# used to perform is gone: verify.sh's "no headers in the payload" check
# passes because they were never put there.

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
# The one library of ours that ships as a .so, because libnacl reaches it
# through ctypes.cdll.LoadLibrary -- dlopen, and you cannot dlopen an archive.
# Moonraker's `authorization` component signs its JWTs with the ed25519 pair
# libnacl exposes, so this is on the web UI's startup path.
#
# IT COSTS anvil-env.sh NOTHING, which is worth stating because it looks like
# it should need a library path entry. libnacl's third fallback is
# __file__[0:__file__.find("lib")+3] + "/libsodium.so", and __file__ is
# $MODDIR/lib/python3.13/site-packages/libnacl/__init__.py -- so it resolves
# $MODDIR/lib/libsodium.so by absolute path, measured with LD_LIBRARY_PATH
# unset. That works because this prefix contains the string "lib"; one that
# did not would break silently, which matters if $MODDIR ever moves.
#
# THE THREE NAMES ARE TWO SYMLINKS AND A FILE -- libsodium.so ->
# libsodium.so.26 -> libsodium.so.26.2.0. The first is the name that fallback
# constructs, the second the SONAME the loader then asks for. The check below
# is also the only thing on the release path asserting that opkg-build puts a
# symlink in the archive and opkg restores it as one.
[ -L "$PAYLOAD_DIR/lib/libsodium.so" ] \
    || { echo "   !! libsodium: lib/libsodium.so is not a symlink -- libnacl's" >&2
         echo "      dlopen fallback asks for that exact name." >&2; exit 1; }
# Resolved rather than reported by link name: a legacy-NaN or big-endian
# libsodium imports fine on a build host and fails inside libnacl's ctypes
# call on the printer, surfacing as Moonraker's authorization component not
# loading -- three layers from anything that says MIPS.
SODIUM_SO=$(readlink -f "$PAYLOAD_DIR/lib/libsodium.so")
say "libsodium: $SODIUM_VERSION in lib/ --" \
    "$(readelf -d "$SODIUM_SO" | awk '/SONAME/{gsub(/[][]/,"",$5); print $5}')," \
    "$(du -h "$SODIUM_SO" | cut -f1)"

# --------------------------------------------------- 5e. a richer busybox
# Optional (config.env, unset in normal builds), and the one file in the
# payload that no package puts there -- which is why it goes ABOVE the gate
# below. A foreign-ABI busybox in $MODDIR/bin is ENOEXEC at the first call
# from an init script. Its own gate call, so the error names BUSYBOX_BIN
# rather than "the payload".
if [ -n "${BUSYBOX_BIN:-}" ] && [ -f "$BUSYBOX_BIN" ]; then
    cp -f "$BUSYBOX_BIN" "$PAYLOAD_DIR/bin/busybox"
    chmod +x "$PAYLOAD_DIR/bin/busybox"
    mips_abi_gate "$PAYLOAD_DIR/bin/busybox" >/dev/null || {
        echo "   !! BUSYBOX_BIN=$BUSYBOX_BIN is not nan2008/o32/mips32r2." >&2
        echo "      The printer cannot exec it. Unset BUSYBOX_BIN in config.env" >&2
        echo "      or point it at one built for this ABI." >&2
        exit 1; }
    say "busybox: $(du -h "$PAYLOAD_DIR/bin/busybox" | cut -f1) from BUSYBOX_BIN"
fi

# ------------------------------------------------------- 5f. the ABI gate
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
# Every path this payload installs, shipped inside it so the NEXT update
# deletes exactly what this one left behind -- and only that. run-append.sh
# used to `rm -rf` seven whole directories, which destroyed anything a user
# had put in them.
#
# The property the rm -rf had and this must keep: the installed set ends up
# exactly the shipped set, or a RENAMED init script leaves a stale twin and
# firmwareExe runs both. A file the last payload shipped and this one does not
# is still named in the last payload's list, so it still goes.
#
# Read off the staged tree at the last moment -- everything above this line
# has finished staging. Directories are listed too, so emptied ones can be
# rmdir'd. It names ITSELF, because the next update must be free to replace
# it. Written to a temp file and moved in, or `find` would list the
# half-written manifest as one more payload path.
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
