"""Does an update delete what the last one installed -- and ONLY that?

A port of test/integration/printer/case-upgrade.sh, which was 224 lines of ash
reporting one bit. Same subject, same method: two synthetic payloads are built
on the printer, the REAL installer/run-append.sh is run over them by the
printer's own busybox, and every question below is put to the filesystem
afterwards. Nothing here greps the installer -- a grep would pass on an
installer that deletes nothing and fail on a variable rename, and neither
answer is about the printer.

WHY IT MATTERS. Deleting whole directories at the start of an update is right
only while every file under them is ours, and $MODDIR/bin holds the supervisor
and the interpreter and is the obvious place for someone to leave a script of
their own. So bin/patch.sh ships a manifest of the paths the payload installs
and run-append.sh deletes what the PREVIOUS list named, nothing else. Two
claims that pull against each other: either alone is trivially satisfiable
(delete everything, or delete nothing) and only holding both at once means
anything. The negative control -- a hand-dropped file in the SAME directory as
one that has to go -- is what makes the pair a test.

THE FIXTURE FILENAMES ARE ARBITRARY. `bin/helper-v1`, `share/web-launcher`,
`share/nginx-launcher`, `oldskin/` and friends stand for "a path the last
package shipped"; nothing about them is real and no shipped file has those
names. The case script used init.d/S60web, S60nginx and S62moonraker because
the failure that prompted all this was a renamed init script surviving an
update and starting nginx twice. Those names are NOT reused here, for a
reason worth recording: run-append.sh now removes $MODDIR/init.d and
$MODDIR/anvil-service.sh UNCONDITIONALLY, whatever any manifest says, so an
assertion about a file under init.d cannot distinguish the manifest from the
sweep and would pass on an installer whose manifest logic had been deleted
outright. The unconditional removal is asserted in its own right below; the
manifest is asserted with names in directories only it governs.

WHAT THIS MODULE DOES TO THE MACHINE. The `printer` fixture is a replica with
the real package installed, and the first thing here is `rm -rf $MODDIR`: what
is under test is run-append.sh, whose entire input is a tarball plus whatever
the last install left on disk, and a hand-built five-file payload exercises
that exactly as well as a 100MB one while leaving the assertions legible.
The container is module-scoped and nothing else shares it, so the wipe costs
nothing -- but it is the reason this lives in its own file. Tests are
sequential steps against one machine, in file order, as the case script's
sections were.

DELIBERATELY DROPPED from the port: nothing. Two things are ADDED, because
they are cheap here and were not observable from a case script's exit code --
the log line that says WHICH deletion branch ran (manifest or pre-manifest
sweep), and the rmdir pass, which the case script never exercised.
"""
import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
MANIFEST = MODDIR + "/.install-manifest"
LOG = "/usr/data/anvil-install.log"

# run-append.sh is never a file on a printer: bin/patch.sh splices it into
# FlashForge's own run.sh. It is staged into the chroot from the checkout so
# that the thing under test is the file in the tree, not a copy of it.
INSTALLER = "/tmp/anvil-run-append.sh"
SOURCE = ROOT / "installer" / "run-append.sh"

# Where the two payloads are built, and where run-append.sh looks for one.
BUILD = "/tmp/anvil-qa"
MODTAR = "/usr/data/update/anvil.tar.xz"

# Under qemu, tar + a few hundred forks of the printer's busybox. Measured runs
# are seconds; this is the "something wedged" line, not an expectation.
INSTALL_T = 300


# --------------------------------------------------------------- the actions

