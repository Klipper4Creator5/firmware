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
# Install the Moonraker bin/patch.sh staged, over whatever is there. Only the
# python package is swapped -- the interpreter, the moonraker-env beside it and
# moonrakerDaemon are FlashForge's and keep working, because the version we
# ship runs on the libraries already installed. See bin/patch.sh for why that
# is true and why this is the only way the camera can appear in Mainsail.
#
# UNCONDITIONAL, AND THERE IS NO ROLLBACK. This used to move the old tree
# aside, run an import check first, and put FlashForge's 2022 build back
# whenever that check failed or the copy did not complete. It read as caution
# and behaved as a coin toss: the printer ended up running the mod's Moonraker
# or a five-year-old one depending on a decision taken during a flash, nothing
# on the screen said which, and the mod's own Mainsail config -- webcam flag
# included -- assumes the new one. A package that ships a Moonraker installs
# that Moonraker.
#
# The import check that used to gate this is gone from the printer entirely.
# By the time a machine is being flashed it is far too late to discover that
# the Moonraker in the package does not load -- there is no second build to
# choose instead, and a log line saying so on the printer helps nobody. That
# check belongs to the build, against the printer's own interpreter, before
# anything ships: see test/integration/printer/case-moonraker.sh, which
# imports every component this config asks for and is what `make
# test-moonraker` runs.
if [ -d $MODDIR/moonraker ]; then
    MOONRAKER_ROOT=/usr/prog/moonraker/moonraker
    NEED_KB=`du -sk $MODDIR/moonraker | cut -f1`
    FREE_KB=`df /usr/prog | tail -1 | tr -s ' ' | cut -d' ' -f4`
    # The tree being replaced is removed before the copy, so its space counts
    # as available. /usr/prog is the small firmware partition and this is the
    # one physical limit left -- not a choice between builds, just whether the
    # copy can happen at all.
    if [ -d $MOONRAKER_ROOT/moonraker ]; then
        OLD_KB=`du -sk $MOONRAKER_ROOT/moonraker | cut -f1`
        FREE_KB=$((${FREE_KB:-0} + ${OLD_KB:-0}))
    fi
    if [ "${FREE_KB:-0}" -lt "$NEED_KB" ]; then
        echo "!! moonraker: ${FREE_KB}KB available on /usr/prog, need ${NEED_KB}KB"
        echo "!! nothing was installed -- this printer has no working web UI"
    else
        mkdir -p $MOONRAKER_ROOT
        rm -rf $MOONRAKER_ROOT/moonraker $MOONRAKER_ROOT/moonraker.modold
        if cp -a $MODDIR/moonraker $MOONRAKER_ROOT/moonraker; then
            sync
            # Bytecode from the FlashForge build would otherwise be the first
            # thing imported. Same trap as klippy below.
            find $MOONRAKER_ROOT/moonraker -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
            echo "moonraker: replaced with the mod's build"
        else
            # Say it plainly. There is nothing to restore -- that is the point
            # of the change -- so the only useful output is what happened and
            # what fixes it.
            echo "!! moonraker: copy failed -- $MOONRAKER_ROOT/moonraker is incomplete"
            echo "!! re-flash the package; there is no web UI until you do"
        fi
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
