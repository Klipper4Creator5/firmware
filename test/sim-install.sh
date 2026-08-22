#!/usr/bin/env bash
# The core anti-brick test: run the installer against a fake printer and
# assert the machine would still boot.
#
# Runs in a container with a modelled printer filesystem, so it works in CI
# with no proprietary firmware. The stock installer gates on `uname -m` =
# mips, which is stubbed here; running the payload under the printer's real
# MIPS busybox is test/test-ash-conformance.sh's job.
set -uo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
PKG="${1:?usage: sim-install.sh <package.tgz>}"
KEY="${FF_KEY:-FFP0331&*%root}"
IMAGE="${SIM_IMAGE:-debian:bookworm-slim}"

DOCKER=docker
command -v docker >/dev/null 2>&1 || DOCKER=docker.exe
command -v $DOCKER >/dev/null 2>&1 || { echo "  SKIP: docker not available"; exit 0; }
$DOCKER info >/dev/null 2>&1 || { echo "  SKIP: docker daemon not running"; exit 0; }

PKG_ABS="$(cd "$(dirname "$PKG")" && pwd)/$(basename "$PKG")"
# The installer itself is arch-neutral shell, so it is exercised here in a
# Debian container with a modelled printer filesystem. The printer's REAL
# busybox ash is used separately by test/test-ash-conformance.sh to parse
# every payload script -- that is where MIPS/busybox fidelity comes from.

$DOCKER run --rm -i \
    -v "$PKG_ABS:/pkg.tgz:ro" \
    -e "FF_KEY=$KEY" \
    "$IMAGE" sh -s <<'INNER'
set -u
FAIL=0
ok()  { printf '  \033[32mPASS\033[0m  %s\n' "$*"; }
bad() { printf '  \033[31mFAIL\033[0m  %s\n' "$*"; FAIL=1; }

export DEBIAN_FRONTEND=noninteractive
apt-get update -qq >/dev/null 2>&1
apt-get install -y -qq openssl xz-utils >/dev/null 2>&1

mkdir -p /usr/prog/bin /usr/prog/etc /usr/prog/modules \
         /usr/prog/klipper/klippy/extras /usr/prog/klipper/klippy/kinematics \
         /usr/prog/nginx/sbin /usr/prog/nginx/conf \
         /usr/prog/PROGRAM/software/1.9.7 \
         /usr/data/config /usr/data/logs /usr/data/update /mnt

cat > /usr/prog/app_startup.sh <<'A'
#!/bin/sh
# STOCK app_startup marker
insmod /usr/prog/modules/gt9xx_touch.ko gtp_max_touch_number=2
/usr/prog/PROGRAM/software/firmwareExe &
sleep 5
A
cat > /usr/prog/klipper/start.sh <<'A'
#!/bin/sh
# STOCK start.sh marker
/usr/prog/klipper/klipperDaemon start
#/usr/prog/nginx/sbin/nginx -p /usr/prog/nginx -c /usr/prog/nginx/conf/nginx.conf
#/usr/prog/klipper/moonrakerDaemon start
A
printf 'root:x:0:0:root:/root:/bin/sh\n'                        > /usr/prog/etc/passwd
printf 'root:$1$stockstock$aaaaaaaaaaaaaaaaaaaaa0:20603::::::\n'> /usr/prog/etc/shadow
printf 'STOCK-FIRMWAREEXE\n' > /usr/prog/PROGRAM/software/firmwareExe
chmod +x /usr/prog/PROGRAM/software/firmwareExe
printf 'STOCK-FIRMWAREEXE\n' > /usr/prog/PROGRAM/software/1.9.7/firmwareExe
printf '# stock klippy\n'    > /usr/prog/klipper/klippy/klippy.py
printf 'USER-CONFIG-MUST-SURVIVE\n' > /usr/data/config/printer.cfg
: > /usr/prog/nginx/conf/mime.types
printf 'events{}\n' > /usr/prog/nginx/conf/nginx.conf
touch /usr/prog/nginx/sbin/nginx; chmod +x /usr/prog/nginx/sbin/nginx
chmod +x /usr/prog/app_startup.sh /usr/prog/klipper/start.sh

mkdir -p /usr/local/bin
for c in insmod reboot chrt start-stop-daemon killall pgrep cmd_mcu \
         checkEboard klipperDaemon moonrakerDaemon dropbear dropbearkey; do
    printf '#!/bin/sh\nexit 0\n' > /usr/local/bin/$c; chmod +x /usr/local/bin/$c
