#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"

SOFTWARE_DIR=work/software
[ -d "$SOFTWARE_DIR" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

say() { printf '>> %s\n' "$*"; }
skip() { printf '   (skip) %s\n' "$*"; }

# Everything we add to the printer lives under this one directory on the DATA
# partition, so a FlashForge OTA cannot delete it.
MODDIR=/usr/data/anvil
# The mod payload is built OUTSIDE the software component on purpose. The
# software component is extracted to /usr/prog/PROGRAM/software/<ver>/ -- the
# firmware partition, of which the installer keeps only one version. Mainsail and
# HelixScreen are ~100MB and would overflow it. They ride in the outer package
# instead, land in /usr/data/update/ (data partition), and are moved to
# /usr/data/anvil from there.
MOD_PAYLOAD=work/modpayload
rm -rf "$MOD_PAYLOAD" "$SOFTWARE_DIR/mod"   # $SOFTWARE_DIR/mod: leftover from an older layout
# libexec/ is here because $MODDIR is a --prefix root, not a junk drawer: it
# holds helper programs that other programs exec and users do not, which for
# now means s6-ftrigrd. It has to be a sibling of bin/ and spelled exactly
# this way -- s6 resolves it from the --prefix baked into its binaries at
# compile time, so the directory name is part of the ABI, not a preference.
# etc/ is the same idea one directory further on: a --prefix root keeps the
# mod's own configuration in etc/, and etc/s6/ is the s6 SCANDIR -- the
# directory s6-svscan watches, one subdirectory per supervised service. It is
# created here rather than at runtime by payload/init.d/S40s6, and the reason
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
# Lives in this repo under payload/klipper/ -- it used to be the separate
# creator5-toolchange checkout, pointed at by TOOLCHANGE= in config.env.
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
if [ "${BUILD_MAINSAIL:-1}" = "1" ]; then
    # BUILD_MAINSAIL=1 asked for Mainsail, so a missing file is a broken build,
    # not a reason to ship a package with an empty web root. bin/fetch-assets.sh
    # should have put it here.
    [ -f "${MAINSAIL_ZIP:-}" ] || { echo "BUILD_MAINSAIL=1 but no Mainsail zip at '${MAINSAIL_ZIP:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "Mainsail: unpacking $(basename "$MAINSAIL_ZIP")"
    mkdir -p "$MOD_PAYLOAD/www/mainsail"
    unzip -q -o "$MAINSAIL_ZIP" -d "$MOD_PAYLOAD/www/mainsail"
    cp -f assets/nginx.conf "$MOD_PAYLOAD/nginx/nginx.conf"
    du -sh "$MOD_PAYLOAD/www/mainsail" | awk '{print "   "$1}'
else
    skip "Mainsail"
fi
[ -f assets/moonraker.conf ] && cp -f assets/moonraker.conf "$MOD_PAYLOAD/config/moonraker.conf"
# The user seam for Moonraker. moonraker.conf includes it by name, and
# run-append.sh creates it only when it is missing -- never overwrites it.
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
if [ "${BUILD_MOONRAKER:-1}" = "1" ]; then
    [ -f "${MOONRAKER_TGZ:-}" ] || { echo "BUILD_MOONRAKER=1 but no Moonraker tarball at '${MOONRAKER_TGZ:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "Moonraker: staging $MOONRAKER_VERSION package tree"
    rm -rf work/.moonraker
    mkdir -p work/.moonraker
    tar -xzf "$MOONRAKER_TGZ" -C work/.moonraker --strip-components=1
    # Guard against a tarball whose shape changed under us -- silently
    # shipping nothing here would look like a clean build and a dead UI.
    [ -f work/.moonraker/moonraker/moonraker.py ] || {
        echo "   !! no moonraker/moonraker.py in $(basename "$MOONRAKER_TGZ")" >&2; exit 1; }
    rm -rf "$MOD_PAYLOAD/moonraker"
    cp -a work/.moonraker/moonraker "$MOD_PAYLOAD/moonraker"
    # Tests never run on the printer and are a sizeable chunk of the tree.
    rm -rf "$MOD_PAYLOAD/moonraker/tests"
    find "$MOD_PAYLOAD/moonraker" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    rm -rf work/.moonraker
    du -sh "$MOD_PAYLOAD/moonraker" | awk '{print "   "$1}'
else
    skip "Moonraker: keeping the stock 2022 build"
fi

# ----------------------------------------------------------- 5. HelixScreen
if [ "${BUILD_HELIX:-1}" = "1" ]; then
    [ -f "${HELIX_TGZ:-}" ] || { echo "BUILD_HELIX=1 but no HelixScreen tarball at '${HELIX_TGZ:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "HelixScreen: unpacking $(basename "$HELIX_TGZ")"
    mkdir -p "$MOD_PAYLOAD/helixscreen"
    tar -xzf "$HELIX_TGZ" -C "$MOD_PAYLOAD" # yields $MOD_PAYLOAD/helixscreen/
    # Printer-database entry so it detects the Creator 5 Pro as a tool changer
    mkdir -p "$MOD_PAYLOAD/helixscreen/config/printer_database.d"
    cp -f payload/helixscreen/printer_database.d/*.json \
          "$MOD_PAYLOAD/helixscreen/config/printer_database.d/"
    # Optional platform hook. No such file is in the repo, so this never fires
    # on a stock checkout -- drop one in assets/ to have it shipped.
    [ -f assets/hooks-creator5.sh ] && \
        cp -f assets/hooks-creator5.sh "$MOD_PAYLOAD/helixscreen/assets/config/platform/"
    du -sh "$MOD_PAYLOAD/helixscreen" | awk '{print "   "$1}'
else
    skip "HelixScreen"
fi

# ------------------------------------------------------- 5b. s6 supervision
# The process supervisor, cross-compiled here from the sources pinned in
# versions.env with the musl toolchain pinned beside them -- the same shape as
# c_helper.so above, and for the same reason: nothing binary is vendored in
# this repo, so anything the printer executes is built from a hash we pinned.
#
# NOTHING STARTS s6 YET. This step only puts it in the payload. The init
# scripts still hand-roll their supervision in payload/anvil-service.sh and
# will keep doing so until the scanner lands (docs/notes/80-s6-migration.md,
# phase 3). Shipping it first is what makes that a one-file change instead of
# a build change and a boot change at once.
#
# WHY NOT IN A CONTAINER OF ITS OWN. tools/supervisor/Dockerfile builds this
# in a debian:bookworm of its own -- that was the measurement harness, and it
# also had to build runit and execline for the comparison. The real build
# cannot work that way: bin/patch.sh already runs inside the pinned build
# image, and the Makefile's build lane deliberately gives that container no
# docker socket (only the test lane gets one), so there is no daemon to ask
# for a second container. It unpacks a toolchain into work/ and compiles in
# place instead, exactly as the chelper step does.
#
# WHY IT IS CACHED AND c_helper.so IS NOT. c_helper.so is rebuilt whenever any
# chelper source is newer than it, because its sources are a checkout someone
# may be editing and a stale .so under a fresh klippy is a bug that reached a
# printer. s6's sources are a pinned tarball that cannot change without its
# sha256 changing, so the two version strings ARE the whole cache key: build
# once, stamp work/.s6/.version, and every later build just copies. That also
# lets bin/fetch-assets.sh skip the ~100MB toolchain download entirely. Staging
# into the payload is NOT cached -- patch.sh rm -rf's work/modpayload on every
# run -- so a stale payload is not a thing that can happen.
S6_HOST=mipsel-linux-musl
S6_TOOLCHAIN_DIR=work/.musl-toolchain/$S6_HOST-cross
# The supervision subset, and only it. s6 installs ~40 binaries; the rest are
# the s6-log/fdholder/ipc machinery we have no use for. Every name below is
# reachable from something an init script will call:
#   svscan/svscanctl  the scanner and its control channel
#   supervise/svc     one supervisor per service, and the verb that talks to it
#   svstat/svok       "is it up", for the `status` verb the S* scripts expose
#   svwait            the readiness wait that is the whole reason for s6
#   svlisten/svlisten1/ftrig-listen1  the waiting verbs EXEC these; s6-svc -w
#                     and s6-svwait are unusable without them
#   mkfifodir/cleanfifodir  create and tidy the fifodirs those listen on
#   notifyoncheck     readiness for a service that cannot notify for itself
S6_BINS="s6-svscan s6-svscanctl s6-supervise s6-svc s6-svstat s6-svwait s6-svok
         s6-svlisten s6-svlisten1 s6-ftrig-listen1 s6-mkfifodir s6-cleanfifodir
         s6-notifyoncheck"
# Not in bin/ and not optional: s6-svlisten spawns this by absolute path out of
# the compiled-in libexecdir, and without it every waiting verb dies with
# "unable to ftrigr_startf: No such file or directory".
S6_LIBEXEC="s6-ftrigrd"
S6_STAMP="$SKALIBS_VERSION $S6_VERSION"

if [ "$(cat "$S6_BUILD/.version" 2>/dev/null || true)" != "$S6_STAMP" ]; then
    if [ ! -x "$S6_TOOLCHAIN_DIR/bin/$S6_HOST-gcc" ]; then
        [ -f "${MUSL_TOOLCHAIN_TGZ:-}" ] || {
            echo "   !! s6 needs (re)building and there is no musl toolchain:" >&2
            echo "      $MUSL_TOOLCHAIN_TGZ is missing. Run ./bin/fetch-assets.sh." >&2
            exit 1; }
        say "s6: unpacking the musl mipsel toolchain"
        rm -rf work/.musl-toolchain
        mkdir -p work/.musl-toolchain
        tar -xzf "$MUSL_TOOLCHAIN_TGZ" -C work/.musl-toolchain
    fi
    for t in "${SKALIBS_TGZ:-}" "${S6_TGZ:-}"; do
        [ -f "$t" ] || { echo "   !! no s6 sources at '$t' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    done
    say "s6: cross-compiling skalibs $SKALIBS_VERSION + s6 $S6_VERSION for $MODDIR"
    rm -rf work/.s6-src work/.s6-sysroot work/.s6-stage "$S6_BUILD"
    mkdir -p work/.s6-src
    tar -xzf "$SKALIBS_TGZ" -C work/.s6-src
    tar -xzf "$S6_TGZ" -C work/.s6-src
    (
        # A subshell so the cross-compiler's CC/CFLAGS/PATH cannot leak into
        # anything patch.sh does afterwards.
        export PATH="$PWD/$S6_TOOLCHAIN_DIR/bin:$PATH"
        export CC="$S6_HOST-gcc"
        # -D_FILE_OFFSET_BITS=64 is not a size optimisation, it is the
        # difference between a supervisor that works and one that starts
        # cleanly and then cannot readdir() its own scandir (EOVERFLOW: a
        # 32-bit build meeting 64-bit inodes). See versions.env.
        export CFLAGS="-Os -D_FILE_OFFSET_BITS=64"
        SK="$PWD/work/.s6-sysroot"
        STAGE="$PWD/work/.s6-stage"
        JOBS=$(nproc 2>/dev/null || echo 4)

        # skalibs is a BUILD DEPENDENCY. It goes to a throwaway sysroot, never
        # to the payload: s6 is linked statically against it, so the .a and the
        # headers have no reason to exist on a printer.
        #
        # The four --with-sysdep flags are answers to questions ./configure
        # normally settles by COMPILING AND RUNNING a probe, which it cannot do
        # when the target is a mipsel box and the builder is x86. Left
        # unanswered, configure stops. The answers are the printer's:
        # /dev/urandom exists, posix_spawn does not return early, /proc/self/exe
        # is readable, and select() accepts an infinite timeout.
        cd "$PWD/work/.s6-src/skalibs-$SKALIBS_VERSION"
        ./configure --host="$S6_HOST" --prefix="$SK" \
            --disable-shared --enable-static --enable-static-libc \
            --with-sysdep-devurandom=yes \
            --with-sysdep-posixspawnearlyreturn=no \
            --with-sysdep-procselfexe=/proc/self/exe \
            --with-sysdep-selectinfinite=yes >/dev/null
        make -j"$JOBS" >/dev/null
        make install >/dev/null

        # --prefix is $MODDIR and NOT the staging directory, because s6 bakes
        # the prefix into the binaries: this is the path they will look for
        # s6-ftrigrd under at runtime on the printer. DESTDIR is how the tree
        # lands somewhere we can read it here without needing /usr/data/anvil to
        # exist on the build machine.
        #
        # --disable-execline is not an optimisation either. s6 links against
        # execline by DEFAULT -- src/libs6 and the ftrig tools #include
        # <execline/execline.h> and the build simply stops without it -- and
        # execline is 53 more binaries and 2.1MB we would have to ship and
        # nothing would run: our `run` scripts are plain #!/bin/sh. Turning it
        # off here is what makes "we do not ship execline" true rather than
        # aspirational.
        cd "$OLDPWD/work/.s6-src/s6-$S6_VERSION"
        ./configure --host="$S6_HOST" --prefix="$MODDIR" \
            --with-sysdeps="$SK/lib/skalibs/sysdeps" \
            --with-include="$SK/include" --with-lib="$SK/lib" \
            --disable-execline \
            --disable-shared --enable-static --enable-static-libc >/dev/null
        make -j"$JOBS" >/dev/null
        make install DESTDIR="$STAGE" >/dev/null
    )
    # Take only what we ship, out of the DESTDIR tree at its real prefix.
    mkdir -p "$S6_BUILD/bin" "$S6_BUILD/libexec"
    for b in $S6_BINS; do
        cp -f "work/.s6-stage$MODDIR/bin/$b" "$S6_BUILD/bin/$b"
    done
    for b in $S6_LIBEXEC; do
        cp -f "work/.s6-stage$MODDIR/libexec/$b" "$S6_BUILD/libexec/$b"
    done
    "$PWD/$S6_TOOLCHAIN_DIR/bin/$S6_HOST-strip" "$S6_BUILD/bin"/* "$S6_BUILD/libexec"/*
    rm -rf work/.s6-src work/.s6-sysroot work/.s6-stage
    echo "$S6_STAMP" > "$S6_BUILD/.version"
else
    skip "s6: work/.s6 already holds $S6_STAMP"
fi

# The gates, asked of the built tree rather than of the build. A cross-build
# that silently produced host binaries, or produced a big-endian or 64-bit
# object, looks like a clean build here and like a printer that cannot exec
# its own supervisor there -- the kernel says ENOEXEC and nothing explains
# why. So: every name we promised exists, is not empty, and is an ELF the
# printer's kernel will load.
for b in $S6_BINS $S6_LIBEXEC; do
    case " $S6_LIBEXEC " in *" $b "*) f="$S6_BUILD/libexec/$b" ;; *) f="$S6_BUILD/bin/$b" ;; esac
    [ -s "$f" ] || { echo "   !! s6: $b is missing or empty in $S6_BUILD" >&2; exit 1; }
    hdr=$(readelf -h "$f" 2>/dev/null || true)
    grep -q 'Class:.*ELF32' <<<"$hdr" && grep -q "Machine:.*MIPS" <<<"$hdr" \
        && grep -q "Data:.*little endian" <<<"$hdr" \
        || { echo "   !! s6: $b is not a 32-bit little-endian MIPS ELF" >&2
             readelf -h "$f" 2>&1 | sed 's/^/      /' >&2; exit 1; }
done
say "s6: $(echo $S6_BINS | wc -w) binaries + $S6_LIBEXEC are 32-bit MIPS (LE) -- good"
cp -f "$S6_BUILD/bin"/* "$MOD_PAYLOAD/bin/"
cp -f "$S6_BUILD/libexec"/* "$MOD_PAYLOAD/libexec/"
chmod +x "$MOD_PAYLOAD/bin"/s6-* "$MOD_PAYLOAD/libexec"/*
du -sh "$S6_BUILD/bin"     | awk '{print "   "$1"\tbin/"}'
du -sh "$S6_BUILD/libexec" | awk '{print "   "$1"\tlibexec/"}'

# -------------------------------------------------- 5c. CPython 3.13 (shipped)
# A second Python for the printer, cross-compiled here from the sources pinned
# in versions.env with the SAME Ingenic glibc toolchain that builds c_helper.so
# above. Same shape as s6 in 5b -- pinned tarballs, compiled in place, cached
# on a version stamp, gated on the tree that ships -- and for the same reason:
# nothing binary is vendored, so anything the printer executes is built from a
# hash we pinned.
#
# ############################################################################
# # NOTHING USES THIS INTERPRETER YET, AND THAT IS DELIBERATE.               #
# #                                                                          #
# # payload/anvil-env.sh points FF_PYTHON at /usr/prog/Python-3.8.2/bin/     #
# # python3 and MUST KEEP DOING SO. Moonraker, klippy and bin/ff-startup.py  #
# # need third-party C extensions -- tornado, lmdb, cffi, greenlet, pillow,  #
# # libnacl -- that live in FlashForge's site-packages as mipsel .so files    #
# # built against 3.8. None of them has been cross-built for 3.13. Point     #
# # FF_PYTHON here and the printer loses klippy AND its web UI on the next   #
# # boot, with an ImportError nobody sees because the screen is already dark. #
# #                                                                          #
# # This is exactly how s6 shipped in phase 2: in the payload, started by     #
# # nothing, for one release, so that the switch is later a one-file change   #
# # rather than a build change and a boot change at once. The extensions are  #
# # the next piece of work; until they exist this is 30MB of dead weight that #
# # can be measured on a real printer, which is worth more than 30MB saved.   #
# ############################################################################
#
# WHY IT IS WORTH SHIPPING DEAD. FlashForge built 3.8.2 without _sqlite3, and
# that single omission is what pins MOONRAKER_VERSION to a 2023 commit: every
# Moonraker from v0.9.0 on keeps its database in sqlite. This interpreter has
# a working sqlite3 (measured on the replica, create/insert/select/reopen --
# test/integration/printer/case-python.sh), which is what eventually unpins it.
#
# WHERE IT LANDS. $MODDIR is a --prefix root -- that is the whole reason s6 was
# configured for it, and it is why the mod's tree has bin/, lib/, libexec/ and
# etc/ directly inside it rather than a directory per package. The interpreter
# is configured --prefix=$MODDIR like everything else, so `make install` puts
# bin/python3.13 beside bin/s6-svscan and lib/python3.13/ beside lib/. One
# prefix, one library path, one place to look.
#
# That path is COMPILED IN (sys.prefix, and the stdlib search that follows from
# it), so moving the directory on the printer breaks the interpreter exactly
# the way moving s6 breaks its waiting verbs -- it has to be rebuilt, not
# renamed. Which is also the argument for putting it here and not somewhere
# private: there is only one prefix to keep stable, not two.
#
# WHAT IS DELETED OUT OF bin/ BEFORE STAGING, and why it is not fussiness.
# `make install` also creates bin/python3 -- a symlink to python3.13 -- plus
# idle3, pydoc3 and the *-config scripts. anvil-env.sh PREPENDS $MODDIR/bin to
# PATH (s6-svscan execs s6-supervise by name off PATH, so it has to), so a
# bin/python3 of ours would sit AHEAD of FlashForge's on the PATH of every
# process that sources it. Anything that says `python3` rather than
# "$FF_PYTHON" -- a hand-typed ssh command, a subprocess in someone's
# component, a shebang -- would silently change interpreter. That is the
# accidental version of the switch the box above says must not happen yet, so
# the symlink does not ship. The name python3.13 is unambiguous and nothing on
# this printer answers to it. idle3 and pydoc3 go with it because idlelib and
# the config directory they need are trimmed away anyway.
#
# PY_MM is spelled out rather than derived from PY_VERSION with a sed, because
# it is not a substring of it in any interesting sense: it is the ABI series
# CPython names its own directories and binaries after, and a 3.14 bump has to
# be a deliberate edit of both lines.
PY_MM="3.13"
PY_PREFIX="$MODDIR"
PY_HOST=mips-linux-gnu
PY_TOOLCHAIN_DIR=work/.mips-toolchain/mips-gcc720-glibc229
# The cache key is every version that goes into the tree, not just CPython's:
# a bumped OpenSSL with an unchanged PY_VERSION has to rebuild, and the failure
# if it does not is an interpreter linked against a library nobody can name.
PY_STAMP="$PY_VERSION $OPENSSL_VERSION $SQLITE_VERSION $ZLIB_VERSION $LIBFFI_VERSION $XZ_VERSION $BZIP2_VERSION $EXPAT_VERSION"

if [ "$(cat "$PY_BUILD/.version" 2>/dev/null || true)" != "$PY_STAMP" ]; then
    if [ ! -x "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-gcc" ]; then
        [ -f "${MIPS_TOOLCHAIN_TGZ:-}" ] || {
            echo "   !! python needs (re)building and there is no toolchain:" >&2
            echo "      $MIPS_TOOLCHAIN_TGZ is missing. Run ./bin/fetch-assets.sh." >&2
            exit 1; }
        say "python: unpacking the Ingenic MIPS toolchain"
        mkdir -p work/.mips-toolchain
        tar -xzf "$MIPS_TOOLCHAIN_TGZ" -C work/.mips-toolchain
    fi
    for t in "${PY_TGZ:-}" "${OPENSSL_TGZ:-}" "${SQLITE_TGZ:-}" "${ZLIB_TGZ:-}" \
             "${LIBFFI_TGZ:-}" "${XZ_TGZ:-}" "${BZIP2_TGZ:-}" "${EXPAT_TGZ:-}"; do
        [ -f "$t" ] || { echo "   !! no python sources at '$t' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    done
    command -v gcc >/dev/null || {
        echo "   !! no host gcc. Cross-building CPython needs a build-python of" >&2
        echo "      the SAME version, which is compiled here for x86-64 first." >&2
        echo "      Run through 'make build' -- docker/Dockerfile.build has it." >&2
        exit 1; }
    say "python: cross-compiling CPython $PY_VERSION + 7 libraries for $PY_PREFIX"
    say "        (a few minutes, once -- work/.py313 caches it after that)"
    rm -rf work/.py-src work/.py-dep work/.py-host work/.py-stage work/.py-xw "$PY_BUILD"
    mkdir -p work/.py-src work/.py-dep work/.py-host work/.py-xw/bin
    for t in "$PY_TGZ" "$OPENSSL_TGZ" "$SQLITE_TGZ" "$ZLIB_TGZ" \
             "$LIBFFI_TGZ" "$XZ_TGZ" "$BZIP2_TGZ" "$EXPAT_TGZ"; do
        tar -xzf "$t" -C work/.py-src
    done
    # CPython twice, into two directories. The host build leaves its own
    # Makefile, config.status, pyconfig.h and .o files behind, and a cross
    # ./configure run on top of that inherits host answers -- the resulting
    # interpreter is x86 in places and mipsel in others, and it fails at
    # `make` in a way that reads like a compiler bug. Two trees, no sharing.
    mkdir -p work/.py-src/cross
    tar -xzf "$PY_TGZ" -C work/.py-src/cross
    (
        # A subshell, as in 5b: the cross-compiler's CC/CFLAGS/PATH must not
        # leak into anything patch.sh does afterwards -- and unlike s6 this
        # section also exports LIBS and CONFIG_SITE, which would wreck a later
        # ./configure in ways that are very hard to read.
        set -e
        SRC="$PWD/work/.py-src"
        DEP="$PWD/work/.py-dep"        # cross-built C libraries, STATIC. Not shipped.
        HOSTPY="$PWD/work/.py-host"    # the x86-64 build-python
        STAGE="$PWD/work/.py-stage"    # DESTDIR
        TC="$PWD/$PY_TOOLCHAIN_DIR"
        XW="$PWD/work/.py-xw"
        # Absolute, because everything below runs from inside a source tree.
        # A relative log path here means eight ./configure runs each writing a
        # log into their own directory, which is then deleted with them --
        # i.e. no log at all on the one run where you want one.
        LOG="$PWD/work"
        JOBS=$(nproc 2>/dev/null || echo 4)

        # ---------------------------------------------------------- wrappers
        # THE SINGLE MOST IMPORTANT THING IN THIS SECTION. `-EL -mnan=2008`
        # has to reach the COMPILE and the LINK of every object: this
        # toolchain defaults to big-endian legacy-NaN, and the printer's
        # kernel refuses anything that is not little-endian NAN2008 -- it
        # says ENOEXEC and explains nothing. Passing them in CFLAGS is not
        # enough, because several of the eight projects below do not forward
        # CFLAGS to their link line. So the two flags are baked into the gcc
        # driver itself by a wrapper on PATH, and no build system gets a vote.
        for t in gcc g++ cpp; do
            printf '#!/bin/sh\nexec %s/bin/%s-%s -EL -mnan=2008 "$@"\n' \
                "$TC" "$PY_HOST" "$t" > "$XW/bin/$PY_HOST-$t"
            chmod +x "$XW/bin/$PY_HOST-$t"
        done
        # The binutils have no flags to bake in, so they are plain symlinks --
        # but they must be on the SAME PATH entry, or configure finds the
        # host's ar/ranlib and produces archives the cross-linker cannot read.
        for t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
            ln -sf "$TC/bin/$PY_HOST-$t" "$XW/bin/$PY_HOST-$t"
        done
        export PATH="$XW/bin:$PATH"

        # Gate the wrapper before building 300MB on top of it. A wrapper that
        # silently lost its flags produces a tree that builds perfectly and is
        # ENOEXEC on the printer, and the ship gate below would then be the
        # first thing to notice -- twenty minutes later.
        echo 'int main(void){return 0;}' > "$SRC/abi.c"
        "$PY_HOST-gcc" "$SRC/abi.c" -o "$SRC/abi.out"
        abi=$("$PY_HOST-readelf" -h "$SRC/abi.out" | awk '/Flags:/{print $2}' | tr -d ,)
        [ "$abi" = "0x70001405" ] || {
            echo "   !! the toolchain wrapper produces e_flags=$abi, want 0x70001405" >&2
            exit 1; }

        # ------------------------------------------------- 1. the build-python
        # Cross-building CPython needs a build-python of the SAME version:
        # the Makefile runs it to freeze modules, generate the deepfreeze
        # sources and byte-compile the stdlib, and configure hard-errors when
        # the version does not match. The image's python3.11 cannot stand in.
        # x86-64, thrown away at the end of this section, never shipped.
        ( cd "$SRC/Python-$PY_VERSION"
          ./configure --prefix="$HOSTPY" --without-ensurepip >"$LOG/.py-hostpy.log" 2>&1
          make -j"$JOBS" >>"$LOG/.py-hostpy.log" 2>&1
          make install >>"$LOG/.py-hostpy.log" 2>&1 )

        # ------------------------------------------- 2. the C libraries, STATIC
        # All seven go into $DEP as .a with -fPIC, and NONE of them ships. The
        # interpreter and its extension modules link them in, so the tree on
        # the printer has no .so of ours to find at runtime: no
        # LD_LIBRARY_PATH to get right, no chance of picking up one of
        # FlashForge's /usr/prog copies (which is a real hazard -- /usr/prog
        # carries libffi.so.8 and the rootfs carries libffi.so.7), and nothing
        # to version-skew. The cost is a few MB of duplicated libcrypto
        # between _ssl.so and _hashlib.so, which is a good trade at 30MB.
        export CC="$PY_HOST-gcc" CXX="$PY_HOST-g++"
        export AR="$PY_HOST-ar" RANLIB="$PY_HOST-ranlib" STRIP="$PY_HOST-strip"
        export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64"
        export CPPFLAGS="-I$DEP/include"
        export LDFLAGS="-L$DEP/lib"
        # pkg-config must see ONLY our sysroot. Left alone it answers out of
        # the build image's /usr/lib/pkgconfig, and configure then links an
        # x86-64 .so into a mipsel interpreter -- or, more often, decides a
        # module is buildable and finds out at `make` time that it is not.
        export PKG_CONFIG_LIBDIR="$DEP/lib/pkgconfig"
        export PKG_CONFIG_PATH="$DEP/lib/pkgconfig"
        BUILDTRIPLE=x86_64-linux-gnu

        ( cd "$SRC/zlib-$ZLIB_VERSION"
          CHOST=$PY_HOST ./configure --prefix="$DEP" --static >/dev/null
          make -j"$JOBS" >/dev/null && make install >/dev/null )

        # OpenSSL, and two traps that were both hit for real:
        #  * `no-docs` only exists from 3.1. On 3.0.x it is an "Unsupported
        #    options" HARD ERROR, not a warning -- so it is not passed here.
        #  * the linux-mips32 target hardcodes -mips2 into its cflags, and
        #    this toolchain defaults to -mfp64, which gcc refuses below
        #    mips32r2 ("'-mgp32' and '-mfp64' can only be combined if the
        #    target supports the mfhc1 and mthc1 instructions"). User cflags
        #    land AFTER the target's, so -mips32r2 below puts the ISA back
        #    where the printer actually is. If a future OpenSSL orders them
        #    the other way round, linux-generic32 (portable C, no mips
        #    assembly) is the fallback -- and it is taken automatically rather
        #    than left as a note, because the failure is a wall of assembler
        #    errors that says nothing about ISA levels.
        #  * --openssldir is where the interpreter looks for CA certificates
        #    ON THE PRINTER. Nothing installs any there. `import ssl` works,
        #    but verifying a certificate chain does not until someone ships a
        #    ca-certificates bundle -- see tools/python/README.md.
        ( cd "$SRC/openssl-$OPENSSL_VERSION"
          ossl() { ./Configure "$@" --prefix="$DEP" --libdir=lib \
                       --openssldir="$PY_PREFIX/ssl" no-shared no-tests \
                       -fPIC -O2 -D_FILE_OFFSET_BITS=64 >/dev/null; }
          ossl linux-mips32 -mips32r2
          if ! make -j"$JOBS" >"$LOG/.py-openssl.log" 2>&1; then
              echo "   .. openssl linux-mips32 failed; falling back to linux-generic32"
              make distclean >/dev/null 2>&1 || true
              ossl linux-generic32 no-asm
              make -j"$JOBS" >"$LOG/.py-openssl.log" 2>&1
          fi
          make install_sw >/dev/null )

        for p in "libffi-$LIBFFI_VERSION --disable-docs" \
                 "sqlite-autoconf-$SQLITE_VERSION --disable-readline --disable-editline" \
                 "xz-$XZ_VERSION --disable-xz --disable-xzdec --disable-lzmadec --disable-lzmainfo --disable-scripts --disable-doc --disable-nls" \
                 "expat-$EXPAT_VERSION --without-docbook --without-examples --without-tests"; do
            # Deliberately unquoted: each entry is a directory plus the flags
            # that turn that project's command-line tools and documentation
            # off. We want the library, never the programs.
            # shellcheck disable=SC2086
            set -- $p
            d=$1; shift
            ( cd "$SRC/$d"
              ./configure --host=$PY_HOST --build=$BUILDTRIPLE --prefix="$DEP" \
                  --disable-shared --enable-static --with-pic "$@" >/dev/null
              make -j"$JOBS" >/dev/null && make install >/dev/null )
        done

        # bzip2 has no configure and no install target worth using; drive its
        # Makefile at the one target we want and place the two files by hand.
        ( cd "$SRC/bzip2-$BZIP2_VERSION"
          make -j"$JOBS" libbz2.a CC="$CC" AR="$AR" RANLIB="$RANLIB" \
              CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -Wall -Winline" >/dev/null
          install -m644 libbz2.a "$DEP/lib/"
          install -m644 bzlib.h  "$DEP/include/" )

        # ------------------------------------------------ 3. CPython, cross
        cd "$SRC/cross/Python-$PY_VERSION"
        # Answers to the questions configure settles by COMPILING AND RUNNING
        # a probe, which it cannot do when the target is mipsel and the
        # builder is x86. Left unanswered these either stop configure or --
        # worse -- default to the conservative answer and produce a working
        # interpreter with subtly wrong float and time behaviour.
        cat > "$SRC/config.site" <<'EOF'
ac_cv_file__dev_ptmx=yes
ac_cv_file__dev_ptc=no
ac_cv_buggy_getaddrinfo=no
ac_cv_little_endian_double=yes
ac_cv_big_endian_double=no
ac_cv_mixed_endian_double=no
ac_cv_working_tzset=yes
ac_cv_have_long_long_format=yes
ac_cv_no_strict_aliasing=no
ac_cv_pthread_system_supported=yes
EOF
        export CONFIG_SITE="$SRC/config.site"
        export CFLAGS="-O2 -D_FILE_OFFSET_BITS=64"
        # THE TRAP THAT COSTS A DAY IF YOU MISS IT, and the reason the gate
        # below exists:
        #   -latomic  64-bit atomics on mips32 are out-of-line calls into
        #             libatomic, and CPython 3.13's _Py_atomic_* on 64-bit
        #             types needs them. libatomic.so.1 IS on the printer's
        #             rootfs -- measured -- so this one is a runtime dep, not
        #             a static link.
        #   -lm       because libsqlite3 here is STATIC. A shared libsqlite3.so
        #             carries its own DT_NEEDED on libm; a libsqlite3.a does
        #             not. configure's `checking for sqlite3_bind_double in
        #             -lsqlite3` link probe then fails on undefined floor/log/
        #             pow, and CPython records _sqlite3 as "missing" AND
        #             CARRIES ON -- a probe failure, not a compile failure, so
        #             nothing in 400 lines of build output says why the one
        #             module this whole section exists for is absent.
        export LIBS="-latomic -lm"
        # And the same link line stated outright, bypassing pkg-config, so
        # that -lm cannot be reordered out from under the probe.
        export LIBSQLITE3_CFLAGS="-I$DEP/include"
        export LIBSQLITE3_LIBS="-L$DEP/lib -lsqlite3 -lm"
        # --disable-shared: no libpython3.13.so to find at runtime, for the
        #   same reason the seven libraries above are static. An out-of-tree
        #   extension module was proven to build and import against this.
        # --without-ensurepip: pip needs a network and a compiler; neither is
        #   on a printer, and a pip that half works is worse than none.
        # --disable-test-modules: the CPython test suite is a third of the
        #   tree and none of it runs here.
        ./configure \
            --host=$PY_HOST --build=$BUILDTRIPLE \
            --with-build-python="$HOSTPY/bin/python3.13" \
            --prefix="$PY_PREFIX" \
            --disable-shared \
            --without-ensurepip \
            --disable-test-modules \
            --with-openssl="$DEP" \
            --with-system-expat >"$LOG/.py-configure.log" 2>&1
        make -j"$JOBS" >"$LOG/.py-make.log" 2>&1
        make install DESTDIR="$STAGE" >>"$LOG/.py-make.log" 2>&1
    ) || { echo "   !! the python cross-build failed. The most recently" >&2
           echo "      written of work/.py-hostpy.log, work/.py-openssl.log," >&2
           echo "      work/.py-configure.log and work/.py-make.log is where it" >&2
           echo "      stopped; the source trees under work/.py-src are still" >&2
           echo "      there, config.log included." >&2
           exit 1; }

    # --------------------------------------------------------------- trim
    # 183MB staged, 30MB shipped. What goes: the test package and idlelib
    # (nothing on a printer runs either), tkinter (there is no X11), the
    # config-*/ directory, include/ and lib/pkgconfig (they exist to BUILD
    # extension modules, which happens on a developer's machine and not here
    # -- and lib/pkgconfig would otherwise put four .pc files describing that
    # build into the prefix's SHARED lib/, next to s6's neighbours), every
    # static archive, and every __pycache__ -- which is 12MB of .pyc for
    # modules that will be imported once, if ever, and which the interpreter
    # regenerates into /usr/data anyway if it ever wants them.
    say "python: trimming the staged tree"
    PY_TRIM="work/.py-stage$PY_PREFIX"
    rm -rf "$PY_TRIM/lib/python$PY_MM/test" \
           "$PY_TRIM/lib/python$PY_MM/idlelib" \
           "$PY_TRIM/lib/python$PY_MM/tkinter" \
           "$PY_TRIM/lib/python$PY_MM/turtledemo" \
           "$PY_TRIM/lib/python$PY_MM/config-"* \
           "$PY_TRIM/include" "$PY_TRIM/share" "$PY_TRIM/lib/pkgconfig"
    find "$PY_TRIM" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
    find "$PY_TRIM" -name '*.a' -delete
    # And out of bin/, everything except the one unambiguously-named binary --
    # see the comment at the top of this section. bin/python3 is the one that
    # matters (it would shadow FlashForge's on the PATH anvil-env.sh exports);
    # the rest are launchers for a package the trim above just deleted.
    rm -f "$PY_TRIM/bin/python3" "$PY_TRIM/bin/idle3" "$PY_TRIM/bin/idle$PY_MM" \
          "$PY_TRIM/bin/pydoc3" "$PY_TRIM/bin/pydoc$PY_MM" \
          "$PY_TRIM/bin/python3-config" "$PY_TRIM/bin/python$PY_MM-config"
    "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-strip" "$PY_TRIM/bin/python$PY_MM" 2>/dev/null || true
    find "$PY_TRIM/lib/python$PY_MM/lib-dynload" -name '*.so' \
        -exec "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-strip" {} + 2>/dev/null || true
    # Nothing must be left in bin/ but the interpreter: a future CPython that
    # installs one more launcher would otherwise put an unreviewed name on the
    # PATH of every mod process, which is precisely the accident the rm above
    # is for. Cheap to assert, and it fails at build time rather than on a
    # printer.
    left=$(ls "$PY_TRIM/bin")
    [ "$left" = "python$PY_MM" ] || {
        echo "   !! python: bin/ should hold python$PY_MM and nothing else, got: $left" >&2
        exit 1; }

    # The cache holds bin/ and lib/ -- exactly the shape work/.s6 holds for s6,
    # and for the same reason: unpacking it at $MODDIR puts every file back
    # where it was compiled to live. The .version stamp sits BESIDE them rather
    # than inside, so it can never be mistaken for something that ships.
    mkdir -p "$PY_BUILD"
    cp -a "$PY_TRIM/bin" "$PY_TRIM/lib" "$PY_BUILD/"
    rm -rf work/.py-src work/.py-dep work/.py-host work/.py-stage work/.py-xw
    echo "$PY_STAMP" > "$PY_BUILD/.version"
else
    skip "python: work/.py313 already holds CPython $PY_VERSION"
fi

# The gates, asked of the TREE THAT SHIPS rather than of the build -- so a
# cached tree from an older, wronger build is checked too, and so the answer
# comes from the bytes the printer will execute.
[ -x "$PY_BUILD/bin/python$PY_MM" ] \
    || { echo "   !! python: no bin/python$PY_MM in $PY_BUILD" >&2; exit 1; }
# bin/ holds the interpreter and NOTHING ELSE -- re-asserted here and not only
# at build time, because this runs against the cache as well, and a cache
# built before that rule existed would otherwise stage a bin/python3 that
# shadows FlashForge's on PATH. See the top of this section.
PY_BINS=$(ls "$PY_BUILD/bin")
[ "$PY_BINS" = "python$PY_MM" ] \
    || { echo "   !! python: $PY_BUILD/bin holds '$PY_BINS', expected only python$PY_MM." >&2
         echo "      Delete work/.py313 and rebuild." >&2; exit 1; }
# _sqlite3 is THE reason this section exists, and its absence is silent: see
# the LIBS comment above. A hard failure here, at build time, is the only
# thing standing between a dropped -lm and a release that ships an
# interpreter with the one module it was built for missing.
PY_SQLITE=$(ls "$PY_BUILD/lib/python$PY_MM/lib-dynload/"_sqlite3*.so 2>/dev/null | head -n1)
[ -n "$PY_SQLITE" ] \
    || { echo "   !! python: NO _sqlite3 MODULE. configure's link probe failed" >&2
         echo "      silently -- check LIBS/LIBSQLITE3_LIBS and work/.py-configure.log" >&2
         exit 1; }
# ABI, over every ELF in the tree: interpreter, 56 extension modules and
# whatever else `make install` put there. The printer's kernel wants
# nan2008/o32/mips32r2 and says ENOEXEC to anything else, and a cross-build
# that quietly emitted one host object -- or one legacy-NaN object, because a
# flag did not reach one link line -- looks like a clean build here.
#
# TWO expected words, not one. 0x70001405 is the measured value for an
# EXECUTABLE; a shared object additionally carries EF_MIPS_PIC (0x2) and so
# reads 0x70001407. That is correct and unavoidable for a DYN -- klippy's own
# c_helper.so has it too -- so a gate that pinned one word would fail on every
# extension module in the tree.
PY_ELF=0
while IFS= read -r f; do
    [ "$(head -c 4 "$f" 2>/dev/null)" = "$(printf '\177ELF')" ] || continue
    hdr=$(readelf -h "$f" 2>/dev/null || true)
    case "$hdr" in
        *nan2008*o32*mips32r2*) ;;
        *) echo "   !! python: $f is not nan2008/o32/mips32r2" >&2
           readelf -h "$f" 2>&1 | sed 's/^/      /' >&2; exit 1 ;;
    esac
    flags=$(awk '/Flags:/{print $2}' <<<"$hdr" | tr -d ,)
    want=0x70001405; grep -q '^  Type:.*DYN' <<<"$hdr" && want=0x70001407
    [ "$flags" = "$want" ] || {
        echo "   !! python: $f has e_flags=$flags, want $want" >&2; exit 1; }
    PY_ELF=$((PY_ELF + 1))
done < <(find "$PY_BUILD/bin" "$PY_BUILD/lib" -type f)
say "python: $PY_ELF ELF objects, all nan2008/o32/mips32r2; $(basename "$PY_SQLITE") present"
# Staged into the SAME bin/ and lib/ as everything else in this prefix root,
# which is why this is a copy of the contents and not of the directories: s6's
# binaries are already in $MOD_PAYLOAD/bin and must stay there.
cp -a "$PY_BUILD/bin/." "$MOD_PAYLOAD/bin/"
mkdir -p "$MOD_PAYLOAD/lib"
cp -a "$PY_BUILD/lib/." "$MOD_PAYLOAD/lib/"
chmod +x "$MOD_PAYLOAD/bin/python$PY_MM"
du -sh "$PY_BUILD/lib/python$PY_MM" | awk '{print "   "$1"\tlib/python'"$PY_MM"'/"}'

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
mkdir -p "$MOD_PAYLOAD/init.d"
# The shared environment. Sourced by run-append.sh, firmwareExe, start.sh and
# every init.d script -- one library path and one interpreter for the whole
# mod, because carrying a private copy in each of them is how the installer's
# check and the boot script came to disagree. Not chmod +x: it is sourced.
cp -f payload/anvil-env.sh "$MOD_PAYLOAD/anvil-env.sh"
# The shared service shape. Sourced by every init.d script for svc_say,
# svc_start_daemon, svc_stop_daemon and the start|stop|restart|status block --
# one answer to "is it alive?" and one busybox correction for
# start-stop-daemon, instead of a different one per script. Every converted
# script exits at once if this file is missing, so leaving it out of the
# payload is a printer with no services at all. Not chmod +x: it is sourced.
cp -f payload/anvil-service.sh "$MOD_PAYLOAD/anvil-service.sh"
[ -d payload/bin ] && cp -f payload/bin/* "$MOD_PAYLOAD/bin/" && chmod +x "$MOD_PAYLOAD/bin"/*
cp -f payload/init.d/S* "$MOD_PAYLOAD/init.d/"
chmod +x "$MOD_PAYLOAD/init.d"/S*
# The s6 service directories: one per supervised service, each holding a `run`
# script and whatever s6 control files it needs beside it (`down` to start in
# the down state, `notification-fd` to say which descriptor readiness arrives
# on). cp -a rather than cp -f because those control files are not scripts and
# a plain glob of *.sh would miss them -- and because a `run` that arrives
# without its executable bit is a service s6 can never start, which it reports
# only in its own log. The chmod is belt and braces for exactly that.
if [ -d payload/etc/s6 ]; then
    cp -a payload/etc/s6/. "$MOD_PAYLOAD/etc/s6/"
    chmod +x "$MOD_PAYLOAD"/etc/s6/*/run 2>/dev/null || true
fi
sed -e "s/^MOD_WEB=.*/MOD_WEB=${MOD_WEB:-1}/" \
    -e "s/^MOD_CAM=.*/MOD_CAM=${MOD_CAM:-1}/" \
    -e "s/^MOD_UI=.*/MOD_UI=${MOD_UI:-1}/" \
    -e "s/^MOD_SSH=.*/MOD_SSH=${MOD_SSH:-1}/" \
    -e "s/^MOD_WIFI=.*/MOD_WIFI=${MOD_WIFI:-1}/" \
    payload/anvil.conf > "$MOD_PAYLOAD/anvil.conf"

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
# payload/run-append.sh, which is where that bill came due. A manifest gives
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
