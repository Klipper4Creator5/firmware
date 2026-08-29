#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"
# lib.sh for pkg_recipes, pkg_ipk and pkg_die. Not pkg_out:
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
# bin/build-payload.py replaces $PAYLOAD_DIR itself; this clears anything
# beside it and a stale directory from an older layout.
rm -rf "$PAYLOAD_ROOT" "$SOFTWARE_DIR/mod"

# ------------------------------------------------- 0. the payload, installed
# Every file bound for $MODDIR comes from a package, installed by the
# PRINTER'S OWN opkg out of the feed bin/build-packages.sh indexed, inside the
# replica. `opkg list-installed` answers "what does this release install?" off
# the payload itself.
say "payload: installing the feed with the printer's own opkg"

# The payload is not model-specific: anvil-klipper-config ships both chamber
# configs and anvil-link-prog.sh symlinks the one the printer names.
# TARGET_MACHINE still names the OUTPUT, because runFirmwareExe.sh refuses a
# package whose machine is not its own and app_startup.sh globs for the model
# prefix, so bin/pack.sh stamps it on the filename.

# WHAT THE RELEASE IS, not the closure of it. Depends brings the rest, and
# whether it does is the same question an `opkg install anvil-moonraker` on a
# printer asks -- so the metadata is exercised on every build instead of only
# when somebody tries it. Naming the closure by hand would have hidden that.
#
# A root with no .ipk in the feed is skipped, which is how the PKG_WHEN gates
# reach here: BUILD_HELIX=0 builds no anvil-helixscreen, and an unset
# BUSYBOX_BIN builds no anvil-busybox, so there is nothing to install and no
# flag restated in this file. A missing DEPENDENCY is still an error, and opkg
# raises it.
#
# The four loose python packages are Recommends, which opkg has no field for:
# pillow and preprocess-cancellation are Moonraker's thumbnail path
# (pkgs/moonraker argues them out of Depends), greenlet and cffi are klippy's,
# which pkgs/klipper cannot declare while klippy still runs under
# FlashForge's interpreter.
MOD_ROOTS="anvil-core anvil-opkg anvil-s6-rc anvil-klipper
           anvil-moonraker anvil-python-pillow anvil-python-preprocess-cancellation
           anvil-python-greenlet anvil-python-cffi
           anvil-mainsail anvil-helixscreen anvil-busybox"

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

# Built on the printer: bin/build-payload.py starts the replica, lets the
# machine's own opkg install the feed onto the machine's own filesystem, and
# tars the result back. That needs a privileged container and the printer
# image, which is why `make build` has its own docker lane.
# shellcheck disable=SC2086
./bin/build-payload.py $MOD_INSTALL

say "payload: $(grep -c '^Package:' "$PAYLOAD_DIR/var/lib/opkg/status") packages installed (both chamber configs; the printer picks)"

# ---------------------------------------------------------------- 1. Klipper
# THE BUILD LIVES IN pkgs/klipper, and this section copies what it produced --
# the arrangement sections 3, 4, 5 and 5d have had since each became a recipe,
# and for the same reason: the .ipk and the tarball have to contain the same
# klippy tree and the same c_helper.so, or they are two different Klippers
# wearing one version number and no test can tell which a printer got.
#
# THERE IS NO STOCK PATH. BUILD_KLIPPER=stock kept FlashForge's v0.12 tree and
# it is gone -- everything else the mod ships is written against the fork. The
# flag's own history is why it went rather than gaining another guard: a
# "fork" build silently falling back to stock is exactly what shipped as
# v20260824-nova-kakhovka, where the 0.12-era overlay half-overwrote the v0.13
# tree and klippy died at connect with "expects 4 arguments, got 3" -- a v0.12
# extruder.py calling the v0.13 chelper cdef.
#
# THE TREE COMES OUT OF THE PAYLOAD, which is to say out of the installed
# anvil-klipper package, not out of the recipe's build directory. That was the
# last place this script reached into work/pkg, and removing it is what makes
# "the tarball and the .ipk contain the same klippy" true by construction
# rather than by two copies of one cp -a agreeing.
_kl="$PAYLOAD_DIR/klipper"
[ -d "$_kl/klippy" ] || pkg_die \
    "the payload has no $MODDIR/klipper/klippy -- anvil-klipper did not install"

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
# -- read out of a real stock package, so a package without it
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
    # recipe directory would be a second source for a file a package holds.
    _ffx="$PAYLOAD_DIR/klipper/klippy/extras"
    mkdir -p "$SOFTWARE_DIR/klipper/extras"
    # Named by the recipe, not globbed out of the payload: the fork ships an
    # ff_eddy.py of its own and `ff_*.py` cannot tell it from ours. It rides
    # the klippy tree section 1 copied either way, so sweeping it up here
    # would put the same file in the component twice.
    for _f in pkgs/klipper/payload/klipper/klippy/extras/ff_*.py; do
        cp -f "$_ffx/$(basename "$_f")" "$SOFTWARE_DIR/klipper/extras/"
    done

    # NO .cfg IS WRITTEN HERE: the software component's klipper/config is left
    # exactly as FlashForge shipped it. anvil-klipper-config carries every
    # config the mod owns and anvil-link-prog.sh symlinks them into
    # /usr/data/config, which is where the stock run.sh puts that directory
    # anyway. The ff_*.py above are what is left that cannot be a package.
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

