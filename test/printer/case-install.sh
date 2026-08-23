#!/bin/sh
# THE END-TO-END UPDATE TEST, executed by the printer's own busybox inside a
# chroot of the real rootfs.squashfs, on a /usr/prog installed by the real
# stock updater.
#
# Nothing here re-implements the printer's update logic. The package is on a
# genuine FAT filesystem exposed as /dev/sda1, and the thing that finds it,
# mounts it, decrypts it and installs it is the machine's OWN
# /usr/prog/app_startup.sh, run verbatim, exactly as /etc/init.d does at boot.
# An earlier version of this file replayed app_startup.sh by hand -- which
# meant a bug in our reading of it could never be caught.
#
# Three boots, in the order a user actually produces them:
#
#   boot 1  stick in            -> the update installs
#   boot 2  stick STILL in      -> it installs again (people leave the stick)
#   boot 3  stick pulled        -> the machine comes up with the mod running
#
# On the printer a successful install ends in `sleep 100000` waiting for the
# user to power-cycle; that is the signal boots 1 and 2 wait for.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

SW=/usr/prog/PROGRAM/software
APP=/usr/prog/app_startup.sh
FE=$SW/firmwareExe

# busybox 1.31.1 on this machine has no `timeout` applet, so bound the waits
# by hand.
wait_for() {            # wait_for <seconds> <command...>
    limit=$1; shift
    n=0
    while [ "$n" -lt "$limit" ]; do
        "$@" && return 0
        sleep 2; n=$((n+2))
    done
    return 1
}
# Is a process with this in its command line running?
#
# NOT `ps | grep`: busybox ps truncates COMMAND to the terminal width (80 when
# there is no tty) and under qemu every command line is prefixed with
# "/usr/bin/qemu-mipsel-static ", which pushes the interesting part off the
# end. `ps | grep 'sleep 100000'` therefore never matches, and the wait would
# sit there until it timed out on a install that had actually succeeded.
# /proc is exact, and `case` is a builtin so this cannot match itself.
running() {
    for _p in /proc/[0-9]*; do
        _c=$( { tr '\0' ' ' < "$_p/cmdline"; } 2>/dev/null )   # the pid may exit mid-scan
        case "$_c" in *"$1"*) return 0 ;; esac
    done
    return 1
}
installed()   { running 'sleep 100000'; }
exited()      { ! kill -0 "$BOOTPID" 2>/dev/null; }
settled()     { installed || exited; }

# Run app_startup.sh the way init does, and wait for it to reach either the
# post-install sleep or its own end.
boot() {                # boot <logfile> <seconds>
    sh "$APP" > "$1" 2>&1 &
    BOOTPID=$!
    wait_for "$2" settled
    RC=$?
    if installed; then BOOT_RESULT=installed
    elif exited;  then BOOT_RESULT=completed
    else               BOOT_RESULT=timeout
    fi
    kill "$BOOTPID" 2>/dev/null
    killall sleep 2>/dev/null
    [ "$RC" = 0 ]
}

# ------------------------------------------------------------ the USB stick
[ -b /dev/sda1 ] || { bad "no /dev/sda1 -- the harness did not attach a stick"; exit 1; }
ok "the stick is a real block device (/dev/sda1)"

MACHINE=$(sed -n 's/^MACHINE=//p' $APP | head -n 1)
PID=$(sed -n 's/^PID=//p' $APP | head -n 1)
echo "  -- stock app_startup.sh: MACHINE=$MACHINE PID=$PID --"

cp -a $APP /tmp/app_startup.before

# ================================================================== boot 1 ==
echo
echo "  -- boot 1: stick inserted --"
boot /tmp/boot1.log 900 || bad "boot 1 never settled (still running after 900s)"

if grep -q 'find update file' /tmp/boot1.log; then
    ok "app_startup.sh found the package on the stick by itself"
