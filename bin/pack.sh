#!/usr/bin/env bash
# 3/3 -- build the installable USB package.
#   ./bin/pack.sh [--full|--plain]    default is slim: our installer + payload
#
# SLIM SHIPS NO FLASHFORGE COMPONENT AT ALL -- not the kernel, not the rootfs,
# not the MCU firmware, and since we own the installer, not the 26MB software
# component either. Two files do the work:
#
#     runFirmwareExe.sh   ours; app_startup.sh runs it, and it IS the install
#     anvil.tar.xz        the payload, everything under $MODDIR
#
# plus start.img, end.img and play, which are what the owner sees and hears
# while it runs. start.img is ours (installer/start.img); end.img and play
# still come from the stock package.
#
# Shipping no software component is what keeps app_startup.sh's own recovery
# working: /usr/prog/PROGRAM/software goes on holding FlashForge's version
# directory and their firmwareExe inside it, so the five-second watchdog there
# has a working UI to restore when an install goes wrong. Nothing in that
# component was ever ours to ship -- their klippy tree, their wifi module and
# their configs, going straight back to the partition they were already on.
#
# --full carries kernel/control/library verbatim, and the installer installs
# any component a package does carry: absent ones are skipped, exactly as
# FlashForge's own `ls -1t <name>-*.tar.xz` guard did.
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

# work/outer, not work/software: no component is shipped, but start.img,
# end.img, play and (with --full) the other three components still come out of
# the stock package bin/unpack.sh opened.
[ -d work/outer ] || { echo "run ./bin/unpack.sh first" >&2; exit 1; }

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

# --- 1. the outer package
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
# Four lines are rewritten rather than being config the script reads: it runs
# on a printer with nothing beside it but the package it came in, so the gate
# and the password mode have to be IN it. The `^NAME=` shape is what
# bin/unpack.sh and tools/replica/printer/entrypoint.sh read back.
echo ">> generating runFirmwareExe.sh ($OUT_MACHINE/$OUT_PID, pw-auto=$PW_AUTO)"
# SINGLE-QUOTED in the generated file, and that is not style. A crypt hash is
# `$6$salt$...`, and an unquoted assignment would have the printer's shell
# expand $6 as a positional parameter and ship a truncated hash -- a printer
# nobody can log into. Crypt output is [./A-Za-z0-9$] so it can never contain
# the quote that would close it early.
#
# `|` as the sed delimiter for the same reason: a hash is full of `/`. & and \
# are escaped in case ROOT_PW_HASH is ever something stranger than a hash.
_pw_esc=$(printf '%s' "${ROOT_PW_HASH:-}" | sed -e 's/[\\&|]/\\&/g')
sed -e "s/^MACHINE=.*/MACHINE=$OUT_MACHINE/" \
    -e "s/^PID=.*/PID=$OUT_PID/" \
    -e "s/^MOD_PW_AUTO=.*/MOD_PW_AUTO=$PW_AUTO/" \
    -e "s|^MOD_ROOT_PW_HASH=.*|MOD_ROOT_PW_HASH='$_pw_esc'|" \
    installer/runFirmwareExe.sh > work/stage/runFirmwareExe.sh
chmod +x work/stage/runFirmwareExe.sh
# The substitutions are not optional: a package whose gate still says
# Creator5Pro because a sed missed would install on the wrong machine, and one
# whose password line did not take would ship an unreachable printer.
for _want in "MACHINE=$OUT_MACHINE" "PID=$OUT_PID" "MOD_PW_AUTO=$PW_AUTO" \
             "MOD_ROOT_PW_HASH='${ROOT_PW_HASH:-}'"; do
    grep -qxF "$_want" work/stage/runFirmwareExe.sh || {
        echo "runFirmwareExe.sh has no '${_want%%=*}=' line as expected -- the sed above missed" >&2
        exit 1; }
done
# It must also still PARSE after the substitutions: a hash with a stray
# character in it would otherwise reach a printer as a syntax error, and the
# only symptom would be a package that installs nothing.
sh -n work/stage/runFirmwareExe.sh || {
    echo "the generated runFirmwareExe.sh does not parse" >&2; exit 1; }

# FF_STOCK_PW_HASH is how the installer tells "nobody has set a root password
# on this printer" from "someone has". It is hardcoded there, and this is the
# one moment a build can check it: work/software is the stock component this
# package was built from, and its shadow is where the constant came from.
#
# Getting it wrong is silent and total -- every printer reads as "already set",
# none is ever given a password, and nobody can ssh in -- so a mismatch fails
# the build rather than shipping.
if [ -f work/software/shadow ]; then
    _ff_live=$(awk 'BEGIN{FS=":"} $1=="root"{print $2}' work/software/shadow)
    _ff_baked=$(sed -n "s/^FF_STOCK_PW_HASH='\(.*\)'$/\1/p" installer/runFirmwareExe.sh)
    if [ "$_ff_live" != "$_ff_baked" ]; then
        echo "FF_STOCK_PW_HASH is stale: installer/runFirmwareExe.sh has" >&2
        echo "    $_ff_baked" >&2
        echo "  but this stock package's shadow has" >&2
        echo "    $_ff_live" >&2
        echo "  Update the constant. Until you do, no printer on this firmware" >&2
        echo "  would ever be given a root password -- every one would read as" >&2
        echo "  'password already set' and ssh would stay shut." >&2
        exit 1
    fi
fi
# start.img is ours now, not FlashForge's: a raw 480x800@32 framebuffer dump
# rendered once with ffscreen.py and committed, the same tool that draws every
# later boot frame. To regenerate:
#   python3 pkgs/anvil-core/payload/bin/ffscreen.py --fb installer/start.img \
#       --size 480x800@32 --title "Reforge" --status "Installing..." --note "DO NOT POWER OFF"
# (the file must already exist -- ffscreen.py refuses to write a device/path
# that isn't there yet -- so `touch installer/start.img` first if recreating.)
cp -f installer/start.img work/stage/start.img
for f in end.img play; do
    [ -f "work/outer/$f" ] && cp -f "work/outer/$f" work/stage/
done
if [ "$SLIM" = "0" ]; then
    echo ">> --full: also carrying kernel / control / library"
    echo "   (this reflashes the kernel and the MCU/board firmware)"
    for f in work/outer/kernel-*.tar.xz work/outer/control-*.tar.xz work/outer/library-*.tar.xz; do
        [ -f "$f" ] && cp -f "$f" work/stage/
    done
else
    echo ">> slim: installer + payload only -- no FlashForge component is reflashed"
fi
echo ">> outer payload:"
ls -la work/stage | sed 's/^/   /'

# --- 2. emit
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