def _pack(box, src, with_manifest):
    """Stage `src` as the payload run-append.sh will find on the disk.

    The manifest is generated the way bin/patch.sh generates it -- find over
    the staged tree, plus the manifest's own name, LC_ALL=C sort -u -- rather
    than written out by hand here, because a hand-written fixture list would
    be a list of what we HOPED was in the tree.

    One deviation, and it is not a difference in the result: patch.sh drops
    the tree's own root with `find -mindepth 1`, which is a GNU extension the
    printer's busybox find need not have. This runs on the printer, so the
    root is dropped with the grep the case script used instead.

    A plain tar under the .xz name, deliberately: the printer's busybox
    decompresses xz but cannot create it, and run-append.sh documents a
    fallback from `xz -dc` to plain tar for exactly the case of a build that
    shipped it uncompressed. Packing this way means the fallback is executed
    by every run instead of being taken on trust -- and asserted, below.
    """
    if with_manifest:
        manifest = (
            "{ ( cd %(src)s && find . | sed 's|^\\./||' | grep -v '^\\.$' )\n"
            "  echo '.install-manifest'\n"
            "} | LC_ALL=C sort -u > %(src)s/.install-manifest\n" % {"src": src})
    else:
        # The same tree shipped as a pre-manifest package would have shipped
        # it. Removing the file rather than building a second directory keeps
        # the two payloads identical in every other respect, so the legacy
        # section differs from the ones above it in one thing only. The
        # removal itself is the unconditional line below.
        manifest = ""
    done = box.sh(
        "set -e\n"
        "rm -f %(src)s/.install-manifest\n"
        "%(manifest)s"
        "mkdir -p /usr/data/update\n"
        "rm -f %(tar)s\n"
        "( cd %(src)s && tar -cf %(tar)s . )\n"
        % {"src": src, "manifest": manifest, "tar": MODTAR})
    if not done.ok:
        pytest.fail("could not build the %s payload: %s" % (src, done.text))


def _install(box):
    """Run the real installer and return everything it logged.

    The log is TRUNCATED first, and that is not tidiness. run-append.sh sends
    its own output to $LOG with an `exec >>` append, and this replica was
    assembled by installing the real package -- so the log already carries a
    "mod payload installed" from the bake. Reading it whole would let every
    assertion below pass on a run in which the installer did nothing at all,
    which is the exact vacuity the case script's final check existed to close.
    """
    box.sh(": > %s" % LOG)
    box.sh("sh %s" % INSTALLER, timeout=INSTALL_T)
    return box.file(LOG).text


def _tail(log, lines=25):
    return "\n".join(log.splitlines()[-lines:]) or "(the installer logged nothing)"


# -------------------------------------------------------------- the fixtures

@pytest.fixture(scope="module")
def installer(printer):
    """The checkout's run-append.sh, staged into the machine."""
    if not SOURCE.is_file():
        pytest.fail(
            "no installer to test: %s is missing from the checkout, and it is "
            "the file under test -- bin/patch.sh splices it into FlashForge's "
            "run.sh, so it is never a file on a printer and cannot be read "
            "off the replica instead." % SOURCE)
    printer.write(INSTALLER, SOURCE.read_text())
    return printer


@pytest.fixture(scope="module")
def first_install(installer):
    """Version 1: the payload the printer is already carrying.

    Five files. `bin/anvil-hello` is shipped by both versions, `bin/helper-v1`
    and `share/web-launcher` by this one only, and `oldskin/` is a whole
    directory that version 2 drops.

    The install is guarded here rather than asserted downstream: if version 1
    never landed, every question in this file is being put to an empty
    directory and the answers are noise.
    """
    box = installer
    built = box.sh(
        "set -e\n"
        "rm -rf %(build)s %(mod)s\n"
        "mkdir -p %(build)s/v1/bin %(build)s/v1/share %(build)s/v1/www "
        "%(build)s/v1/oldskin\n"
        "echo '#!/bin/sh' > %(build)s/v1/bin/anvil-hello\n"
        "echo '#!/bin/sh' > %(build)s/v1/bin/helper-v1\n"
        "echo '#!/bin/sh' > %(build)s/v1/share/web-launcher\n"
        # v1 stands in for a release that still shipped an anvil.conf, so
        # that the upgrade below is the real jump a printer takes.
        "echo 'MOD_WEB=1'  > %(build)s/v1/anvil.conf\n"
        "echo v1 > %(build)s/v1/www/index.html\n"
        "echo v1 > %(build)s/v1/oldskin/index.html\n"
        % {"build": BUILD, "mod": MODDIR})
    if not built.ok:
        pytest.fail("could not build the version 1 tree: %s" % built.text)

    _pack(box, BUILD + "/v1", with_manifest=True)
    log = _install(box)
    if "mod payload installed" not in log:
        pytest.fail(
            "version 1 did not install, so nothing below would mean "
            "anything. Tail of %s:\n%s" % (LOG, _tail(log)))
    return box


