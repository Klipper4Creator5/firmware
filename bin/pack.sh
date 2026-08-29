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
# The payload rides here so it lands on /usr/data, not the firmware partition.
if [ -d "$PAYLOAD_DIR" ]; then
    # This one IS really xz: we extract it ourselves with `xz -dc`.
    echo ">> compressing anvil.tar.xz (Mainsail / HelixScreen / Moonraker / bin)"
    tar -cf - -C "$PAYLOAD_DIR" . | xz -T0 -6 > work/stage/anvil.tar.xz
    ls -lh work/stage/anvil.tar.xz | awk '{print "   "$5}'
fi

# FlashForge's own installer, reused verbatim; only what it installs changes.
cp -f work/outer/runFirmwareExe.sh work/stage/
chmod +x work/stage/runFirmwareExe.sh
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
    # The two models ship DIFFERENT firmwareExe binaries.
    PKG_MACHINE=$(cat work/.pkg_machine 2>/dev/null || echo "")
    if [ "$PKG_MACHINE" = unknown ]; then PKG_MACHINE=""; fi
    if [ -n "$PKG_MACHINE" ] && [ "$PKG_MACHINE" != "${TARGET_MACHINE:-$PKG_MACHINE}" ]; then
        echo "MODEL MISMATCH: stock package is for '$PKG_MACHINE', TARGET_MACHINE='$TARGET_MACHINE'" >&2
        echo "  point STOCK_TGZ_$(echo "$TARGET_MACHINE" | tr a-z A-Z) at a $TARGET_MACHINE package" >&2
        exit 1
    fi
    OUT_MACHINE="${PKG_MACHINE:-${TARGET_MACHINE:-Creator5Pro}}"

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
