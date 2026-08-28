"""A recipe directory has a fixed shape, and the shape is what says where a
file goes.

The repository used to keep everything it ships in one top-level payload/
tree, organised by DESTINATION -- init.d/, bin/, etc/s6/, klipper/config/ --
and the only thing recording which package owned any of it was a thirty-line
comment at the top of pkg/anvil-core/build.sh. A comment cannot be checked.
Three kinds of file lived in there and looked identical:

  * files a recipe stages into its .ipk,
  * files that go to /usr/prog and CANNOT be in a package, because every path
    in one of ours lands under $MODDIR,
  * files that never ship as files at all -- run-pre.sh and run-append.sh are
    spliced into FlashForge's own run.sh at build time.

Now each of those is a directory name inside the recipe that owns the file:

    pkg/<recipe>/payload/   staged into the .ipk, laid out as it lands under
                            $MODDIR. payload/init.d/S60nginx becomes
                            $MODDIR/init.d/S60nginx and no recipe says so.
    pkg/<recipe>/prog/      placed on /usr/prog by bin/patch.sh. The residue:
                            files a recipe owns and cannot yet ship. It
                            empties out when a postinst places them from a
                            staging root (docs/notes/85-packaging.md phase 2).
    pkg/<recipe>/seed/      templated or seeded user state -- anvil.conf.in,
                            moonraker-custom.conf. Not package members,
                            because a package member is overwritten on every
                            upgrade by definition and these are the files a
                            printer's owner edits.

This file holds that to being true. The failure it exists to catch is not a
misfiled file -- it is a fourth directory appearing with no rule attached to
it, which is how the old payload/ got the way it was.
"""
import os

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

# Everything a recipe may contain. build.sh and pkg.conf are the recipe;
# the three subtrees are its files.
RECIPE_FILES = {"build.sh", "pkg.conf"}
RECIPE_DIRS = {"payload", "prog", "seed"}


def recipes(root=ROOT):
    pkgdir = os.path.join(ROOT, "pkg")
    return sorted(n for n in os.listdir(pkgdir)
                  if os.path.isfile(os.path.join(pkgdir, n, "pkg.conf")))


def test_there_are_recipes():
    """A glob that silently matches nothing is a test that passes hollow."""
    assert len(recipes()) > 10


def test_a_recipe_holds_nothing_but_a_recipe_and_its_files():
    strays = []
    for name in recipes():
        d = os.path.join(ROOT, "pkg", name)
        for entry in sorted(os.listdir(d)):
            if entry in RECIPE_FILES or entry in RECIPE_DIRS:
                continue
            strays.append("pkg/%s/%s" % (name, entry))
    assert not strays, (
        "a recipe may hold build.sh, pkg.conf, and payload/ prog/ seed/ -- "
        "nothing else, because the directory name is what says where a file "
        "goes: %s" % ", ".join(strays))


def test_every_recipe_subtree_is_one_of_the_three():
    """The rule stated the other way round: no fourth kind of directory."""
    for name in recipes():
        d = os.path.join(ROOT, "pkg", name)
        dirs = {e for e in os.listdir(d) if os.path.isdir(os.path.join(d, e))}
        assert dirs <= RECIPE_DIRS, (
            "pkg/%s has %s -- a new directory needs a rule in this file "
            "saying where its contents end up" % (name, sorted(dirs - RECIPE_DIRS)))


@pytest.mark.parametrize("sub", sorted(RECIPE_DIRS))
def test_each_subtree_is_used_by_someone(sub):
    """If one of the three empties out, this fails and the rule can be deleted.

    That is the good outcome, not a defect: prog/ empty means every /usr/prog
    file is placed by a package, seed/ empty means the seeder landed. The test
    is here so the day it happens is noticed rather than silently carried.
    """
    users = [n for n in recipes()
             if os.path.isdir(os.path.join(ROOT, "pkg", n, sub))]
    assert users, (
        "no recipe has a %s/ any more -- if that is deliberate, delete it "
        "from RECIPE_DIRS and from the layout note in this file's docstring"
        % sub)


def test_nothing_under_a_payload_escapes_the_prefix():
    """payload/ is a $MODDIR overlay, so it may not name an absolute path.

    A file at payload/usr/bin/x would stage to $MODDIR/usr/bin/x, which is
    correct-looking and wrong: it is not what the recipe author meant, and
    bin/build-packages.sh would happily package it.
    """
    bad = []
    for name in recipes():
        d = os.path.join(ROOT, "pkg", name, "payload")
        for top in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if top in ("usr", "opt", "var", "proc", "sys", "dev"):
                bad.append("pkg/%s/payload/%s" % (name, top))
    assert not bad, (
        "payload/ is rooted at $MODDIR, not at /: %s" % ", ".join(bad))


def test_the_installer_is_not_a_recipe():
    """installer/ sits outside pkg/ because its two files are never packages.

    They are text spliced into FlashForge's run.sh by bin/patch.sh. Calling
    them a package -- or filing them under a recipe as though they could
    become one -- would be the only untrue path in the tree.
    """
    d = os.path.join(ROOT, "installer")
    assert os.path.isdir(d)
    assert not os.path.exists(os.path.join(d, "pkg.conf"))
    assert sorted(os.listdir(d)) == ["run-append.sh", "run-pre.sh"]