@pytest.fixture(scope="module")
def upgraded(first_install):
    """Version 2, installed over version 1 and over what a printer accumulates.

    Everything planted here is something no payload ever shipped, and every
    one of them is a thing an update has destroyed at some point in this
    project's history. `bin/not-ours` is THE negative control: it sits in
    $MODDIR/bin beside `helper-v1`, which does have to go, so nothing but
    reading the manifest can tell the two apart.

    init.d/S70klipper and anvil-service.sh are planted too, and they are the
    opposite claim: run-append.sh removes both unconditionally because the
    payload ships neither any more, and a leftover S70klipper starts an
    unsupervised klippy beside the supervised one.

    Version 2 drops helper-v1 and oldskin/ and splits share/web-launcher in
    two, which is the rename that started all this.
    """
    box = first_install
    planted = box.sh(
        "set -e\n"
        "echo 'MOD_WEB=0   # edited by hand' > %(mod)s/anvil.conf\n"
        "echo '#!/bin/sh' > %(mod)s/bin/not-ours\n"
        "mkdir -p %(mod)s/config-installed\n"
        "echo '[server]' > %(mod)s/config-installed/moonraker.conf\n"
        "mkdir -p %(mod)s/init.d\n"
        "echo '#!/bin/sh' > %(mod)s/init.d/S70klipper\n"
        "echo '#!/bin/sh' > %(mod)s/anvil-service.sh\n"
        "mkdir -p %(build)s/v2/bin %(build)s/v2/share %(build)s/v2/www\n"
        "echo '#!/bin/sh' > %(build)s/v2/bin/anvil-hello\n"
        "echo '#!/bin/sh' > %(build)s/v2/share/nginx-launcher\n"
        "echo '#!/bin/sh' > %(build)s/v2/share/moonraker-launcher\n"
        # NO anvil.conf in v2, deliberately: the payload ships none any more,
        # which is what makes the printer's copy something to remove rather
        # than something to put back.
        "echo v2 > %(build)s/v2/www/index.html\n"
        % {"build": BUILD, "mod": MODDIR})
    if not planted.ok:
        pytest.fail("could not set up the upgrade: %s" % planted.text)

    _pack(box, BUILD + "/v2", with_manifest=True)
    box.upgrade_log = _install(box)
    return box


@pytest.fixture(scope="module")
def legacy(upgraded):
    """The compatibility path: a printer whose install predates the manifest.

    Every printer running a package built before the manifest existed has no
    $MODDIR/.install-manifest and no way to reconstruct one, so run-append.sh
    falls back to the old sweep of whole directories. An upgrade off one of
    those that left a renamed script in place would be the double-start
    failure all over again, on the printers least able to report it.

    NOT asserted here, because it cannot be: a hand-dropped bin/not-ours does
    not survive this path. The sweep has no way to know it was not ours, which
    is the cost of the branch and the reason run-append.sh marks it for
    deletion once no pre-manifest install can still be upgraded.
    """
    box = upgraded
    laid = box.sh(
        "set -e\n"
        "rm -rf %(mod)s\n"
        "mkdir -p %(mod)s/bin %(mod)s/config-installed\n"
        "echo '#!/bin/sh' > %(mod)s/bin/stale-legacy\n"
        "echo 'MOD_WEB=0   # edited by hand' > %(mod)s/anvil.conf\n"
        "echo '[server]' > %(mod)s/config-installed/moonraker.conf\n"
        % {"mod": MODDIR})
    if not laid.ok:
        pytest.fail("could not lay down the pre-manifest layout: %s" % laid.text)
    if box.file(MANIFEST).exists:
        pytest.fail("the pre-manifest layout was set up with a manifest in it "
                    "-- this fixture would be testing the manifest branch")

    _pack(box, BUILD + "/v2", with_manifest=False)
    box.legacy_log = _install(box)
    return box


# ------------------------------------------------------- version 1 is on disk

def test_the_first_install_shipped_a_manifest(first_install):
    """Without one the update below takes the compatibility sweep, and every
    claim about what it spares is a claim about a branch that did not run."""
    listed = first_install.file(MANIFEST).lines
    assert listed, "%s is empty or missing after the first install" % MANIFEST
    assert ".install-manifest" in listed, (
        "the manifest does not name itself, so the next update cannot replace "
        "it: %r" % listed)
    assert "share/web-launcher" in listed, listed


def test_the_first_install_extracted_the_payload(first_install):
    assert first_install.file(MODDIR + "/www/index.html").text.strip() == "v1", (
        "version 1's payload is not on disk: %r"
        % first_install.file(MODDIR + "/www/index.html").text)


# ------------------------------------------------------------- the upgrade

def test_the_upgrade_ran_and_said_so(upgraded):
    """First, because every check that follows is of the form "is this file
    there?" and all of them would answer just as happily if the installer had
    never run -- apart from those that would then fail, which is only half a
    defence. run-append.sh says so in its own log, on the printer, in the
    words a support request quotes back."""
    assert "mod payload installed" in upgraded.upgrade_log, (
        "%s has no record of the update:\n%s"
        % (LOG, _tail(upgraded.upgrade_log)))