# --------------------------------------------- 5b-2. the s6-rc database
# The boot order, compiled. payload/etc/s6-rc/source/ holds the definition
# directories (one per service, plus the ok-all bundle) and this turns them
# into the binary database s6-rc-init reads at boot.
#
# COMPILED HERE, ON THE BUILD HOST, NOT ON THE PRINTER. That needs a
# s6-rc-compile that runs on x86, which means a second, native build of the
# same four tarballs -- which is why this step exists at all and is not two
# lines. The alternative was shipping the target s6-rc-compile (131KB) and
# compiling at install time, and it was rejected for the reason phase 6 of
# docs/notes/80-s6-migration.md states as "do the gate first, not the
# installer": a database compiled on the printer can fail on a printer in a
# way CI never sees, and the ABI gate above cannot look at a database.
#
# THAT THIS WORKS AT ALL WAS MEASURED, not reasoned from the manual. On
# 2026-08-28, in the replica: the same source tree compiled by the native
# s6-rc-compile and by the target one under qemu produced byte-identical
# db, n and resolve.cdb, and `diff -r` found no difference in the generated
# servicedirs. The database files are host-neutral by construction (every
# integer goes through uint32_pack_big) and the servicedirs are neutral
# BECAUSE both builds are configured --prefix=$MODDIR -- the #! line
# s6-rc-compile writes into the oneshot runner comes from the execline the
# COMPILER was linked against, not from the one we ship. Configure the native
# stack with a different prefix and every oneshot on the printer dies with
# ENOENT while every longrun keeps working.
# The source tree comes out of the INSTALLED payload, not out of the recipe
# directory -- anvil-core ships it, so compiling what shipped is the only way
# the database and the package cannot disagree.
S6RC_SRC="$PAYLOAD_DIR/etc/s6-rc/source"
S6RC_NATIVE="$PWD/work/.s6-native"
# The four versions and nothing else: this compiler is built by the build
# image's own gcc, so there is no toolchain file to key on.
S6RC_NATIVE_STAMP="$SKALIBS_VERSION $EXECLINE_VERSION $S6_VERSION $S6RC_VERSION"
[ -d "$S6RC_SRC" ] || { echo "   !! no s6-rc source tree at $S6RC_SRC" >&2; exit 1; }

