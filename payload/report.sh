# Diagnostic report. Runs on the printer during install and writes everything
# we need to know to /mnt (the USB stick), which is still mounted at this
# point -- app_startup.sh unmounts it only after runFirmwareExe.sh returns.
#
# Read this BEFORE flashing anything that modifies the machine: it tells you
# the real partition sizes, what is already installed, and whether the whole
# decrypt -> md5 -> run.sh chain works on your unit.
REPORT=/mnt/c5mod-report.txt
{
    echo "=== c5mod report ==="
    echo "date:    `date 2>/dev/null`"
    echo "machine: `uname -a`"
    echo "args:    $*"
    echo
    echo "--- free space (the number that decides what fits) ---"
    df -h 2>/dev/null || df
    echo
    echo "--- mounts (a mount named like a mod blocks factory restore) ---"
    mount
    echo
    echo "--- partitions ---"
    /sbin/fdisk -l /dev/mmcblk0 2>/dev/null | head -30
    echo
    echo "--- installed component versions ---"
    for c in software library kernel control; do
        echo "  $c: `ls -1 /usr/prog/PROGRAM/$c 2>/dev/null | tr '\n' ' '`"
    done
    echo
    echo "--- does the web stack really ship on stock? ---"
    echo "  nginx binary : `[ -x /usr/prog/nginx/sbin/nginx ] && echo yes || echo NO`"
    echo "  nginx conf   : `[ -f /usr/prog/nginx/conf/nginx.conf ] && echo yes || echo NO`"
    echo "  moonraker    : `[ -f /usr/prog/moonraker/moonraker/moonraker/moonraker.py ] && echo yes || echo NO`"
    echo "  moonrakerDmn : `[ -x /usr/prog/klipper/moonrakerDaemon ] && echo yes || echo NO`"
    echo "  python3      : `/usr/prog/Python-3.8.2/bin/python3 -V 2>&1`"
    echo "  xz           : `command -v xz || echo NO`"
    echo
    echo "--- nginx.conf (needed to know the stock docroot/ports) ---"
    cat /usr/prog/nginx/conf/nginx.conf 2>/dev/null | head -60
    echo
    echo "--- INIT SYSTEM (decides how we should start services) ---"
    echo "  PID 1        : `cat /proc/1/comm 2>/dev/null` (`readlink /proc/1/exe 2>/dev/null`)"
    echo "  systemctl    : `command -v systemctl || echo NO`"
    echo "  /etc/inittab : `[ -f /etc/inittab ] && echo yes || echo NO`"
    echo "  /etc/init.d  : `[ -d /etc/init.d ] && echo yes || echo NO`"
    echo "  start-stop-daemon: `command -v start-stop-daemon || echo NO`"
    echo
    echo "  ### /etc/inittab"
    cat /etc/inittab 2>/dev/null
    echo "  ### ls /etc/init.d"
    ls -la /etc/init.d 2>/dev/null
    echo "  ### /etc/init.d/rcS"
    cat /etc/init.d/rcS 2>/dev/null | head -40
    echo "  ### what invokes app_startup.sh"
    grep -rl "app_startup" /etc /usr/prog/bin 2>/dev/null | head
    grep -rn "app_startup" /etc/inittab /etc/init.d/* 2>/dev/null | head
    echo
    echo "  ### running processes at install time"
    ps 2>/dev/null | head -40
    echo
    echo "--- klipper ---"
    echo "  chelper: `ls -l /usr/prog/klipper/klippy/chelper/c_helper.so 2>/dev/null`"
    echo "  extras : `ls -1 /usr/prog/klipper/klippy/extras 2>/dev/null | wc -l` modules"
    echo
    echo "--- existing config on the data partition ---"
    ls -la /usr/data/config 2>/dev/null
    echo
    echo "--- stock boot scripts (so we can diff our patched versions) ---"
    echo "### /usr/prog/app_startup.sh"; cat /usr/prog/app_startup.sh 2>/dev/null
    echo "### /usr/prog/klipper/start.sh"; cat /usr/prog/klipper/start.sh 2>/dev/null
    echo
    echo "=== end of report ==="
} > "$REPORT" 2>&1
sync

# Copy the stock nginx conf out too -- we need it verbatim to build a correct
# Mainsail vhost, and it is not in any update package.
cp -f /usr/prog/nginx/conf/nginx.conf /mnt/c5mod-stock-nginx.conf 2>/dev/null
# The whole /etc, so the init layout can be studied offline instead of
# guessed at. It is a few hundred KB and answers the init.d-vs-custom
# question definitively.
tar -cf /mnt/c5mod-stock-etc.tar /etc 2>/dev/null
tar -cf /mnt/c5mod-stock-bootscripts.tar \
    /usr/prog/app_startup.sh /usr/prog/klipper/start.sh \
    /usr/prog/etc/passwd /usr/prog/etc/shadow 2>/dev/null
sync
