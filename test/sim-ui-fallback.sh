#!/usr/bin/env bash
# Exercise the UI selection + crash-fallback logic.
#
# This matters because the plan is to retire FlashForge's firmwareExe in
# favour of HelixScreen. Once the stock UI no longer drives the screen, a UI
# failure must not cost you the machine -- ssh comes from the stock
# /etc/init.d/S50dropbear and is unaffected, and the mod must still fall back
# rather than crash-loop.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
IMAGE="${SIM_IMAGE:-debian:bookworm-slim}"
DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 0; }
$DOCKER info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 0; }

$DOCKER run --rm -i \
    -v "$ROOT/payload/init.d:/init.d:ro" \
    -v "$ROOT/payload/firmwareExe:/firmwareExe:ro" \
    "$IMAGE" sh -s <<'INNER'
set -u
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
MOD=/usr/data/mod
SWD=/usr/prog/PROGRAM/software

setup() {   # $1=helix installed?  $2=stock UI installed?  $3=MOD_UI
    rm -rf /usr/data /usr/prog
    mkdir -p $MOD/init.d $MOD/helixscreen/bin /usr/data/logs $SWD
    cp /init.d/S* $MOD/init.d/; chmod +x $MOD/init.d/S*
    printf 'MOD_UI=%s\nMOD_WEB=0\nMOD_SSH=1\n' "$3" > $MOD/mod.conf
    [ "$1" = yes ] && { printf '#!/bin/sh\nsleep 300\n' > $MOD/helixscreen/bin/helix-launcher.sh; chmod +x $MOD/helixscreen/bin/helix-launcher.sh; }
    [ "$2" = yes ] && { printf '#!/bin/sh\nsleep 300\n' > $SWD/firmwareExe.stock; chmod +x $SWD/firmwareExe.stock; }
}
choice() { cat $MOD/.ui-choice 2>/dev/null; }
# In production the firmwareExe wrapper redirects service output into
# mod-boot.log; here we capture it per-run.
run_ui() { $MOD/init.d/S80ui start >/tmp/ui.out 2>&1; }
LOG()    { cat /tmp/ui.out 2>/dev/null; }

echo "  case 1: helix installed and requested"
setup yes yes helix; run_ui
[ "$(choice)" = helix ] && ok "chose helix" || bad "chose '$(choice)', expected helix"

echo
echo "  case 2: helix requested but NOT installed"
setup no yes helix; run_ui
[ "$(choice)" = stock ] && ok "fell back to stock UI" || bad "chose '$(choice)', expected stock"

echo
echo "  case 3: repeated short boots latch SAFE-MODE"
setup yes yes helix
echo 3 > $MOD/ui-failures
run_ui
[ -f $MOD/SAFE-MODE ] && ok "SAFE-MODE latched" || bad "SAFE-MODE not latched"
[ "$(choice)" = stock ] && ok "forced to stock UI" || bad "chose '$(choice)', expected stock"

echo
echo "  case 4: SAFE-MODE is honoured on the next boot"
rm -f $MOD/ui-failures
run_ui
[ "$(choice)" = stock ] && ok "still stock while SAFE-MODE is latched" || bad "SAFE-MODE ignored"
rm -f $MOD/SAFE-MODE
run_ui
[ "$(choice)" = helix ] && ok "clearing SAFE-MODE re-enables helix" || bad "still '$(choice)' after clearing SAFE-MODE"

echo
echo "  case 5: NO UI AT ALL (the firmwareExe-is-retired scenario)"
setup no no helix; run_ui
LOG | grep -q 'headless' && ok "headless state reported" || bad "headless state not reported"
cp /firmwareExe $SWD/firmwareExe; chmod +x $SWD/firmwareExe
timeout 5 sh $SWD/firmwareExe >/dev/null 2>&1
rc=$?
[ $rc -eq 124 ] && ok "wrapper HOLDS the process instead of exiting (no respawn loop)" \
                || bad "wrapper exited rc=$rc -- app_startup.sh would respawn it forever"

echo
echo "  case 6: Klipper is started independently of the UI"
setup yes yes helix
printf '#!/bin/sh\ntouch /tmp/klipper-started\n' > /usr/prog/klipper_start_stub
mkdir -p /usr/prog/klipper
printf '#!/bin/sh\ntouch /tmp/klipper-started\nsleep 60\n' > /usr/prog/klipper/start.sh
chmod +x /usr/prog/klipper/start.sh
rm -f /tmp/klipper-started
$MOD/init.d/S70klipper start >/dev/null 2>&1
sleep 1
[ -f /tmp/klipper-started ] \
    && ok "S70klipper starts Klipper without firmwareExe" \
    || bad "Klipper never started -- a UI swap would leave the printer unable to print"

echo
[ "$FAIL" = 0 ] && echo "  UI selection and fallback behave correctly" || echo "  UI FALLBACK TESTS FAILED"
exit $FAIL
INNER
