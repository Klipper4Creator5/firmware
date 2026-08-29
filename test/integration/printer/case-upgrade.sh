#!/bin/sh
# Does an update delete what it installed -- and ONLY what it installed?
#
# WHY THIS EXISTS. Deleting whole directories at the start of an update is
# right only while every file under them is ours -- $MODDIR/bin holds the
# supervisor and the interpreter, and is the obvious place for someone to put a
# script of their own. So bin/patch.sh ships a manifest of the paths the
# payload installs, and the next update deletes what the PREVIOUS list named
# and nothing else.
#
# The property that must not be lost in that trade: S60web was once split into S60nginx and S62moonraker, and on a
# printer that already had the mod the old S60web survived the update and sat
# beside both new scripts -- firmwareExe runs every executable
# $MODDIR/init.d/S* in filename order, so nginx and moonraker were each
# started twice by two scripts that disagreed about where moonraker lives.
# That is what (a) below is: a real S60web, because that is the failure.
#
# So there are two claims here and they pull against each other. Either one
# alone is trivially satisfiable -- delete everything, or delete nothing --
# and only holding both at once means anything. (b) is the negative control
# for (a): a file nothing ever shipped, dropped into the SAME directory as a
# file that does have to go, has to still be there afterwards.
#
# This runs the real installer. `sh $PAYLOAD/run-append.sh` is the block
# bin/patch.sh injects into FlashForge's run.sh, executed by the printer's own
# busybox ash against a real tarball on a real filesystem, and every assertion
# below is a question put to that filesystem afterwards. Nothing here greps
# the installer: a grep would pass on an installer that deletes nothing and
# fail on a variable rename, and neither answer is about the printer.
#
# The payload under test is mounted at /tmp/payload.
FAIL=0
ok()  { echo "  PASS  $*"; }
bad() { echo "  FAIL  $*"; FAIL=1; }

MODDIR=/usr/data/anvil
PAYLOAD=/tmp/payload
INSTALLER=$PAYLOAD/run-append.sh
UPDATE=/usr/data/update
MODTAR=$UPDATE/anvil.tar.xz
MANIFEST=$MODDIR/.install-manifest
LOG=/usr/data/anvil-install.log

[ -f "$INSTALLER" ] || { bad "no run-append.sh at $INSTALLER"; exit 1; }

# ---- the two payload versions ---------------------------------------------
# Built here by hand rather than by the real build. What is under test is
# run-append.sh, whose entire input is a tarball plus whatever the last one
# left on disk, and a five-file payload exercises that exactly as well as a
# 100MB one while leaving the assertions legible. (Whether the real build
# EMITS a manifest is a different question, and bin/verify.sh asks it of the
# package it just built.)
#
# The manifest is generated the same way bin/patch.sh generates it -- find
# over the staged tree, plus the manifest's own name, sorted -- because a
# hand-written fixture list would be a list of what we hoped was in the tree.
pack_payload() {
    src=$1                 # directory to ship
    want=$2                # "manifest" or "no-manifest" (the old layout)
    if [ "$want" = manifest ]; then
        { ( cd "$src" && find . | sed 's|^\./||' | grep -v '^\.$' )
          echo ".install-manifest"
        } | sort -u > "$src/.install-manifest"
    else
        # The same tree shipped as a pre-manifest package would have shipped
        # it. Removing the file rather than building a second directory keeps
        # the two versions of the payload identical in every other respect,
        # so section (e) differs from the sections above in one thing only.
        rm -f "$src/.install-manifest"
    fi
    mkdir -p $UPDATE
    rm -f $MODTAR
    # A plain tar under the .xz name, deliberately: the printer's busybox
    # decompresses xz but does not create it, and run-append.sh documents a
    # fallback from `xz -dc` to plain tar for exactly the case of a build that
    # shipped it uncompressed. Using it here means the fallback is executed by
    # every run of this gate instead of being taken on trust.
    ( cd "$src" && tar -cf $MODTAR . )
}