if [ ! -x "$S6RC_NATIVE/bin/s6-rc-compile" ] \
   || [ "$(cat "$S6RC_NATIVE/.version" 2>/dev/null || true)" != "$S6RC_NATIVE_STAMP" ]; then
    say "s6-rc: building a native compiler ($SKALIBS_VERSION/$EXECLINE_VERSION/$S6_VERSION/$S6RC_VERSION)"
    rm -rf work/.s6-native work/.s6-native-src
    mkdir -p work/.s6-native-src
    for t in "$SKALIBS_TGZ" "$EXECLINE_TGZ" "$S6_TGZ" "$S6RC_TGZ"; do
        tar -xzf "$t" -C work/.s6-native-src
    done
    (
        # A subshell for the same reason the cross build has one: nothing
        # about this compiler's environment may leak into the rest of the
        # build. Note the ABSENCE of --host: this one runs here.
        set -e
        NSRC="$PWD/work/.s6-native-src"
        ND="$PWD/work/.s6-native-stage"
        rm -rf "$ND"
        export CFLAGS="-Os"
        JOBS=$(nproc 2>/dev/null || echo 4)
        for pkg in "skalibs-$SKALIBS_VERSION" "execline-$EXECLINE_VERSION" \
                   "s6-$S6_VERSION" "s6-rc-$S6RC_VERSION"; do
            cd "$NSRC/$pkg"
            if [ "$pkg" = "skalibs-$SKALIBS_VERSION" ]; then
                # No --with-sysdep answers here: configure can compile and RUN
                # its probes, because the target is this machine.
                ./configure --prefix="$MODDIR" \
                    --disable-shared --enable-static >/dev/null
            else
                ./configure --prefix="$MODDIR" \
                    --with-sysdeps="$ND$MODDIR/lib/skalibs/sysdeps" \
                    --with-include="$ND$MODDIR/include" \
                    --with-lib="$ND$MODDIR/lib" \
                    --disable-shared --enable-static >/dev/null
            fi
            make -j"$JOBS" >/dev/null
            make install DESTDIR="$ND" >/dev/null
        done
    )
    mkdir -p "$S6RC_NATIVE/bin"
    # s6-rc-db comes too: qa/static/test_s6rc_source.py reads the boot graph
    # back out of the compiled database rather than out of the source tree,
    # and this is the only copy of it that runs on the build host.
    for b in s6-rc-compile s6-rc-db; do
        cp -f "work/.s6-native-stage$MODDIR/bin/$b" "$S6RC_NATIVE/bin/"
    done
    rm -rf work/.s6-native-src work/.s6-native-stage
    echo "$S6RC_NATIVE_STAMP" > "$S6RC_NATIVE/.version"
else
    skip "s6-rc: native compiler already built for $S6RC_NATIVE_STAMP"
fi

# The database goes to etc/s6-rc/compiled/<stamp>, with `current` a symlink to
# it -- skarnet's own advice, so the boot command never changes when the
# database does. Not /etc/s6-rc/, which is s6-rc-init's default and is inside
# the read-only squashfs.
S6RC_DB_NAME="db-$MOD_VER"
rm -rf "$PAYLOAD_DIR/etc/s6-rc/compiled"
mkdir -p "$PAYLOAD_DIR/etc/s6-rc/compiled"
"$S6RC_NATIVE/bin/s6-rc-compile" \
    "$PAYLOAD_DIR/etc/s6-rc/compiled/$S6RC_DB_NAME" "$S6RC_SRC" || {
    echo "   !! s6-rc-compile refused $S6RC_SRC" >&2; exit 1; }
ln -sfn "$S6RC_DB_NAME" "$PAYLOAD_DIR/etc/s6-rc/compiled/current"

# The shebang the compiler baked in is the one assertion that catches a native
# stack built with the wrong prefix, and it is worth making here rather than
# discovering on a printer: this file is generated, so it is the only place
# the build can see what the database will ask the printer to exec.
S6RC_RUNNER="$PAYLOAD_DIR/etc/s6-rc/compiled/$S6RC_DB_NAME/servicedirs/s6rc-oneshot-runner/run"
[ -f "$S6RC_RUNNER" ] || {
    echo "   !! s6-rc-compile produced no oneshot runner -- has the source tree no oneshots?" >&2
    exit 1; }
S6RC_SHEBANG=$(head -1 "$S6RC_RUNNER")
case "$S6RC_SHEBANG" in
    "#!$MODDIR/bin/execlineb"*) ;;
    *) echo "   !! the s6-rc database asks for '$S6RC_SHEBANG', not $MODDIR/bin/execlineb --" >&2
       echo "      the native stack was configured with the wrong --prefix" >&2
       exit 1 ;;
esac
say "s6-rc: database $S6RC_DB_NAME compiled -- $(ls "$S6RC_SRC" | wc -l) definitions"

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
# The dev half is not installed, so verify.sh's "no headers in the payload"
# check passes because they were never put there.

