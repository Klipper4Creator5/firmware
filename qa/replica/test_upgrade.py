"""Does an update replace the whole of $MODDIR, and keep the little that must live?

Two synthetic payloads are built on the printer, the REAL
installer/runFirmwareExe.sh is run over them by the printer's own busybox, and
every question below is put to the filesystem afterwards. Nothing here greps
the installer -- a grep would pass on an installer that deletes nothing and
fail on a variable rename, and neither answer is about the printer.

WHY IT MATTERS. `rm -rf $MODDIR` before extracting makes the installed set the
shipped set by construction: a renamed script cannot survive beside the one
that replaced it, and no list has to be shipped, read or trusted for that to
hold. What it costs is everything else under $MODDIR, so the pair of claims
this module holds is "the whole tree goes" and "the two things that outlive it
did". Either alone is trivially satisfiable -- delete everything, or delete
nothing -- and only both at once mean anything.

The survivor is HelixScreen's settings, held on /tmp across the wipe and copied
back over the tarball's seeded defaults. It is now the ONLY preservation
mechanism in the installer, so it is asserted here with a value that could only
have come from the printer. /usr/data/config is the other half of the answer,
and it is outside $MODDIR entirely: printer.cfg and moonraker-custom.conf are
never candidates for deletion because the wipe cannot reach them.

THE NEGATIVE CONTROL IS INVERTED from what it used to be. `bin/not-ours` is a
file no payload ever shipped, sitting in $MODDIR/bin beside one that has to go,
and it must NOT survive: $MODDIR is the mod's install tree and an owner's own
files belong in /usr/data. See docs/notes/86-wipe-and-extract.md for the audit
behind that trade.

THE FIXTURE FILENAMES ARE ARBITRARY. `bin/helper-v1`, `share/web-launcher`,
`share/nginx-launcher`, `oldskin/` and friends stand for "a path the last
package shipped"; nothing about them is real and no shipped file has those
names.

WHAT THIS MODULE DOES TO THE MACHINE. The `printer` fixture is a replica with
the real package installed, and the first thing here is `rm -rf $MODDIR`: what
is under test is runFirmwareExe.sh, whose entire input is a tarball plus
whatever the last install left on disk, and a hand-built payload exercises that
exactly as well as a 100MB one while leaving the assertions legible. The
container is module-scoped and nothing else shares it, so the wipe costs
nothing -- but it is the reason this lives in its own file. Tests are
sequential steps against one machine, in file order.
"""
import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"
CONFDIR = "/usr/data/config"
LOG = "/usr/data/anvil-install.log"

# The installer is a real file on a printer now -- app_startup.sh runs it out
# of /usr/data/update and deletes it afterwards -- but it is staged here from
# the CHECKOUT rather than read off the replica, so that the thing under test
# is the file in the tree and not the copy a bake happened to leave behind.
#
# Unsubstituted: bin/pack.sh rewrites MACHINE=/PID=/MOD_PW_AUTO= when it stages
# it into a package, and the checkout's MOD_PW_AUTO=0 is what keeps these runs
# from rerolling the replica's root password. The model gate is skipped by
# passing no arguments, which is the case FlashForge's own script documents as
# "old firmware, upgradeable".
INSTALLER = "/tmp/anvil-installer.sh"
SOURCE = ROOT / "installer" / "runFirmwareExe.sh"

# Where the two payloads are built, and where the installer looks for one.
BUILD = "/tmp/anvil-qa"
MODTAR = "/usr/data/update/anvil.tar.xz"

# Under qemu, tar + a few hundred forks of the printer's busybox. Measured runs
# are seconds; this is the "something wedged" line, not an expectation.
INSTALL_T = 300


# --------------------------------------------------------------- the actions

