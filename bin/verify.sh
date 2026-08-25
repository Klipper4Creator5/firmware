#!/usr/bin/env bash
# Simulate every check the printer performs, against a built package.
#   ./bin/verify.sh                      verify work/out/Creator5Pro-*.tgz
#   ./bin/verify.sh path/to/pkg.tgz
set -uo pipefail
. "$(dirname "$0")/common.sh"

# Default to the package for the model currently selected, not a hardcoded
# one -- otherwise a two-model release verifies the same file twice.
PKG="${1:-$(ls -1 "work/out/${TARGET_MACHINE:-Creator5Pro}"-*.tgz 2>/dev/null | head -n1)}"
[ -f "${PKG:-}" ] || { echo "no package; run ./bin/pack.sh" >&2; exit 1; }
echo "verifying $PKG"; echo

FAIL=0
ok()   { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad()  { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
warn() { printf '  \033[33mWARN\033[0m  %s\n' "$*"; }

WORK=$(mktemp -d); trap 'rm -rf "$WORK"' EXIT

# 1 ---------------------------------------------------------------- decrypt
if openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$PKG" 2>/dev/null \
     | tar -xf - -C "$WORK" 2>/dev/null; then
    ok "decrypts with the firmware key and is a valid tar"
else
    bad "decrypt/untar failed -- the printer's unTar will reject this"; exit 1
fi

# 2 ------------------------------------------------------- installer present
if [ -f "$WORK/runFirmwareExe.sh" ]; then
    ok "runFirmwareExe.sh present"
else
    bad "no runFirmwareExe.sh -- app_startup.sh falls back to plain tar and gives up"
fi

# 3 ----------------------------------------- components are PLAIN tar, not xz
for f in "$WORK"/software-*.tar.xz "$WORK"/kernel-*.tar.xz "$WORK"/control-*.tar.xz "$WORK"/library-*.tar.xz; do
    [ -f "$f" ] || continue
    b=$(basename "$f")
    if tar -tf "$f" >/dev/null 2>&1; then
        ok "$b is a plain tar (stock installer runs bare 'tar -xvf')"
    else
        bad "$b is not a plain tar -- stock 'tar -xvf' cannot read it"
    fi
done

# 4 ------------------------------------------------------------- md5sum gate
SOFTWARE_TAR=$(ls -1 "$WORK"/software-*.tar.xz 2>/dev/null | head -n1)
if [ -n "$SOFTWARE_TAR" ]; then
    mkdir -p "$WORK/sw" && tar -xf "$SOFTWARE_TAR" -C "$WORK/sw"
    if [ -f "$WORK/sw/md5sum.list" ]; then
        # NB: the printer's busybox md5sum takes -s for quiet; GNU coreutils
        # spells it --status. Use whichever this host has.
        if ( cd "$WORK/sw" && md5sum --status -c md5sum.list 2>/dev/null ) \
           || ( cd "$WORK/sw" && md5sum -s -c md5sum.list 2>/dev/null ); then
            ok "md5sum.list verifies ($(wc -l < "$WORK/sw/md5sum.list") entries)"
        else
            bad "md5sum.list does NOT verify -- installer aborts and deletes the payload"
            ( cd "$WORK/sw" && md5sum -c md5sum.list 2>&1 | grep -v ': OK$' | head -5 | sed 's/^/        /' )
        fi
        grep -q 'md5sum.list' "$WORK/sw/md5sum.list" && bad "md5sum.list lists itself (can never match)"
    else
        bad "no md5sum.list in the software component"
    fi
fi

# 5 -------------------------------------------------- shell syntax of scripts
for s in "$WORK/runFirmwareExe.sh" "$WORK/sw/run.sh" "$WORK/sw/start.sh" "$WORK/sw/app_startup.sh"; do
    [ -f "$s" ] || continue
    if sh -n "$s" 2>/dev/null; then ok "syntax OK: $(basename "$s")"
    else bad "SYNTAX ERROR in $(basename "$s")"; sh -n "$s" 2>&1 | head -3 | sed 's/^/        /'; fi
done

# 6 ---------------------------------------------- boot chain actually hooks up
if [ -f "$WORK/sw/app_startup.sh" ]; then
    grep -q 'gt9xx_touch.ko' "$WORK/sw/app_startup.sh" \
        && ok "touchscreen driver still loaded at boot" \
        || bad "gt9xx_touch.ko insmod missing -- no touchscreen"
    grep -q 'firmwareExe' "$WORK/sw/app_startup.sh" \
        && ok "a UI is launched at boot" \
        || bad "nothing launches a UI -- printer boots to a blank screen"
fi

# 7 ------------------------------------------------- MIPS ABI of any binaries
# A fork build that ships no fork is a broken package, not an optional check:
# the v20260824 release passed here precisely because everything below was
# conditional on files that the broken build simply did not contain.
if [ "${BUILD_KLIPPER:-fork}" = "fork" ]; then
    if [ -f "$WORK/sw/klipper/klippy/chelper/__init__.py" ]; then
        ok "package carries the fork klippy tree"
    else
        bad "BUILD_KLIPPER=fork but no klippy tree in the package -- this is the stock-overlay build that shipped as v20260824"
    fi
    [ -f "$WORK/sw/klipper/chelper.tar" ] \
        || bad "BUILD_KLIPPER=fork but no chelper.tar in the package"
fi
if [ -f "$WORK/sw/klipper/chelper.tar" ]; then
    mkdir -p "$WORK/ch" && tar -xf "$WORK/sw/klipper/chelper.tar" -C "$WORK/ch"
    CHELPER=$(find "$WORK/ch" -name 'c_helper.so' | head -n1)
    if [ -n "$CHELPER" ] && ! head -c 4 "$CHELPER" | grep -q ELF; then
        warn "c_helper.so is not an ELF (synthetic fixture) -- ABI check skipped"
        CHELPER=""
    fi
    if [ -n "$CHELPER" ]; then
        if readelf -h "$CHELPER" 2>/dev/null | grep -q nan2008; then
            ok "c_helper.so is nan2008 MIPS32r2 (kernel will load it)"
        else
            bad "c_helper.so is NOT nan2008 -- kernel returns ENOEXEC, klippy dies"
        fi
        # The failure mode that reached a printer: a .so from older sources
        # than the klippy tree beside it. cffi resolves lazily, so only a
        # symbol-table check catches it before the machine does.
        if [ -f "$WORK/sw/klipper/klippy/chelper/__init__.py" ]; then
            if python3 "$ROOT/test/test-chelper.py" "$WORK/sw/klipper" >/dev/null 2>&1; then
                ok "c_helper.so exports everything the shipped klippy declares"
            else
                bad "c_helper.so does not match the shipped klippy tree (stale build)"
            fi
        fi
    fi
fi

# 8 ------------------------------------------------------------ mod payload
if [ -f "$WORK/anvil.tar.xz" ]; then
    if xz -t "$WORK/anvil.tar.xz" 2>/dev/null; then ok "anvil.tar.xz is valid xz"
    elif tar -tf "$WORK/anvil.tar.xz" >/dev/null 2>&1; then ok "anvil.tar.xz is a plain tar"
    else bad "anvil.tar.xz is neither valid xz nor tar"; fi

    LIST=$(xz -dc "$WORK/anvil.tar.xz" 2>/dev/null | tar -tf - 2>/dev/null || tar -tf "$WORK/anvil.tar.xz" 2>/dev/null)
    # Herestrings, NOT `echo "$LIST" | grep -q`: under pipefail, grep -q
    # exiting at an early match SIGPIPEs the echo and the pipeline returns
    # 141 -- a race that stayed invisible until the fork klippy tree tripled
    # the listing, then intermittently reported Mainsail/Moonraker missing
    # from packages that carried both.
    grep -q 'init.d/S80ui' <<<"$LIST" && ok "mod payload has the service scripts" \
                                          || bad "mod payload missing init.d services"
    grep -q 'init.d/S70klipper' <<<"$LIST" && ok "mod payload owns Klipper startup" \
                                          || bad "mod payload missing S70klipper -- Klipper would never start"
    grep -q 'mainsail/index.html' <<<"$LIST" && ok "Mainsail present" || warn "no Mainsail in payload"
    grep -q 'helixscreen/bin/helix-screen' <<<"$LIST" && ok "HelixScreen present" || warn "no HelixScreen in payload"
    # We deliberately ship no dropbear: the stock rootfs already has one, with
    # an enabled S50dropbear, so ssh is up before the mod does anything. A
    # dropbear in the payload would mean something unexpected, not something
    # missing -- hence the check reads the way round it does.
    grep -q 'bin/dropbear' <<<"$LIST" \
        && warn "dropbear in the payload -- we ship none; stock S50dropbear provides ssh" \
        || ok "no dropbear in the payload (stock S50dropbear provides ssh)"
    # moonraker.py is the file moonrakerDaemon execs by absolute path; a
    # payload with the directory but not that file installs a Moonraker that
    # cannot start, which looks identical to a dead printer from the outside.
    grep -q 'moonraker/moonraker.py' <<<"$LIST" && ok "Moonraker present" \
                                          || warn "no Moonraker in payload -- the stock 2022 build stays, and Mainsail will hide the webcam"
else
    warn "no anvil.tar.xz -- scripts only"
fi

# 8b ------------------------------------------------------- MODEL GATE
# The most easily missed failure: a package built from the wrong model's
# firmware refuses to install, and a package built from the RIGHT model but
# flashed to the wrong one would install the wrong binaries.
PKG_MACHINE=$(sed -n 's/^MACHINE=//p' "$WORK/runFirmwareExe.sh" 2>/dev/null | head -n1)
PKG_PID=$(sed -n 's/^PID=//p' "$WORK/runFirmwareExe.sh" 2>/dev/null | head -n1)
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
PKG_NAME=$(basename "$PKG")
case "$PKG_NAME" in
    Creator5Pro-*.tgz) FN_MACHINE=Creator5Pro ;;
    Creator5-*.tgz)    FN_MACHINE=Creator5 ;;
    *) FN_MACHINE=""; bad "filename '$PKG_NAME' matches no glob -- app_startup.sh will ignore it" ;;
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
mkdir -p "$WORK/ship"
tar -xf "$WORK"/software-*.tar.xz -C "$WORK/ship" 2>/dev/null || true
if [ -f "$WORK/anvil.tar.xz" ]; then
    mkdir -p "$WORK/ship/.anvil"
    xz -dc "$WORK/anvil.tar.xz" 2>/dev/null | tar -xf - -C "$WORK/ship/.anvil" 2>/dev/null \
        || tar -xf "$WORK/anvil.tar.xz" -C "$WORK/ship/.anvil" 2>/dev/null || true
