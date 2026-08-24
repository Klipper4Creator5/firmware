#!/usr/bin/env bash
# Build a SYNTHETIC stand-in for a FlashForge update package.
#
# Why: the real firmware is proprietary and ~93MB, so it can never live in the
# repo or run in CI. This fixture reproduces the *structure* the build scripts
# depend on -- the DES3 wrapper, the plain-tar components, md5sum.list, and
# boot scripts with the same hook points -- using our own content. It lets the
# entire pipeline be exercised on a clean machine with no proprietary blobs.
#
# It is deliberately NOT a copy of FlashForge's scripts: only the structural
# contract is reproduced.
set -euo pipefail
OUT="${1:?usage: make-stock-fixture.sh <output-dir>}"
KEY='FFP0331&*%root'
VER="${FIXTURE_SW_VER:-1.9.7}"
# Real packages carry a model gate; the fixture must too, or the model checks
# have nothing to test against.
MACHINE="${FIXTURE_MACHINE:-Creator5Pro}"
case "$MACHINE" in
    Creator5Pro) PID=0029 ;;
    Creator5)    PID=0028 ;;
    *) echo "FIXTURE_MACHINE must be Creator5 or Creator5Pro" >&2; exit 1 ;;
esac

rm -rf "$OUT"; mkdir -p "$OUT/sw/klipper/klippy/chelper" "$OUT/sw/klipper/extras" \
                        "$OUT/sw/klipper/kinematics" "$OUT/sw/klipper/config" "$OUT/outer"

# --- a stand-in for app_startup.sh with the same hook points ----------------
cat > "$OUT/sw/app_startup.sh" <<A
#!/bin/sh
# FIXTURE stand-in for /usr/prog/app_startup.sh
WORK_DIR=/usr/prog
MACHINE=$MACHINE
PID=$PID
A
cat >> "$OUT/sw/app_startup.sh" <<'A' 

if [ ! -d /usr/prog/etc ]; then
        cp -rf /etc /usr/prog/
fi
mount /usr/prog/etc /etc

# (USB update scan lives here on the real device)

insmod /usr/prog/modules/gt9xx_touch.ko gtp_i2c_bus_num=0 gtp_max_touch_number=2

export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:$LD_LIBRARY_PATH

/usr/prog/bin/sys_start.sh &
chmod a+x /usr/prog/bin/mencoder

/usr/prog/PROGRAM/software/firmwareExe &
sleep 5

count=`ps |grep firmwareExe |grep -v "grep" |wc -l`
if [ 0 = "$count" ];then
	echo "restart"
	cd  /usr/prog/PROGRAM/software/
	SoftwareVer=`ls -d [0-9]* | head -n 1`
	cp /usr/prog/PROGRAM/software/$SoftwareVer/firmwareExe /usr/prog/PROGRAM/software/
	/usr/prog/PROGRAM/software/firmwareExe &
fi
A

cat > "$OUT/sw/start.sh" <<'A'
#!/bin/sh
# FIXTURE stand-in for /usr/prog/klipper/start.sh -- web stack commented out,
# exactly like stock.
/usr/prog/klipper/checkEboard
/usr/prog/klipper/klipperDaemon start
#/usr/prog/nginx/sbin/nginx -p /usr/prog/nginx -c /usr/prog/nginx/conf/nginx.conf
#/usr/prog/klipper/moonrakerDaemon start
A

