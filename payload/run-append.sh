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
    NEED_KB=`ls -l "$MODTAR" | tr -s ' ' | cut -d' ' -f5`
    NEED_KB=$((NEED_KB / 1024 * 4))          # xz payload expands ~3-4x
    FREE_KB=`df /usr/data | tail -1 | tr -s ' ' | cut -d' ' -f4`
    echo "mod payload: $MODTAR (need ~${NEED_KB}KB, free ${FREE_KB}KB)"
    if [ "${FREE_KB:-0}" -lt "$NEED_KB" ]; then
        echo "!! not enough space on /usr/data -- skipping mod payload"
    else
        # Keep user-editable state; replace everything we own.
        [ -f $MODDIR/anvil.conf ] && cp -f $MODDIR/anvil.conf /tmp/anvil.conf.keep
        # init.d is in this list for a reason that only shows up on UPDATES.
        # Scripts here used to be overwritten in place and never removed, which
        # was harmless only while the set of filenames never changed. It does
        # change: S60web was split into S60nginx and S62moonraker, and on a
        # printer that already had the mod the old S60web would have survived
        # the update and sat next to both new scripts. firmwareExe runs every
        # executable $MODDIR/init.d/S* in filename order, so nginx and moonraker
        # would each have been started twice, by two scripts that disagree about
        # where moonraker even lives. Clearing the directory first makes the
        # installed set exactly the shipped set. rm -rf is happy when it is not
        # there yet (first install), and the tarball recreates it below.
        rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen $MODDIR/config $MODDIR/moonraker $MODDIR/init.d
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
        # From here on this script runs the printer's own interpreter, so it
        # needs the same environment the boot path gets -- and it is a hand-run
        # `sh run.sh` over ssh at least as often as it is a flash, which is
        # exactly where that environment is not inherited. anvil-env.sh has
        # just been extracted above.
        [ -f $MODDIR/anvil-env.sh ] && . $MODDIR/anvil-env.sh
    fi
else
    echo "!! no anvil.tar.xz found -- scripts only, no Mainsail/HelixScreen"
fi
sync