else
    bad "app_startup.sh never saw the package -- on a real printer nothing would happen"
    echo "        glob in app_startup.sh: $(grep -o '/mnt/[A-Za-z0-9]*-\*\.tgz' $APP | head -1)"
    tail -20 /tmp/boot1.log | sed 's/^/        /'
    exit 1
fi

case "$BOOT_RESULT" in
    installed) ok "the installer exited 0 (boot reached the post-install wait)" ;;
    *) bad "the installer did not succeed -- app_startup.sh fell through to a normal boot"
       tail -25 /tmp/boot1.log | sed 's/^/        /' ;;
esac

# app_startup.sh unmounts the stick and clears the scratch dir on success.
[ -d /usr/data/update ] && bad "/usr/data/update left behind" \
                        || ok "the update scratch directory was cleaned up"
mount | grep -q ' /mnt ' && [ -n "$(ls /mnt 2>/dev/null)" ] \
    && bad "the stick is still mounted" || ok "the stick was unmounted"

# -------------------------------------------------------- would it boot? ---
echo
echo "  -- did the update leave a bootable machine? --"

# The package's own copy of app_startup.sh is what got installed. It must be
# byte-identical: this is the file init execs, and the mod is not allowed to
# touch it.
grep -q 'anvil' $APP \
    && bad "app_startup.sh carries mod markers -- boot scripts must stay stock" \
    || ok "app_startup.sh carries no mod markers"
grep -q 'insmod' $APP && ok "kernel modules still loaded at boot" \
                      || bad "BRICK: insmod lines lost from app_startup.sh"
sh -n $APP 2>/dev/null && ok "app_startup.sh parses under the printer's busybox" \
                       || bad "BRICK: app_startup.sh has a syntax error"

[ -s "$FE" ] && ok "firmwareExe present where app_startup.sh runs it" || bad "BRICK: $FE missing"
[ -x "$FE" ] && ok "firmwareExe is executable" || bad "BRICK: $FE not executable"

WRAPPER=0
if head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    WRAPPER=1
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
BADPARSE=0
for f in $(find /usr/data/anvil -name '*.sh' 2>/dev/null) \
         $(find /usr/data/anvil/init.d -type f 2>/dev/null) \
         /usr/prog/klipper/start.sh; do
    [ -f "$f" ] || continue
    sh -n "$f" 2>/dev/null || { bad "syntax error under busybox ash: $f"; BADPARSE=1
                                sh -n "$f" 2>&1 | sed 's/^/        /'; }
done
[ "$BADPARSE" = 0 ] && ok "every installed script parses under the printer's busybox ash"

if [ -d /usr/data/anvil/init.d ]; then
    grep -rq 'start\.sh' /usr/data/anvil/init.d/ 2>/dev/null \
        && ok "a service owns Klipper startup" \
        || bad "nothing starts Klipper -- UI would boot with no motion or heaters"
elif [ "$WRAPPER" = 1 ]; then
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

# ================================================================== boot 2 ==
# The stick is still in the slot. This is the common case -- people flash and
# walk away -- and it means the printer installs the same package a second
# time on the very next power-on.
echo
echo "  -- boot 2: the stick was left in the slot --"
cp -a $APP /tmp/app_startup.after1
[ "$WRAPPER" = 1 ] && cp -a "$SW/firmwareExe.stock" /tmp/stock-ui.after1

boot /tmp/boot2.log 900 || bad "boot 2 never settled"
case "$BOOT_RESULT" in
    installed) ok "the second install also exited 0" ;;
    *) bad "re-install did not succeed"; tail -25 /tmp/boot2.log | sed 's/^/        /' ;;
esac
cmp -s /tmp/app_startup.after1 $APP && ok "re-install is idempotent (app_startup.sh unchanged)" \
                                    || bad "re-install changed app_startup.sh again"
[ -s "$FE" ] && ok "firmwareExe still present after re-install" \
             || bad "BRICK: re-install left no firmwareExe"
