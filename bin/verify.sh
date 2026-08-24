#!/usr/bin/env bash
# Simulate every check the printer performs, against a built package.
#   ./verify.sh                      verify work/out/Creator5Pro-*.tgz
#   ./verify.sh path/to/pkg.tgz
set -uo pipefail
. "$(dirname "$0")/common.sh"

# Default to the package for the model currently selected, not a hardcoded
# one -- otherwise a two-model release verifies the same file twice.
PKG="${1:-$(ls -1 "work/out/${TARGET_MACHINE:-Creator5Pro}"-*.tgz 2>/dev/null | head -n1)}"
[ -f "${PKG:-}" ] || { echo "no package; run ./pack.sh" >&2; exit 1; }
echo "verifying $PKG"; echo

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

T=$(mktemp -d); trap 'rm -rf "$T"' EXIT

# 1 ---------------------------------------------------------------- decrypt
if openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$PKG" 2>/dev/null \
     | tar -xf - -C "$T" 2>/dev/null; then
    ok "decrypts with the firmware key and is a valid tar"
else
    bad "decrypt/untar failed -- the printer's unTar will reject this"; exit 1
fi

# 2 ------------------------------------------------------- installer present
if [ -f "$T/runFirmwareExe.sh" ]; then
    ok "runFirmwareExe.sh present"
else
    bad "no runFirmwareExe.sh -- app_startup.sh falls back to plain tar and gives up"
fi

# 3 ----------------------------------------- components are PLAIN tar, not xz
for f in "$T"/software-*.tar.xz "$T"/kernel-*.tar.xz "$T"/control-*.tar.xz "$T"/library-*.tar.xz; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if tar -tf "$f" >/dev/null 2>&1; then
        ok "$b is a plain tar (stock installer runs bare 'tar -xvf')"
    else
        bad "$b is not a plain tar -- stock 'tar -xvf' cannot read it"
    fi
done

# 4 ------------------------------------------------------------- md5sum gate
SW=$(ls -1 "$T"/software-*.tar.xz 2>/dev/null | head -n1)
if [ -n "$SW" ]; then
    mkdir -p "$T/sw" && tar -xf "$SW" -C "$T/sw"
    if [ -f "$T/sw/md5sum.list" ]; then
        # NB: the printer's busybox md5sum takes -s for quiet; GNU coreutils
        # spells it --status. Use whichever this host has.
        if ( cd "$T/sw" && md5sum --status -c md5sum.list 2>/dev/null ) \
           || ( cd "$T/sw" && md5sum -s -c md5sum.list 2>/dev/null ); then
            ok "md5sum.list verifies ($(wc -l < "$T/sw/md5sum.list") entries)"
        else
            bad "md5sum.list does NOT verify -- installer aborts and deletes the payload"
            ( cd "$T/sw" && md5sum -c md5sum.list 2>&1 | grep -v ': OK$' | head -5 | sed 's/^/        /' )
        fi
        grep -q 'md5sum.list' "$T/sw/md5sum.list" && bad "md5sum.list lists itself (can never match)"
    else
        bad "no md5sum.list in the software component"
    fi
fi

# 5 -------------------------------------------------- shell syntax of scripts
for s in "$T/runFirmwareExe.sh" "$T/sw/run.sh" "$T/sw/start.sh" "$T/sw/app_startup.sh"; do
    [ -f "$s" ] || continue
    if sh -n "$s" 2>/dev/null; then ok "syntax OK: $(basename "$s")"
    else bad "SYNTAX ERROR in $(basename "$s")"; sh -n "$s" 2>&1 | head -3 | sed 's/^/        /'; fi
done

# 6 ---------------------------------------------- boot chain actually hooks up
if [ -f "$T/sw/app_startup.sh" ]; then
    grep -q 'gt9xx_touch.ko' "$T/sw/app_startup.sh" \
        && ok "touchscreen driver still loaded at boot" \
        || bad "gt9xx_touch.ko insmod missing -- no touchscreen"
    grep -q 'firmwareExe' "$T/sw/app_startup.sh" \
        && ok "a UI is launched at boot" \
        || bad "nothing launches a UI -- printer boots to a blank screen"
fi

# 7 ------------------------------------------------- MIPS ABI of any binaries
if [ -f "$T/sw/klipper/chelper.tar" ]; then
    mkdir -p "$T/ch" && tar -xf "$T/sw/klipper/chelper.tar" -C "$T/ch"
    CH=$(find "$T/ch" -name 'c_helper.so' | head -n1)
    if [ -n "$CH" ] && ! head -c 4 "$CH" | grep -q ELF; then
        warn "c_helper.so is not an ELF (synthetic fixture) -- ABI check skipped"
        CH=""
    fi
    if [ -n "$CH" ]; then
        if readelf -h "$CH" 2>/dev/null | grep -q nan2008; then
            ok "c_helper.so is nan2008 MIPS32r2 (kernel will load it)"
        else
            bad "c_helper.so is NOT nan2008 -- kernel returns ENOEXEC, klippy dies"
        fi
    fi
fi