def test_the_upgrade_took_the_manifest_branch(upgraded):
    """The two deletion paths leave very similar filesystems and only the log
    distinguishes them. Without this, an installer that silently fell through
    to the sweep would pass every deletion test below and fail only the
    negative control -- one confusing red instead of a diagnosis."""
    assert "previous install removed (manifest)" in upgraded.upgrade_log, (
        "the installer did not report the manifest branch:\n%s"
        % _tail(upgraded.upgrade_log))


def test_the_plain_tar_fallback_is_what_ran(upgraded):
    """The payload is an uncompressed tar under the .xz name, so run-append's
    documented `xz -dc` -> `tar -xf` fallback is what extracted it. If this
    ever reports (xz), the fallback stopped being covered by this module."""
    assert "extracted (plain tar)" in upgraded.upgrade_log, (
        "not the plain-tar path:\n%s" % _tail(upgraded.upgrade_log))


def test_a_file_the_last_payload_shipped_and_this_one_does_not_is_gone(upgraded):
    """Half the trade. Extracting over the old tree without removing anything
    is harmless only while the set of filenames never changes, and it does."""
    assert not upgraded.file(MODDIR + "/bin/helper-v1").exists, (
        "bin/helper-v1 survived -- a file version 1 shipped and version 2 "
        "does not")


def test_a_renamed_file_leaves_no_stale_twin(upgraded):
    """The failure this whole mechanism exists for: one script split into two,
    with the original left sitting beside both of them."""
    assert not upgraded.file(MODDIR + "/share/web-launcher").exists, (
        "share/web-launcher survived its own replacement")
    for name in ("nginx-launcher", "moonraker-launcher"):
        assert upgraded.file(MODDIR + "/share/" + name).exists, (
            "share/%s is not there, so the rename did not happen and the "
            "check above proves nothing" % name)


def test_a_directory_the_last_payload_shipped_is_removed_too(upgraded):
    """The manifest's second pass -- reverse sort, rmdir, deepest first. The
    file inside oldskin/ goes in pass 1 and the emptied directory in pass 2;
    a payload that drops a whole subtree leaves nothing behind."""
    assert not upgraded.file(MODDIR + "/oldskin").exists, (
        "%s/oldskin survived, so emptied directories are never rmdir'd"
        % MODDIR)


def test_a_file_nothing_ever_shipped_survives(upgraded):
    """THE NEGATIVE CONTROL, and the entire point of the manifest. It sits in
    $MODDIR/bin next to helper-v1, which had to go, so nothing but reading the
    manifest can tell the two apart."""
    assert upgraded.file(MODDIR + "/bin/not-ours").exists, (
        "%s/bin/not-ours was deleted -- the installer is still eating files "
        "it does not own" % MODDIR)


def test_the_directory_holding_it_survives_too(upgraded):
    """The other half of pass 2. bin/ IS in the manifest, so it is offered to
    rmdir; it must be refused while a file we never shipped is still in it.
    A pass that forced the directory would take the file with it."""
    assert upgraded.file(MODDIR + "/bin").is_dir, (
        "%s/bin is gone, so the rmdir pass is not honouring a non-empty "
        "directory" % MODDIR)


def test_init_d_and_anvil_service_go_unconditionally(upgraded):
    """These two are removed whatever the manifest says, and must be: the
    payload ships neither any more, so nothing names them, and a leftover
    S70klipper starts an unsupervised klippy beside the supervised one while a
    leftover anvil-service.sh is a library something stale could still source.
    Both were planted here by hand -- exactly the case a manifest diff cannot
    see."""
    assert not upgraded.file(MODDIR + "/init.d").exists, (
        "%s/init.d survived; firmwareExe's predecessor ran every S* in it"
        % MODDIR)
    assert not upgraded.file(MODDIR + "/anvil-service.sh").exists, (
        "%s/anvil-service.sh survived the update" % MODDIR)


def test_anvil_conf_is_removed_rather_than_kept(upgraded):
    """The payload ships no anvil.conf any more, so the upgrade takes the
    printer's away -- edit and all.

    This is the reversal of the property this test used to hold. The file was
    user state, preserved across updates through /tmp; it is now inert, and
    an inert file at the top of $MODDIR that still looks editable is worse
    than no file. The edit planted by the fixture is what makes the deletion
    provable: a file that merely still exists could be the shipped default.
    """
    conf = upgraded.file(MODDIR + "/anvil.conf")
    assert not conf.exists, (
        "%s/anvil.conf survived the upgrade with %r in it -- nothing reads "
        "it any more, so it is a file inviting an edit that does nothing"
        % (MODDIR, conf.text))