# THE GATES ARE THE RECIPES'. pkgs/3rdparty/python/build.sh asks for _sqlite3
# by name, and the seven python-* recipes that ship a .so each assert their
# own extension -- an aggregate count could say that A native package had
# fallen back to a pure-python wheel but never WHICH.
#
# WHAT THAT COSTS: a gate inside build.sh does not run on a cache hit, and
# none of the python recipes sets PKG_STAMP_EXTRA, so editing one does not
# rebuild it. That is a property of pkg_stamp rather than of where a gate
# lives; the answer is to make the stamp see the recipe, not to keep a second
# copy of every check here.
du -sh "$PAYLOAD_DIR/lib/python$PY_MM" | awk '{print "   "$1"\tlib/python'"$PY_MM"'/"}'
du -sh "$PAYLOAD_DIR/lib/python$PY_MM/site-packages" \
    | awk '{print "   "$1"\tlib/python'"$PY_MM"'/site-packages/"}'

# ------------------------------------------------------------------- 6. SSH
# Nothing to install. The stock rootfs (kernel-*.tar.xz -> rootfs.squashfs)
# already ships /usr/sbin/dropbear, /usr/bin/dropbearkey AND an enabled
# /etc/init.d/S50dropbear that busybox init runs at every boot. SSH is
# therefore ALREADY LISTENING on port 22 of a stock printer.
#
# The only thing missing is a root password anyone knows: stock /etc/shadow
# carries an unpublished hash. Setting ROOT_PW_HASH below is the entire
# "enable ssh" feature -- no cross-compiled binaries, no init script.
#
# MOD_SSH USED TO GATE THIS and is gone. It never turned ssh off -- dropbear is
# the rootfs's and listens either way -- so all it did was decline to set a
# password on a machine whose whole recovery story is "ssh in". A build that
# genuinely wants the stock hash left alone is a build that wants a stock
# package.
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "SSH: stock dropbear is already running; setting a known root password"
else
    say "SSH: no ROOT_PW_HASH -- the installer will pick a random root password"
    say "     and write it to anvil-password.txt on the USB stick."
    say "     Set ROOT_PW_HASH to choose your own instead."
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
# FROM THE INSTALLED PAYLOAD, not from a directory beside the recipe -- the
# same move section 1 already makes for the klippy fork. anvil-core ships this
# file at $MODDIR/prog/start.sh, so the package is the one source of truth and
# the component is a copy of it rather than a second original.
#
# It still travels in the component, because that is what FlashForge's run.sh
# copies to /usr/prog/klipper/start.sh and what keeps a printer bootable when
# the payload is not there. anvil-link-prog.sh replaces that copy with a
# symlink afterwards; see its header.
say "start.sh: enabling nginx + moonraker"
cp -f "$PAYLOAD_DIR/prog/start.sh" "$SOFTWARE_DIR/start.sh"
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
#
# Also from the installed payload, for the reason section 8 gives. The copy
# that ends up on /usr/prog is what app_startup.sh launches until
# anvil-link-prog.sh turns it into a symlink -- after which an `opkg upgrade
# anvil-core` is enough to change what the printer runs, with no .tgz.
say "firmwareExe: installing wrapper (replaces the stock binary)"
cp -f "$PAYLOAD_DIR/prog/firmwareExe" "$SOFTWARE_DIR/firmwareExe"
chmod +x "$SOFTWARE_DIR/firmwareExe"

# ---------------------------------------------------------- 10. anvil.conf
# THE MOD'S OWN FILES ARE anvil-core, INSTALLED BY SECTION 0: the shared
# environment and service libraries every init script sources, the init
# scripts themselves, the helper programs, the nginx config and the s6
# scandir.
#
# ANVIL.CONF IS NOT IN THAT PACKAGE, and this is the whole of what is left
# here. It is templated from config.env and then preserved across updates by
# run-append.sh, which makes it user state rather than a package member: a
# package would overwrite a printer's settings on the first upgrade. See the
# header of pkgs/anvil-core/build.sh.
#
# FIVE OF THE SEVEN SUBSTITUTIONS ARE GONE with the switches they wrote:
# MOD_WEB, MOD_CAM, MOD_UI, MOD_SSH and MOD_WIFI all defaulted to 1 and are now
# simply always true. What is left is the two that have a RANGE -- a nice level
# is a number, not a state -- which is the line between a tunable and a switch
# and the reason these two stayed.
sed -e "s/^NICE_MOONRAKER=.*/NICE_MOONRAKER=${NICE_MOONRAKER:-5}/" \
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
# 1 when nothing was baked in: a package is one file that many people flash, so
# a baked-in default would be the same password on every printer. The installer
# picks a random per-machine one instead and writes it onto the USB stick it
# was flashed from.
if [ -z "${ROOT_PW_HASH:-}" ]; then
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