cat > "$OUT/sw/run.sh" <<'A'
#!/bin/sh
# FIXTURE stand-in for the software component's run.sh
set -x
WORK_DIR=`dirname $0`
cp -f $WORK_DIR/app_startup.sh /usr/prog/
cp -f $WORK_DIR/start.sh /usr/prog/klipper/start.sh
cp -f $WORK_DIR/firmwareExe /usr/prog/PROGRAM/software/
cp -f $WORK_DIR/passwd /usr/prog/etc/passwd
cp -f $WORK_DIR/shadow /usr/prog/etc/shadow
cp $WORK_DIR/klipper/klippy/* /usr/prog/klipper/klippy/ -rf
cp $WORK_DIR/klipper/extras/* /usr/prog/klipper/klippy/extras/ -rf
tar -xf $WORK_DIR/klipper/chelper.tar -C /usr/prog/klipper/klippy/
cp $WORK_DIR/klipper/config/* /usr/data/config/ -rf
exit 0
A

cat > "$OUT/sw/klipper_pri.sh" <<'A'
#!/bin/sh
chrt -f -p 50 $(pgrep -f "klippy.py")
A
printf 'root:x:0:0:root:/root:/bin/sh\nnobody:x:65534:65534:nobody:/home:/bin/false\n' > "$OUT/sw/passwd"
printf 'root:$1$fixture$0000000000000000000000:20603::::::\nnobody:*:::::::\n' > "$OUT/sw/shadow"
printf '#!/bin/sh\nwhile true; do sleep 1; done\n' > "$OUT/sw/sys_start.sh"
printf '#!/bin/sh\necho freecache\n' > "$OUT/sw/freecach.sh"

# Fake "binaries": real content is proprietary; size/behaviour is irrelevant
# to the packaging logic under test.
head -c 200000 /dev/urandom > "$OUT/sw/firmwareExe"
head -c  20000 /dev/urandom > "$OUT/sw/unTar"
head -c  10000 /dev/urandom > "$OUT/sw/wakeup_level"
head -c  50000 /dev/urandom > "$OUT/sw/8821cu.ko"

for f in klippy.py toolhead.py mcu.py configfile.py; do
    printf '# fixture klippy file\n' > "$OUT/sw/klipper/klippy/$f"
done
printf '# fixture extra\n' > "$OUT/sw/klipper/extras/probe.py"
printf '# fixture kinematics\n' > "$OUT/sw/klipper/kinematics/corexy.py"
printf '[printer]\nkinematics: corexy\n' > "$OUT/sw/klipper/config/printer.base.cfg"
mkdir -p "$OUT/chelper/chelper"
head -c 30000 /dev/urandom > "$OUT/chelper/chelper/c_helper.so"
tar -cf "$OUT/sw/klipper/chelper.tar" -C "$OUT/chelper" chelper
rm -rf "$OUT/chelper"

chmod +x "$OUT/sw"/*.sh

# --- md5sum.list, exactly as the real installer expects ---------------------
( cd "$OUT/sw" && find . -type f ! -name md5sum.list -print0 | sort -z | xargs -0 md5sum > md5sum.list )

# --- components are PLAIN tar despite the .tar.xz name ----------------------
tar -cf "$OUT/outer/software-$VER.tar.xz" -C "$OUT/sw" .
head -c 4096 /dev/urandom > "$OUT/outer/start.img"
head -c 4096 /dev/urandom > "$OUT/outer/end.img"
head -c 2048 /dev/urandom > "$OUT/outer/play"

# --- a stand-in outer installer with the same component contract ------------
cat > "$OUT/outer/runFirmwareExe.sh" <<A
#!/bin/sh
# FIXTURE stand-in for the outer runFirmwareExe.sh
set -x
MACHINE=$MACHINE
PID=$PID
A
cat >> "$OUT/outer/runFirmwareExe.sh" <<'A'
WORK_DIR=`dirname $0`
RUN_DIR="/usr/prog/PROGRAM"
[ "`uname -m`" != "mips" ] && echo "arch check skipped in fixture"
update_component() {
    name="$1"
    cd $WORK_DIR || return 1
    f=`ls -1t ${name}-*.tar.xz 2>/dev/null | head -n 1`
    [ -n "$f" ] || return 0
    v=`echo "$f" | sed "s/^${name}-//; s/\.tar\.xz$//"`
    mkdir -p ${RUN_DIR}/${name}
    rm -rf ${RUN_DIR}/${name}/temp
    mkdir -p ${RUN_DIR}/${name}/temp
    tar -xf "$f" -C ${RUN_DIR}/${name}/temp || return 1
    cd ${RUN_DIR}/${name}/temp || return 1
    md5sum -s -c md5sum.list || md5sum --status -c md5sum.list || { cd ..; rm -rf temp; return 1; }
    cd ..
    ls | grep -v temp | xargs rm -rf 2>/dev/null
    mv temp "$v"
    [ -f "$v/run.sh" ] && { chmod a+x "$v/run.sh"; "${RUN_DIR}/${name}/${v}/run.sh"; }
    return 0
}
update_component software || exit 1
exit 0
A
chmod +x "$OUT/outer/runFirmwareExe.sh"

# --- wrap it the way the printer expects ------------------------------------
tar -cf - -C "$OUT/outer" . | openssl des3 -salt -md md5 -k "$KEY" 2>/dev/null \
    > "$OUT/${MACHINE}-stock-fixture.tgz"
rm -rf "$OUT/sw" "$OUT/outer"
echo "fixture package: $OUT/${MACHINE}-stock-fixture.tgz ($MACHINE/$PID)"
