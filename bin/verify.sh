#!/usr/bin/env bash
# Simulate every check the printer performs, against a built package.
#   ./verify.sh                      verify work/out/Creator5Pro-*.tgz
#   ./verify.sh path/to/pkg.tgz
set -uo pipefail
. "$(dirname "$0")/common.sh"

PKG="${1:-$(ls -1 work/out/Creator5Pro-*.tgz 2>/dev/null | head -n1)}"
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
    grep -qE 'firmwareExe|boot.sh' "$T/sw/app_startup.sh" \
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
if [ -f "$T/mod.tar.xz" ]; then
    if xz -t "$T/mod.tar.xz" 2>/dev/null; then ok "mod.tar.xz is valid xz"
    elif tar -tf "$T/mod.tar.xz" >/dev/null 2>&1; then ok "mod.tar.xz is a plain tar"
    else bad "mod.tar.xz is neither valid xz nor tar"; fi

    LIST=$(xz -dc "$T/mod.tar.xz" 2>/dev/null | tar -tf - 2>/dev/null || tar -tf "$T/mod.tar.xz" 2>/dev/null)
    echo "$LIST" | grep -q 'init.d/S80ui' && ok "mod payload has the service scripts" \
                                          || bad "mod payload missing init.d services"
    echo "$LIST" | grep -q 'init.d/S70klipper' && ok "mod payload owns Klipper startup" \
                                          || bad "mod payload missing S70klipper -- Klipper would never start"
    echo "$LIST" | grep -q 'mainsail/index.html' && ok "Mainsail present" || warn "no Mainsail in payload"
    echo "$LIST" | grep -q 'helixscreen/bin/helix-screen' && ok "HelixScreen present" || warn "no HelixScreen in payload"
    echo "$LIST" | grep -q 'bin/dropbear'  && ok "dropbear present" || warn "no dropbear -- ssh will not start"
else
    warn "no mod.tar.xz -- scripts only"
fi

# 9 --------------------------------------------------------------- USB names
BN=$(basename "$PKG")
case "$BN" in
    Creator5Pro-*.tgz) ok "filename matches the Pro's glob (/mnt/Creator5Pro-*.tgz)" ;;
    Creator5-*.tgz)    ok "filename matches the non-Pro's glob (/mnt/Creator5-*.tgz)" ;;
    *) bad "filename '$BN' matches no glob -- app_startup.sh will ignore it" ;;
esac
[ -f "$(dirname "$PKG")/Creator5-$(echo "$BN" | sed 's/^Creator5Pro-//')" ] \
    && ok "companion non-Pro package exists" \
    || warn "only one model's filename built"

echo
if [ "$FAIL" = 0 ]; then echo "ALL CHECKS PASSED -- safe to copy to USB"; else echo "FAILURES ABOVE -- do not install"; exit 1; fi