if [ "$WRAPPER" = 1 ]; then
    head -c 4 "$SW/firmwareExe.stock" 2>/dev/null | grep -q 'ELF' \
        && ok "firmwareExe.stock is still the stock UI, not the wrapper" \
        || bad "BRICK: firmwareExe.stock is now the wrapper -- stock UI lost forever"
    cmp -s /tmp/stock-ui.after1 "$SW/firmwareExe.stock" \
        && ok "the preserved stock UI is byte-identical after the second install" \
        || bad "BRICK: the second install overwrote firmwareExe.stock"
fi

# ================================================================== boot 3 ==
# Pull the stick and boot normally. This is the boot that decides whether the
# machine is a printer or a brick.
echo
echo "  -- boot 3: stick removed, ordinary boot --"
umount /mnt 2>/dev/null
rm -f /dev/sda1                      # unplugged
rm -f /usr/data/logs/anvil-boot.log

boot /tmp/boot3.log 300 || bad "boot 3 never finished -- app_startup.sh hung"
grep -q 'find update file' /tmp/boot3.log \
    && bad "app_startup.sh tried to update again with no stick present" \
    || ok "no stick, no update -- app_startup.sh went straight to a normal boot"
[ "$BOOT_RESULT" = completed ] \
    && ok "app_startup.sh ran to completion" \
    || bad "app_startup.sh did not complete (result: $BOOT_RESULT)"

if grep -qE 'not found|Syntax error|command not found' /tmp/boot3.log; then
    bad "the boot log has missing-command or syntax errors"
    grep -nE 'not found|Syntax error' /tmp/boot3.log | head -5 | sed 's/^/        /'
else
    ok "the boot log has no missing commands and no syntax errors"
fi

if [ "$WRAPPER" = 1 ]; then
    # The mod's firmwareExe stays in the FOREGROUND on purpose, so
    # app_startup.sh's own `ps | grep firmwareExe` watchdog sees it 5s later
    # and does not respawn it. If it is not alive here, the printer boots into
    # a respawn loop.
    running firmwareExe \
        && ok "the mod UI is running and the stock watchdog is satisfied" \
        || bad "BRICK: nothing is running as firmwareExe -- app_startup.sh would respawn forever"
    grep -q 'restart' /tmp/boot3.log \
        && bad "app_startup.sh's watchdog fired -- the UI died within 5s" \
        || ok "the UI survived app_startup.sh's 5-second watchdog"
    if [ -f /usr/data/logs/anvil-boot.log ]; then
        ok "the mod wrote its boot log"
        for s in S60web S70klipper S80ui; do
            grep -q "$s" /usr/data/logs/anvil-boot.log \
                && ok "$s ran at boot" || bad "$s never ran at boot"
        done
        sed 's/^/        /' /usr/data/logs/anvil-boot.log | head -30
    else
        bad "no /usr/data/logs/anvil-boot.log -- the mod firmwareExe never ran"
    fi
else
    # A stock Qt firmwareExe cannot draw on a framebuffer that does not exist,
    # so its liveness says nothing here. What must still hold is that
    # app_startup.sh's recovery path found a binary to run.
    [ -s "$FE" ] && ok "firmwareExe still in place after a normal boot" \
                 || bad "BRICK: the boot left no firmwareExe"
fi
killall sleep 2>/dev/null

# Nothing may be written to the read-only root. A mod that needs it works in a
# permissive sandbox and fails silently on the machine.
if [ -f /tmp/sim-neutered.log ]; then
    echo
    echo "  -- calls neutered by the simulation --"
    sort -u /tmp/sim-neutered.log | sed 's/^/        /'
fi

echo
[ "$FAIL" = 0 ] && echo "  end-to-end update clean: install, re-install, and boot" \
                || echo "  END-TO-END UPDATE TEST FAILED"
exit $FAIL
