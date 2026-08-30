# Runs near the END of the stock run.sh, after it has installed its own
# files. Backups already happened in the pre-block at the top.
MODDIR=/usr/data/anvil
# Set by bin/patch.sh: 1 when no ROOT_PW_HASH was baked in.
MOD_PW_AUTO=0
case "$MODDIR" in
    /usr/data/?*) ;;
    *) echo "refusing to run: MODDIR='$MODDIR' is not under /usr/data"; exit 0 ;;
esac
exec >>/usr/data/anvil-install.log 2>&1

# ---- the mod payload -------------------------------------------------------
# Shipped as anvil.tar.xz in the OUTER package, already on the data partition
# next to us. Never unpacked into /usr/prog: no room for ~100MB of web UI.
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
        # HelixScreen keeps every user setting INSIDE its own install tree
        # ($MODDIR/helixscreen, via HELIX_DATA_DIR), so brightness, theme, log
        # level, touch calibration and spool assignments all live in what we
        # are about to replace. Backed up before either deletion path runs and
        # restored after extraction, since the tarball ships its own
        # settings.json with "wizard_completed": false. The list is
        # HelixScreen's own HELIX_USER_CONFIG_FILES; settings.json.backup rides
        # along because Config::init falls back to it.
        HELIX_USER_FILES="settings.json settings.json.backup helixscreen.env
                          .disabled_services tool_spools.json crash_history.json"
        HELIX_KEEP=/tmp/anvil-helix-keep
        rm -rf $HELIX_KEEP
        for f in $HELIX_USER_FILES; do
            [ -f $MODDIR/helixscreen/config/$f ] || continue
            mkdir -p $HELIX_KEEP
            cp -f $MODDIR/helixscreen/config/$f $HELIX_KEEP/$f
        done
        # Remove what the PREVIOUS payload installed -- exactly that, and
        # nothing else. Overwriting in place is harmless only while the set of
        # filenames never changes, and it does: a renamed script survives the
        # update and sits next to the one that replaced it. bin/patch.sh ships
        # a manifest of every path the payload installs, so deleting what the
        # LAST manifest lists makes the installed set exactly the shipped set
        # without touching a byte we did not put there.
        MOD_MANIFEST=$MODDIR/.install-manifest
        if [ -s "$MOD_MANIFEST" ]; then
            # Work from a copy in /tmp: the manifest lists itself, and the
            # second pass opens it again by name after pass 1 deleted it.
            cp -f "$MOD_MANIFEST" /tmp/anvil.manifest.old
            # Pass 1 -- files, and a symlink even when it points at a
            # directory, which is why -L is asked first: the rmdir pass would
            # refuse such a link and leave it behind.
            while read -r mrel; do
                [ -n "$mrel" ] || continue
                case "$mrel" in
                /*|*..*)
                    # This loop runs as root with $MODDIR pasted onto whatever
                    # the manifest says. Neither an absolute path nor `..` can
                    # come out of bin/patch.sh, so one appearing here means the
                    # file is damaged or forged: say so and skip. The `..` test
                    # is deliberately blunt.
                    echo "!! manifest: refusing '$mrel' -- not a path under $MODDIR"
                    continue ;;
                esac
                if [ -L "$MODDIR/$mrel" ] || [ ! -d "$MODDIR/$mrel" ]; then
                    rm -f "$MODDIR/$mrel"
                fi
            done < /tmp/anvil.manifest.old
            # Pass 2 -- directories, deepest first (reverse sort puts
            # "www/mainsail" before "www") and only when empty. rmdir refusing
            # a non-empty directory is the point: a directory holding a file we
            # did not ship stays, and so does the file.
            sort -r /tmp/anvil.manifest.old | while read -r mrel; do
                case "$mrel" in ''|/*|*..*) continue ;; esac
                [ -d "$MODDIR/$mrel" ] && rmdir "$MODDIR/$mrel" 2>/dev/null
            done
            rm -f /tmp/anvil.manifest.old
            echo "previous install removed (manifest)"
        else
            # ---- COMPATIBILITY: an install that predates the manifest ------
            # No $MODDIR/.install-manifest and no way to work out what such an
            # install left behind, so the whole-directory sweep is the only
            # honest answer. -s rather than -f: a zero-byte manifest is a
            # broken install, not a payload that shipped nothing.
            #
            # DELETE THIS BRANCH once no pre-manifest install can still be
            # upgraded -- it is the one piece here that can destroy a file
            # nobody asked it to.
            rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen $MODDIR/config $MODDIR/moonraker $MODDIR/init.d
            echo "previous install removed (no manifest -- pre-manifest layout)"
        fi
        # init.d/ AND anvil-service.sh ARE GONE, unconditionally rather than by
        # manifest. A leftover S70klipper starts an UNSUPERVISED klippy beside
        # the supervised one, and a leftover anvil-service.sh is a library
        # something stale could source -- and either can be planted by hand or
        # survive the one pre-manifest jump, which a manifest diff cannot see.
        #
        # No hot migration: the install runs from app_startup.sh DURING BOOT,
        # so no supervision tree is up. A `sh run.sh` over ssh is the exception
        # and needs a reboot, which nothing here forces.
        rm -rf $MODDIR/init.d $MODDIR/anvil-service.sh
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
        # Put HelixScreen's settings back over the tarball's defaults; the
        # user's copy wins outright, there being no include-and-override seam
        # the way ff-*.cfg has one. helixscreen.env is the exception -- the
        # launcher sources it and a release can add options -- so a changed one
        # is left beside the user's as .mod-new rather than dropped.
        if [ -d $HELIX_KEEP ]; then
            mkdir -p $MODDIR/helixscreen/config
            for f in $HELIX_USER_FILES; do
                [ -f $HELIX_KEEP/$f ] || continue
                live=$MODDIR/helixscreen/config/$f
                if [ "$f" = helixscreen.env ] && [ -f "$live" ] \
                   && [ "`md5sum < "$live"`" != "`md5sum < "$HELIX_KEEP/$f"`" ]; then
                    cp -f "$live" "$live.mod-new"
                    echo "helixscreen: $f kept -- new version left as $f.mod-new"
                fi
                cp -f $HELIX_KEEP/$f "$live"
                echo "helixscreen: $f preserved across the update"
            done
            rm -rf $HELIX_KEEP
        fi
        chmod a+x $MODDIR/bin/* 2>/dev/null
        # ---- the s6 scandir, swept -------------------------------------
        # MEASURED: s6-rc-init fails outright ("File exists") if a name in the
        # scandir is taken. A printer upgrading from the pre-s6-rc payload has
        # nginx, moonraker and camera there as real directories that the
        # manifest cannot remove -- s6-supervise created supervise/ and event/
        # inside each at RUNTIME, so rmdir correctly refuses. After the
        # extraction, so the payload's own empty etc/s6 has landed.
        rm -rf $MODDIR/etc/s6
        mkdir -p $MODDIR/etc/s6
        # /run is a tmpfs, so this matters only for a `sh run.sh` typed over
        # ssh: a live s6-rc state points at the database just replaced.
        rm -rf /run/s6-rc
        # klipperDaemon is anvil-link-prog.sh's now, like the other two files
        # in $MODDIR/prog. Hand-copying it with the stock KLIPPER_NICENESS
        # seded in is what made it machine-specific and unlinkable; the number
        # is NICE_KLIPPER in anvil.conf now.
        echo "mod payload installed"
        # Point the stock boot path at the payload's own copies. This has to be
        # HERE: FlashForge's run.sh distributed the component long before the
        # payload existed, so on a first install these links would dangle and
        # on an upgrade they would resolve to the payload being replaced.
        [ -x $MODDIR/bin/anvil-link-prog.sh ] && $MODDIR/bin/anvil-link-prog.sh
        # From here on this script runs the printer's own interpreter, so it
        # needs the boot path's environment -- which a hand-run `sh run.sh`
        # over ssh does not inherit. anvil-env.sh was just extracted.
        [ -f $MODDIR/anvil-env.sh ] && . $MODDIR/anvil-env.sh
    fi
else
    echo "!! no anvil.tar.xz found -- scripts only, no Mainsail/HelixScreen"
fi
sync

# ---- Moonraker -------------------------------------------------------------
# Nothing to do: the extracted payload already IS the installation, with the
# entry point at $MODDIR/moonraker/moonraker.py. Nothing is written to
# /usr/prog, which a stock FlashForge flash overwrites while /usr/data/anvil
# survives one. FlashForge's own tree is left alone and never used.

# ---- klipper + moonraker configs -------------------------------------------
# Every file here is one the mod ships (ff-*.cfg, printer.chamber.cfg,
# moonraker.conf); printer.cfg is the user's and is never a candidate. Two
# rules, because the two kinds differ in whether the user has somewhere else
# to put a change.
#
# ff-*.cfg are OURS and are overwritten every update: Klipper's
# RawConfigParser(strict=False) merges same-named sections and takes the last
# value, so overriding from printer.cfg AFTER the include survives every
# flash. printer.base.cfg needs no rule -- anvil-link-prog.sh symlinks
# $MODDIR/config into /usr/data/config, so an upgrade repoints the link.
#
# moonraker.conf is KEPT when edited: there is no override seam, and a printer
# reached through a tuned trusted_clients would lose that access. Byte-identical
# to what the LAST package wrote (kept in $MODDIR/config-installed, which
# survives the payload swap) means ours to update; different means the user's
# to keep, and the shipped one lands as .mod-new. Without that snapshot a
# config we own could be written once and then be .mod-new forever.
#
# A first install has no config-installed, so an existing file is treated as
# edited UNLESS it still matches FlashForge's pristine runConfig template.
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
        ff-*.cfg|printer.base.cfg|printer.chamber.cfg|chamber)
            # Ours, and NOT COPIED: anvil-link-prog.sh symlinks these into
            # /usr/data/config after this loop, so an `opkg upgrade` changes
            # them without a .tgz and a copy here would only block the link.
            # printer.chamber.cfg is a directory (one per model), named here so
            # it is skipped rather than falling through to the compare.
            continue
            ;;
        esac
        # FlashForge's own copy is not a user edit, and
        # /usr/data/config/moonraker.conf IS on the factory image -- so without
        # this branch the shipped config could never reach the printer at all.
        # runConfig/ holds the pristine template; a byte-for-byte match means
        # nobody has touched the live copy.
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
# landmine, and the stock run.sh clears only four __pycache__ dirs. $MODDIR,
# NOT /usr/prog: the klipper s6-rc service execs $MODDIR/klipper/klippy. It
# needs the sweep more, too -- klippy WRITES those directories at runtime, so
# they are in no manifest and the delete above walks past them.
find $MODDIR/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# The stock tree is swept too, and only because it costs one line: nothing
# imports it any more, but a machine that has been through several releases
# has bytecode there from when something did.
find /usr/prog/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
sync

# ---- root password, chosen here when none was baked in ---------------------
# The normal path is ROOT_PW_HASH at build time. When it is empty the package
# cannot carry a password -- one file is flashed by many people, so a baked-in
# default would be the same password on every printer. Pick a random one on
# the machine instead and write it onto the USB stick being flashed from.
#
# ORDER MATTERS: the password lands on the stick and is read back BEFORE the
# printer accepts it, because a password set but never written is a locked-out
# printer. An UPDATE must not change it: when the hash the printer had before
# the stock installer ran differs from the one the package shipped, a password
# was already set and is put back unchanged.
PW_KEEP=""
if [ "$MOD_PW_AUTO" = "1" ] && [ -f $MODDIR/.prev-root-hash ]; then
    PREV_HASH=`cat $MODDIR/.prev-root-hash 2>/dev/null`
    # Compare against the hash the PACKAGE ships, not the live file: the stock
    # installer has already copied the shipped shadow over the live one, and if
    # that copy failed the live file still holds the old password -- which must
    # read as "set by someone", not as "fresh".
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