# The installer sends its own output to $LOG with an exec redirect, so there
# is nothing to capture here; on a failure the tail of that log is printed at
# the end, which is also what one would read off a real printer.
install_payload() { sh "$INSTALLER" >/dev/null 2>&1; }

# ---- version 1: the payload already on the printer ------------------------
rm -rf /tmp/v1 /tmp/v2 $MODDIR
mkdir -p /tmp/v1/bin /tmp/v1/init.d /tmp/v1/www
echo "#!/bin/sh"              > /tmp/v1/bin/anvil-hello   # shipped by both
echo "#!/bin/sh"              > /tmp/v1/bin/helper-v1     # shipped by v1 only
echo "#!/bin/sh"              > /tmp/v1/init.d/S60web     # the stale twin to be
echo "MOD_WEB=1"              > /tmp/v1/anvil.conf
echo "v1"                     > /tmp/v1/www/index.html
pack_payload /tmp/v1 manifest
install_payload

[ -f $MODDIR/init.d/S60web ] && [ -s $MANIFEST ] \
    && ok "version 1 installed, with a manifest at $MANIFEST" \
    || { bad "version 1 did not install -- nothing below would mean anything"
         tail -20 $LOG 2>/dev/null; exit 1; }

# ---- what a printer accumulates between updates ---------------------------
# Everything created here is something the payload did NOT ship, and every one
# of them is a thing an update has destroyed at some point in this project's
# history.
echo "MOD_WEB=0   # edited by hand" > $MODDIR/anvil.conf
echo "#!/bin/sh"                    > $MODDIR/bin/not-ours      # (b)
mkdir -p $MODDIR/config-installed
echo "[server]"                     > $MODDIR/config-installed/moonraker.conf

# ---- version 2: the update ------------------------------------------------
# S60web is gone and split in two, helper-v1 is gone, everything else is the
# same file it always was.
mkdir -p /tmp/v2/bin /tmp/v2/init.d /tmp/v2/www
echo "#!/bin/sh"              > /tmp/v2/bin/anvil-hello
echo "#!/bin/sh"              > /tmp/v2/init.d/S60nginx
echo "#!/bin/sh"              > /tmp/v2/init.d/S62moonraker
echo "MOD_WEB=1"              > /tmp/v2/anvil.conf
echo "v2"                     > /tmp/v2/www/index.html
pack_payload /tmp/v2 manifest
install_payload

# (a) the stale twin. This is the whole reason the old code wiped directories.
[ -f $MODDIR/init.d/S60web ] \
    && bad "(a) S60web survived the update -- firmwareExe would start nginx and moonraker twice" \
    || ok "(a) a renamed init script left no stale twin behind"
[ -f $MODDIR/bin/helper-v1 ] \
    && bad "(a) bin/helper-v1 survived -- a file version 1 shipped and version 2 does not" \
    || ok "(a) a file the previous payload shipped and this one does not is gone"

# (b) THE NEGATIVE CONTROL, and the entire point of the change. It sits in
# $MODDIR/bin, next to helper-v1 which had to go, so nothing but reading the
# manifest can tell the two apart.
[ -f $MODDIR/bin/not-ours ] \
    && ok "(b) a file nothing ever shipped survived the update" \
    || bad "(b) $MODDIR/bin/not-ours was deleted -- the installer is still eating files it does not own"

# (c) anvil.conf, with the user's edit. It IS in the manifest -- the payload
# ships one -- so it is deleted and then put back from /tmp by the installer;
# what matters is the contents that come out the other end, not the file.
if grep -q "edited by hand" $MODDIR/anvil.conf 2>/dev/null; then
    ok "(c) anvil.conf survived with the user's edit intact"
else
    bad "(c) anvil.conf lost its edit: `cat $MODDIR/anvil.conf 2>&1 | head -1`"
fi

# (d) config-installed is the snapshot of the configs the last package wrote,
# and the three-way diff further down run-append.sh cannot tell "unmodified"
# from "edited" without it -- lose it and a config we own lands as .mod-new
# forever. It is never shipped, so it must never be in a manifest; this is
# what proves that.
[ -f $MODDIR/config-installed/moonraker.conf ] \
    && ok "(d) config-installed survived the payload swap" \
    || bad "(d) config-installed was deleted -- moonraker.conf would land as .mod-new forever"