def _pack(box, src):
    """Stage `src` as the payload runFirmwareExe.sh will find on the disk.

    A plain tar under the .xz name, deliberately: the printer's busybox
    decompresses xz but cannot create it, and runFirmwareExe.sh documents a
    fallback from `xz -dc` to plain tar for exactly the case of a build that
    shipped it uncompressed. Packing this way means the fallback is executed
    by every run instead of being taken on trust -- and asserted, below.
    """
    done = box.sh(
        "set -e\n"
        "mkdir -p /usr/data/update\n"
        "rm -f %(tar)s\n"
        "( cd %(src)s && tar -cf %(tar)s . )\n"
        % {"src": src, "tar": MODTAR})
    if not done.ok:
        pytest.fail("could not build the %s payload: %s" % (src, done.text))


def _install(box):
    """Run the real installer and return everything it logged.

    The log is TRUNCATED first, and that is not tidiness. The installer sends
    its own output to $LOG with an `exec >>` append, and this replica was
    assembled by installing the real package -- so the log already carries a
    "mod payload installed" from the bake. Reading it whole would let every
    assertion below pass on a run in which the installer did nothing at all.
    """
    box.sh(": > %s" % LOG)
    box.sh("sh %s" % INSTALLER, timeout=INSTALL_T)
    return box.file(LOG).text


def _tail(log, lines=25):
    return "\n".join(log.splitlines()[-lines:]) or "(the installer logged nothing)"


# -------------------------------------------------------------- the fixtures

@pytest.fixture(scope="module")
def installer(printer):
    """The checkout's runFirmwareExe.sh, staged into the machine."""
    if not SOURCE.is_file():
        pytest.fail(
            "no installer to test: %s is missing from the checkout, and it is "
            "the file under test -- the copy a printer runs is deleted by "
            "app_startup.sh as soon as the install finishes, so it cannot be "
            "read off the replica instead." % SOURCE)
    printer.write(INSTALLER, SOURCE.read_text())
    return printer


