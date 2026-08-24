#!/usr/bin/env bash
# 2/3 -- apply the mods to work/software/.
# Idempotent: safe to re-run after editing config.env or assets.
set -euo pipefail
. "$(dirname "$0")/common.sh"

SW=work/software
[ -d "$SW" ] || { echo "run bin/unpack.sh first" >&2; exit 1; }

MARK_BEGIN="# >>> anvil begin >>>"
MARK_END="# <<< anvil end <<<"

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
MP=work/modpayload
rm -rf "$MP" "$SW/mod"   # $SW/mod: leftover from an older layout
mkdir -p "$MP/bin" "$MP/nginx" "$MP/www" "$MP/config"

# ---------------------------------------------------------------- 1. Klipper
if [ "${BUILD_KLIPPER:-fork}" = "fork" ] && [ -d "${KLIPPER_FORK:-}/klippy" ]; then
    say "Klipper: installing fork tree from $KLIPPER_FORK"
    # Stock ships only a handful of klippy files as an overlay; the fork is a
    # different Klipper generation (v0.13 vs v0.12), so ship the WHOLE tree.
    rm -rf "$SW/klipper/klippy"
    mkdir -p "$SW/klipper/klippy"
    ( cd "$KLIPPER_FORK/klippy" && tar -cf - \
        --exclude='__pycache__' --exclude='*.pyc' --exclude='chelper/*.o' . ) \
      | tar -xf - -C "$SW/klipper/klippy"

    # c_helper.so must be MIPS32r2 / nan2008 / o32 or klippy dies on import.
    CH="$KLIPPER_FORK/klippy/chelper/c_helper.so"
    if [ -f "$CH" ]; then
        # Only the ABI is checked here. A symbol-level check against the
        # klippy tree beside it used to run too, because cffi resolves symbols
        # lazily and a .so older than its sources installs, boots and then
        # dies at connect. That check is gone; if klippy ever fails at connect
        # with a cffi traceback, a stale c_helper.so is the first thing to
        # suspect and rebuilding it is the fix.
        if readelf -h "$CH" 2>/dev/null | grep -q nan2008; then
            say "Klipper: c_helper.so is nan2008 MIPS32r2 -- good"
            mkdir -p work/.chelper/chelper
            cp -f "$CH" work/.chelper/chelper/c_helper.so
            tar -cf "$SW/klipper/chelper.tar" -C work/.chelper chelper
            rm -rf work/.chelper
        else
            echo "   !! c_helper.so is NOT nan2008 -- the kernel will refuse it" >&2
            exit 1
        fi
    else
        echo "   !! no c_helper.so in the fork; see README 'Rebuilding chelper'" >&2
        exit 1
    fi
    # klippy/ now contains the fork's own extras+kinematics, so the stock
    # overlay dirs would only re-inject 0.12-era files on top. Drop them.
    rm -rf "$SW/klipper/extras" "$SW/klipper/kinematics"
    mkdir -p "$SW/klipper/extras"
else
    skip "Klipper: keeping stock tree"
fi

# ----------------------------------------------------------- 2. Toolchanger
# Lives in this repo under payload/klipper/ -- it used to be the separate
# creator5-toolchange checkout, pointed at by TOOLCHANGE= in config.env.
if [ "${BUILD_TOOLCHANGE:-1}" = "1" ]; then
    say "Toolchange: ff_*.py + configs"
    mkdir -p "$SW/klipper/extras"
    cp -f payload/klipper/extras/ff_*.py "$SW/klipper/extras/"
    # .cfg files belong on the data partition. These are mod-owned: run.sh
    # overwrites them on every update (test_config_ownership.py enforces it).
    # User changes go in printer.cfg, which no flash ever writes.
    cp -f payload/klipper/config/ff-*.cfg "$MP/config/"
    # Our printer.base.cfg is FlashForge's with the chamber block replaced by
    # [include printer.chamber.cfg] -- Klipper can override an option but
    # cannot un-declare a section, and the plain Creator 5 has no chamber
    # heating element, so its heater has to be absent rather than neutralised.
    # NOTE: this cp is why the stock-drift check lives in bin/unpack.sh and
    # not in a test -- it overwrites the pristine copy, and the test that used
    # to read it afterwards was comparing our file against itself.
    cp -f payload/klipper/config/printer.base.cfg "$SW/klipper/config/printer.base.cfg"

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
            printer.*) dest="$SW/klipper/config/$base" ;;
            *)         dest="$MP/config/$base" ;;
        esac
        cp -f "$variant" "$dest"
        say "Model: $base for $TARGET_MACHINE"
    done
    # printer.base.cfg includes it unconditionally, so without it klippy will
    # not start at all. A broken build, not a silent default.
    [ -f "$SW/klipper/config/printer.chamber.cfg" ] \
        || { echo "no printer.chamber.cfg.$SUFFIX for TARGET_MACHINE=$TARGET_MACHINE" >&2; exit 1; }
else
    skip "Toolchange"
fi

