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

# ABI, over every ELF this build cross-compiles: s6 in 5b below, the
# interpreter and its extensions in 5c, libsodium in 5d. The printer's kernel
# wants nan2008/o32/mips32r2 and says ENOEXEC to anything else, and a
# cross-build that quietly emitted one host object -- or one legacy-NaN
# object, because a flag did not reach one link line -- looks like a clean
# build here. Defined once, up here, because 5b needs it before 5c exists to
# borrow it from.
#
# TWO expected words, not one. 0x70001405 is the measured value for an
# EXECUTABLE; a shared object additionally carries EF_MIPS_PIC (0x2) and so
# reads 0x70001407. That is correct and unavoidable for a DYN -- klippy's own
# c_helper.so has it too -- so a gate that pinned one word would fail on every
# extension module in the tree. s6's own binaries are static EXECs, so they
# want 0x70001405 like the interpreter does.
#
# A FUNCTION, AND POINTED AT THE PAYLOAD. It used to walk $PY_BUILD/bin and
# $PY_BUILD/lib -- the build cache. That was the whole tree while the
# interpreter was the only thing this toolchain produced, and it stopped being
# so the moment site-packages and libsodium arrived: a .so staged into
# $MOD_PAYLOAD by a path the gate did not know about ships ungated, and the
# first machine to notice is a printer. So the rule did not change (it already
# covers a DYN correctly) -- the REACH did, to the staged payload, which is
# the only tree that is by definition everything that ships.
#
# s6 is IN this gate now, not exempt from it. It used to be built by a plain
# mips32r1 musl toolchain and read e_flags=0x1007 (mips1, legacy NaN) -- a
# choice defended here as "no floating point, so the NaN encoding cannot
# matter" for exactly as long as nobody checked what the printer's own kernel
# does with that flag at exec() rather than at runtime. It matters at exec():
# a MIPS kernel built nan2008-only can refuse to run a legacy-NaN binary
# outright, or silently misconfigure its FPU mode, neither of which shows up
# under qemu-mipsel-static -- user-mode emulation does not enforce the same
# ABI check a real kernel's binfmt loader does, which is exactly how s6
# shipped in this state and every replica gate still passed. Section 5b now
# cross-builds with Bootlin's mips32r5el-musl toolchain, whose crt/libc
# objects are nan2008 by construction (mips32r5 has no legacy-NaN silicon to
# be compatible with), restricted to mips32r2 codegen with the same
# gcc-wrapper discipline 5c uses -- so s6 gets exactly the ABI everything else
# on this printer already had to have, checked the same way.
mips_abi_gate() {
    local n=0 f hdr flags want
    while IFS= read -r f; do
        # readelf itself is the ELF test, rather than comparing the first four
        # bytes to \177ELF: that comparison was a command substitution over
        # arbitrary binary content, and every data file in site-packages that
        # happens to start with a NUL made bash print "warning: command
        # substitution: ignored null byte in input" -- eight lines of noise
        # across a clean build, from the gate that is supposed to be the quiet
        # one. readelf exits non-zero on anything that is not an ELF, which is
        # the same question asked of the tool that has to answer it anyway.
        hdr=$(readelf -h "$f" 2>/dev/null) || continue
        case "$hdr" in
            *nan2008*o32*mips32r2*) ;;
            *) echo "   !! $f is not nan2008/o32/mips32r2" >&2
               readelf -h "$f" 2>&1 | sed 's/^/      /' >&2; return 1 ;;
        esac
        # 0x70001405 or 0x70001407, not "whichever the Type says": that was
        # true of the Ingenic-glibc objects alone, where EF_MIPS_PIC only
        # ever showed up on a genuine DYN. s6's musl toolchain bakes
        # EF_MIPS_PIC into its crt startup objects unconditionally -- no
        # combination of -static/-no-pie/-fno-PIC removes it, measured -- so
        # a plain static EXEC from that toolchain carries the bit too and
        # still reads 0x70001407. Both values already mean the same thing
        # (nan2008/o32/mips32r2, matched above); which one shows up is a
        # property of the toolchain, not a sign of anything wrong.
        flags=$(awk '/Flags:/{print $2}' <<<"$hdr" | tr -d ,)
        case "$flags" in
            0x70001405|0x70001407) ;;
            *) echo "   !! $f has e_flags=$flags, want 0x70001405 or 0x70001407" >&2
               return 1 ;;
        esac
        n=$((n + 1))
    done < <(find "$@" -type f 2>/dev/null)
    printf '%s' "$n"
}

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
S6_HOST=mipsel-buildroot-linux-musl
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
# MUSL_TOOLCHAIN_FILE is IN the stamp, not just the two source versions: the
# toolchain that builds s6 determines its ABI as much as the sources do, and
# work/.s6/.version has no other way to notice that the pin moved from a
# legacy-NaN toolchain to a nan2008 one. Without this, a checkout that had
# already built s6 once would read its old e_flags=0x1007 tree as current
# and never rebuild it -- exactly the failure mode that shipped once.
S6_STAMP="$SKALIBS_VERSION $S6_VERSION $MUSL_TOOLCHAIN_FILE"

