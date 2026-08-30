#!/bin/sh
# THE INSTALLER. Ours, not FlashForge's.
#
# app_startup.sh finds a package on the USB stick, decrypts it with
# /usr/prog/bin/unTar into /usr/data/update/ and runs THIS file:
#
#     /usr/data/update/runFirmwareExe.sh <MACHINE> <PID>
#
# That is the whole contract, and the exit code is the other half of it:
#
#     exit 0     app_startup.sh unmounts the stick, deletes /usr/data/update
#                and sleeps for ever -- the "flashed, now power-cycle me"
#                state, with end.img on the panel.
#     exit != 0  it unmounts, deletes, and goes on booting the printer.
#
# So a gate that refuses to install must exit non-zero: the printer then comes
# up on whatever it had before, which is the right answer to "this package is
# not for this machine".
#
# WHY OURS. FlashForge's version of this file drives four component installers
# (control, kernel, software, library), each of which extracts a tarball into
# /usr/prog/PROGRAM/<name>/, verifies md5sum.list, wipes every previous version
# directory and runs the run.sh inside it. Our install used to reach the printer
# by being spliced into the software component's run.sh -- which meant shipping
# a 26MB component, 21MB of it FlashForge's own firmwareExe, for the sake of one
# exec hook. We own this file instead. See docs/how-it-works.md.
#
# It still installs the stock components when a package carries them, because
# --full packages do. A slim package carries none and the loop skips them,
# exactly as FlashForge's own `ls -1t <name>-*.tar.xz` guard did.
#
# WHAT WENT AND IS NOT COMING BACK: create_key() (defined, never called, and it
# built its paths without a slash, so it would have written /usr/progprivate.pem);
# SSID_NAME/SSID_PASS (assigned, never read); the commented-out kernel version
# gate; and the screwflag factory bypass for the model check, which we never
# ship a screwflag for.
#
# This runs under the printer's busybox ash. qa/static/test_shell_syntax.py
# parses it with that in mind; keep it dialect-clean.

WORK_DIR=`dirname $0`
RUN_DIR=/usr/prog/PROGRAM
MODDIR=/usr/data/anvil
LOG=/usr/data/anvil-install.log

# Rewritten by bin/pack.sh from the stock package's own MACHINE=/PID= values.
# The names and the line shape matter: bin/unpack.sh, bin/pack.sh and
# tools/replica/printer/entrypoint.sh all read them back with
# `sed -n 's/^MACHINE=//p'`.
MACHINE=Creator5Pro
PID=0029
# Rewritten by bin/pack.sh: 1 when no ROOT_PW_HASH was baked into the build, so
# the installer picks a random root password on the machine instead.
#
# 0 in the checkout, and that is the safe default rather than an arbitrary one:
# qa/replica/test_upgrade.py runs THIS file, unsubstituted, and 1 would have it
# rewrite the replica's shadow and drop a password file on /mnt every run.
MOD_PW_AUTO=0

# Where the software component landed, once it has. Only the root password
# block at the bottom reads it, and only when a package carries the component.
SW_COMPONENT_DIR=""

# ---------------------------------------------------------------- the gates --
# These print to the console rather than to the log: they run before there is
# an install to have a log about, and a refusal the owner cannot see is a
# printer that "did nothing" for no visible reason.
CHECK_ARCH=`uname -m`
if [ "$CHECK_ARCH" != mips ]; then
    echo "Machine architecture error: $CHECK_ARCH"
    exit 1
fi

# Empty arguments mean an old app_startup.sh that passed none; FlashForge
# treated that as installable and so do we. Two non-empty ones must match.
# This is the gate that stops a Creator5 package installing on a Creator5Pro.
# The payload is not model-specific but the chamber config is, and the filename
# glob alone cannot be trusted -- a file can be renamed by hand.
if [ -n "$1" ] && [ -n "$2" ]; then
    if [ "$1" != "$MACHINE" ] || [ "$2" != "$PID" ]; then
        echo "Firmware does not match machine type: got $1/$2, this package is $MACHINE/$PID."
        exit 1
    fi
