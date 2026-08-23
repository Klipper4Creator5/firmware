#!/bin/sh
# The anti-brick test, executed by the printer's own busybox inside a chroot of
# the real rootfs.squashfs, on a /usr/prog installed by the real stock updater.
#
# It replays what app_startup.sh does with a USB stick -- using the glob,
# MACHINE and PID out of the installed app_startup.sh, and the printer's own
# unTar binary -- and then asks the only question that matters: would this
# machine still boot?
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

SW=/usr/prog/PROGRAM/software
APP=/usr/prog/app_startup.sh

# ---------------------------------------------------------------- USB pickup
# The stick is /mnt. app_startup.sh looks for exactly one filename pattern, and
# a package named anything else is invisible to the printer -- no error, no
# update, just nothing happening.
GLOB=$(sed -n 's/.*`ls -1t \(\/mnt\/[^`]*\.tgz\) | head.*/\1/p' $APP | head -n 1)
[ -n "$GLOB" ] || GLOB=$(grep -o '/mnt/[A-Za-z0-9]*-\*\.tgz' $APP | head -n 1)
MACHINE=$(sed -n 's/^MACHINE=//p' $APP | head -n 1)
PID=$(sed -n 's/^PID=//p' $APP | head -n 1)
echo "  -- stock app_startup.sh: MACHINE=$MACHINE PID=$PID glob=$GLOB --"

UPDATEFILE=$(ls -1t $GLOB 2>/dev/null | head -n 1)
if [ -n "$UPDATEFILE" ] && [ -f "$UPDATEFILE" ]; then
    ok "app_startup.sh's glob finds the package ($(basename "$UPDATEFILE"))"
else
    bad "app_startup.sh globs $GLOB and would never see this package"
    echo "        on the stick: $(ls /mnt)"
    exit 1
fi

# app_startup.sh copies the package to /usr/data first, then decrypts with the
# printer's own unTar, and only falls back to plain tar if that produced no
# runFirmwareExe.sh.
rm -rf /usr/data/update; mkdir -p /usr/data/update
cp -a "$UPDATEFILE" /usr/data/
SRCFILE="/usr/data/$(basename "$UPDATEFILE")"
export PATH=/usr/prog/openssl-1.0.2d/bin:$PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:$LD_LIBRARY_PATH
/usr/prog/bin/unTar "$SRCFILE" > /tmp/untar.log 2>&1
if [ -f /usr/data/update/runFirmwareExe.sh ]; then
    ok "the printer's own unTar decrypted the package"
else
    tar -xvf "$SRCFILE" -C /usr/data/update/ >/dev/null 2>&1
    if [ -f /usr/data/update/runFirmwareExe.sh ]; then
        bad "unTar could not decrypt it -- the printer would fall back to plain tar"
    else
        bad "neither unTar nor tar could unpack it: the update does nothing"
        tail -5 /tmp/untar.log | sed 's/^/        /'
        exit 1
    fi
fi
rm -f "$SRCFILE"

cp -a $APP /tmp/app_startup.before
chmod a+x /usr/data/update/runFirmwareExe.sh
/usr/data/update/runFirmwareExe.sh "$MACHINE" "$PID" > /tmp/install.log 2>&1
RC=$?
[ $RC -eq 0 ] && ok "installer exited 0" \
              || { bad "installer exited $RC"; tail -25 /tmp/install.log | sed 's/^/        /'; }

# ------------------------------------------------------- would it still boot?
echo
echo "  -- would the printer still boot? --"

mkdir -p /tmp/ref
tar -xf /usr/data/update/software-*.tar.xz -C /tmp/ref ./app_startup.sh 2>/dev/null
if [ -f /tmp/ref/app_startup.sh ] && cmp -s /tmp/ref/app_startup.sh $APP; then
    ok "app_startup.sh matches the package's own copy"
else
    bad "app_startup.sh differs from the package copy"
fi
grep -q 'anvil' $APP \
    && bad "app_startup.sh carries mod markers -- boot scripts must stay stock" \
    || ok "app_startup.sh carries no mod markers"
grep -q 'insmod' $APP && ok "kernel modules still loaded at boot" \
                      || bad "BRICK: insmod lines lost from app_startup.sh"
sh -n $APP 2>/dev/null && ok "app_startup.sh parses under the printer's busybox" \
                       || bad "BRICK: app_startup.sh has a syntax error"

FE=$SW/firmwareExe
[ -s "$FE" ] && ok "firmwareExe present where app_startup.sh runs it" || bad "BRICK: $FE missing"
[ -x "$FE" ] && ok "firmwareExe is executable" || bad "BRICK: $FE not executable"

if head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    sh -n "$FE" 2>/dev/null && ok "firmwareExe wrapper parses under the printer's busybox" \
                            || { bad "BRICK: wrapper syntax error"; sh -n "$FE" 2>&1 | sed 's/^/        /'; }
    [ -s "$SW/firmwareExe.stock" ] \
        && ok "stock UI binary preserved as firmwareExe.stock" \
        || bad "BRICK: wrapper installed but the stock UI binary is gone"
    head -c 4 "$SW/firmwareExe.stock" 2>/dev/null | grep -q 'ELF' \
        && ok "firmwareExe.stock is a real ELF binary" \
        || bad "firmwareExe.stock is not an ELF -- the UI could not be restored"