# ---- Moonraker -------------------------------------------------------------
# Nothing to do here any more. The payload extracted above already IS the
# installation: bin/patch.sh stages Moonraker's python package into the
# payload, so once the tarball lands the entry point exists at
# $MODDIR/moonraker/moonraker.py, and the init script starts the server from
# exactly there.
#
# What used to sit here was a SECOND copy of that identical tree, into
# /usr/prog/moonraker/moonraker/, and every reason for it turned out to be
# wrong:
#
#   * /usr/prog is the FIRMWARE partition. The header of this very script says
#     the payload is "Never unpacked into /usr/prog: the firmware partition has
#     no room for ~100MB of web UI" -- and then this block copied a Moonraker
#     tree there anyway. It was the only step of the install that could fail on
#     disk space, and the way it failed was "this printer has no working web
#     UI".
#   * It bought nothing: the staged $MODDIR/moonraker was never deleted
#     afterwards, so the printer carried two byte-identical trees -- one on the
#     partition that has room, one on the partition that does not.
#   * /usr/prog is what a stock FlashForge flash overwrites, while
#     /usr/data/anvil survives one. So the copy meant that flashing stock
#     firmware silently reverted Moonraker to FlashForge's 2022 build while the
#     rest of the mod stayed exactly where it was -- reintroducing the "which
#     Moonraker is this printer actually running?" ambiguity that the previous
#     commit existed to end.
#
# The two things that supposedly pinned Moonraker to /usr/prog do not hold.
# The moonraker-env virtualenv sitting beside it is unused: imports resolve
# from /usr/prog/Python-3.8.2/lib/python3.8/site-packages -- verified by
# running the printer's own interpreter on the real image, where moonraker-env
# is not on sys.path at all. And moonrakerDaemon, which did exec the tree by
# absolute path, is never invoked any more; the mod's init script starts
# moonraker itself.
#
# FlashForge's tree is deliberately left where it is. Deleting it would be a
# migration that buys nothing on a partition that is not ours; simply not
# writing to it is the whole fix.

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
# First install after this rule arrives has no config-installed. An existing
# file is then treated as edited -- .mod-new, the conservative answer -- UNLESS
# it still matches FlashForge's pristine runConfig template, which means nobody
# has touched it and it is ours to replace. See the branch below.
if [ -d $MODDIR/config ]; then
    mkdir -p /usr/data/config
    for source in $MODDIR/config/*; do
        [ -f "$source" ] || continue
        name=`basename "$source"`
        live="/usr/data/config/$name"
        prev="$MODDIR/config-installed/$name"
        case "$name" in
        moonraker-custom.conf)
            # Yours, permanently. Created once so moonraker.conf's [include]
            # resolves -- Moonraker treats an include matching no file as a
            # fatal error -- and never touched again, not even as .mod-new.
            if [ -f "$live" ]; then
                echo "config: $name kept (yours; never overwritten)"
            else
                cp -f "$source" "$live"
                echo "config: $name created -- put your Moonraker settings here"
            fi
            continue
            ;;
        ff-*.cfg)
            # Ours. Overwrite and say so when it had drifted, so the log
            # explains where a local edit went.
            if [ -f "$live" ] && [ "`md5sum < "$live"`" != "`md5sum < "$source"`" ]; then
                echo "config: $name overwritten (mod-owned; override it from printer.cfg)"
            fi
            cp -f "$source" "$live"
            continue
            ;;
        esac
        # FlashForge's own copy, straight off the factory image, is not a
        # user edit -- and /usr/data/config/moonraker.conf IS on the factory
        # image, so without this branch the first install lands as .mod-new,
        # every later one compares the live factory file against the snapshot
        # of OURS, and the shipped config could never reach the printer at all.
        # runConfig/ holds the pristine template the machine was built with;
        # matching it byte for byte means nobody has touched the live copy.
        stock="/usr/prog/klipper/runConfig/$name"
        if [ ! -f "$live" ]; then
            cp -f "$source" "$live"
        elif [ -f "$prev" ] && [ "`md5sum < "$live"`" = "`md5sum < "$prev"`" ]; then
            cp -f "$source" "$live"
            echo "config: $name updated (was unmodified)"
        elif [ ! -f "$prev" ] && [ -f "$stock" ] \
             && [ "`md5sum < "$live"`" = "`md5sum < "$stock"`" ]; then
            cp -f "$source" "$live"
            echo "config: $name installed over FlashForge's untouched copy"
        else
            cp -f "$source" "$live.mod-new"
            echo "config: $name kept -- new version left as $name.mod-new"
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
#
# An UPDATE must not change the password. The pre-block recorded the hash the
# printer had before the stock installer replaced the shadow file; when that
# hash differs from the one the package shipped, a password was already set
# -- by a previous install, or by hand with `passwd` -- and it is put back
# unchanged. The stick only ever sees a password once, on the first install.
PW_KEEP=""
if [ "$MOD_PW_AUTO" = "1" ] && [ -f $MODDIR/.prev-root-hash ]; then
    PREV_HASH=`cat $MODDIR/.prev-root-hash 2>/dev/null`
    # Compare against the hash the PACKAGE ships ($WORK_DIR is the stock
    # run.sh's own variable, still in scope here), not the live file: the
    # stock installer has already copied the shipped shadow over the live one
    # by now, and if that copy ever fails the live file still holds the old
    # password -- which must read as "set by someone", not as "fresh".
    SHIPPED_HASH=""
    [ -n "${WORK_DIR:-}" ] && [ -f "$WORK_DIR/shadow" ] &&
        SHIPPED_HASH=`awk 'BEGIN{FS=":"} $1=="root"{print $2}' "$WORK_DIR/shadow" 2>/dev/null`
    [ -n "$SHIPPED_HASH" ] ||
        SHIPPED_HASH=`awk 'BEGIN{FS=":"} $1=="root"{print $2}' /usr/prog/etc/shadow 2>/dev/null`
    case "$PREV_HASH" in
    '$'*) [ "$PREV_HASH" != "$SHIPPED_HASH" ] && PW_KEEP="$PREV_HASH" ;;
    esac
fi
rm -f $MODDIR/.prev-root-hash
if [ -n "$PW_KEEP" ]; then
    if awk -v h="$PW_KEEP" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
            /usr/prog/etc/shadow > /usr/prog/etc/shadow.new &&
        mv -f /usr/prog/etc/shadow.new /usr/prog/etc/shadow; then
        chmod 600 /usr/prog/etc/shadow
        echo "root password preserved from the previous install"
    else
        echo "!! could not restore the previous root password hash"
        echo "!! root password is the stock one -- no ssh login"
    fi
elif [ "$MOD_PW_AUTO" = "1" ]; then
    NEW_PASSWORD=`tr -dc A-Za-z0-9 < /dev/urandom 2>/dev/null | head -c 14`
    NEW_HASH=""
    [ -n "$NEW_PASSWORD" ] && NEW_HASH=`mkpasswd -m sha512 "$NEW_PASSWORD" 2>/dev/null`
    case "$NEW_HASH" in
    '$6$'*)
        PWFILE=/mnt/anvil-password.txt
        {   echo "anvil -- the root password for this printer"
            echo
            echo "    ssh root@<printer-ip>"
            echo "    password: $NEW_PASSWORD"
            echo
            echo "Save it somewhere safe and delete this file."
            echo "To change it, run  passwd  on the printer."
        } > $PWFILE 2>/dev/null
        sync
        # Read it back off the stick: proves the write survived, not just that
        # the shell accepted the redirect.
        if grep -q "password: $NEW_PASSWORD" $PWFILE 2>/dev/null; then
            # /etc is a bind mount of /usr/prog/etc, so this IS the live file
            # dropbear authenticates against.
            awk -v h="$NEW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
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
