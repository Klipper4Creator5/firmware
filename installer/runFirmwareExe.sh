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
# It does two jobs. FlashForge's four components (control, kernel, software,
# library) are installed when a package carries them -- a --full one does --
# and then the mod payload is installed on top. A slim package carries no
# component at all and install_component skips each in turn, which is what lets
# a release leave /usr/prog entirely alone.
#
# See docs/how-it-works.md for where this sits in the boot chain.
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

# Rewritten by bin/pack.sh from ROOT_PW_HASH, and empty in the checkout for the
# same reason MOD_PW_AUTO is 0. This is how a baked-in hash reaches the
# printer: it is applied to /usr/prog/etc/shadow on the machine, below.
MOD_ROOT_PW_HASH=''

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
    if [ -f "$dest/$version/run.sh" ]; then
        chmod a+x "$dest/$version/run.sh"
        "$dest/$version/run.sh"
    fi
    return 0
}

# --------------------------------------------------------------- no backups --
# Nothing is copied aside before an install. There is one recovery path and it
# does not read from this printer: flash the stock FlashForge package for the
# model back, which is the only thing that still carries the genuine
# firmwareExe -- ours is a symlink into $MODDIR and the real binary went the
# first time a component was installed over it. See docs/hardware-testing.md.
#
# A copy of start.sh, passwd and shadow taken here would not change that, and
# $MODDIR is wiped below, so there is nowhere on this printer for one to live.

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
        # HelixScreen keeps every user setting INSIDE its own install tree.
        # firmwareExe exports HELIX_DATA_DIR=$MODDIR/helixscreen and the binary
        # resolves its settings as config/settings.json relative to that root,
        # so the tree below is not ours alone to replace -- the user's screen
        # brightness, theme, log level, touch calibration and spool assignments
        # all live in it.
        #
        # Held in /tmp across the wipe below and restored after extraction.
        # The tarball ships a seeded settings.json of its own, with
        # "wizard_completed": false, that would otherwise land on top.
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
        # Remove the previous install outright, then extract into the empty
        # directory.
        #
        # THE PROPERTY THIS KEEPS, which is why anything is removed at all
        # rather than just extracted over: files overwritten in place and never
        # removed are harmless only while the set of filenames never changes.
        # It does change -- a renamed script otherwise survives the update and
        # sits next to the one that replaced it. Deleting the directory makes
        # the installed set the shipped set by construction, with no list to
        # ship, read or trust.
        #
        # $MODDIR is ours alone. Everything an owner edits lives in
        # /usr/data/config -- printer.cfg, moonraker.conf, moonraker-custom.conf
        # -- and HelixScreen's settings are in $HELIX_KEEP on /tmp by now. A
        # file dropped under $MODDIR by hand does NOT survive; that is the
        # trade, and docs/notes/86-wipe-and-extract.md is the audit behind it.
        #
        # It takes anything an older release left here with it and needs no
        # branch for any of them: a pre-s6-rc init.d/, an anvil-service.sh, an
        # anvil.conf, a .install-manifest, a .prev-root-hash. A leftover
        # S70klipper would start an UNSUPERVISED klippy beside the supervised
        # one, so being thorough here is the point rather than a bonus.
        #
        # $MODDIR is gated at the top of this script: nothing but a path under
        # /usr/data reaches this line.
        #
        # No hot migration is attempted. This runs from app_startup.sh DURING
        # BOOT, before firmwareExe starts, so there is no supervision tree up
        # while it runs and the new one comes up from scratch a moment later.
        # A hand-run `sh runFirmwareExe.sh` over ssh is the exception: that
        # printer needs a reboot, and nothing here forces one.
        rm -rf $MODDIR
        mkdir -p $MODDIR
        echo "previous install removed (wiped)"
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
        # The s6 scandir needs no sweep. MEASURED: s6-rc-init creates one
        # symlink per service in it and fails outright -- "unable to supervise
        # service directories ...: File exists" -- if a name is taken, and
        # s6-supervise fills it with supervise/ and event/ directories at
        # RUNTIME that no payload knows about. The wipe above takes the lot,
        # and firmwareExe makes the directory again when it starts s6-svscan.
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
# moonraker.conf is ours on the same terms, and it has the same kind of seam:
# [include moonraker-custom.conf] is its LAST line, Moonraker applies options in
# the order it reads them, so a tuned trusted_clients or cors_domains block set
# there wins over anything above. Overwriting is also how the [webcam] block and
# the API lockdown reach a printer at all -- a copy kept back because someone
# edited it would never receive either again.
if [ -d $MODDIR/config ]; then
    mkdir -p /usr/data/config
    for source in $MODDIR/config/*; do
        [ -f "$source" ] || continue
        name=`basename "$source"`
        live="/usr/data/config/$name"
        case "$name" in
        moonraker-custom.conf)
            # Yours, permanently. Created once so moonraker.conf's [include]
            # resolves -- Moonraker treats an include matching no file as a
            # fatal error -- and never written again. It is the seam for every
            # Moonraker setting of your own, because moonraker.conf itself is
            # overwritten below.
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
            # skipped rather than falling through to the copy below.
            continue
            ;;
        esac
        cp -f "$source" "$live"
        echo "config: $name installed"
    done
fi
sync

# Stale bytecode from the previous Klipper generation is a silent import-time
# landmine. $MODDIR/klipper/klippy is the tree the klipper s6-rc service execs
# and klippy writes __pycache__ there at runtime on a writable /usr/data -- the
# wipe above takes all of it, so only FlashForge's tree is left to sweep.
# Nothing imports that one any more, but a machine that has been through
# several releases has bytecode there from when something did.
find /usr/prog/klipper/klippy -name '__pycache__' -type d -exec rm -rf {} + 2>/dev/null
sync

# ---- the root password ------------------------------------------------------
# Two ways in, and both end at the same place: this script edits
# /usr/prog/etc/shadow on the machine. (/etc is a bind mount of /usr/prog/etc,
# so that IS the live file dropbear authenticates against.)
#
# BAKED. ROOT_PW_HASH at build time, put here by bin/pack.sh. Applied on every
# flash, which is what the old path did too -- the hash rode in the software
# component's shadow and the component's run.sh copied it over the live file
# every time. Someone who bakes a hash into their own build is saying which
# password their printers have.
#
# RANDOM. An empty ROOT_PW_HASH cannot ship a password at all: one file is
# flashed by many people, so a baked-in default would be the SAME password on
# every printer. Pick a random one here, on the machine, and write it onto the
# USB stick being flashed from. Every printer gets a different one and it is
# never guessable from anything printed on the case.
#
# ORDER MATTERS: the password goes onto the stick and is read back BEFORE the
# printer starts accepting it. A password that was set but never landed on the
# stick is a locked-out printer, so if the write fails we change nothing at all
# and say so.
#
# AN UPDATE MUST NOT REROLL IT, and the test for that is one comparison. Root
# has a real password on a stock printer -- FlashForge ship the hash below, the
# same one on every machine, they just never published what it unlocks -- so
# the question is not "does root have a hash" but "is it still THEIRS". If it
# is, nobody has set one, by us or by hand with `passwd`, and it is ours to
# set. If it is not, someone has, and it is not ours to touch.
#
# Taken from the shadow in the stock software component
# (software-1.9.7.tar.xz, Creator5Pro). If FlashForge ever change it, a printer
# on the new firmware reads as "password already set" and never gets one --
# bin/pack.sh compares this against the stock package it was built from and
# fails the build rather than let that ship silently.
FF_STOCK_PW_HASH='$1$ax/gSlz5$poL89lSQB9./7fUZwc3ej/'

LIVE_HASH=`awk 'BEGIN{FS=":"} $1=="root"{print $2}' /usr/prog/etc/shadow 2>/dev/null`

if [ -n "$MOD_ROOT_PW_HASH" ]; then
    if awk -v h="$MOD_ROOT_PW_HASH" 'BEGIN{FS=OFS=":"} $1=="root"{$2=h} {print}' \
            /usr/prog/etc/shadow > /usr/prog/etc/shadow.new &&
        mv -f /usr/prog/etc/shadow.new /usr/prog/etc/shadow; then
        chmod 600 /usr/prog/etc/shadow
        echo "root password set (the hash baked into this build)"
    else
        echo "!! could not write the baked root password hash"
        echo "!! root password is whatever it was -- ssh may not work"
    fi
elif [ "$MOD_PW_AUTO" = "1" ] && [ "$LIVE_HASH" != "$FF_STOCK_PW_HASH" ]; then
    echo "root password already set on this printer -- left alone"
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