if [ "$(cat "$S6_BUILD/.version" 2>/dev/null || true)" != "$S6_STAMP" ]; then
    if [ ! -x "$S6_TOOLCHAIN_DIR/bin/$S6_HOST-gcc" ]; then
        [ -f "${MUSL_TOOLCHAIN_TGZ:-}" ] || {
            echo "   !! s6 needs (re)building and there is no musl toolchain:" >&2
            echo "      $MUSL_TOOLCHAIN_TGZ is missing. Run ./bin/fetch-assets.sh." >&2
            exit 1; }
        say "s6: unpacking the musl mipsel toolchain"
        rm -rf work/.musl-toolchain
        mkdir -p work/.musl-toolchain
        # -xf, not -xzf: Bootlin ships this .tar.xz, not musl.cc's .tar.gz --
        # tar picks the decompressor off the file itself either way.
        tar -xf "$MUSL_TOOLCHAIN_TGZ" -C work/.musl-toolchain
        # Bootlin's archive extracts into a directory named after the
        # release ("mips32r5el--musl--stable-2025.08-1"), not the fixed
        # "$S6_HOST-cross" musl.cc used. It is the only thing the archive
        # unpacks at top level, so renaming whatever that turns out to be is
        # what decouples S6_TOOLCHAIN_DIR from a version string that moves on
        # every release.
        set -- work/.musl-toolchain/*/
        [ -d "$1" ] || { echo "   !! musl toolchain archive unpacked no directory" >&2; exit 1; }
        mv "$1" "$S6_TOOLCHAIN_DIR"
    fi
    for t in "${SKALIBS_TGZ:-}" "${S6_TGZ:-}"; do
        [ -f "$t" ] || { echo "   !! no s6 sources at '$t' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    done
    say "s6: cross-compiling skalibs $SKALIBS_VERSION + s6 $S6_VERSION for $MODDIR"
    rm -rf work/.s6-src work/.s6-sysroot work/.s6-stage work/.s6-xw "$S6_BUILD"
    mkdir -p work/.s6-src work/.s6-xw/bin
    tar -xzf "$SKALIBS_TGZ" -C work/.s6-src
    tar -xzf "$S6_TGZ" -C work/.s6-src
    (
        # A subshell so the cross-compiler's CC/CFLAGS/PATH cannot leak into
        # anything patch.sh does afterwards.
        set -e
        TC="$PWD/$S6_TOOLCHAIN_DIR"
        XW="$PWD/work/.s6-xw"
        SRC="$PWD/work/.s6-src"

        # ---------------------------------------------------------- wrappers
        # THE SAME DISCIPLINE 5c USES FOR THE INGENIC TOOLCHAIN, and for the
        # same reason: passing -EL -mnan=2008 -march=mips32r2 in CFLAGS alone
        # is not enough, because skalibs' and s6's own ./configure-generated
        # link lines do not all forward CFLAGS to the link step. Baking the
        # flags into the gcc driver itself means no build system gets a vote.
        #
        # -EL is redundant on a toolchain whose triple already says mipsel --
        # kept anyway, for the same reason the Ingenic wrapper keeps it on a
        # toolchain that is genuinely bi-endian: explicit beats "the default
        # happens to be right", and it costs nothing to write.
        #
        # This is Bootlin's mips32r5el toolchain, not mips32el: mips32r5 has
        # no legacy-NaN silicon to be compatible with, so its musl crt/libc
        # objects are nan2008 by construction and a plain mips32el-legacy
        # toolchain (which this repo used until the printer's kernel turned
        # out to enforce the ABI flag at exec() -- ENOEXEC or a silently
        # wrong FPU mode, neither of which qemu-mipsel-static's user-mode
        # emulation reproduces) cannot be made to emit nan2008 output at all:
        # forcing -mnan=2008 on it fails to LINK, "mixing -mnan=2008 module
        # with previous -mnan=legacy modules", because its own crt is legacy.
        # -march=mips32r2 restricts codegen to what the actual silicon
        # implements; nothing here should assume r5 or r6 instructions exist.
        for t in gcc g++ cpp; do
            printf '#!/bin/sh\nexec %s/bin/%s-%s -EL -mnan=2008 -march=mips32r2 "$@"\n' \
                "$TC" "$S6_HOST" "$t" > "$XW/bin/$S6_HOST-$t"
            chmod +x "$XW/bin/$S6_HOST-$t"
        done
        for t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
            ln -sf "$TC/bin/$S6_HOST-$t" "$XW/bin/$S6_HOST-$t"
        done
        export PATH="$XW/bin:$PATH"
        export CC="$S6_HOST-gcc"

        # Gate the wrapper before building anything on top of it, exactly as
        # 5c does -- and with -static, because that is how skalibs and s6
        # actually link. want is 0x70001405 OR 0x70001407 (mips_abi_gate,
        # defined above, explains why a static EXEC from this toolchain
        # legitimately carries EF_MIPS_PIC and reads the DYN value anyway).
        echo 'int main(void){return 0;}' > "$SRC/abi.c"
        "$S6_HOST-gcc" -static "$SRC/abi.c" -o "$SRC/abi.out"
        abi=$("$S6_HOST-readelf" -h "$SRC/abi.out" | awk '/Flags:/{print $2}' | tr -d ,)
        case "$abi" in
            0x70001405|0x70001407) ;;
            *) echo "   !! the s6 toolchain wrapper produces e_flags=$abi, want 0x70001405 or 0x70001407" >&2
               exit 1 ;;
        esac

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
        cd "$SRC/skalibs-$SKALIBS_VERSION"
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
        cd "$SRC/s6-$S6_VERSION"
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
    rm -rf work/.s6-src work/.s6-sysroot work/.s6-stage work/.s6-xw
    echo "$S6_STAMP" > "$S6_BUILD/.version"
else
    skip "s6: work/.s6 already holds $S6_STAMP"
fi

# The gate, asked of the built tree rather than of the build, and the SAME
# gate 5c and 5d use -- s6 is no longer exempt from it (see mips_abi_gate's
# own comment, above, for why it used to be and no longer is). A cross-build
# that silently produced a host object, or one legacy-NaN object because a
# flag did not reach one link line, looks like a clean build here and like a
# printer that cannot exec its own supervisor there -- the kernel says
# ENOEXEC, or worse, execs it with the wrong FPU mode, and explains neither.
S6_ELF=$(mips_abi_gate "$S6_BUILD/bin" "$S6_BUILD/libexec") || exit 1
[ "$S6_ELF" = "$(($(echo $S6_BINS | wc -w) + 1))" ] || {
    echo "   !! s6: expected $(($(echo $S6_BINS | wc -w) + 1)) gated ELF objects, mips_abi_gate saw $S6_ELF" >&2
    exit 1; }
for b in $S6_BINS $S6_LIBEXEC; do
    case " $S6_LIBEXEC " in *" $b "*) f="$S6_BUILD/libexec/$b" ;; *) f="$S6_BUILD/bin/$b" ;; esac
    [ -s "$f" ] || { echo "   !! s6: $b is missing or empty in $S6_BUILD" >&2; exit 1; }
done
say "s6: $S6_ELF ELF objects are nan2008/o32/mips32r2 -- good"
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
# # FF_PYTHON POINTS HERE NOW. payload/anvil-env.sh names this interpreter    #
# # for Moonraker, ff-startup.py, ffscreen.py and ff_mcu_bringup.py. Every    #
# # third-party C extension those need -- tornado, lmdb, cffi, greenlet,     #
# # libnacl -- is cross-built into $MODDIR/lib/python3.13/site-packages by    #
# # step 4 below, and Moonraker has been measured SERVING on this            #
# # interpreter through the real boot path on the replica                    #
# # (test/integration/printer/case-moonraker313-s6.sh): S40s6's scandir,     #
# # S62moonraker, readiness gating on :7125 actually listening, a kill -9    #
# # respawn, and a stop that stays stopped.                                  #
# #                                                                          #
# # klippy is NOT among FF_PYTHON's callers and does not run on this         #
# # interpreter -- it is started separately, by FlashForge's own             #
# # /usr/prog/klipper/start.sh, hardcoded to 3.8.2 (see init.d/S70klipper).  #
# # klippy's numpy gap is therefore a separate, smaller item, not a          #
# # precondition of this switch.                                            #
# ############################################################################
#
# WHY IT IS WORTH SHIPPING. FlashForge built 3.8.2 without _sqlite3, and
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
# The SECOND cache key, for the third-party packages that go into this
# interpreter's site-packages (step 4 below): every sdist file name and hash
# from versions.env, as bin/common.sh assembles it.
#
# TWO STAMPS, ONE CACHE DIRECTORY, AND A REBUILD OF EVERYTHING IF EITHER
# MOVES. That is not sloppiness, it is the shape of the dependency. Building a
# package for this target needs three things that exist ONLY while this
# section is mid-flight: the untrimmed staged tree (the trim below deletes
# include/ and lib/python3.13/config-3.13-*, and INCLUDEPY points at the
# first), the static C libraries in work/.py-dep (pillow links zlib, cffi
# links libffi), and the x86-64 build-python that answers every sysconfig
# question for mipsel. Caching those separately means caching a second
# ~200MB tree and a second interpreter for the sake of a package bump, which
# buys a faster rare path by making the common path bigger. So a package pin
# that moves rebuilds CPython too: minutes, on a bump that happens rarely and
# deliberately, against a cache that is otherwise never touched.
PYPKG_STAMP="$(pypkg_stamp)"

if [ "$(cat "$PY_BUILD/.version" 2>/dev/null || true)" != "$PY_STAMP" ] \
   || [ "$(cat "$PY_BUILD/.pkg-version" 2>/dev/null || true)" != "$PYPKG_STAMP" ]; then
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
    # And the package sdists, checked here rather than in step 4 -- twenty
    # minutes into a CPython build is the wrong place to discover that
    # vendor/ is one tarball short, and the fix is the same one command.
    for p in $PYPKG_LIST $PYPKG_HOST_LIST; do
        t="$(pypkg_tgz "$p")"
        [ -f "$t" ] || { echo "   !! no sdist for $p at '$t' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
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
        #
        # --with-ensurepip=install, where the CROSS build below has
        # --without-ensurepip and must keep it. The two are not in tension:
        # they are opposite answers to opposite questions. On the printer a
        # pip would need a network and a compiler and has neither. HERE, pip
        # is what builds the third-party packages in step 4 -- and it comes
        # out of THIS tarball, whose sha256 is pinned, rather than off
        # bootstrap.pypa.io the way the spike got it. That is the difference
        # between a build machine that downloads and runs an unpinned
        # get-pip.py and one that does not talk to anybody: everything below
        # this line runs with --no-index against files bin/fetch-assets.sh
        # already checked.
        ( cd "$SRC/Python-$PY_VERSION"
          ./configure --prefix="$HOSTPY" --with-ensurepip=install >"$LOG/.py-hostpy.log" 2>&1
          make -j"$JOBS" >>"$LOG/.py-hostpy.log" 2>&1
          make install >>"$LOG/.py-hostpy.log" 2>&1 )
        # zlib, asserted rather than assumed, because CPython's answer to a
        # missing library is to record the module as absent and CARRY ON --
        # the same silence that hides a missing _sqlite3 in the cross build
        # below, here on the host side. Every wheel is a zip and so is pip:
        # ensurepip installs it out of a bundled .whl, and without zlib that
        # fails with "can't decompress data" INSIDE a make install that
        # reports success. The symptom then arrives three steps later as "No
        # module named pip", nowhere near the cause. zlib1g-dev in
        # docker/Dockerfile.build is the fix, and this is the sentence that
        # says so.
        "$HOSTPY/bin/python$PY_MM" -c 'import zlib' 2>/dev/null || {
            echo "   !! the build-python has no zlib module, so it cannot unpack" >&2
            echo "      a single wheel. Install zlib1g-dev in the build image" >&2
            echo "      (docker/Dockerfile.build has it) and delete work/.py313." >&2
            exit 1; }
        # And pip itself, which --with-ensurepip=install above was for. Asked
        # here and not in step 4 because `make install` runs ensurepip in a
        # shell fragment that does not stop the install when it fails: without
        # this line a broken bootstrap is reported by the FIRST PACKAGE to try
        # to build, twenty lines of C library later.
        "$HOSTPY/bin/python$PY_MM" -m pip --version >>"$LOG/.py-hostpy.log" 2>&1 || {
            echo "   !! the build-python has no pip, so nothing in step 4 can" >&2
            echo "      be built. ensurepip failed inside 'make install' --" >&2
            echo "      its traceback is in work/.py-hostpy.log." >&2
            exit 1; }

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

    # ------------------------------------------- 4. the third-party packages
    # What runs ON the interpreter: the 18 sdists pinned in versions.env,
    # cross-built into the staged tree's own lib/python3.13/site-packages.
    #
    # WHY IT IS HERE, INSIDE 5c, RATHER THAN IN A SECTION OF ITS OWN. Because
    # of what it needs, all of which exists only at this exact moment:
    #
    #   * the UNTRIMMED stage. INCLUDEPY is $PY_PREFIX/include/python3.13 and
    #     every C extension compiles against it -- and the trim thirty lines
    #     below deletes include/ and lib/python3.13/config-3.13-* precisely
    #     because nothing on a PRINTER builds extension modules.
    #   * work/.py-dep, the static -fPIC C libraries. pillow links zlib out of
    #     it and cffi links libffi, and it is deleted with the rest of the
    #     scratch trees at the end of this section.
    #   * work/.py-host, the x86-64 build-python of the SAME 3.13.7. It is the
    #     thing that makes the cross work at all (see below), and it is also
    #     thrown away here.
    #
    # The alternative -- cache a second, untrimmed tree so the packages can be
    # built later and separately -- was considered and declined: it means
    # keeping ~200MB and a second interpreter warm to make a rare path faster,
    # and it means two caches that can disagree about which interpreter the
    # extension modules were compiled against. That disagreement is not
    # theoretical: an .so built against 3.13 headers and loaded by a 3.14
    # interpreter is an import-time crash on the printer and nowhere else.
    # One cache, two stamps, everything rebuilt together (see PYPKG_STAMP).
    #
    # THE CROSS TRICK, and there is no crossenv in it. The staged interpreter
    # carries _sysconfigdata__linux_mipsel-linux-gnu.py, which records the
    # cross CC, LDSHARED, EXT_SUFFIX (.cpython-313-mipsel-linux-gnu.so) and
    # INCLUDEPY for the TARGET. Point _PYTHON_SYSCONFIGDATA_NAME at it from an
    # x86-64 CPython of the same version and sysconfig -- and therefore
    # setuptools' build_ext -- answers every question about mipsel while
    # running on x86-64. The one thing the spike needed a container for was
    # making INCLUDEPY resolve: it bind-mounted the stage at /usr/data/anvil.
    # There is no daemon to ask for that here (the build lane deliberately has
    # no docker socket), so instead a COPY of that module is written with
    # every $PY_PREFIX path rewritten to where the stage actually is. It goes
    # first on PYTHONPATH, is read only by the build, and never ships.
    #
    # NOTHING HERE TALKS TO A NETWORK. pip runs with --no-index against the
    # sdists bin/fetch-assets.sh already checked the sha256 of, which is the
    # strong form of the rule that --no-binary :all: below is the weak form
    # of: pip cannot download a wheel it cannot reach. Both are kept, because
    # the day someone adds an index URL for one awkward package the second one
    # is what stops three x86-64 .so files from sailing into the tree -- which
    # is not a hypothetical, it is what happened on the spike's first run.
    say "python: cross-building $(echo $PYPKG_LIST | wc -w) third-party packages"
    (
        set -e
        DEP="$PWD/work/.py-dep"
        STAGE="$PWD/work/.py-stage"
        XW="$PWD/work/.py-xw"
        LOG="$PWD/work"
        HOSTPY="$PWD/work/.py-host/bin/python$PY_MM"
        PKGSRC="$PWD/work/.py-pkgsrc"      # unpacked sdists
        WHEELS="$PWD/work/.py-wheels"      # the wheels they produce
        XSYS="$PWD/work/.py-xsysconfig"    # the rewritten sysconfigdata
        TREE="$STAGE$PY_PREFIX"            # the untrimmed staged interpreter
        SP="$TREE/lib/python$PY_MM/site-packages"
        SYSCFG=_sysconfigdata__linux_mipsel-linux-gnu
        rm -rf "$PKGSRC" "$WHEELS" "$XSYS"
        mkdir -p "$PKGSRC" "$WHEELS" "$XSYS" "$SP"
        # The same gcc wrappers step 3 built, still on disk: -EL -mnan=2008
        # baked into the driver so that setuptools -- which does NOT forward
        # CFLAGS to its link lines -- cannot lose them on the way to ld.
        export PATH="$XW/bin:$PATH"

        # -------------------------------------------------- the PEP 517 side
        # Three backends into the build-python: setuptools (most of the list),
        # flit_core (jinja2) and poetry_core (libnacl). All three sdists
        # bootstrap themselves through backend-path, so this needs nothing
        # that is not already in vendor/, and --no-index proves it.
        #
        # Every failure in this subshell is caught BY HAND, with an explicit
        # `|| { ...; exit 1; }`, and the `set -e` at the top is not what is
        # doing the work: a compound command on the left of `||` -- which is
        # what this whole subshell is -- runs with errexit suppressed
        # THROUGHOUT, so a bare failing command in here would be shrugged off
        # and the build would carry on to produce a tree with one package
        # quietly missing from it.
        for p in setuptools $PYPKG_HOST_LIST; do
            "$HOSTPY" -m pip install --quiet --no-index --no-cache-dir \
                --no-build-isolation --no-deps "$PWD/vendor/$(pypkg_var "$p" FILE)" \
                >>"$LOG/.py-pkg-backends.log" 2>&1 \
                || { echo "   !! could not install the build backend $p --" \
                          "work/.py-pkg-backends.log" >&2
                     tail -15 "$LOG/.py-pkg-backends.log" | sed 's/^/      /' >&2
                     exit 1; }
        done

        # ------------------------------------------- sysconfig, for the TARGET
        # The rewrite described above. It is a blanket substitution of
        # $PY_PREFIX for the staging path over every string value rather than
        # a list of the variables that matter, because the list of variables
        # that matter is exactly the thing nobody gets right by hand:
        # INCLUDEPY is the one that fails loudly, LIBDIR and LIBPL fail
        # quietly, and a future setuptools is free to ask for another.
        "$HOSTPY" - "$TREE/lib/python$PY_MM/$SYSCFG.py" "$XSYS/$SYSCFG.py" \
                    "$PY_PREFIX" "$TREE" <<'PYEOF' || exit 1
import sys
src, dst, prefix, stage = sys.argv[1:5]
ns = {}
exec(compile(open(src).read(), src, "exec"), ns)
out = {k: (v.replace(prefix, stage) if isinstance(v, str) else v)
       for k, v in ns["build_time_vars"].items()}
with open(dst, "w") as fh:
    fh.write("# Generated by bin/patch.sh: %s with the build-time prefix\n"
             "# rewritten to the staging tree. Build-time only; never ships.\n"
             "build_time_vars = %r\n" % (src, out))
PYEOF
        [ -s "$XSYS/$SYSCFG.py" ] || {
            echo "   !! could not rewrite $SYSCFG for the staging tree" >&2; exit 1; }
        export _PYTHON_SYSCONFIGDATA_NAME="$SYSCFG"
        # ONLY the rewritten module -- deliberately NOT the target's stdlib as
        # well, which is what the spike put here. They are the same 3.13.7, so
        # it did no harm, but it also means the host interpreter importing
        # the TARGET's os.py and sysconfig.py by accident is one path-ordering
        # mistake away, and the only thing that has to be importable is this.
        export PYTHONPATH="$XSYS"
        export PYTHONDONTWRITEBYTECODE=1
        export PIP_DISABLE_PIP_VERSION_CHECK=1
        export CC="$PY_HOST-gcc" CXX="$PY_HOST-g++"
        export AR="$PY_HOST-ar" RANLIB="$PY_HOST-ranlib" STRIP="$PY_HOST-strip"
        export LDSHARED="$PY_HOST-gcc -shared -L$DEP/lib"
        export CFLAGS="-O2 -fPIC -D_FILE_OFFSET_BITS=64 -I$DEP/include -I$TREE/include/python$PY_MM"
        export CXXFLAGS="$CFLAGS"
        export LDFLAGS="-L$DEP/lib"
        # pkg-config must see ONLY our sysroot, for the same reason as step 2:
        # left alone it answers out of the build image's /usr/lib/pkgconfig and
        # a package links an x86-64 library into a mipsel extension module.
        export PKG_CONFIG_LIBDIR="$DEP/lib/pkgconfig"
        export PKG_CONFIG_PATH="$DEP/lib/pkgconfig"

        # Gate the trick before building 18 packages on top of it. If
        # _PYTHON_SYSCONFIGDATA_NAME has not taken, every question sysconfig
        # is asked below is answered for x86-64 -- and the answer is a tree of
        # host objects that builds perfectly and imports nowhere.
        "$HOSTPY" - "$TREE/include/python$PY_MM" <<'PYEOF' || exit 1
import sys, sysconfig
suffix = sysconfig.get_config_var("EXT_SUFFIX")
inc = sysconfig.get_config_var("INCLUDEPY")
print("   sysconfig answers for %s, headers %s"
      % (suffix, "found" if __import__("os").path.isdir(inc) else "MISSING"))
if suffix != ".cpython-313-mipsel-linux-gnu.so":
    raise SystemExit("   !! sysconfig is answering for the HOST (EXT_SUFFIX=%s)"
                     " -- _PYTHON_SYSCONFIGDATA_NAME did not take" % suffix)
if inc != sys.argv[1]:
    raise SystemExit("   !! INCLUDEPY is %s, expected the staged %s"
                     % (inc, sys.argv[1]))
PYEOF

        # ------------------------------------------------------- the helpers
        # pywheel <sdist-path> [env=val ...] -- build one wheel into $WHEELS.
        #
        # --no-binary :all: is not caution and not decoration; see the top of
        # this step and versions.env. --no-build-isolation is what keeps
        # _PYTHON_SYSCONFIGDATA_NAME reaching setup.py: with isolation ON pip
        # rewrites PYTHONPATH for the build subprocess and the module above
        # stops being importable.
        pywheel() {
            local what=$1; shift
            env "$@" "$HOSTPY" -m pip wheel --no-deps --no-build-isolation \
                --no-index --no-binary :all: --no-cache-dir \
                -w "$WHEELS" "$what" >"$LOG/.py-pkg-$(basename "$what").log" 2>&1 \
                || { echo "   !! $(basename "$what") failed to build --" \
                          "work/.py-pkg-$(basename "$what").log" >&2
                     tail -25 "$LOG/.py-pkg-$(basename "$what").log" | sed 's/^/      /' >&2
                     exit 1; }
        }
        # unpack <list-entry> -- untar its sdist and echo the source directory.
        # Every one of these tarballs unpacks to its own basename; a release
        # that did not would fail on the [ -d ] rather than build the wrong
        # tree.
        unpack() {
            local f d
            f="$(pypkg_var "$1" FILE)"
            d="$PKGSRC/${f%.tar.gz}"
            tar -xzf "$PWD/vendor/$f" -C "$PKGSRC"
            [ -d "$d" ] || { echo "   !! $f does not unpack to $(basename "$d")" >&2; exit 1; }
            printf '%s' "$d"
        }

        # ------------------------------------------------------- the packages
        # PYPKG_LIST is the order, so the order lives in versions.env beside
        # the pins. Four entries need more than "wheel the sdist", and each
        # `case` arm says why.
        for p in $PYPKG_LIST; do
            SDIST="$PWD/vendor/$(pypkg_var "$p" FILE)"
            case "$p" in
            preprocess-cancellation)
                # NOT BUILT: copied. This sdist declares no [build-system] and
                # ships no setup.py, so there is no backend to call -- pip's
                # legacy fallback would auto-discover a flat layout and emit a
                # wheel named UNKNOWN-0.0.0 containing the one module, which
                # is the right file arrived at by an accident that a future
                # setuptools is free to change. The package IS one module, so
                # the honest operation is a copy. Moonraker imports it in the
                # metadata SUBPROCESS (gcode object cancellation), lazily, so
                # a printer without it loses that feature and nothing else.
                d=$(unpack "$p")
                cp -f "$d/preprocess_cancellation.py" "$SP/"
                ;;
            greenlet)
                # gcc 7.2 refuses greenlet 3.x's C++ designated initializers
                # ("sorry, unimplemented: non-trivial designated initializers
                # not supported") wherever they skip a field. The rule was
                # probed, not assumed: in-order contiguous is fine, a TRAILING
                # gap is fine, an interior or leading gap is refused.
                # fill-designators.py writes the skipped fields back as
                # explicit zeros, taking field order from the target's own
                # headers and refusing to guess about a designator that is not
                # in them. These are objects of static storage duration, so
                # every field it inserts was already zero: it changes the
                # spelling, not the program. 55 fields across two files.
                d=$(unpack "$p")
                # Deliberately unquoted: the find is a LIST of sources to
                # patch, one argument each, and none of greenlet's file names
                # has ever contained a space.
                # shellcheck disable=SC2046
                "$HOSTPY" tools/python-packages/fill-designators.py \
                    "$TREE/include/python$PY_MM" \
                    $(find "$d/src/greenlet" -name '*.cpp' -o -name '*.hpp' | sort) \
                    >"$LOG/.py-pkg-greenlet-designators.log" 2>&1 \
                    || { echo "   !! fill-designators.py failed --" \
                              "work/.py-pkg-greenlet-designators.log" >&2
                         tail -20 "$LOG/.py-pkg-greenlet-designators.log" | sed 's/^/      /' >&2
                         exit 1; }
                pywheel "$d"
                ;;
            lmdb)
                # LMDB_FORCE_CPYTHON=1 is load-bearing. lmdb's setup.py has two
                # backends: a real CPython extension and a cffi one that ships
                # mdb.c and COMPILES IT AT IMPORT TIME. Left to itself here it
                # picks cffi and produces a py3-none-any wheel with mdb.c
                # inside -- i.e. a Moonraker that tries to invoke a compiler on
                # a printer that has none. (Do not "fix" this with
                # LMDB_FORCE_CFFI=0: setup.py tests the variable for PRESENCE,
                # so the string "0" selects cffi.)
                pywheel "$SDIST" LMDB_FORCE_CPYTHON=1
                ;;
            pillow)
                # ZLIB ONLY, and pip cannot drive it: the --disable-* flags are
                # build_ext options and PEP 517 offers no way to pass them, so
                # setup.py is called directly. Gcode thumbnails are base64 PNG,
                # so zlib is the only codec on that path; jpeg, tiff, webp,
                # jpeg2000, lcms, freetype and imagequant are libraries nobody
                # has cross-built here, and pillow probes for them by trying to
                # LINK against the HOST's copies unless told not to -- which is
                # what --disable-platform-guessing is for.
                d=$(unpack "$p")
                ( cd "$d" && "$HOSTPY" setup.py build_ext \
                    --disable-jpeg --disable-tiff --disable-webp --disable-jpeg2000 \
                    --disable-imagequant --disable-lcms --disable-freetype \
                    --disable-xcb --disable-platform-guessing --enable-zlib \
                    -I"$DEP/include" -L"$DEP/lib" bdist_wheel ) \
                    >"$LOG/.py-pkg-pillow.log" 2>&1 \
                    || { echo "   !! pillow failed to build -- work/.py-pkg-pillow.log" >&2
                         tail -25 "$LOG/.py-pkg-pillow.log" | sed 's/^/      /' >&2
                         exit 1; }
                cp -a "$d"/dist/*.whl "$WHEELS/" \
                    || { echo "   !! pillow built no wheel -- work/.py-pkg-pillow.log" >&2
                         exit 1; }
                ;;
            *)
                pywheel "$SDIST"
                ;;
            esac
            printf '   %-24s %s\n' "$p" "$(pypkg_var "$p" FILE)"
        done

        # ----------------------------------------------------- into the tree
        # Unzipped rather than pip-installed, because `pip install` insists on
        # installing FOR the interpreter running it -- and that one is x86-64.
        # A wheel is a zip whose layout is already the layout of
        # site-packages, so unzipping it is the whole of what an install does
        # here.
        #
        # .dist-info goes: nothing on the printer resolves a dependency, asks
        # for a version or runs an entry point, and it is 200KB of metadata
        # describing a build machine to nobody. The .data directories and the
        # scripts in them go for a stronger reason -- their console-script
        # shebangs name the BUILD-PYTHON's path, so shipping them would put
        # files on the printer that reference /home/somebody/work/.py-host.
        for w in "$WHEELS"/*.whl; do
            "$HOSTPY" -m zipfile -e "$w" "$SP" \
                || { echo "   !! could not unpack $(basename "$w") into site-packages" >&2
                     exit 1; }
        done
        find "$SP" -name '__pycache__' -prune -exec rm -rf {} + 2>/dev/null || true
        find "$SP" -maxdepth 1 -name '*.dist-info' -prune -exec rm -rf {} + 2>/dev/null || true
        rm -rf "${SP:?}"/bin "${SP:?}"/*.data
        # Stripped here rather than in the trim below, because the trim's
        # find only knows about lib-dynload -- and these are the .so files
        # that are NOT stdlib. 12 of them, ~1.5MB of symbols.
        find "$SP" -name '*.so' -exec "$PY_HOST-strip" {} + 2>/dev/null || true
    ) || { echo "   !! the third-party package build failed. Its logs are" >&2
           echo "      work/.py-pkg-*.log, one per package, and the unpacked" >&2
           echo "      sources are still in work/.py-pkgsrc." >&2
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
    #
    # site-packages rides along inside lib/python$PY_MM/ and needs no line of
    # its own here, which is the whole reason step 4 installs into the staged
    # tree rather than somewhere beside it: one copy, one cache, one tarball
    # for the replica gates (test/ffsim/gates.py packs bin/ + lib/ out of this
    # directory), and the ABI gate below already walks all of it.
    mkdir -p "$PY_BUILD"
    cp -a "$PY_TRIM/bin" "$PY_TRIM/lib" "$PY_BUILD/"
    rm -rf work/.py-src work/.py-dep work/.py-host work/.py-stage work/.py-xw \
           work/.py-pkgsrc work/.py-wheels work/.py-xsysconfig
    echo "$PY_STAMP" > "$PY_BUILD/.version"
    # Written LAST and separately, so that an interrupted build leaves a cache
    # that is stale rather than one that lies: both files have to be right
    # before the next run is allowed to skip this section.
    printf '%s\n' "$PYPKG_STAMP" > "$PY_BUILD/.pkg-version"
else
    skip "python: work/.py313 already holds CPython $PY_VERSION and its packages"
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
# And the packages, asked of the cache for the same reason: this runs whether
# step 4 built them a minute ago or a previous build did. Two claims, because
# they fail differently. A site-packages with no EXTENSION MODULES in it is a
# build where every native package quietly fell back to something pure or was
# skipped -- it imports on the build host and loses lmdb, cffi and greenlet on
# the printer. A site-packages missing a NAMED package is a list that changed
# without anyone noticing; the three named here are the three whose absence
# takes Moonraker or klippy down completely rather than costing a feature.
PY_SP="$PY_BUILD/lib/python$PY_MM/site-packages"
for m in lmdb tornado cffi; do
    [ -e "$PY_SP/$m" ] || [ -e "$PY_SP/$m.py" ] \
        || { echo "   !! python: no '$m' in site-packages -- the package build" >&2
             echo "      did not produce it. Delete work/.py313 and rebuild." >&2
             exit 1; }
done
PY_EXT=$(find "$PY_SP" -name '*.so' | wc -l)
[ "$PY_EXT" -ge 12 ] \
    || { echo "   !! python: only $PY_EXT extension modules in site-packages," >&2
         echo "      expected at least 12. A native package fell back to a" >&2
         echo "      pure-python or py3-none-any build; check work/.py-pkg-*.log." >&2
         exit 1; }

# Staged into the SAME bin/ and lib/ as everything else in this prefix root,
# which is why this is a copy of the contents and not of the directories: s6's
# binaries are already in $MOD_PAYLOAD/bin and must stay there.
cp -a "$PY_BUILD/bin/." "$MOD_PAYLOAD/bin/"
mkdir -p "$MOD_PAYLOAD/lib"
cp -a "$PY_BUILD/lib/." "$MOD_PAYLOAD/lib/"
chmod +x "$MOD_PAYLOAD/bin/python$PY_MM"
PY_ELF=$(mips_abi_gate "$MOD_PAYLOAD/bin/python$PY_MM" "$MOD_PAYLOAD/lib/python$PY_MM") || exit 1
say "python: $PY_ELF ELF objects staged, all nan2008/o32/mips32r2;" \
    "$(basename "$PY_SQLITE") present; $PY_EXT extension modules in site-packages"
du -sh "$PY_BUILD/lib/python$PY_MM" | awk '{print "   "$1"\tlib/python'"$PY_MM"'/"}'
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
# CACHED ON THE VERSION, like s6 and unlike c_helper.so. 24 seconds is not the
# reason -- the reason is bin/fetch-assets.sh: an uncached build of this drags
# the ~203MB Ingenic toolchain download along behind it on every build of a
# checkout that has nothing else to compile. The stamp is what lets the
# fetcher skip it, so the stamp is what makes it free.
SODIUM_XW=work/.sodium-xw
if [ "$(cat "$SODIUM_BUILD/.version" 2>/dev/null || true)" != "$SODIUM_VERSION" ]; then
    if [ ! -x "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-gcc" ]; then
        [ -f "${MIPS_TOOLCHAIN_TGZ:-}" ] || {
            echo "   !! libsodium needs (re)building and there is no toolchain:" >&2
            echo "      $MIPS_TOOLCHAIN_TGZ is missing. Run ./bin/fetch-assets.sh." >&2
            exit 1; }
        say "libsodium: unpacking the Ingenic MIPS toolchain"
        mkdir -p work/.mips-toolchain
        tar -xzf "$MIPS_TOOLCHAIN_TGZ" -C work/.mips-toolchain
    fi
    [ -f "${SODIUM_TGZ:-}" ] || {
        echo "   !! no libsodium source at '$SODIUM_TGZ' -- run ./bin/fetch-assets.sh" >&2
        exit 1; }
    say "libsodium: cross-compiling $SODIUM_VERSION for $MODDIR/lib"
    rm -rf work/.sodium-src work/.sodium-stage "$SODIUM_XW" "$SODIUM_BUILD"
    mkdir -p work/.sodium-src "$SODIUM_XW/bin"
    tar -xzf "$SODIUM_TGZ" -C work/.sodium-src
    (
        set -e
        # A subshell, as in 5b and 5c, so the cross-compiler cannot leak.
        TC="$PWD/$PY_TOOLCHAIN_DIR"
        XW="$PWD/$SODIUM_XW"
        STAGE="$PWD/work/.sodium-stage"
        LOG="$PWD/work"
        # The same wrapper trick, rebuilt here rather than shared with 5c:
        # 5c deletes work/.py-xw when its build succeeds, and this step has to
        # work on a run where 5c did nothing at all because its cache was
        # warm. -EL -mnan=2008 in the driver, where libsodium's libtool link
        # lines cannot drop them.
        for t in gcc g++ cpp; do
            printf '#!/bin/sh\nexec %s/bin/%s-%s -EL -mnan=2008 "$@"\n' \
                "$TC" "$PY_HOST" "$t" > "$XW/bin/$PY_HOST-$t"
            chmod +x "$XW/bin/$PY_HOST-$t"
        done
        for t in ar as ld nm objcopy objdump ranlib readelf strip strings size; do
            ln -sf "$TC/bin/$PY_HOST-$t" "$XW/bin/$PY_HOST-$t"
        done
        export PATH="$XW/bin:$PATH"
        cd "$PWD/work/.sodium-src/libsodium-$SODIUM_VERSION"
        # --disable-static: nothing links this statically and a .a would only
        #   be deleted again below.
        # --host is what makes autoconf reach for the mips-linux-gnu- prefixed
        #   tools in the wrapper directory, which is the entire point of them.
        # libsodium's runtime feature probes are AC_RUN_IFELSE with cross
        #   defaults supplied, so nothing here needs qemu.
        ./configure --host="$PY_HOST" --prefix="$MODDIR" \
            --disable-static --enable-shared --with-pic \
            CFLAGS="-O2 -fPIC" >"$LOG/.sodium-configure.log" 2>&1
        make -j"$(nproc 2>/dev/null || echo 4)" >"$LOG/.sodium-make.log" 2>&1
        make install DESTDIR="$STAGE" >>"$LOG/.sodium-make.log" 2>&1
    ) || { echo "   !! the libsodium cross-build failed -- work/.sodium-configure.log" >&2
           echo "      and work/.sodium-make.log; the source tree is still in" >&2
           echo "      work/.sodium-src." >&2
           exit 1; }
    # lib/ ONLY. include/ and lib/pkgconfig exist to BUILD against libsodium,
    # which happens on a developer's machine and not on a printer -- and
    # pkgconfig would otherwise drop a .pc file describing this build into the
    # prefix's shared lib/, next to the interpreter's stdlib. The .la file goes
    # for the same reason plus one more: it names absolute build-machine paths.
    mkdir -p "$SODIUM_BUILD/lib"
    cp -a "work/.sodium-stage$MODDIR/lib/"libsodium.so* "$SODIUM_BUILD/lib/"
    rm -f "$SODIUM_BUILD/lib/"*.la
    find "$SODIUM_BUILD/lib" -type f -name 'libsodium.so*' \
        -exec "$PY_TOOLCHAIN_DIR/bin/$PY_HOST-strip" --strip-unneeded {} +
    rm -rf work/.sodium-src work/.sodium-stage "$SODIUM_XW"
    echo "$SODIUM_VERSION" > "$SODIUM_BUILD/.version"
else
    skip "libsodium: work/.sodium already holds $SODIUM_VERSION"
fi

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
    -e "s/^NICE_MOONRAKER=.*/NICE_MOONRAKER=${NICE_MOONRAKER:-5}/" \
    -e "s/^NICE_CAM=.*/NICE_CAM=${NICE_CAM:-10}/" \
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
