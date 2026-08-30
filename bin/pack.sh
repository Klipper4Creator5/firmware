#!/usr/bin/env bash
# 3/3 -- repack work/software into an installable USB package.
#   ./bin/pack.sh [--full|--plain]    default is slim: software component only
#
# Slim works because the stock installer skips any absent component -- every
# update_<name> guards on `ls -1t <name>-*.tar.xz` -- so the kernel, rootfs and
# MCU firmware are left untouched. start.img, end.img and play still ship:
# runFirmwareExe.sh uses them unconditionally.
set -euo pipefail
. "$(dirname "$0")/common.sh"

SLIM=1; PLAIN=0
for a in "$@"; do
    case "$a" in
        --full)  SLIM=0 ;;
        --slim)  SLIM=1 ;;   # accepted for compatibility; now the default
        --plain) PLAIN=1 ;;
        *) echo "unknown option: $a" >&2; exit 1 ;;
    esac
done

[ -d work/software ] || { echo "run ./bin/unpack.sh first" >&2; exit 1; }
STOCK_SW_VER=$(cat work/.stock_sw_ver)
OUT_VER="${SW_VER:-$STOCK_SW_VER}"

rm -rf work/stage work/out
mkdir -p work/stage work/out

# A baked-in default would be the same password on every printer, so an empty
# ROOT_PW_HASH means the installer picks a random one ON the machine and writes
# it to the USB stick. Baked into runFirmwareExe.sh below.
if [ -z "${ROOT_PW_HASH:-}" ]; then
    PW_AUTO=1
else
    PW_AUTO=0
fi

# --- 1. md5sum.list -- the installer hard-gates on it. Paths must be "./rel",
#     and the list must not contain itself.
echo ">> regenerating md5sum.list"
( cd work/software
  rm -f md5sum.list
  find . -type f ! -name md5sum.list -print0 \
      | sort -z \
      | xargs -0 md5sum > md5sum.list
  echo "   $(wc -l < md5sum.list) entries" )

# --- 2. software-<ver>.tar.xz, NOT actually xz. FlashForge's own components
#     are plain tars carrying a .tar.xz name and the installer runs a bare
#     `tar -xvf`, so a real xz file does not install.
echo ">> building software-$OUT_VER.tar.xz (plain tar, matching stock)"
tar -cf "work/stage/software-$OUT_VER.tar.xz" -C work/software .
ls -lh "work/stage/software-$OUT_VER.tar.xz" | awk '{print "   "$5}'

# --- 3. the rest of the outer package
#
# Which model this package installs on. Resolved HERE rather than at emit time
# because two things need it now: the gate baked into our installer, and the
# output filename app_startup.sh globs for. They must agree -- a file named for
# one model carrying a gate for the other installs on neither.
PKG_MACHINE=$(cat work/.pkg_machine 2>/dev/null || echo "")
PKG_PID=$(cat work/.pkg_pid 2>/dev/null || echo "")
[ "$PKG_MACHINE" = unknown ] && PKG_MACHINE=""
[ "$PKG_PID" = unknown ] && PKG_PID=""
if [ -n "$PKG_MACHINE" ] && [ "$PKG_MACHINE" != "${TARGET_MACHINE:-$PKG_MACHINE}" ]; then
    echo "MODEL MISMATCH: stock package is for '$PKG_MACHINE', TARGET_MACHINE='$TARGET_MACHINE'" >&2
    echo "  point STOCK_TGZ_$(echo "$TARGET_MACHINE" | tr a-z A-Z) at a $TARGET_MACHINE package" >&2
    exit 1
fi
OUT_MACHINE="${PKG_MACHINE:-${TARGET_MACHINE:-Creator5Pro}}"
OUT_PID="${PKG_PID:-${TARGET_PID:-0029}}"