@pytest.fixture(scope="module")
def first_install(installer):
    """Version 1: the payload the printer is already carrying.

    `bin/anvil-hello` is shipped by both versions, `bin/helper-v1` and
    `share/web-launcher` by this one only, and `oldskin/` is a whole directory
    that version 2 drops.

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

    _pack(box, BUILD + "/v1")
    log = _install(box)
    if "mod payload installed" not in log:
        pytest.fail(
            "version 1 did not install, so nothing below would mean "
            "anything. Tail of %s:\n%s" % (LOG, _tail(log)))
    return box


@pytest.fixture(scope="module")
def upgraded(first_install):
    """Version 2, installed over version 1 and over what a printer accumulates.

    Planted by hand, each standing for something no payload ships: `bin/
    not-ours` is the negative control, `anvil.conf` carries an edit, and
    init.d/S70klipper and anvil-service.sh are the leftovers of a pre-s6-rc
    release. All of them must go, and the wipe is the only thing that takes
    them -- there is no list that names any of them.

    Two things must survive, and are planted with values that could only have
    come from this printer: HelixScreen's settings.json, and an edited
    /usr/data/config/moonraker.conf, which is outside $MODDIR and must be
    overwritten anyway because the mod owns it.

    Version 2 drops helper-v1 and oldskin/, splits share/web-launcher in two --
    the rename that started all this -- and ships a settings.json and a
    moonraker.conf of its own for the two survivors to be measured against.
    """
    box = first_install
    planted = box.sh(
        "set -e\n"
        "echo 'MOD_WEB=0   # edited by hand' > %(mod)s/anvil.conf\n"
        "echo '#!/bin/sh' > %(mod)s/bin/not-ours\n"
        "mkdir -p %(mod)s/init.d\n"
        "echo '#!/bin/sh' > %(mod)s/init.d/S70klipper\n"
        "echo '#!/bin/sh' > %(mod)s/anvil-service.sh\n"
        # The survivor: HelixScreen writes its settings inside its own install
        # tree, so the wipe would take them without the /tmp stash.
        "mkdir -p %(mod)s/helixscreen/config\n"
        "echo mine > %(mod)s/helixscreen/config/settings.json\n"
        # Outside $MODDIR, and ours to replace: an edit here used to be kept
        # and landed the new version as .mod-new.
        "mkdir -p %(conf)s\n"
        "echo 'edited by hand' > %(conf)s/moonraker.conf\n"
        "mkdir -p %(build)s/v2/bin %(build)s/v2/share %(build)s/v2/www "
        "%(build)s/v2/helixscreen/config %(build)s/v2/config\n"
        "echo '#!/bin/sh' > %(build)s/v2/bin/anvil-hello\n"
        "echo '#!/bin/sh' > %(build)s/v2/share/nginx-launcher\n"
        "echo '#!/bin/sh' > %(build)s/v2/share/moonraker-launcher\n"
        "echo shipped > %(build)s/v2/helixscreen/config/settings.json\n"
        "echo v2 > %(build)s/v2/config/moonraker.conf\n"
        # NO anvil.conf in v2, deliberately: the payload ships none any more,
        # which is what makes the printer's copy something to remove rather
        # than something to put back.
        "echo v2 > %(build)s/v2/www/index.html\n"
        % {"build": BUILD, "mod": MODDIR, "conf": CONFDIR})
    if not planted.ok:
        pytest.fail("could not set up the upgrade: %s" % planted.text)

    _pack(box, BUILD + "/v2")
    box.upgrade_log = _install(box)
    return box


# ------------------------------------------------------- version 1 is on disk

def test_the_first_install_extracted_the_payload(first_install):
    assert first_install.file(MODDIR + "/www/index.html").text.strip() == "v1", (
        "version 1's payload is not on disk: %r"
        % first_install.file(MODDIR + "/www/index.html").text)


# --------------------------------------------------------------- the upgrade

def test_the_upgrade_ran_and_said_so(upgraded):
    """First, because every check that follows is of the form "is this file
    there?" and all of them would answer just as happily if the installer had
    never run -- apart from those that would then fail, which is only half a
    defence. runFirmwareExe.sh says so in its own log, on the printer, in the
    words a support request quotes back."""
    assert "mod payload installed" in upgraded.upgrade_log, (
        "%s has no record of the update:\n%s"
        % (LOG, _tail(upgraded.upgrade_log)))


def test_the_upgrade_wiped_the_directory(upgraded):
    """The installer says which thing it did, and there is only one thing it
    can say now. An installer that quietly went back to pruning by a list would
    pass most of the deletions below and fail only the negative control -- one
    confusing red instead of a diagnosis."""
    assert "previous install removed (wiped)" in upgraded.upgrade_log, (
        "the installer did not report the wipe:\n%s"
        % _tail(upgraded.upgrade_log))


def test_the_plain_tar_fallback_is_what_ran(upgraded):
    """The payload is an uncompressed tar under the .xz name, so the installer's
    documented `xz -dc` -> `tar -xf` fallback is what extracted it. If this
    ever reports (xz), the fallback stopped being covered by this module."""
    assert "extracted (plain tar)" in upgraded.upgrade_log, (
        "not the plain-tar path:\n%s" % _tail(upgraded.upgrade_log))


def test_a_file_the_last_payload_shipped_and_this_one_does_not_is_gone(upgraded):
    """Extracting over the old tree without removing anything is harmless only
    while the set of filenames never changes, and it does."""
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
    """A payload that drops a whole subtree leaves nothing behind."""
    assert not upgraded.file(MODDIR + "/oldskin").exists, (
        "%s/oldskin survived the wipe" % MODDIR)


def test_a_file_nothing_ever_shipped_is_gone_too(upgraded):
    """THE NEGATIVE CONTROL, and it is the inverse of what it used to be. It
    sits in $MODDIR/bin next to helper-v1, which also had to go, and telling
    the two apart is exactly what this installer no longer tries to do:
    $MODDIR is the mod's tree and everything in it is replaced. An owner's own
    files belong in /usr/data, which the wipe cannot reach."""
    assert not upgraded.file(MODDIR + "/bin/not-ours").exists, (
        "%s/bin/not-ours survived -- something is still pruning selectively "
        "instead of replacing the tree" % MODDIR)


def test_init_d_and_anvil_service_are_gone(upgraded):
    """Both were planted by hand and neither is in any payload, so the wipe is
    the only thing that can take them. A leftover S70klipper starts an
    unsupervised klippy beside the supervised one, and a leftover
    anvil-service.sh is a library something stale could still source."""
    assert not upgraded.file(MODDIR + "/init.d").exists, (
        "%s/init.d survived; firmwareExe's predecessor ran every S* in it"
        % MODDIR)
    assert not upgraded.file(MODDIR + "/anvil-service.sh").exists, (
        "%s/anvil-service.sh survived the update" % MODDIR)


def test_anvil_conf_is_removed_rather_than_kept(upgraded):
    """The payload ships no anvil.conf any more, so the upgrade takes the
    printer's away -- edit and all. The edit planted by the fixture is what
    makes the deletion provable: a file that merely still exists could be the
    shipped default."""
    conf = upgraded.file(MODDIR + "/anvil.conf")
    assert not conf.exists, (
        "%s/anvil.conf survived the upgrade with %r in it -- nothing reads "
        "it any more, so it is a file inviting an edit that does nothing"
        % (MODDIR, conf.text))


def test_no_manifest_is_written(upgraded):
    """Nothing ships or reads one. A file reappearing here would mean a payload
    still carries the list, which is 3000 lines of the one file in the tree
    that differs between two otherwise identical builds."""
    assert not upgraded.file(MODDIR + "/.install-manifest").exists, (
        "%s/.install-manifest is back -- the payload is still shipping a list "
        "nothing reads" % MODDIR)


# ---------------------------------------------------- what outlives the wipe

def test_helixscreen_settings_survive_the_wipe(upgraded):
    """The one preservation mechanism left in the installer, so it carries the
    whole weight of "an update does not cost you what you set on the screen".

    The value asserted is the one planted on the printer, not merely a file
    that exists: version 2 ships a settings.json of its own, so a restore that
    silently did nothing would leave the shipped copy sitting there and pass a
    weaker check."""
    live = upgraded.file(MODDIR + "/helixscreen/config/settings.json")
    assert live.exists, (
        "%s/helixscreen/config/settings.json is gone -- the wipe took the "
        "user's screen settings with it" % MODDIR)
    assert live.text.strip() == "mine", (
        "the tarball's seeded settings.json landed on top of the user's: %r"
        % live.text)


def test_the_users_config_directory_is_outside_the_wipe(upgraded):
    """/usr/data/config is where everything an owner edits lives, and nothing
    in the installer's deletion path can reach it. This is the assertion that
    nothing needs to."""
    assert upgraded.file(CONFDIR).is_dir, (
        "%s is gone -- the wipe reached outside $MODDIR" % CONFDIR)


def test_moonraker_conf_is_overwritten_even_when_edited(upgraded):
    """It is mod-owned, like every ff-*.cfg: overwriting is how the [webcam]
    block and the API lockdown reach a printer at all. The seam for an owner's
    own settings is moonraker-custom.conf, included last so it wins.

    The fixture planted an edit, so a copy left behind would be visible here as
    the old text rather than as a missing file."""
    live = upgraded.file(CONFDIR + "/moonraker.conf")
    assert live.text.strip() == "v2", (
        "%s/moonraker.conf was not replaced: %r" % (CONFDIR, live.text))
    assert not upgraded.file(CONFDIR + "/moonraker.conf.mod-new").exists, (
        "a .mod-new was written -- the compare-and-keep dance is back")


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