elif head -c 4 "$FE" | grep -q 'ELF'; then
    ok "stock firmwareExe binary in place (no UI replacement in this profile)"
fi

# Every shell script the mod puts on the machine has to parse with THIS shell.
for f in $(find /usr/data/anvil /usr/prog/klipper/start.sh -name '*.sh' -o -path '*/init.d/S*' 2>/dev/null); do
    [ -f "$f" ] || continue
    sh -n "$f" 2>/dev/null || { bad "syntax error under busybox ash: $f"; sh -n "$f" 2>&1 | sed 's/^/        /'; }
done
ok "all mod scripts parse under the printer's busybox ash"

if [ -d /usr/data/anvil/init.d ]; then
    grep -rq 'start\.sh' /usr/data/anvil/init.d/ 2>/dev/null \
        && ok "a service owns Klipper startup" \
        || bad "nothing starts Klipper -- UI would boot with no motion or heaters"
elif head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    bad "firmwareExe replaced but no service dir exists to start Klipper"
fi

[ -f /usr/prog/klipper/klippy/klippy.py ] && ok "klippy.py present" || bad "klippy.py missing"

# The chelper has to match this CPU or klippy dies at import.
CH=/usr/prog/klipper/klippy/chelper/c_helper.so
if [ -f "$CH" ]; then
    HEX=$(head -c 40 "$CH" | xxd -p | tr -d '\n')
    # e_ident: 32-bit (01) little-endian (01);  e_machine at byte 18 = 0x0008 MIPS
    case "$HEX" in
        7f454c46010101*) MIPSOK=1 ;;
        *) MIPSOK=0 ;;
    esac
    MACHW=$(echo "$HEX" | cut -c37-40)
    # e_flags at byte 36; bit 0x400 is EF_MIPS_NAN2008, which this CPU requires
    FLAGS=$(echo "$HEX" | cut -c73-80)
    if [ "$MIPSOK" = 1 ] && [ "$MACHW" = "0800" ]; then
        ok "c_helper.so is a 32-bit little-endian MIPS object (e_flags $FLAGS)"
    else
        bad "BRICK: c_helper.so is not 32-bit LE MIPS (header $HEX) -- klippy will not start"
    fi
    # e_flags is little-endian, so 0x...0400 (EF_MIPS_NAN2008) lands in the
    # low nibble of the second byte of the hex dump.
    case "$(echo "$FLAGS" | cut -c3-4)" in
        *4|*5|*6|*7|*c|*d|*e|*f) ok "c_helper.so is nan2008 (matches the printer's toolchain)" ;;
        *) bad "BRICK: c_helper.so is not nan2008 -- klippy dies on import" ;;
    esac
else
    bad "c_helper.so missing -- klippy will not start"
fi

grep -q 'USER-CONFIG-MUST-SURVIVE' /usr/data/config/printer.cfg 2>/dev/null \
    && ok "user printer.cfg preserved" || bad "user printer.cfg was clobbered"

if [ -d /usr/data/anvil/backup ]; then
    n=$(find /usr/data/anvil/backup -type f | wc -l)
    [ "$n" -gt 0 ] && ok "installer wrote $n backup file(s)" || bad "backup dir is empty"
    [ -d /usr/data/anvil/backup/stock ] && ok "pristine snapshot at backup/stock" \
                                      || bad "no pristine snapshot to restore from"
fi

# Nothing may be written to the read-only root. A mod that needs it works in a
# permissive sandbox and fails silently on the machine.
if [ -f /tmp/sim-neutered.log ]; then
    echo "  -- calls neutered by the simulation --"
    sort -u /tmp/sim-neutered.log | sed 's/^/        /'
fi

# ------------------------------------------------------------- second install
cp -a $APP /tmp/app_startup.after1
rm -rf /usr/data/update; mkdir -p /usr/data/update
cp -a "$UPDATEFILE" /usr/data/
/usr/prog/bin/unTar "$SRCFILE" >/dev/null 2>&1
chmod a+x /usr/data/update/runFirmwareExe.sh
/usr/data/update/runFirmwareExe.sh "$MACHINE" "$PID" > /tmp/install2.log 2>&1
RC2=$?
[ $RC2 -eq 0 ] && ok "re-install exited 0" || bad "re-install exited $RC2"
cmp -s /tmp/app_startup.after1 $APP && ok "re-install is idempotent" \
                                    || bad "re-install changed app_startup.sh again"
[ -s "$SW/firmwareExe" ] && ok "firmwareExe still present after re-install" \
                         || bad "BRICK: re-install left no firmwareExe"
if head -c 2 "$SW/firmwareExe" 2>/dev/null | grep -q '#!'; then
    head -c 4 "$SW/firmwareExe.stock" 2>/dev/null | grep -q 'ELF' \
        && ok "re-install did not overwrite firmwareExe.stock with the wrapper" \
        || bad "BRICK: firmwareExe.stock is now the wrapper -- stock UI lost forever"
fi

echo
[ "$FAIL" = 0 ] && echo "  install simulation clean" || echo "  INSTALL SIMULATION FAILED"
exit $FAIL
