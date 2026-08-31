"""The two facts about recipe layout that have a consequence.

A recipe directory has a fixed shape -- build.sh and pkg.conf beside
payload/, seed/ and control/ -- and recipes live at two depths, pkgs/<name>/
for the ones carrying files of this repo and pkgs/3rdparty/<name>/ for the ones
building a pinned tarball. That shape is documented in docs/building.md and in
pkgs/lib.sh, which is the only code that depends on it.

MOST OF IT IS NOT ASSERTED HERE, and that is deliberate. This file used to hold
seven more tests: that a recipe contains no fourth kind of directory, that each
kind is still used by someone, that a 3rdparty recipe carries no files of ours
and a first-party one carries some, that installer/ holds exactly two named
files. Every one of them compared the tree against a description of the tree.
None could go red for a reason a printer would notice -- a stray file in a
recipe directory is not read by anything, and a recipe filed at the wrong depth
still builds the same package -- while all seven went red the moment the layout
legitimately changed, which is the opposite of what a test is for.

What is left is the two that bite:
"""
import os

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

MODDIR_PREFIX = ("usr", "opt", "var", "proc", "sys", "dev")

THIRD = os.path.join(ROOT, "pkgs", "3rdparty")


def recipes():
    """(name, directory) for every recipe, at either level."""
    out = []
    for base in (os.path.join(ROOT, "pkgs"), THIRD):
        for n in sorted(os.listdir(base)):
            d = os.path.join(base, n)
            if os.path.isfile(os.path.join(d, "pkg.conf")):
                out.append((n, d))
    return out


def test_there_are_recipes():
    """A glob that silently matches nothing is a test that passes hollow.

    Both tests below iterate recipes(); this is what stops them reporting
    green over an empty list.
    """
    assert len(recipes()) > 10


def test_nothing_under_a_payload_escapes_the_prefix():
    """payload/ is a $MODDIR overlay, so it may not name an absolute path.

    A file at payload/usr/bin/x stages to $MODDIR/usr/bin/x -- correct-looking
    and wrong. The whole reason the mod lives on /usr/data is that /usr is
    FlashForge's and an OTA rewrites it, so a package that owned a path up
    there would survive exactly until the next factory update and take
    whatever it overwrote with it.

    qa/static/test_packages.py asks the same question of every BUILT package, which is
    the stronger form. This one is kept beside it because it runs on a bare
    checkout with no feed, and names the recipe rather than the artefact.
    """
    bad = []
    for name, rd in recipes():
        d = os.path.join(rd, "payload")
        for top in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if top in MODDIR_PREFIX:
                bad.append("%s payload/%s" % (name, top))
    assert not bad, (
        "payload/ is rooted at $MODDIR, not at /: %s" % ", ".join(bad))


def test_recipe_names_are_unique_across_the_two_levels():
    """pkg_out, pkg_stamp and the package filename are all keyed by the bare name.

    A name at both levels would resolve to whichever pkgs/lib.sh's pkg_dir
    searches first and quietly build the other one's package. Nothing
    downstream can catch that: the wrong package builds perfectly.
    """
    names = [n for n, _ in recipes()]
    dupes = sorted({n for n in names if names.count(n) > 1})
    assert not dupes, (
        "recipe name at both levels: %s -- pkg_dir would silently pick one"
        % ", ".join(dupes))


def test_klipper_still_depends_on_numpy():
    """The one Depends in this repo whose absence is a printer that will not boot.

    Every other name in anvil-klipper's Depends means "klippy imports this".
    numpy means "klippy does not start": extras/stepper_resonance_tester.py
    opens with a bare `import numpy as np`, klippy.py:122 walks EVERY config
    section through a load_object, and klippy.py:103 does not catch
    ImportError -- so with printer.base.cfg including FlashForge's
    printer.vibration.cfg ([stepper_resonance_tester]), dropping this line does
    not lose a feature, it bricks the boot.

    It is asserted HERE, statically, because the replica gates that would catch
    it (qa/replica/test_klippy_extras_import.py, test_numpy.py) need an image
    baked and a container up, and this one is a grep. It is the cheapest gate
    on the most expensive mistake, and the mistake has already been made once:
    two comments in this repo asserted the module guarded its own import, and
    the dependency did not exist at all until the note that disproved them.

    See docs/notes/44-vfa-calibration.md.
    """
    conf = os.path.join(ROOT, "pkgs", "klipper", "pkg.conf")
    assert os.path.isfile(conf), "pkgs/klipper/pkg.conf is gone"
    text = open(conf, encoding="utf-8").read()

    # The recipe it must name has to be a recipe, or the Depends resolves to
    # nothing at install time and apk refuses the package.
    assert any(n == "python-numpy" for n, _ in recipes()), \
        "no python-numpy recipe, so anvil-klipper's Depends names a package " \
        "no feed of ours builds"

    depends = "".join(
        line for line in text.splitlines(keepends=True)
        if not line.lstrip().startswith("#"))
    assert "anvil-python-numpy" in depends, (
        "anvil-klipper no longer depends on anvil-python-numpy. That is not a "
        "lost feature -- klippy loads [stepper_resonance_tester] from "
        "FlashForge's printer.vibration.cfg and dies on the ImportError, so "
        "the printer never reaches ready.")
