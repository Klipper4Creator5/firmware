#!/usr/bin/env bash
# Recovery test: install the mod, then flash the STOCK FlashForge package,
# and assert the printer is genuinely back to stock.
#
# This is the real recovery path, so it is the one worth testing. A stock
# package carries the pristine app_startup.sh, start.sh, passwd, shadow and
# firmwareExe, and its run.sh copies all of them into place -- which undoes
# every file the mod touches. Nothing bespoke is required.
#
# The mod's payload under /usr/data/mod survives, deliberately: once
# firmwareExe is the genuine binary again nothing reads it, so it is inert.
# The assertions below check exactly that -- inert, not absent.
#
#   ./test/sim-roundtrip.sh <mod.tgz> <stock.tgz>
set -uo pipefail
MOD="${1:?usage: sim-roundtrip.sh <mod.tgz> <stock.tgz>}"
STOCK="${2:?usage: sim-roundtrip.sh <mod.tgz> <stock.tgz>}"
KEY="${FF_KEY:-FFP0331&*%root}"
IMAGE="${SIM_IMAGE:-debian:bookworm-slim}"

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 0; }
$DOCKER info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 0; }

A="$(cd "$(dirname "$MOD")" && pwd)/$(basename "$MOD")"
B="$(cd "$(dirname "$STOCK")" && pwd)/$(basename "$STOCK")"

$DOCKER run --rm -i -v "$A:/mod.tgz:ro" -v "$B:/stock.tgz:ro" -e "FF_KEY=$KEY" \
    "$IMAGE" sh -s <<'INNER'
set -u
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }
export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1; apt-get install -y -qq openssl xz-utils >/dev/null 2>&1

mkdir -p /usr/prog/bin /usr/prog/etc /usr/prog/modules /usr/prog/klipper/klippy \
         /usr/prog/nginx/conf /usr/prog/PROGRAM/software /usr/data/config /usr/data/update /mnt
printf 'root:x:0:0:root:/root:/bin/sh\n' > /usr/prog/etc/passwd
printf 'root:$1$stock$aaaa:20603::::::\n' > /usr/prog/etc/shadow
printf 'PLACEHOLDER\n' > /usr/prog/PROGRAM/software/firmwareExe
chmod +x /usr/prog/PROGRAM/software/firmwareExe
printf 'USER-CONFIG-MUST-SURVIVE\n' > /usr/data/config/printer.cfg
: > /usr/prog/nginx/conf/mime.types
mkdir -p /usr/local/bin
for c in insmod reboot chrt start-stop-daemon killall pgrep cmd_mcu dropbear dropbearkey; do
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/$c; chmod +x /usr/local/bin/$c
done
printf '#!/bin/sh\n[ "$1" = "-m" ] && { echo mips; exit 0; }\nexec /bin/uname "$@"\n' > /usr/local/bin/uname
chmod +x /usr/local/bin/uname
export PATH=/usr/local/bin:$PATH

install_pkg() {
    rm -rf /usr/data/update; mkdir -p /usr/data/update
    openssl des3 -d -k "$FF_KEY" -salt -md md5 -in "$1" 2>/dev/null | tar -xf - -C /usr/data/update || return 1
    chmod +x /usr/data/update/runFirmwareExe.sh
    /usr/data/update/runFirmwareExe.sh Creator5Pro 0029 >>/tmp/inst.log 2>&1
}

# Reference copies of the genuine stock files, taken from the stock package.
mkdir -p /tmp/ref && cd /tmp/ref
openssl des3 -d -k "$FF_KEY" -salt -md md5 -in /stock.tgz 2>/dev/null | tar -xf - 2>/dev/null
mkdir -p /tmp/ref/sw && tar -xf /tmp/ref/software-*.tar.xz -C /tmp/ref/sw 2>/dev/null
cd /

install_pkg /mod.tgz && ok "mod installed" || bad "mod install failed"
FE=/usr/prog/PROGRAM/software/firmwareExe
head -c 2 "$FE" 2>/dev/null | grep -q '#!' \
    && ok "firmwareExe is the mod wrapper after install" \
    || bad "firmwareExe was not replaced -- nothing to recover from"
[ -d /usr/data/mod ] && ok "mod payload present after install" || bad "no mod payload"

echo
echo "  -- now flash the STOCK FlashForge package --"
install_pkg /stock.tgz && ok "stock package installed" || bad "stock package failed"

echo
echo "  -- back to stock? --"
if head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    bad "firmwareExe is still the mod wrapper -- stock reflash did not restore it"
else
    ok "firmwareExe is the genuine binary again"
fi
if [ -f /tmp/ref/sw/firmwareExe ] && cmp -s /tmp/ref/sw/firmwareExe "$FE"; then
    ok "firmwareExe matches the stock package byte-for-byte"
else
    bad "firmwareExe does not match the stock binary"
fi
for f in app_startup.sh; do
    if [ -f /tmp/ref/sw/$f ] && cmp -s /tmp/ref/sw/$f /usr/prog/$f; then
        ok "$f restored byte-for-byte"
    else
        bad "$f not restored"
    fi
done
if [ -f /tmp/ref/sw/start.sh ] && cmp -s /tmp/ref/sw/start.sh /usr/prog/klipper/start.sh; then
    ok "klipper/start.sh restored byte-for-byte"
else
    bad "klipper/start.sh not restored"
fi
grep -q '^/usr/prog/klipper/moonrakerDaemon start' /usr/prog/klipper/start.sh 2>/dev/null \
    && bad "start.sh still has the mod's uncommented moonraker line" \
    || ok "start.sh web-stack lines are commented out again (stock state)"

# The payload is intentionally left behind. Prove it cannot do anything.
if [ -d /usr/data/mod ]; then
    ok "mod payload left on the data partition (expected)"
    grep -rq 'c5mod\|/usr/data/mod' /usr/prog/app_startup.sh /usr/prog/klipper/start.sh 2>/dev/null \
        && bad "a stock boot script still references the mod -- payload is NOT inert" \
        || ok "no stock boot script references it -- payload is inert"
fi

grep -q 'USER-CONFIG-MUST-SURVIVE' /usr/data/config/printer.cfg 2>/dev/null \
    && ok "user printer.cfg preserved through both flashes" \
    || bad "user printer.cfg was clobbered"

echo
[ "$FAIL" = 0 ] && echo "  recovery clean: a stock package fully reverts the mod" \
                || echo "  RECOVERY TEST FAILED"
exit $FAIL
INNER