fi

case "$MODDIR" in
    /usr/data/?*) ;;
    *) echo "refusing to run: MODDIR='$MODDIR' is not under /usr/data"; exit 1 ;;
esac

# The panel, for as long as this takes. Guarded because a package need not
# carry the images; unguarded, a missing one would be the first thing in the
# log rather than the install.
[ -f "$WORK_DIR/start.img" ] && cat "$WORK_DIR/start.img" > /dev/fb0 2>/dev/null

# Everything from here is logged rather than printed. The owner is watching the
# panel, not a console they have no way to see.
mkdir -p "$MODDIR"
exec >>"$LOG" 2>&1
STAMP=`date +%Y%m%d-%H%M%S 2>/dev/null || echo manual`
echo "=== mod install $STAMP ==="

# ----------------------------------------------- FlashForge's own components --
# One function where FlashForge had four identical copies. The semantics are
# kept exactly, including the two that look like accidents and are not:
#
#   * a component whose md5sum.list does not verify is DISCARDED rather than
#     installed half-way, and the install carries on with the next one.
#   * every previous version directory is wiped before the new one is renamed
#     into place, which is why /usr/prog/PROGRAM/software holds exactly one
#     version and why nothing on the printer is a reliable backup of the
#     firmwareExe it shipped with.
install_component() {
    name=$1
    tarball=`ls -1t "$WORK_DIR/$name-"*.tar.xz 2>/dev/null | head -n 1`
    if [ -z "$tarball" ]; then
        echo "component $name: not in this package -- skipped"
        return 0
    fi
    version=`basename "$tarball" | sed "s/^$name-//; s/\.tar\.xz\$//"`
    dest=$RUN_DIR/$name
    echo "component $name: installing $version"
    mkdir -p "$dest"
    rm -rf "$dest/temp"
    mkdir -p "$dest/temp"
    # A bare `tar -xf`, because FlashForge's components are plain tars carrying
    # a .tar.xz name. A real xz file would not extract here.
    tar -xf "$tarball" -C "$dest/temp"
    sync
    if ! ( cd "$dest/temp" && md5sum -s -c md5sum.list ); then
        echo "!! component $name: md5sum.list does not verify -- not installed"
        rm -rf "$dest/temp"
        return 1
    fi
    for old in "$dest"/*; do
        case "$old" in */temp) continue ;; esac
        [ -e "$old" ] && rm -rf "$old"
    done
    mv "$dest/temp" "$dest/$version"
    sync
    [ "$name" = software ] && SW_COMPONENT_DIR="$dest/$version"
    if [ -f "$dest/$version/run.sh" ]; then
        chmod a+x "$dest/$version/run.sh"
        "$dest/$version/run.sh"
    fi
    return 0
}

# ------------------------------------------------------ backups, taken first --
# BEFORE any component is installed: the software component ships /usr/prog's
# passwd and shadow and its run.sh copies them over the live ones, so a backup
# taken afterwards would capture the package's files rather than the printer's.
#
# app_startup.sh is deliberately not in this list. The mod replaces firmwareExe
# instead, so the stock boot scripts are never modified and never need
# restoring.
BACKUP=$MODDIR/backup/$STAMP
mkdir -p "$BACKUP"
for file in /usr/prog/klipper/start.sh /usr/prog/etc/passwd /usr/prog/etc/shadow; do
    if [ -e "$file" ]; then
        dest="$BACKUP`dirname $file`"
        mkdir -p "$dest" && cp -a "$file" "$dest/" && echo "backed up $file"
    fi
done
# NOT the previous firmwareExe. install_component wipes the software directory
# before the new version lands, so by the time anything of ours runs the old
# binary is already gone. That is also why uninstalling means flashing the
# STOCK package again: it is the only thing that still carries the genuine
# binary. See docs/hardware-testing.md and `make test-recovery`.