def test_config_installed_survives_the_payload_swap(upgraded):
    """config-installed is the snapshot of the configs the last package wrote,
    and the three-way diff further down run-append.sh cannot tell "unmodified"
    from "edited" without it -- lose it and a config we own lands as .mod-new
    forever. It is never shipped, so it is never in a manifest, and this is
    what proves the deletion respects that."""
    assert upgraded.file(MODDIR + "/config-installed/moonraker.conf").exists, (
        "%s/config-installed was deleted -- moonraker.conf would land as "
        ".mod-new forever" % MODDIR)


def test_the_upgrade_left_its_own_manifest(upgraded):
    """Or the NEXT update falls back to the sweep and the negative control
    stops holding from then on."""
    listed = upgraded.file(MANIFEST).lines
    assert listed, "%s is empty or missing after the update" % MANIFEST
    assert "share/nginx-launcher" in listed, (
        "the manifest does not describe the payload just installed: %r"
        % listed)
    assert "bin/helper-v1" not in listed, (
        "the new manifest still names a version 1 path: %r" % listed)


def test_shipped_files_are_replaced_with_the_new_version(upgraded):
    got = upgraded.file(MODDIR + "/www/index.html").text.strip()
    assert got == "v2", "www/index.html is not the version 2 copy: %r" % got


def test_the_installer_still_makes_bin_executable(upgraded):
    """`chmod a+x $MODDIR/bin/*` still runs after the extraction. tar preserves
    the mode it was given, so this is only visible on a payload built without
    one -- which is what _pack produces, and what makes it worth asking."""
    assert upgraded.file(MODDIR + "/bin/anvil-hello").executable, (
        "%s/bin/anvil-hello is not executable -- nothing in bin/ would run"
        % MODDIR)


# ---------------------------------------- the printers that have no manifest

def test_the_legacy_path_ran_and_said_so(legacy):
    """Same vacuity guard as above, and the same reason it comes first: this
    section's fixture rebuilt $MODDIR by hand, so an installer that did
    nothing at all leaves a filesystem that answers several of the questions
    below correctly."""
    assert "mod payload installed" in legacy.legacy_log, (
        "%s has no record of the legacy install:\n%s"
        % (LOG, _tail(legacy.legacy_log)))
    assert "previous install removed (no manifest -- pre-manifest layout)" \
        in legacy.legacy_log, (
            "the installer did not take the pre-manifest branch:\n%s"
            % _tail(legacy.legacy_log))


def test_the_legacy_sweep_removed_the_stale_file(legacy):
    """bin/ is one of the seven directories the sweep wipes. A renamed script
    left in place here is the double-start failure, on a printer whose owner
    has no manifest to protect them."""
    assert not legacy.file(MODDIR + "/bin/stale-legacy").exists, (
        "with no manifest, %s/bin/stale-legacy is still there -- upgrading "
        "from a shipped pre-manifest version leaves stale files behind"
        % MODDIR)


def test_the_payload_extracted_over_the_pre_manifest_layout(legacy):
    assert legacy.file(MODDIR + "/share/nginx-launcher").exists, (
        "the new payload did not install over the pre-manifest layout")


def test_anvil_conf_is_removed_on_the_legacy_path(legacy):
    """The path that could most easily have left it behind.

    The pre-manifest sweep removes seven DIRECTORIES, and anvil.conf is a file
    at the top of $MODDIR, so nothing in that branch touches it. It goes only
    because run-append.sh removes it unconditionally alongside init.d and
    anvil-service.sh -- which is exactly why it is removed there and not left
    to the manifest.
    """
    conf = legacy.file(MODDIR + "/anvil.conf")
    assert not conf.exists, (
        "%s/anvil.conf survived the pre-manifest path with %r in it -- the "
        "directory sweep does not reach a top-level file, so the "
        "unconditional removal is the only thing that takes it"
        % (MODDIR, conf.text))


def test_config_installed_survives_the_legacy_sweep(legacy):
    """It is not one of the seven directories, and must not become one."""
    assert legacy.file(MODDIR + "/config-installed/moonraker.conf").exists, (
        "%s/config-installed was deleted by the legacy sweep" % MODDIR)