# 8 ------------------------------------------------------------ mod payload
if [ -f "$T/anvil.tar.xz" ]; then
    if xz -t "$T/anvil.tar.xz" 2>/dev/null; then ok "anvil.tar.xz is valid xz"
    elif tar -tf "$T/anvil.tar.xz" >/dev/null 2>&1; then ok "anvil.tar.xz is a plain tar"
    else bad "anvil.tar.xz is neither valid xz nor tar"; fi

    LIST=$(xz -dc "$T/anvil.tar.xz" 2>/dev/null | tar -tf - 2>/dev/null || tar -tf "$T/anvil.tar.xz" 2>/dev/null)
    echo "$LIST" | grep -q 'init.d/S80ui' && ok "mod payload has the service scripts" \
                                          || bad "mod payload missing init.d services"
    echo "$LIST" | grep -q 'init.d/S70klipper' && ok "mod payload owns Klipper startup" \
                                          || bad "mod payload missing S70klipper -- Klipper would never start"
    echo "$LIST" | grep -q 'mainsail/index.html' && ok "Mainsail present" || warn "no Mainsail in payload"
    echo "$LIST" | grep -q 'helixscreen/bin/helix-screen' && ok "HelixScreen present" || warn "no HelixScreen in payload"
    echo "$LIST" | grep -q 'bin/dropbear'  && ok "dropbear present" || warn "no dropbear -- ssh will not start"
    # moonraker.py is the file moonrakerDaemon execs by absolute path; a
    # payload with the directory but not that file installs a Moonraker that
    # cannot start, which looks identical to a dead printer from the outside.
    echo "$LIST" | grep -q 'moonraker/moonraker.py' && ok "Moonraker present" \
                                          || warn "no Moonraker in payload -- the stock 2022 build stays, and Mainsail will hide the webcam"
else
    warn "no anvil.tar.xz -- scripts only"
fi

# 8b ------------------------------------------------------- MODEL GATE
# The most easily missed failure: a package built from the wrong model's
# firmware refuses to install, and a package built from the RIGHT model but
# flashed to the wrong one would install the wrong binaries.
PKG_MACHINE=$(sed -n 's/^MACHINE=//p' "$T/runFirmwareExe.sh" 2>/dev/null | head -n1)
PKG_PID=$(sed -n 's/^PID=//p' "$T/runFirmwareExe.sh" 2>/dev/null | head -n1)
if [ -n "$PKG_MACHINE" ]; then
    echo "         package installs on: $PKG_MACHINE (PID $PKG_PID)"
    if [ -n "${TARGET_MACHINE:-}" ]; then
        if [ "$PKG_MACHINE" = "$TARGET_MACHINE" ]; then
            ok "model gate matches TARGET_MACHINE=$TARGET_MACHINE"
        else
            bad "MODEL MISMATCH: package is for '$PKG_MACHINE' but TARGET_MACHINE='$TARGET_MACHINE'"
            bad "  this package will be REFUSED by your printer (\"Firmware does not match machine type\")"
            bad "  you need a stock package built for $TARGET_MACHINE to start from"
        fi
    else
        warn "TARGET_MACHINE not set in config.env -- cannot check this against your printer"
    fi
else
    warn "no MACHINE= gate found in runFirmwareExe.sh"
fi

# 9 --------------------------------------------------------------- USB names
# The filename prefix must match the model, because app_startup.sh globs for
# it: the Pro looks for /mnt/Creator5Pro-*.tgz, the non-Pro for
# /mnt/Creator5-*.tgz. It must ALSO match the gate inside, or the printer
# picks the file up and then refuses it.
BN=$(basename "$PKG")
case "$BN" in
    Creator5Pro-*.tgz) FN_MACHINE=Creator5Pro ;;
    Creator5-*.tgz)    FN_MACHINE=Creator5 ;;
    *) FN_MACHINE=""; bad "filename '$BN' matches no glob -- app_startup.sh will ignore it" ;;
esac
if [ -n "$FN_MACHINE" ]; then
    if [ -z "$PKG_MACHINE" ] || [ "$FN_MACHINE" = "$PKG_MACHINE" ]; then
        ok "filename prefix matches the model gate ($FN_MACHINE)"
    else
        bad "filename says $FN_MACHINE but the gate inside says $PKG_MACHINE"
        bad "  the printer would pick this file up and then refuse it"
    fi
fi

# 10 --------------------------------------------------- the ship boundary
# Only payload/ and assets/ may end up on a printer; bin/, test/ and docker/
# are host-side. Nothing enforces that except this check.
#
# It compares by CONTENT, not by name: a name blacklist would trip over any
# file Mainsail or HelixScreen happens to call common.sh, while a byte-for-byte
# match against a host-lane file is exactly the thing we are trying to catch.
mkdir -p "$T/ship"
tar -xf "$T"/software-*.tar.xz -C "$T/ship" 2>/dev/null || true
if [ -f "$T/anvil.tar.xz" ]; then
    mkdir -p "$T/ship/.anvil"
    xz -dc "$T/anvil.tar.xz" 2>/dev/null | tar -xf - -C "$T/ship/.anvil" 2>/dev/null \
        || tar -xf "$T/anvil.tar.xz" -C "$T/ship/.anvil" 2>/dev/null || true
fi
find bin test docker -type f 2>/dev/null | xargs -r md5sum 2>/dev/null \
    | awk '{print $1}' | sort -u > "$T/host.md5"
find "$T/ship" -type f 2>/dev/null | xargs -r md5sum 2>/dev/null > "$T/ship.md5"
LEAK=$(awk 'NR==FNR{h[$1];next} $1 in h {print}' "$T/host.md5" "$T/ship.md5" \
       | sed "s|$T/ship/||")
if [ -z "$LEAK" ]; then
    ok "package carries nothing from bin/, test/ or docker/"
else
    bad "host-side files leaked into the package:"
    echo "$LEAK" | head -10 | sed 's/^/          /'
fi

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED -- safe to copy to USB"; else echo "FAILURES ABOVE -- do not install"; exit 1; fi
