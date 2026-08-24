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
        rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen $MODDIR/config $MODDIR/moonraker
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

# ---- Moonraker -------------------------------------------------------------
# Replace the stock 2022 Moonraker with the one bin/patch.sh staged. Only the
# python package is swapped -- the interpreter, the moonraker-env beside it and
# moonrakerDaemon are FlashForge's and keep working, because the version we
# ship runs on the libraries already installed. See bin/patch.sh for why that
# is true and why this is the only way the camera can appear in Mainsail.
#
# This is the one thing the mod writes to /usr/prog that is not part of the
# software component, so it is done defensively: the old tree is moved aside
# rather than deleted, and put back if the copy does not complete. A printer
# whose Moonraker did not survive an update has no web UI at all, and the
# screen would be the only way to notice.
if [ -d $MODDIR/moonraker ]; then
    MRROOT=/usr/prog/moonraker/moonraker
    if [ -d $MRROOT/moonraker ]; then
        # Both trees exist at once during the swap; /usr/prog is the small
        # firmware partition, so check there is room before starting.
        NEED=`du -sk $MODDIR/moonraker | cut -f1`
        FREE=`df /usr/prog | tail -1 | tr -s ' ' | cut -d' ' -f4`
        # PRE-FLIGHT: ask THIS printer's python whether it can load the tree
        # before anything is moved. moonraker-preflight.py explains what it
        # imports and why; the short version is that it uses Moonraker's own
        # component list rather than one we maintain here, because a
        # hand-written list already missed the component that mattered once.
        #
        # The library path is set explicitly rather than inherited. At boot
        # app_startup.sh exports a dozen /usr/prog/*/lib directories and
        # everything inherits them, but this script also has to behave when it
        # is re-run by hand from ssh, where none of that is set -- and a check
        # that fails for a missing libsodium would condemn a perfectly good
        # build. Same list app_startup.sh uses.
        MRPY=/usr/prog/Python-3.8.2/bin/python3
        MRIMP=0
        if [ -x $MRPY ] && [ -f $MODDIR/moonraker-preflight.py ]; then
            (
                PATH=$PATH:/usr/prog/Python-3.8.2/bin
                for d in /usr/prog/Python-3.8.2/lib /usr/prog/openssl-1.0.2d/lib \
                         /usr/prog/curl-7.55.1/lib /usr/prog/ffmpeg-402/lib \
                         /usr/prog/x264/lib /usr/prog/libffi-3.4.4/lib \
                         /usr/prog/libsodium/lib /usr/prog/opencv-4.2/lib \
                         /usr/prog/nim/lib /usr/prog/libzip-1.10.1/lib; do
                    [ -d "$d" ] && LD_LIBRARY_PATH="$d:$LD_LIBRARY_PATH"
                done
                export PATH LD_LIBRARY_PATH
                $MRPY $MODDIR/moonraker-preflight.py $MODDIR /usr/data/config/moonraker.conf
            ) > /tmp/mr-import.log 2>&1 || MRIMP=1
            sed 's/^/   /' /tmp/mr-import.log 2>/dev/null | tail -12
        fi
        if [ "$MRIMP" != 0 ]; then
            echo "!! moonraker: the shipped tree does not load on this printer -- keeping the stock one"
            echo "   (nothing was moved; the web UI is unaffected)"
        elif [ "${FREE:-0}" -lt "$NEED" ]; then
            echo "!! moonraker: only ${FREE}KB free on /usr/prog, need ${NEED}KB -- keeping the stock tree"
        else
            rm -rf $MRROOT/moonraker.modold
            if mv $MRROOT/moonraker $MRROOT/moonraker.modold; then
                if cp -a $MODDIR/moonraker $MRROOT/moonraker; then
                    sync
                    # Bytecode from the FlashForge build would otherwise be
                    # the first thing imported. Same trap as klippy below.
                    find $MRROOT/moonraker -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
                    rm -rf $MRROOT/moonraker.modold
                    echo "moonraker: replaced with the mod's build"
                else
                    rm -rf $MRROOT/moonraker
                    mv $MRROOT/moonraker.modold $MRROOT/moonraker
                    echo "!! moonraker: copy failed -- rolled back to the stock tree"
                fi
            else
                echo "!! moonraker: could not move the stock tree aside -- left it alone"
            fi
        fi
    else
        echo "!! moonraker: no $MRROOT/moonraker on this printer -- nothing replaced"
    fi
    sync
fi

# ---- klipper + moonraker configs -------------------------------------------
# Every file here is one the mod ships (ff-*.cfg, moonraker.conf); printer.cfg
# is the user's and is never shipped, so it is never a candidate.
#
# Two rules, because the two kinds of file differ in whether the user has
# somewhere else to put a change.
#
# ff-*.cfg are OURS, and are overwritten every update, no questions asked.
# They are the mod's moving parts -- macros and sections that a release
# rewrites -- and Klipper hands the user a better seam than editing them:
# parsing is RawConfigParser(strict=False), so same-named sections MERGE, the
# last value of an option wins, and a redefined [gcode_macro] replaces the
# original. Overriding from printer.cfg AFTER the include therefore costs
# nothing and survives every flash, while an edit here is silently reverted by
# the next one. Each file says so in its own header. This also makes the
# shipped set the same on every printer, which is what makes a bug report
# mean anything.
#
# printer.base.cfg is on the same footing and needs no rule here: it installs
# to /usr/prog/klipper/config with the software component, which a flash
# replaces wholesale.
#
# moonraker.conf is KEPT when edited. It is not a Klipper config, there is no
# include-and-override seam for it, and a printer that is reached through a
# tuned trusted_clients or cors_domains block would lose that access on an
# update. So it still gets the compare-and-.mod-new dance: a file still
# byte-identical to the one the LAST package wrote is ours to update, one that
# differs is the user's to keep. $MODDIR/config-installed holds that
# last-written copy -- it is not in the rm -rf above, so it survives the
# payload swap and is refreshed only after the comparison below.
#
# Without that snapshot a config we own could only ever be written once: it
# exists on the second flash, so it would land as .mod-new forever and updates
# would silently never reach the printer.
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
        case "$b" in
        ff-*.cfg)
            # Ours. Overwrite and say so when it had drifted, so the log
            # explains where a local edit went.
            if [ -f "$live" ] && [ "`md5sum < "$live"`" != "`md5sum < "$f"`" ]; then
                echo "config: $b overwritten (mod-owned; override it from printer.cfg)"
            fi
            cp -f "$f" "$live"
            continue
            ;;
        esac
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

echo "mod installed `date 2>/dev/null`" > $MODDIR/VERSION
echo "=== mod install done ==="
sync