done
printf '#!/bin/sh\nexit 0\n' > /usr/prog/klipper/klipperDaemon
printf '#!/bin/sh\nexit 0\n' > /usr/prog/klipper/moonrakerDaemon
printf '#!/bin/sh\nexit 0\n' > /usr/prog/klipper/checkEboard
chmod +x /usr/prog/klipper/*Daemon /usr/prog/klipper/checkEboard
# MODEL fidelity only: the stock installer gates on `uname -m` = mips.
printf '#!/bin/sh\n[ "$1" = "-m" ] && { echo mips; exit 0; }\nexec /bin/uname "$@"\n' > /usr/local/bin/uname
chmod +x /usr/local/bin/uname
export PATH=/usr/local/bin:$PATH

cp /pkg.tgz "/mnt/Creator5Pro-test.tgz"
cp /usr/prog/app_startup.sh /tmp/stock_app_startup

if openssl des3 -d -k "$FF_KEY" -salt -md md5 -in /pkg.tgz 2>/dev/null \
     | tar -xf - -C /usr/data/update; then
    ok "decrypted into /usr/data/update (unTar path)"
else
    bad "decrypt failed -- the printer's unTar would reject this"; exit 1
fi

chmod +x /usr/data/update/runFirmwareExe.sh 2>/dev/null
/usr/data/update/runFirmwareExe.sh Creator5Pro 0029 >/tmp/install.log 2>&1
RC=$?
if [ $RC -eq 0 ]; then ok "installer exited 0"
else bad "installer exited $RC"; tail -25 /tmp/install.log | sed 's/^/        /'; fi

echo
echo "  -- would the printer still boot? --"

mkdir -p /tmp/ref && tar -xf /usr/data/update/software-*.tar.xz -C /tmp/ref ./app_startup.sh 2>/dev/null
if [ -f /tmp/ref/app_startup.sh ] && diff -q /tmp/ref/app_startup.sh /usr/prog/app_startup.sh >/dev/null 2>&1; then
    ok "app_startup.sh matches the package's own copy (not modified by the mod)"
else
    bad "app_startup.sh differs from the package copy"
fi
grep -q 'c5mod' /usr/prog/app_startup.sh \
    && bad "app_startup.sh carries mod markers -- boot scripts should be untouched" \
    || ok "app_startup.sh carries NO mod markers (mod replaces firmwareExe instead)"
grep -q 'gt9xx_touch' /usr/prog/app_startup.sh \
    && ok "touchscreen driver still loaded" || bad "BRICK: gt9xx_touch insmod lost"

FE=/usr/prog/PROGRAM/software/firmwareExe
[ -s "$FE" ] && ok "firmwareExe present where app_startup.sh runs it" || bad "BRICK: $FE missing"
[ -x "$FE" ] && ok "firmwareExe is executable" || bad "BRICK: $FE not executable"
if head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    sh -n "$FE" && ok "firmwareExe wrapper is valid shell" || bad "BRICK: wrapper syntax error"
    [ -s /usr/prog/PROGRAM/software/firmwareExe.stock ] \
        && ok "original firmwareExe preserved as firmwareExe.stock" \
        || bad "BRICK: wrapper installed but the stock UI binary is gone"
fi

if [ -d /usr/data/mod/init.d ]; then
    grep -rq 'start\.sh' /usr/data/mod/init.d/ 2>/dev/null \
        && ok "a service owns Klipper startup (start.sh is invoked)" \
        || bad "nothing starts Klipper -- UI would boot with no motion/heaters"
elif head -c 2 "$FE" 2>/dev/null | grep -q '#!'; then
    bad "firmwareExe replaced but no service dir exists to start Klipper"
else
    ok "no mod payload and stock firmwareExe intact (probe profile)"
fi

[ -f /usr/prog/klipper/klippy/klippy.py ] && ok "klippy.py present" || bad "klippy.py missing"
grep -q 'USER-CONFIG-MUST-SURVIVE' /usr/data/config/printer.cfg 2>/dev/null \
    && ok "user printer.cfg preserved" || bad "user printer.cfg was clobbered"

if [ -d /usr/data/mod/backup ]; then
    n=$(find /usr/data/mod/backup -type f | wc -l)
    [ "$n" -gt 0 ] && ok "installer wrote $n backup file(s)" || bad "backup dir empty"
    [ -d /usr/data/mod/backup/stock ] && ok "pristine snapshot at backup/stock" || bad "no pristine snapshot"
fi

for f in /usr/data/mod/init.d/S60web /usr/data/mod/init.d/S70klipper \
         /usr/data/mod/init.d/S80ui /usr/prog/klipper/start.sh; do
    [ -f "$f" ] || continue
    sh -n "$f" 2>/dev/null && ok "valid shell: $f" || bad "syntax error in $f"
done

cp /usr/prog/app_startup.sh /tmp/after1
rm -rf /usr/data/update; mkdir -p /usr/data/update
openssl des3 -d -k "$FF_KEY" -salt -md md5 -in /pkg.tgz 2>/dev/null | tar -xf - -C /usr/data/update
/usr/data/update/runFirmwareExe.sh Creator5Pro 0029 >/tmp/install2.log 2>&1
diff -q /tmp/after1 /usr/prog/app_startup.sh >/dev/null 2>&1 \
    && ok "re-install is idempotent" \
    || { bad "re-install changed app_startup.sh again"; diff /tmp/after1 /usr/prog/app_startup.sh | head -8 | sed 's/^/        /'; }

echo
[ "$FAIL" = 0 ] && echo "  install simulation clean" || echo "  INSTALL SIMULATION FAILED"
exit $FAIL
INNER