# -------------------------------------------------------------- 3. Mainsail
if [ "${BUILD_MAINSAIL:-1}" = "1" ]; then
    # The profile asked for Mainsail, so a missing file is a broken build, not
    # a reason to ship a package with an empty web root. bin/fetch-assets.sh
    # should have put it here.
    [ -f "${MAINSAIL_ZIP:-}" ] || { echo "BUILD_MAINSAIL=1 but no Mainsail zip at '${MAINSAIL_ZIP:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "Mainsail: unpacking $(basename "$MAINSAIL_ZIP")"
    mkdir -p "$MP/www/mainsail"
    unzip -q -o "$MAINSAIL_ZIP" -d "$MP/www/mainsail"
    cp -f assets/nginx.conf "$MP/nginx/nginx.conf"
    du -sh "$MP/www/mainsail" | awk '{print "   "$1}'
else
    skip "Mainsail"
fi
[ -f assets/moonraker.conf ] && cp -f assets/moonraker.conf "$MP/config/moonraker.conf"

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
# WHAT IS AND IS NOT REPLACED. Only the python package tree
# (moonraker/moonraker/moonraker/) is swapped. The interpreter, the
# moonraker-env virtualenv beside it and moonrakerDaemon are all left alone,
# because the pinned build runs on what the printer already has:
#
#   tornado 6.1, jinja2 3.1.2, distro 1.5.0, libnacl 1.7.2,
#   streaming-form-data 1.8.1, inotify-simple 1.3.5, importlib_metadata 5.1.0,
#   dbus-next 0.2.3, lmdb 1.3.0
#
# -- verified by booting it against exactly those versions on python 3.8,
# started the way moonrakerDaemon starts it (moonraker/moonraker.py -d), with
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
# So it travels with the rest of the payload and run-append.sh puts it in
# place, which also lets that step swap the tree atomically and roll back.
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
    rm -rf "$MP/moonraker"
    cp -a work/.moonraker/moonraker "$MP/moonraker"
    # The gate run-append.sh puts in front of the swap. It reads Moonraker's
    # own component list out of the tree beside it, so it does not need
    # updating when the pin moves.
    cp -f payload/moonraker-preflight.py "$MP/moonraker-preflight.py"
    # Tests never run on the printer and are a sizeable chunk of the tree.
    rm -rf "$MP/moonraker/tests"
    find "$MP/moonraker" -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
    rm -rf work/.moonraker
    du -sh "$MP/moonraker" | awk '{print "   "$1}'
else
    skip "Moonraker: keeping the stock 2022 build"
fi

# ----------------------------------------------------------- 5. HelixScreen
if [ "${BUILD_HELIX:-1}" = "1" ]; then
    [ -f "${HELIX_TGZ:-}" ] || { echo "BUILD_HELIX=1 but no HelixScreen tarball at '${HELIX_TGZ:-}' -- run ./bin/fetch-assets.sh" >&2; exit 1; }
    say "HelixScreen: unpacking $(basename "$HELIX_TGZ")"
    mkdir -p "$MP/helixscreen"
    tar -xzf "$HELIX_TGZ" -C "$MP" # yields mod/helixscreen/
    # Printer-database entry so it detects the Creator 5 Pro as a tool changer
    mkdir -p "$MP/helixscreen/config/printer_database.d"
    cp -f payload/helixscreen/printer_database.d/*.json \
          "$MP/helixscreen/config/printer_database.d/"
    # Optional platform hook. No such file is in the repo, so this never fires
    # on a stock checkout -- drop one in assets/ to have it shipped.
    [ -f assets/hooks-creator5.sh ] && \
        cp -f assets/hooks-creator5.sh "$MP/helixscreen/assets/config/platform/"
    du -sh "$MP/helixscreen" | awk '{print "   "$1}'
else
    skip "HelixScreen"
fi

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
    cp -f "$BUSYBOX_BIN" "$MP/bin/busybox"; chmod +x "$MP/bin/busybox"
fi

# --------------------------------------------------------- 7. root password
if [ -n "${ROOT_PW_HASH:-}" ]; then
    say "Accounts: setting root password hash"
    # /etc is a bind mount of /usr/prog/etc (app_startup.sh), and this file is
    # what dropbear reads at authentication time -- so this is the live shadow
    # even though dropbear started earlier from the read-only squashfs.
    # /etc is a bind mount of /usr/prog/etc, so this file IS the live shadow.
    awk -v h="$ROOT_PW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
        "$SW/shadow" > "$SW/shadow.new" && mv -f "$SW/shadow.new" "$SW/shadow"
else
    skip "root password (set ROOT_PW_HASH)"
fi

# ------------------------------------------------ 8. start.sh (web stack on)
say "start.sh: enabling nginx + moonraker"
cp -f payload/start.sh "$SW/start.sh"
chmod +x "$SW/start.sh"

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
cp -f payload/firmwareExe "$SW/firmwareExe"
chmod +x "$SW/firmwareExe"

# ----------------------------------------------------- 10. mod service dir
mkdir -p "$MP/init.d"
[ -d payload/bin ] && cp -f payload/bin/* "$MP/bin/" && chmod +x "$MP/bin"/*
cp -f payload/init.d/S* "$MP/init.d/"
chmod +x "$MP/init.d"/S*
sed -e "s/^MOD_WEB=.*/MOD_WEB=${MOD_WEB:-1}/" \
    -e "s/^MOD_CAM=.*/MOD_CAM=${MOD_CAM:-1}/" \
    -e "s/^MOD_UI=.*/MOD_UI=${MOD_UI:-1}/" \
    -e "s/^MOD_SSH=.*/MOD_SSH=${MOD_SSH:-1}/" \
    -e "s/^MOD_WIFI=.*/MOD_WIFI=${MOD_WIFI:-1}/" \
    payload/anvil.conf > "$MP/anvil.conf"

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
python3 - "$SW/run.sh" payload/run-pre.sh "$POST" <<'PY'
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
chmod +x "$SW/run.sh"
rm -f "$POST"

echo
echo "Patched."
echo "  software component: $(du -sh "$SW" | cut -f1)  (-> /usr/prog, firmware partition)"
echo "  mod payload:        $(du -sh "$MP" | cut -f1)  (-> /usr/data/anvil, data partition)"
echo "Now run ./bin/pack.sh"