fi
find bin test docker -type f 2>/dev/null | xargs -r md5sum 2>/dev/null \
    | awk '{print $1}' | sort -u > "$WORK/host.md5"
find "$WORK/ship" -type f 2>/dev/null | xargs -r md5sum 2>/dev/null > "$WORK/ship.md5"
LEAK=$(awk 'NR==FNR{h[$1];next} $1 in h {print}' "$WORK/host.md5" "$WORK/ship.md5" \
       | sed "s|$WORK/ship/||")
# Those finds are RELATIVE, so from any cwd but the repo root host.md5 comes
# out empty, the join matches nothing and this reports ok having compared
# nothing -- retiring the only check that keeps config.env and the host tooling
# off a USB stick. common.sh cds to the root, so this is a guard against a
# future caller that does not.
if [ ! -s "$WORK/host.md5" ]; then
    bad "ship-boundary check compared nothing (no files found under bin/, test/, docker/ -- wrong cwd?)"
elif [ -z "$LEAK" ]; then
    ok "package carries nothing from bin/, test/ or docker/"
else
    bad "host-side files leaked into the package:"
    echo "$LEAK" | head -10 | sed 's/^/          /'
fi

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED -- safe to copy to USB"; else echo "FAILURES ABOVE -- do not install"; exit 1; fi
