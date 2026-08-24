#!/usr/bin/env bash
# 3/3 -- repack work/software back into an installable USB package.
#
#   ./pack.sh              software component only (DEFAULT, ~28MB)
#   ./pack.sh --full       also carry kernel / control / library
#   ./pack.sh --plain      no encryption: emits runFirmwareExe.sh + payload
#                          for the /mnt/runFirmwareExe.sh dev path
#
# Slim is the default because the stock installer skips any component that is
# absent: every update_<name> guards on `ls -1t <name>-*.tar.xz` and returns
# early when it fails. So shipping only the component we actually modified
# leaves the kernel, the rootfs image and the MCU/board firmware completely
# untouched -- MCU flashing is the riskiest thing in the package and there is
# no reason to run it to install a userspace mod.
#
# (start.img, end.img and play are still shipped: runFirmwareExe.sh uses those
# unconditionally.)
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

[ -d work/software ] || { echo "run ./unpack.sh first" >&2; exit 1; }
STOCK_SW_VER=$(cat work/.stock_sw_ver)
OUT_VER="${SW_VER:-$STOCK_SW_VER}"

rm -rf work/stage work/out
mkdir -p work/stage work/out

# ---------------------------------------------------------------------------
# 1. md5sum.list -- the installer hard-gates on this. Paths must be "./rel",
#    and the list must not contain itself.
# ---------------------------------------------------------------------------
echo ">> regenerating md5sum.list"
( cd work/software
  rm -f md5sum.list
  find . -type f ! -name md5sum.list -print0 \
      | sort -z \
      | xargs -0 md5sum > md5sum.list
  echo "   $(wc -l < md5sum.list) entries" )

# ---------------------------------------------------------------------------
# 2. software-<ver>.tar.xz
#
#    !! NOT actually xz-compressed. FlashForge's own components are PLAIN
#    tar archives that merely carry a .tar.xz name -- verify with
#    `file work/outer/software-*.tar.xz`. The stock installer extracts them
#    with a bare `tar -xvf`, so a genuinely xz-compressed file here does not
#    install. Keep this a plain tar.
# ---------------------------------------------------------------------------
echo ">> building software-$OUT_VER.tar.xz (plain tar, matching stock)"
tar -cf "work/stage/software-$OUT_VER.tar.xz" -C work/software .
ls -lh "work/stage/software-$OUT_VER.tar.xz" | awk '{print "   "$5}'

# ---------------------------------------------------------------------------
# 3. the rest of the outer package
# ---------------------------------------------------------------------------
# The mod payload: rides in the outer package so it lands on /usr/data,
# not on the firmware partition.
if [ -d work/modpayload ]; then
    # This one IS really xz: we extract it ourselves with `xz -dc`, and
    # FlashForge's factory installer proves xz exists on the printer.
    echo ">> compressing anvil.tar.xz (Mainsail / HelixScreen / bin)"
    tar -cf - -C work/modpayload . | xz -T0 -6 > work/stage/anvil.tar.xz
    ls -lh work/stage/anvil.tar.xz | awk '{print "   "$5}'
fi

# FlashForge's own installer, reused verbatim -- it already does the whole
# USB auto-install dance. We only change what it installs.
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

# ---------------------------------------------------------------------------
# 4. emit
# ---------------------------------------------------------------------------
# MOD_VER is the release date; common.sh defaults it to today (UTC).
BASE="${MOD_NAME:-anvil}-${MOD_VER:?}"

if [ "$PLAIN" = "1" ]; then
    # app_startup.sh also honours a bare /mnt/runFirmwareExe.sh -- no crypto,
    # no .tgz. Copy the whole work/out/plain/ tree to the USB root.
    mkdir -p work/out/plain
    cp -a work/stage/. work/out/plain/
    echo
    echo "PLAIN package: work/out/plain/  -> copy its CONTENTS to the USB root"
else
    # Name the output after the model the package is actually for. The two
    # models ship DIFFERENT firmwareExe binaries, so emitting both filenames
    # from one build (as an earlier version did) would hand the wrong
    # firmware to one of them. Each model must be built from its own stock
    # package.
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
    # decrypted stream straight into `tar xvf -`.
    # The Pro's app_startup.sh globs /mnt/Creator5Pro-*.tgz and the non-Pro
    # globs /mnt/Creator5-*.tgz, so the filename prefix must match the model.
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
