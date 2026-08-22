#!/usr/bin/env bash
# 3/3 -- repack work/software back into an installable USB package.
#
#   ./pack.sh              full package (keeps kernel/control/library)
#   ./pack.sh --slim       software component only (~26MB, fast to write/test)
#   ./pack.sh --plain      no encryption: emits runFirmwareExe.sh + payload
#                          for the /mnt/runFirmwareExe.sh dev path
set -euo pipefail
. "$(dirname "$0")/common.sh"

SLIM=0; PLAIN=0
for a in "$@"; do
    case "$a" in
        --slim)  SLIM=1 ;;
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
    echo ">> compressing mod.tar.xz (Mainsail / HelixScreen / bin)"
    tar -cf - -C work/modpayload . | xz -T0 -6 > work/stage/mod.tar.xz
    ls -lh work/stage/mod.tar.xz | awk '{print "   "$5}'
fi

# FlashForge's own installer, reused verbatim -- it already does the whole
# USB auto-install dance. We only change what it installs.
cp -f work/outer/runFirmwareExe.sh work/stage/
chmod +x work/stage/runFirmwareExe.sh
for f in start.img end.img play; do
    [ -f "work/outer/$f" ] && cp -f "work/outer/$f" work/stage/
done
if [ "$SLIM" = "0" ]; then
    for f in work/outer/kernel-*.tar.xz work/outer/control-*.tar.xz work/outer/library-*.tar.xz; do
        [ -f "$f" ] && cp -f "$f" work/stage/
    done
fi
echo ">> outer payload:"
ls -la work/stage | sed 's/^/   /'

# ---------------------------------------------------------------------------
# 4. emit
# ---------------------------------------------------------------------------
BASE="${MOD_NAME:-mod}-${MOD_VER:-1.0.0}"

if [ "$PLAIN" = "1" ]; then
    # app_startup.sh also honours a bare /mnt/runFirmwareExe.sh -- no crypto,
    # no .tgz. Copy the whole work/out/plain/ tree to the USB root.
    mkdir -p work/out/plain
    cp -a work/stage/. work/out/plain/
    echo
    echo "PLAIN package: work/out/plain/  -> copy its CONTENTS to the USB root"
else
    echo ">> tarring + encrypting"
    # Outer tar is NOT gzipped despite the .tgz name -- unTar pipes the
    # decrypted stream straight into `tar xvf -`.
    tar -cf - -C work/stage . \
        | openssl des3 -salt -md md5 -k "$FF_KEY" \
        > "work/out/Creator5Pro-${BASE}.tgz"

    # The Pro's app_startup.sh globs Creator5Pro-*.tgz, the non-Pro globs
    # Creator5-*.tgz. Ship both names (FlashForge does the same with its
    # factory package -- the two files are byte-identical).
    cp -f "work/out/Creator5Pro-${BASE}.tgz" "work/out/Creator5-${BASE}.tgz"

    echo
    echo "Packages:"
    ls -lh work/out/*.tgz | awk '{print "   "$9"  "$5}'
    echo
    echo "Sanity check (decrypt + list):"
    openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "work/out/Creator5Pro-${BASE}.tgz" 2>/dev/null \
        | tar -tvf - | sed 's/^/   /'
    echo
    echo "Copy BOTH .tgz files to the root of a FAT32 USB stick, plug it in,"
    echo "and power the printer on. It installs and reboots by itself."
    echo "Install log afterwards: /usr/data/mod-install.log"
fi
