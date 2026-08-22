#!/usr/bin/env bash
# Install the mod, then install the uninstall package, and assert the printer
# is back to stock. This is what makes the "you can always get back" claim
# testable rather than aspirational.
#
#   ./test/sim-roundtrip.sh <mod.tgz> <uninstall.tgz>
set -uo pipefail
MOD="${1:?usage: sim-roundtrip.sh <mod.tgz> <uninstall.tgz>}"
UNI="${2:?usage: sim-roundtrip.sh <mod.tgz> <uninstall.tgz>}"
KEY="${FF_KEY:-FFP0331&*%root}"
IMAGE="${SIM_IMAGE:-debian:bookworm-slim}"

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 0; }
$DOCKER info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 0; }

A="$(cd "$(dirname "$MOD")" && pwd)/$(basename "$MOD")"
B="$(cd "$(dirname "$UNI")" && pwd)/$(basename "$UNI")"

$DOCKER run --rm -i -v "$A:/mod.tgz:ro" -v "$B:/uninstall.tgz:ro" -e "FF_KEY=$KEY" \
    "$IMAGE" sh -s <<'INNER'
set -u
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq openssl xz-utils >/dev/null 2>&1

mkdir -p /usr/prog/bin /usr/prog/etc /usr/prog/modules /usr/prog/klipper/klippy \
         /usr/prog/nginx/conf /usr/prog/PROGRAM/software /usr/data/config /usr/data/update /mnt
cat > /usr/prog/app_startup.sh <<'A'
#!/bin/sh
# STOCK app_startup marker
insmod /usr/prog/modules/gt9xx_touch.ko
/usr/prog/PROGRAM/software/firmwareExe &
A
cat > /usr/prog/klipper/start.sh <<'A'
#!/bin/sh
# STOCK start.sh marker
#/usr/prog/klipper/moonrakerDaemon start
A
printf 'root:x:0:0:root:/root:/bin/sh\n' > /usr/prog/etc/passwd
printf 'root:$1$stockstock$aaaa:20603::::::\n' > /usr/prog/etc/shadow
printf 'STOCK-FIRMWAREEXE\n' > /usr/prog/PROGRAM/software/firmwareExe
printf '# stock klippy\n' > /usr/prog/klipper/klippy/klippy.py
: > /usr/prog/nginx/conf/mime.types
chmod +x /usr/prog/app_startup.sh /usr/prog/klipper/start.sh
mkdir -p /usr/local/bin
for c in insmod reboot chrt start-stop-daemon killall pgrep cmd_mcu dropbear dropbearkey; do
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/$c; chmod +x /usr/local/bin/$c
done
# The reference for "stock" is what the PACKAGE ships, not the file this test
# hand-wrote: the uninstall package reinstalls FlashForge's own component, so
# that is the correct end state.
mkdir -p /tmp/ref && cd /tmp/ref
openssl des3 -d -k "$FF_KEY" -salt -md md5 -in /uninstall.tgz 2>/dev/null | tar -xf - 2>/dev/null
mkdir -p /tmp/ref/sw && tar -xf /tmp/ref/software-*.tar.xz -C /tmp/ref/sw 2>/dev/null
cp /tmp/ref/sw/app_startup.sh /tmp/stock_app 2>/dev/null
cp /tmp/ref/sw/start.sh /tmp/stock_start 2>/dev/null
cd /

install_pkg() {
    rm -rf /usr/data/update; mkdir -p /usr/data/update
    openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$1" 2>/dev/null | tar -xf - -C /usr/data/update || return 1
    chmod +x /usr/data/update/runFirmwareExe.sh
    /usr/data/update/runFirmwareExe.sh Creator5Pro 0029 >>/tmp/inst.log 2>&1
}

install_pkg /mod.tgz && ok "mod installed" || bad "mod install failed"
FE=/usr/prog/PROGRAM/software/firmwareExe
head -c 2 "$FE" 2>/dev/null | grep -q '#!' \
    && ok "firmwareExe is the mod wrapper after install" \
    || bad "firmwareExe was not replaced -- nothing to uninstall"

install_pkg /uninstall.tgz && ok "uninstall package ran" || bad "uninstall package failed"

echo
echo "  -- back to stock? --"
if diff -q /tmp/stock_app /usr/prog/app_startup.sh >/dev/null 2>&1; then
    ok "app_startup.sh matches the stock file the package ships"
else
    bad "app_startup.sh does not match the shipped stock file"
    diff /tmp/stock_app /usr/prog/app_startup.sh | head -10 | sed 's/^/        /'
fi
grep -qE 'firmwareExe' /usr/prog/app_startup.sh \
    && ok "restored boot chain launches the stock UI" \
    || bad "BRICK: restored app_startup.sh launches no UI"
if head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    bad "firmwareExe is still the mod wrapper -- uninstall did not restore the binary"
else
    ok "firmwareExe is the genuine binary again"
fi
diff -q /tmp/stock_start /usr/prog/klipper/start.sh >/dev/null 2>&1 \
    && ok "start.sh matches the shipped stock file" || bad "start.sh not restored"
grep -q '^/usr/prog/klipper/moonrakerDaemon start' /usr/prog/klipper/start.sh \
    && bad "start.sh still has the mod's uncommented moonraker line" \
    || ok "start.sh web-stack lines are commented out again (stock state)"
sh -n /usr/prog/app_startup.sh 2>/dev/null && ok "restored app_startup.sh is valid shell" \
    || bad "restored app_startup.sh is broken"
[ -s /usr/prog/PROGRAM/software/firmwareExe ] \
    && ok "firmwareExe restored (the installer wipes this dir -- see make-uninstall.sh)" \
    || bad "BRICK: firmwareExe lost, printer would boot to a blank screen"
[ -d /usr/data/mod/backup ] && ok "backups kept for forensics" || ok "no backup dir (nothing was installed)"
[ -e /usr/data/mod/boot.sh ] && bad "mod boot.sh still present" || ok "mod payload removed"

echo
[ "$FAIL" = 0 ] && echo "  round-trip clean: mod installs and fully reverts" || echo "  ROUND-TRIP FAILED"
exit $FAIL
INNER