# The new payload has to have left its OWN manifest behind, or the next update
# falls back to the sweep and (b) stops holding from then on.
[ -s $MANIFEST ] && grep -q '^init.d/S60nginx$' $MANIFEST \
    && ok "the update left its own manifest for the next one" \
    || bad "no usable manifest after the update -- the next one reverts to wiping directories"
[ "`cat $MODDIR/www/index.html 2>/dev/null`" = "v2" ] \
    && ok "shipped files were replaced with the new version" \
    || bad "www/index.html is not the version 2 copy -- the payload did not extract"
# `chmod a+x $MODDIR/bin/*` still runs after the extraction. tar preserves the
# mode it was given, so this is only visible on a payload built without one --
# which is what pack_payload above produces, and what makes it worth asking.
[ -x $MODDIR/bin/anvil-hello ] \
    && ok "the installer still makes $MODDIR/bin executable" \
    || bad "$MODDIR/bin/anvil-hello is not executable -- nothing in bin/ would run"

# ---- (e) the compatibility path: a printer with no manifest ---------------
# Every printer in the field today is running a package built before the
# manifest existed, so the first update to reach it finds no list and no way
# to reconstruct one. run-append.sh falls back to exactly the old rm -rf for
# that case, and this is what proves the fallback still cleans up -- an
# upgrade off one of those versions that left S60web in place would be the
# double-start failure all over again, on the very printers least able to
# report it.
#
# Note what is NOT asserted here: a hand-dropped $MODDIR/bin/not-ours does
# not survive this path, and cannot -- the sweep has no way to know it was
# not ours. That is the cost of the branch and the reason run-append.sh marks
# it for deletion once no pre-manifest install can still be upgraded.
rm -rf $MODDIR
mkdir -p $MODDIR/init.d $MODDIR/bin $MODDIR/config-installed
echo "#!/bin/sh"                    > $MODDIR/init.d/S60web
echo "MOD_WEB=0   # edited by hand" > $MODDIR/anvil.conf
echo "[server]"                     > $MODDIR/config-installed/moonraker.conf
[ -f $MANIFEST ] && bad "(e) the pre-manifest layout was set up with a manifest in it"
pack_payload /tmp/v2 no-manifest
install_payload

[ -f $MODDIR/init.d/S60web ] \
    && bad "(e) no manifest and S60web still there -- upgrading from a shipped version leaves stale init scripts" \
    || ok "(e) with no manifest the legacy sweep still removed the stale init script"
[ -f $MODDIR/init.d/S60nginx ] \
    && ok "(e) the new payload extracted over the pre-manifest layout" \
    || bad "(e) the new payload did not install over the pre-manifest layout"
grep -q "edited by hand" $MODDIR/anvil.conf 2>/dev/null \
    && ok "(e) anvil.conf kept its edit through the legacy path too" \
    || bad "(e) anvil.conf lost its edit on the legacy path"
[ -f $MODDIR/config-installed/moonraker.conf ] \
    && ok "(e) config-installed survived the legacy path too" \
    || bad "(e) config-installed was deleted by the legacy sweep"

# ---- the guard against a vacuous pass -------------------------------------
# Every check above is of the form "is this file there?", and all of them
# would report PASS just as happily if the installer had never run at all --
# apart from the ones that would then report FAIL, which is only half a
# defence. run-append.sh says so in its own log, on the printer, in the words
# a support request quotes back.
grep -q "mod payload installed" $LOG 2>/dev/null \
    && ok "the installer ran and said so in $LOG" \
    || bad "$LOG has no record of an install -- the checks above tested nothing"

echo
if [ $FAIL -eq 0 ]; then
    echo "  upgrade: all checks passed"
else
    echo "  --- tail of $LOG ---"
    tail -30 $LOG 2>/dev/null
fi
exit $FAIL