# Only the FIRST install sees genuinely stock files, so never let a later
# re-flash overwrite the pristine copy.
if [ ! -d "$MODDIR/backup/stock" ]; then
    cp -a "$BACKUP" "$MODDIR/backup/stock" && echo "kept pristine copy at backup/stock"
fi

# The root password the printer has RIGHT NOW -- random from a first install,
# or set by hand with `passwd` -- lives only in this shadow, and the software
# component is about to replace the file. Record the hash so the block at the
# bottom can put it back: that is what keeps the password stable across
# updates.
rm -f "$MODDIR/.prev-root-hash"
if [ -f /usr/prog/etc/shadow ]; then
    awk 'BEGIN{FS=":"} $1=="root"{print $2}' /usr/prog/etc/shadow \
        > "$MODDIR/.prev-root-hash" 2>/dev/null &&
        chmod 600 "$MODDIR/.prev-root-hash" &&
        echo "recorded current root password hash"
fi
sync

# FlashForge clears their own NIM logs on every flash. One line, and it leaves
# a reflashed printer as tidy as a stock one.
rm -rf /usr/data/logs/NIM/*

# The order is FlashForge's: control and kernel before software, library last.
install_component control
install_component kernel
install_component software
install_component library
sync

# ---------------------------------------------------------- the mod payload --
# Shipped as anvil.tar.xz in the same package as this script, so it is already
# sitting on the data partition next to us (/usr/data/update). Never unpacked
# into /usr/prog: the firmware partition has no room for ~100MB of web UI.
MODTAR=""
for candidate in "$WORK_DIR/anvil.tar.xz" /usr/data/update/anvil.tar.xz /mnt/anvil.tar.xz; do
    [ -f "$candidate" ] && { MODTAR="$candidate"; break; }
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
        #
        # anvil.conf IS NOT KEPT. A printer upgrading from a release that
        # had one keeps nothing of it: the settings it held are gone, and it
        # is removed unconditionally further down -- see the note there.
        #
        # HelixScreen keeps every user setting INSIDE its own install tree.
        # firmwareExe exports HELIX_DATA_DIR=$MODDIR/helixscreen and the binary
        # resolves its settings as config/settings.json relative to that root,
        # so the tree below is not ours alone to replace -- the user's screen
        # brightness, theme, log level, touch calibration and spool assignments
        # all live in it.
        #
        # Backed up before either deletion path below runs (manifest or
        # compatibility sweep -- both remove $MODDIR/helixscreen) and restored
        # after extraction. The tarball ships a seeded settings.json of its own,
        # with "wizard_completed": false, that would otherwise land on top.
        #
        # The list is HelixScreen's own HELIX_USER_CONFIG_FILES, from the
        # install.sh the mod never runs -- it extracts the release tarball
        # directly -- so the same job has to happen here. settings.json.backup
        # rides along because Config::init falls back to it when the live file
        # is missing or has no config_version.
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
        # nothing else.
        #
        # THE PROPERTY THIS HAS TO KEEP, which is why anything is removed at
        # all rather than just extracted over: files used to be overwritten in
        # place and never removed, which is harmless only while the set of
        # filenames never changes. It does change -- a renamed script survives
        # the update and sits next to the one that replaced it. The installed
        # set must end up exactly the shipped set.
        #
        # bin/patch.sh ships a manifest of every path the payload installs --
        # one per line, relative to $MODDIR, files and directories both, itself
        # included. Deleting what the LAST manifest lists keeps that property
        # (a script the last payload shipped and this one does not is named in
        # that list, so it still goes) without touching a byte we did not put
        # there.
        MOD_MANIFEST=$MODDIR/.install-manifest
        if [ -s "$MOD_MANIFEST" ]; then
            # Work from a copy in /tmp. The manifest lists itself, so the
            # first pass below deletes the very file it is reading; the read
            # would survive that on Linux, but the second pass opens it again
            # by name and would find nothing there.
            cp -f "$MOD_MANIFEST" /tmp/anvil.manifest.old
            # Pass 1 -- the files. Anything that is not a directory, and a
            # symlink even when it points at one, which is why -L is asked
            # first: rm -f on a symlink-to-directory removes the link, while
            # the rmdir pass below would refuse it and leave it behind.
            while read -r mrel; do
                [ -n "$mrel" ] || continue
                case "$mrel" in
                /*|*..*)
                    # A manifest is a file on the printer's disk, and this
                    # loop runs as root with $MODDIR pasted onto the front of
                    # whatever it says. An absolute path escapes $MODDIR
                    # outright; `..` walks out of it one component at a time.
                    # Neither can come out of bin/patch.sh, so one appearing
                    # here means the file is damaged or forged, and the answer
                    # is to say so and skip rather than to find out what it
                    # would have deleted. The `..` test is deliberately blunt
                    # -- it also rejects a legitimate "foo..bar", and we ship
                    # no such name.
                    echo "!! manifest: refusing '$mrel' -- not a path under $MODDIR"
                    continue ;;
                esac
                if [ -L "$MODDIR/$mrel" ] || [ ! -d "$MODDIR/$mrel" ]; then
                    rm -f "$MODDIR/$mrel"
                fi
            done < /tmp/anvil.manifest.old
            # Pass 2 -- the directories, deepest first and only when empty.
            # Reverse sort is what makes them deepest-first: "www/mainsail"
            # sorts after "www", so the child is offered before its parent and
            # the parent is empty by the time its turn comes. rmdir refusing a
            # directory that still holds something is not a failure here, it
            # is the whole point -- a directory holding a file we did not ship
            # stays, and so does the file.
            sort -r /tmp/anvil.manifest.old | while read -r mrel; do
                case "$mrel" in ''|/*|*..*) continue ;; esac
                [ -d "$MODDIR/$mrel" ] && rmdir "$MODDIR/$mrel" 2>/dev/null
            done
            rm -f /tmp/anvil.manifest.old
            echo "previous install removed (manifest)"
        else
            # ---- COMPATIBILITY: an install that predates the manifest ------
            # Those printers have no $MODDIR/.install-manifest and there is no
            # way to work out after the fact what they installed, so the whole
            # directory sweep is the only honest answer: without it an upgrade
            # off one of them leaves every renamed init script in place, which
            # is the double-start failure described above.
            #
            # -s rather than -f: a zero-byte manifest is a broken install, not
            # a payload that shipped nothing.
            #
            # DELETE THIS BRANCH once no pre-manifest install can still be
            # upgraded in the field -- it is the one piece of this installer
            # that can still destroy a file nobody asked it to.
            rm -rf $MODDIR/bin $MODDIR/www $MODDIR/nginx $MODDIR/helixscreen $MODDIR/config $MODDIR/moonraker $MODDIR/init.d
            echo "previous install removed (no manifest -- pre-manifest layout)"
        fi
        # init.d/, anvil-service.sh AND anvil.conf ARE GONE, and go
        # unconditionally rather than by manifest. The payload ships none of
        # them any more: s6-rc is the CLI, the tree is started by firmwareExe,
        # and every setting anvil.conf held is now stated in the service that
        # uses it. A leftover S70klipper is a script that starts an
        # UNSUPERVISED klippy next to the supervised one, and a leftover
        # anvil-service.sh is a library something stale could still source, so
        # neither may be left to a diff that only knows about files the LAST
        # manifest tracked -- a script planted by hand, or surviving the one
        # pre-manifest jump every printer takes, is invisible to that.
        #
        # anvil.conf is here for the second reason rather than the first: it
        # is inert now, nothing reads it, and the manifest branch would take
        # it anyway. What it must not do is SURVIVE the pre-manifest path,
        # where the sweep above removes directories and would leave this file
        # sitting at the top of $MODDIR looking like something an owner could
        # still edit to change how the printer boots.
        #
        # No hot migration is attempted. This runs from app_startup.sh DURING
        # BOOT, before firmwareExe starts, so there is no supervision tree up
        # while it runs and the new one comes up from scratch a moment later.
        # A hand-run `sh runFirmwareExe.sh` over ssh is the exception: that
        # printer needs a reboot, and nothing here forces one.
        rm -rf $MODDIR/init.d $MODDIR/anvil-service.sh $MODDIR/anvil.conf
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
        # Put HelixScreen's settings back over the tarball's defaults. The
        # user's copy wins outright: these are settings, not a config file the
        # mod owns, and there is no include-and-override seam to move an edit
        # to the way ff-*.cfg has one.
        #
        # helixscreen.env is the one file where the shipped version can carry
        # something new -- the launcher sources it, and a release can add an
        # option to it -- so when it has actually changed the new one is left
        # beside the user's as .mod-new rather than thrown away silently.
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
        # MEASURED: s6-rc-init creates one symlink per service in the scandir
        # and fails outright -- "unable to supervise service directories ...:
        # File exists" -- if a name is taken. A printer upgrading from the
        # pre-s6-rc payload has nginx, moonraker and camera in there as real
        # directories, and the manifest cannot remove them: it deletes the
        # files it listed, but s6-supervise created supervise/ and event/
        # inside each at RUNTIME, so the rmdir correctly refuses and leaves
        # exactly the name s6-rc-init collides with.
        #
        # After the extraction, so the payload's own empty etc/s6 has landed.
        rm -rf $MODDIR/etc/s6
        mkdir -p $MODDIR/etc/s6
        # /run is a tmpfs, so this matters only for a hand-run install over
        # ssh: a live s6-rc state points at the database just replaced.
        rm -rf /run/s6-rc
        # klipperDaemon is anvil-link-prog.sh's now, below, like the other two
        # files in $MODDIR/prog. It used to be hand-copied here with the stock
        # KLIPPER_NICENESS seded into it, which is what made it machine-specific
        # and therefore unlinkable -- and the guard on that block named
        # $MODDIR/bin/klipperDaemon, a path it stopped shipping at in 057a3a1,
        # so it was skipped in silence for several releases and every printer
        # kept FlashForge's own. There is no such number now: klipper/run starts
        # klippy at normal priority.
        echo "mod payload installed"
        # Point the stock paths at the payload's own copies. This has to be
        # HERE and not earlier: the software component, when a package carries
        # one, was distributed above -- long before the payload existed -- so
        # the component cannot carry these links itself. On a first install
        # they would dangle; on an upgrade they would resolve to the payload
        # being replaced. See the script's header.
        [ -x $MODDIR/bin/anvil-link-prog.sh ] && $MODDIR/bin/anvil-link-prog.sh
        # From here on this script runs the printer's own interpreter, so it
        # needs the same environment the boot path gets -- and it is a hand-run
        # install over ssh at least as often as it is a flash, which is exactly
        # where that environment is not inherited. anvil-env.sh has just been
        # extracted above.
        [ -f $MODDIR/anvil-env.sh ] && . $MODDIR/anvil-env.sh
    fi
else
    echo "!! no anvil.tar.xz found -- scripts only, no Mainsail/HelixScreen"
fi
sync

# ---- klipper + moonraker configs -------------------------------------------
# Every file here is one the mod ships (ff-*.cfg, printer.chamber.cfg,
# moonraker.conf); printer.cfg is the user's and is never shipped, so it is
# never a candidate.
#
# Two rules, because the two kinds of file differ in whether the user has
# somewhere else to put a change.
#
# ff-*.cfg are OURS and are overwritten every update, no questions asked.
# Klipper hands the user a better seam than editing them: parsing is
# RawConfigParser(strict=False), so same-named sections MERGE, the last value
# of an option wins, and a redefined [gcode_macro] replaces the original.
# Overriding from printer.cfg AFTER the include survives every flash, while an
# edit here is reverted by the next one. Each file says so in its header.
#
# printer.base.cfg is on the same footing and needs no rule here: it is
# anvil-klipper-config's, and anvil-link-prog.sh symlinks $MODDIR/config into
# /usr/data/config, so an upgrade repoints the link rather than editing a file.
# printer.chamber.cfg goes the same way -- see the case below.
#
# moonraker.conf is KEPT when edited. There is no include-and-override seam for
# it, and a printer reached through a tuned trusted_clients or cors_domains
# block would lose that access on an update. So it gets the compare-and-.mod-new
# dance: still byte-identical to what the LAST package wrote means ours to
# update, different means the user's to keep. $MODDIR/config-installed holds
# that last-written copy -- it survives the payload swap and is refreshed only
# after the comparison below. Without it a config we own could be written only
# once, then land as .mod-new forever.
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
        ff-*.cfg|printer.base.cfg|printer.chamber.cfg|chamber)
            # Ours, and NOT COPIED: anvil-link-prog.sh symlinks these into
            # /usr/data/config after this loop, so the file the printer reads
            # is the one the package owns and an `opkg upgrade` changes it
            # without a .tgz. A copy here would only put a real file in the
            # way of the link about to replace it.
            #
            # printer.chamber.cfg is not a file in $MODDIR/config: chamber/
            # holds one per model. The directory is named here so it is
            # skipped rather than falling through to the compare below.
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
# landmine.
#
# $MODDIR, NOT /usr/prog: the klipper s6-rc service execs
# $MODDIR/klipper/klippy, so that is the tree whose .pyc files get imported.
# It also needs the sweep MORE than /usr/prog ever did -- klippy WRITES those
# directories at runtime on a writable /usr/data, and a path created after
# install is in no .install-manifest, so the manifest delete above walks past
# it and leaves last release's bytecode beside this release's source.
find $MODDIR/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
# The stock tree is swept too, and only because it costs one line: nothing
# imports it any more, but a machine that has been through several releases
# has bytecode there from when something did.
find /usr/prog/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
sync

# ---- root password, chosen here when none was baked in ---------------------
# The normal path is ROOT_PW_HASH at build time: patch.sh writes that hash
# straight into the shadow file the software component ships. When it is empty
# the package cannot carry a password -- one file is flashed by many people, so
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
# An UPDATE must not change the password. The backup block at the top recorded
# the hash the printer had before the software component replaced the shadow
# file; when that hash differs from the one the package shipped, a password was
# already set -- by a previous install, or by hand with `passwd` -- and it is
# put back unchanged. The stick only ever sees a password once, on the first
# install.
PW_KEEP=""
if [ "$MOD_PW_AUTO" = "1" ] && [ -f $MODDIR/.prev-root-hash ]; then
    PREV_HASH=`cat $MODDIR/.prev-root-hash 2>/dev/null`
    # Compare against the hash the PACKAGE ships, not the live file: the
    # software component has already copied its shadow over the live one by
    # now, and if that copy ever fails the live file still holds the old
    # password -- which must read as "set by someone", not as "fresh".
    SHIPPED_HASH=""
    [ -n "$SW_COMPONENT_DIR" ] && [ -f "$SW_COMPONENT_DIR/shadow" ] &&
        SHIPPED_HASH=`awk 'BEGIN{FS=":"} $1=="root"{print $2}' "$SW_COMPONENT_DIR/shadow" 2>/dev/null`
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

# The panel says so, and `play` is FlashForge's own chime. Both guarded: a
# package need not carry either, and neither is worth failing an install over.
[ -f "$WORK_DIR/end.img" ] && cat "$WORK_DIR/end.img" > /dev/fb0 2>/dev/null
[ -x "$WORK_DIR/play" ] && "$WORK_DIR/play"

# Always 0 once we have got this far, as FlashForge's own does. It puts
# app_startup.sh into its "flashed, power-cycle me" sleep with end.img on the
# panel, which is the only signal the owner gets that the install finished.
exit 0