# The payload rides here so it lands on /usr/data, not the firmware partition.
if [ -d "$PAYLOAD_DIR" ]; then
    # This one IS really xz: we extract it ourselves with `xz -dc`.
    echo ">> compressing anvil.tar.xz (Mainsail / HelixScreen / Moonraker / bin)"
    tar -cf - -C "$PAYLOAD_DIR" . | xz -T0 -6 > work/stage/anvil.tar.xz
    ls -lh work/stage/anvil.tar.xz | awk '{print "   "$5}'
fi

# OUR installer, not FlashForge's. app_startup.sh runs whatever it finds under
# this name, so owning the name is all it takes to own the install -- see the
# header of installer/runFirmwareExe.sh for the contract and the exit codes.
#
# Three lines are rewritten rather than being config the script reads: it runs
# on a printer with nothing beside it but the package it came in, so the gate
# and the password mode have to be IN it. The `^NAME=` shape is what
# bin/unpack.sh and tools/replica/printer/entrypoint.sh read back.
echo ">> generating runFirmwareExe.sh ($OUT_MACHINE/$OUT_PID, pw-auto=$PW_AUTO)"
sed -e "s/^MACHINE=.*/MACHINE=$OUT_MACHINE/" \
    -e "s/^PID=.*/PID=$OUT_PID/" \
    -e "s/^MOD_PW_AUTO=.*/MOD_PW_AUTO=$PW_AUTO/" \
    installer/runFirmwareExe.sh > work/stage/runFirmwareExe.sh
chmod +x work/stage/runFirmwareExe.sh
# The substitutions are not optional: a package whose gate still says
# Creator5Pro because a sed missed would install on the wrong machine.
for _want in "MACHINE=$OUT_MACHINE" "PID=$OUT_PID" "MOD_PW_AUTO=$PW_AUTO"; do
    grep -qx "$_want" work/stage/runFirmwareExe.sh || {
        echo "runFirmwareExe.sh has no '$_want' line -- the sed above missed" >&2
        exit 1; }
done
for f in start.img end.img play; do
    [ -f "work/outer/$f" ] && cp -f "work/outer/$f" work/stage/
done
if [ "$SLIM" = "0" ]; then
    echo ">> --full: also carrying kernel / control / library"
    echo "   (this reflashes the kernel and the MCU/board firmware)"
    for f in work/outer/kernel-*.tar.xz work/outer/control-*.tar.xz work/outer/library-*.tar.xz; do
        [ -f "$f" ] && cp -f "$f" work/stage/
    done
else
    echo ">> slim: software component only -- kernel, rootfs and MCU untouched"
fi
echo ">> outer payload:"
ls -la work/stage | sed 's/^/   /'

# --- 4. emit
BASE="${MOD_NAME:-anvil}-${MOD_VER:?}"

if [ "$PLAIN" = "1" ]; then
    # app_startup.sh also honours a bare /mnt/runFirmwareExe.sh: copy this
    # whole tree to the USB root.
    mkdir -p work/out/plain
    cp -a work/stage/. work/out/plain/
    echo
    echo "PLAIN package: work/out/plain/  -> copy its CONTENTS to the USB root"
else
    echo ">> tarring + encrypting"
    # Outer tar is NOT gzipped despite the .tgz name -- unTar pipes the
    # decrypted stream into `tar xvf -`. The prefix must match the model:
    # app_startup.sh globs /mnt/Creator5Pro-*.tgz.
    OUTFILE="work/out/${OUT_MACHINE}-${BASE}.tgz"
    tar -cf - -C work/stage . \
        | openssl des3 -salt -md md5 -k "$FF_KEY" > "$OUTFILE"

    echo
    echo "Package:"
    ls -lh "$OUTFILE" | awk '{print "   "$9"  "$5}'
    echo "   installs on: $OUT_MACHINE only"
    echo
    echo "Sanity check (decrypt + list):"
    openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$OUTFILE" 2>/dev/null \
        | tar -tvf - | sed 's/^/   /'
    echo
    echo "Copy it to the root of a FAT32 USB stick, plug it in, power on."
    echo "Install log afterwards: /usr/data/anvil-install.log"
fi
