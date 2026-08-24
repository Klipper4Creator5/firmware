#!/bin/sh
# Recovery test: install the mod on a stock machine, then flash the genuine
# FlashForge package and assert the printer is really back to stock.
#
# Runs on the printer's own userland. /mnt/mod.tgz and /mnt/stock.tgz are the
# two packages; both are unpacked with the printer's unTar, exactly as
# app_startup.sh would.
#
# Unlike case-install.sh this calls the installer directly rather than booting
# through app_startup.sh. That is deliberate: what is under test here is what
# a stock package RESTORES, not how a package is discovered -- and discovery
# is already proven end-to-end next door. Driving two different packages
# through one boot script would mean swapping the contents of the stick
# between boots and relying on `ls -1t` ordering to pick the right one, which
# is a coin flip dressed up as a test.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

APP=/usr/prog/app_startup.sh
FE=/usr/prog/PROGRAM/software/firmwareExe
MACHINE=$(sed -n 's/^MACHINE=//p' $APP | head -n 1)
PID=$(sed -n 's/^PID=//p' $APP | head -n 1)
export PATH=/usr/prog/openssl-1.0.2d/bin:$PATH
export LD_LIBRARY_PATH=/usr/prog/openssl-1.0.2d/lib:$LD_LIBRARY_PATH

install_pkg() {
    rm -rf /usr/data/update; mkdir -p /usr/data/update
    cp -a "$1" /usr/data/pkg.tgz
    /usr/prog/bin/unTar /usr/data/pkg.tgz >/dev/null 2>&1
    rm -f /usr/data/pkg.tgz
    [ -f /usr/data/update/runFirmwareExe.sh ] || return 1
    chmod a+x /usr/data/update/runFirmwareExe.sh
    /usr/data/update/runFirmwareExe.sh "$MACHINE" "$PID" >> /tmp/inst.log 2>&1
}

# Reference copies of the genuine files, straight out of the stock package.
mkdir -p /tmp/ref/sw
cp -a /mnt/stock.tgz /usr/data/ref.tgz
rm -rf /usr/data/update; mkdir -p /usr/data/update
/usr/prog/bin/unTar /usr/data/ref.tgz >/dev/null 2>&1
tar -xf /usr/data/update/software-*.tar.xz -C /tmp/ref/sw 2>/dev/null
rm -f /usr/data/ref.tgz

install_pkg /mnt/mod.tgz && ok "mod installed" || bad "mod install failed"
head -c 2 "$FE" 2>/dev/null | grep -q '#!' \
    && ok "firmwareExe is the mod wrapper after install" \
    || bad "firmwareExe was not replaced -- nothing to recover from"
[ -d /usr/data/anvil ] && ok "mod payload present after install" || bad "no mod payload"

echo
echo "  -- now flash the STOCK FlashForge package --"
install_pkg /mnt/stock.tgz && ok "stock package installed" || bad "stock package failed"

echo
echo "  -- back to stock? --"
head -c 2 "$FE" 2>/dev/null | grep -q '#!' \
    && bad "firmwareExe is still the mod wrapper -- stock reflash did not restore it" \
    || ok "firmwareExe is the genuine binary again"
if [ -f /tmp/ref/sw/firmwareExe ] && cmp -s /tmp/ref/sw/firmwareExe "$FE"; then
    ok "firmwareExe matches the stock package byte-for-byte"
else
    bad "firmwareExe does not match the stock binary"
fi
if [ -f /tmp/ref/sw/app_startup.sh ] && cmp -s /tmp/ref/sw/app_startup.sh $APP; then
    ok "app_startup.sh restored byte-for-byte"
else
    bad "app_startup.sh not restored"
fi
if [ -f /tmp/ref/sw/start.sh ] && cmp -s /tmp/ref/sw/start.sh /usr/prog/klipper/start.sh; then
    ok "klipper/start.sh restored byte-for-byte"
else
    bad "klipper/start.sh not restored"
fi
grep -q '^/usr/prog/klipper/moonrakerDaemon start' /usr/prog/klipper/start.sh 2>/dev/null \
    && bad "start.sh still has the mod's uncommented moonraker line" \
    || ok "start.sh web-stack lines are commented out again (stock state)"

# The payload is deliberately left behind. Prove it cannot do anything.
if [ -d /usr/data/anvil ]; then
    ok "mod payload left on the data partition (expected)"
    grep -q 'anvil\|/usr/data/anvil' $APP /usr/prog/klipper/start.sh 2>/dev/null \
        && bad "a stock boot script still references the mod -- payload is NOT inert" \
        || ok "no stock boot script references it -- payload is inert"
fi

grep -q 'USER-CONFIG-MUST-SURVIVE' /usr/data/config/printer.cfg 2>/dev/null \
    && ok "user printer.cfg preserved through both flashes" \
    || bad "user printer.cfg was clobbered"

# The mod's Klipper config is wired in by printer.base.cfg, which the stock
# run.sh force-copies over on every flash. That is what makes the revert
# complete: the ff-*.cfg are left on the data partition (inert, like the rest
# of the payload) but nothing includes them any more. If a stock reflash left
# the includes behind, klippy would come up referencing [ff_toolchange] with
# the extras gone from /usr/prog -- a printer that will not start.
if grep -q '^\[include ff-' /usr/data/config/printer.base.cfg 2>/dev/null; then
    bad "printer.base.cfg still includes the mod's ff-*.cfg after a stock flash"
else
    ok "printer.base.cfg restored -- nothing includes the mod's config"
fi

echo
[ "$FAIL" = 0 ] && echo "  recovery clean: a stock package fully reverts the mod" \
                || echo "  RECOVERY TEST FAILED"
exit $FAIL
