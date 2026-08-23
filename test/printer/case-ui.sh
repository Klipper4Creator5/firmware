#!/bin/sh
# Exercise the UI decision and crash-protection logic on the printer's own
# shell.
#
# This matters because FlashForge's firmwareExe is retired in favour of
# HelixScreen and there is nothing to fall back to. A UI failure must not cost
# you the machine: ssh comes from the stock /etc/init.d/S50dropbear and is
# unaffected, and the mod has to go headless rather than crash-loop.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }
MOD=/usr/data/anvil
SWD=/usr/prog/PROGRAM/software

setup() {   # $1=helix installed?
    killall sleep 2>/dev/null
    rm -rf $MOD $SWD
    mkdir -p $MOD/init.d $MOD/helixscreen/bin /usr/data/logs $SWD
    cp /tmp/payload/init.d/S* $MOD/init.d/; chmod +x $MOD/init.d/S*
    printf 'MOD_WEB=0\nMOD_SSH=1\n' > $MOD/anvil.conf
    [ "$1" = yes ] && { printf '#!/bin/sh\nsleep 300\n' > $MOD/helixscreen/bin/helix-launcher.sh
                        chmod +x $MOD/helixscreen/bin/helix-launcher.sh; }
    return 0
}
choice() { cat $MOD/.ui-choice 2>/dev/null; }
run_ui() { $MOD/init.d/S80ui start >/tmp/ui.out 2>&1; }

echo "  case 1: helix installed"
setup yes; run_ui
[ "$(choice)" = helix ] && ok "chose helix" || bad "chose '$(choice)', expected helix"

echo
echo "  case 2: helix NOT installed -- headless, not a blank crash loop"
setup no; run_ui
[ "$(choice)" = none ] && ok "chose none" || bad "chose '$(choice)', expected none"
grep -q 'headless' /tmp/ui.out && ok "headless state reported" || bad "headless state not reported"

echo
echo "  case 3: repeated short boots latch SAFE-MODE"
setup yes
echo 3 > $MOD/ui-failures
run_ui
[ -f $MOD/SAFE-MODE ] && ok "SAFE-MODE latched" || bad "SAFE-MODE not latched"
[ "$(choice)" = none ] && ok "SAFE-MODE means no UI at all" || bad "chose '$(choice)', expected none"

echo
echo "  case 4: SAFE-MODE is honoured on the next boot"
rm -f $MOD/ui-failures
run_ui
[ "$(choice)" = none ] && ok "still headless while SAFE-MODE is latched" || bad "SAFE-MODE ignored"
grep -q "$MOD/SAFE-MODE" /tmp/ui.out && ok "the log says which file to delete" \
                                     || bad "the log never names the SAFE-MODE file"
rm -f $MOD/SAFE-MODE
run_ui
[ "$(choice)" = helix ] && ok "clearing SAFE-MODE re-enables helix" \
                        || bad "still '$(choice)' after clearing SAFE-MODE"

echo
echo "  case 5: the wrapper holds the foreground even with no UI"
setup no; run_ui
cp /tmp/payload/firmwareExe $SWD/firmwareExe; chmod +x $SWD/firmwareExe
# The printer's busybox has no `timeout` applet, so hold-and-check by hand.
sh $SWD/firmwareExe >/dev/null 2>&1 &
WPID=$!
sleep 5
if kill -0 $WPID 2>/dev/null; then
    ok "wrapper HOLDS the process instead of exiting (no respawn loop)"
    kill $WPID 2>/dev/null
else
    bad "wrapper exited -- app_startup.sh would respawn it forever"
fi

echo
echo "  case 6: Klipper is started independently of the UI"
setup yes
mkdir -p /usr/prog/klipper
printf '#!/bin/sh\ntouch /tmp/klipper-started\nsleep 60\n' > /usr/prog/klipper/start.sh
chmod +x /usr/prog/klipper/start.sh
rm -f /tmp/klipper-started
$MOD/init.d/S70klipper start >/dev/null 2>&1
sleep 2
[ -f /tmp/klipper-started ] \
    && ok "S70klipper starts Klipper without firmwareExe" \
    || bad "Klipper never started -- a UI swap would leave the printer unable to print"
killall sleep 2>/dev/null

echo
[ "$FAIL" = 0 ] && echo "  UI decision and crash protection behave correctly" \
                || echo "  UI SAFETY TESTS FAILED"
exit $FAIL
