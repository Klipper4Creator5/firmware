# Runs near the END of the stock run.sh, after it has installed its own
# files. Backups already happened in the pre-block at the top.
MODDIR=/usr/data/anvil
# Set by bin/patch.sh: 1 when MOD_SSH=1 but no ROOT_PW_HASH was baked in.
MOD_PW_AUTO=0
case "$MODDIR" in
    /usr/data/?*) ;;
    *) echo "refusing to run: MODDIR='$MODDIR' is not under /usr/data"; exit 0 ;;
esac
exec >>/usr/data/anvil-install.log 2>&1

# ---- the mod payload -------------------------------------------------------
# Shipped as anvil.tar.xz in the OUTER package, so it is already sitting on the
# data partition next to us (/usr/data/update). Never unpacked into /usr/prog:
# the firmware partition has no room for ~100MB of web UI.
MODTAR=""
for c in /usr/data/update/anvil.tar.xz /mnt/anvil.tar.xz $WORK_DIR/anvil.tar.xz; do
    [ -f "$c" ] && { MODTAR="$c"; break; }
done

if [ -n "$MODTAR" ]; then
    NEED=`ls -l "$MODTAR" | tr -s ' ' | cut -d' ' -f5`
    NEED=$((NEED / 1024 * 4))          # xz payload expands ~3-4x
    FREE=`df /usr/data | tail -1 | tr -s ' ' | cut -d' ' -f4`
    echo "mod payload: $MODTAR (need ~${NEED}KB, free ${FREE}KB)"
    if [ "${FREE:-0}" -lt "$NEED" ]; then
        echo "!! not enough space on /usr/data -- skipping mod payload"
    else
        # Keep user-editable state; replace everything we own.
        [ -f $MODDIR/anvil.conf ] && cp -f $MODDIR/anvil.conf /tmp/anvil.conf.keep
        rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen $MODDIR/config
        mkdir -p $MODDIR
        # Try xz first (FlashForge's own factory installer uses `xz -dc`, so
        # it exists), then fall back to plain tar in case a build shipped it
        # uncompressed.
        if xz -dc "$MODTAR" 2>/dev/null | tar -xf - -C $MODDIR; then
            echo "extracted (xz)"
        elif tar -xf "$MODTAR" -C $MODDIR; then
            echo "extracted (plain tar)"
        else
            echo "!! could not extract $MODTAR"
        fi
        [ -f /tmp/anvil.conf.keep ] && mv -f /tmp/anvil.conf.keep $MODDIR/anvil.conf
        chmod a+x $MODDIR/bin/* 2>/dev/null
        echo "mod payload installed"
    fi
else
    echo "!! no anvil.tar.xz found -- scripts only, no Mainsail/HelixScreen"
fi
sync

# ---- klipper + moonraker configs -------------------------------------------
# Every file here is one the mod ships (ff-*.cfg, moonraker.conf); printer.cfg
# is the user's and is never shipped, so it is never a candidate.
#
# Install what is missing. For what already exists the question is whether the
# user edited it: a file still byte-identical to the one the LAST package wrote
# is ours to update, and one that differs is theirs to keep. $MODDIR/config-installed
# holds that last-written copy -- it is not in the rm -rf above, so it survives
# the payload swap and is refreshed only after the comparison below.
#
# Without this, a config we own could only ever be written once: it exists on
# the second flash, so it would land as .mod-new forever and updates would
# silently never reach the printer.
#
# First install after this rule arrives has no config-installed, so an existing
# file is treated as edited -- .mod-new, the conservative answer.
if [ -d $MODDIR/config ]; then
    mkdir -p /usr/data/config
    for f in $MODDIR/config/*; do
        [ -f "$f" ] || continue
        b=`basename "$f"`
        live="/usr/data/config/$b"
        prev="$MODDIR/config-installed/$b"
        if [ ! -f "$live" ]; then
            cp -f "$f" "$live"
        elif [ -f "$prev" ] && [ "`md5sum < "$live"`" = "`md5sum < "$prev"`" ]; then
            cp -f "$f" "$live"
            echo "config: $b updated (was unmodified)"
        else
            cp -f "$f" "$live.mod-new"
            echo "config: $b kept -- new version left as $b.mod-new"
        fi
    done
    # Snapshot what we just shipped, for the NEXT update to compare against.
    rm -rf $MODDIR/config-installed
    mkdir -p $MODDIR/config-installed
    cp -f $MODDIR/config/* $MODDIR/config-installed/ 2>/dev/null
fi
sync

# Stale bytecode from the previous Klipper generation is a silent import-time
# landmine; the stock run.sh only clears four of the __pycache__ dirs.
find /usr/prog/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
sync

# ---- root password, chosen here when none was baked in ---------------------
# The normal path is ROOT_PW_HASH at build time: patch.sh writes that hash
# straight into the shadow file the package ships. When it is empty the
# package cannot carry a password -- one file is flashed by many people, so
# any baked-in default would be the SAME password on every printer. Pick a
# random one here instead, on the machine, and write it onto the USB stick we
# are being flashed from. Every printer gets a different password and it is
# never guessable from anything printed on the case.
#
# ORDER MATTERS: the password goes onto the stick and is read back BEFORE the
# printer starts accepting it. A password that was set but never landed on the
# stick is a locked-out printer, so if the write fails we change nothing at
# all and say so.
if [ "$MOD_PW_AUTO" = "1" ]; then
    PW=`tr -dc A-Za-z0-9 < /dev/urandom 2>/dev/null | head -c 14`
    H=""
    [ -n "$PW" ] && H=`mkpasswd -m sha512 "$PW" 2>/dev/null`
    case "$H" in
    '$6$'*)
        PWFILE=/mnt/anvil-password.txt
        {   echo "anvil -- the root password for this printer"
            echo
            echo "    ssh root@<printer-ip>"
            echo "    password: $PW"
            echo
            echo "Save it somewhere safe and delete this file."
            echo "To change it, run  passwd  on the printer."
        } > $PWFILE 2>/dev/null
        sync
        # Read it back off the stick: proves the write survived, not just that
        # the shell accepted the redirect.
        if grep -q "password: $PW" $PWFILE 2>/dev/null; then
            # /etc is a bind mount of /usr/prog/etc, so this IS the live file
            # dropbear authenticates against.
            awk -v h="$H" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
                /usr/prog/etc/shadow > /usr/prog/etc/shadow.new &&
                mv -f /usr/prog/etc/shadow.new /usr/prog/etc/shadow
            chmod 600 /usr/prog/etc/shadow
            echo "root password set (random -- see anvil-password.txt on the USB stick)"
        else
            rm -f $PWFILE 2>/dev/null
            echo "!! could not write the password to the USB stick"
            echo "!! root password left unchanged -- no ssh login"
        fi
        ;;
    *)  echo "!! could not generate a password hash -- root password unchanged" ;;
    esac
fi
sync

# ---- ssh host keys, once at install time -----------------------------------
if [ -x $MODDIR/bin/dropbearkey ]; then
    mkdir -p $MODDIR/etc/dropbear
    for t in rsa ecdsa ed25519; do
        [ -f $MODDIR/etc/dropbear/dropbear_${t}_host_key ] || \
            $MODDIR/bin/dropbearkey -t $t -f $MODDIR/etc/dropbear/dropbear_${t}_host_key
    done
fi
sync

echo "mod installed `date 2>/dev/null`" > $MODDIR/VERSION
echo "=== mod install done ==="
sync
