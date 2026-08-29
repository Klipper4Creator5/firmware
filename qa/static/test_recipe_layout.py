"""A recipe directory has a fixed shape, and the shape is what says where a
file goes.

The repository used to keep everything it ships in one top-level payload/
tree, organised by DESTINATION -- init.d/, bin/, etc/s6/, klipper/config/ --
and the only thing recording which package owned any of it was a thirty-line
comment at the top of pkgs/anvil-core/build.sh. A comment cannot be checked.
Three kinds of file lived in there and looked identical:

  * files a recipe stages into its .ipk,
  * files that never ship as files at all -- run-pre.sh and run-append.sh are
    spliced into FlashForge's own run.sh at build time.

Files bound for /usr/prog are the first kind: they are package files under
payload/prog/, and anvil-link-prog.sh symlinks them from $MODDIR to the
absolute paths FlashForge's scripts read.

Recipes themselves live at two depths, and pkgs/lib.sh's pkg_dir is the only
thing that knows it:

    pkgs/<name>/            carries files of this repo. Four of them.
    pkgs/3rdparty/<name>/   builds a pinned tarball and carries none. The
                            other thirty-four.

Inside a recipe, each kind of file is a directory name:

    pkgs/<recipe>/payload/   staged into the .ipk, laid out as it lands under
                            $MODDIR. payload/init.d/S60nginx becomes
                            $MODDIR/init.d/S60nginx and no recipe says so.
    pkgs/<recipe>/seed/      templated or seeded user state -- anvil.conf.in,
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
# the subtrees are its files.
#
#   payload/  what the .ipk installs under $MODDIR
#   seed/     user state templated by bin/patch.sh, in no package
#   control/  maintainer scripts and conffiles, copied verbatim into the
#             .ipk's CONTROL/ by bin/build-packages.sh. It is metadata rather
#             than content -- nothing in here lands on the printer as a file,
#             it runs at install time -- which is why it is its own directory
#             and not a corner of payload/.
RECIPE_FILES = {"build.sh", "pkg.conf"}
RECIPE_DIRS = {"payload", "seed", "control"}


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
    """A glob that silently matches nothing is a test that passes hollow."""
    assert len(recipes()) > 10


def test_a_recipe_holds_nothing_but_a_recipe_and_its_files():
    strays = []
    for name, d in recipes():
        for entry in sorted(os.listdir(d)):
            if entry in RECIPE_FILES or entry in RECIPE_DIRS:
                continue
            strays.append("%s: %s" % (name, entry))
    assert not strays, (
        "a recipe may hold build.sh, pkg.conf, and payload/ seed/ control/ -- "
        "nothing else, because the directory name is what says where a file "
        "goes: %s" % ", ".join(strays))


def test_every_recipe_subtree_is_one_of_the_three():
    """The rule stated the other way round: no fourth kind of directory."""
    for name, d in recipes():
        dirs = {e for e in os.listdir(d) if os.path.isdir(os.path.join(d, e))}
        assert dirs <= RECIPE_DIRS, (
            "recipe %s has %s -- a new directory needs a rule in this file "
            "saying where its contents end up" % (name, sorted(dirs - RECIPE_DIRS)))


@pytest.mark.parametrize("sub", sorted(RECIPE_DIRS))
def test_each_subtree_is_used_by_someone(sub):
    """If one empties out, this fails and the rule can be deleted.

    That is the good outcome, not a defect: seed/ empty will mean the seeder
    landed and nothing is templated at build time any more.
    """
    users = [n for n, d in recipes() if os.path.isdir(os.path.join(d, sub))]
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
    for name, rd in recipes():
        d = os.path.join(rd, "payload")
        for top in sorted(os.listdir(d)) if os.path.isdir(d) else []:
            if top in ("usr", "opt", "var", "proc", "sys", "dev"):
                bad.append("%s payload/%s" % (name, top))
    assert not bad, (
        "payload/ is rooted at $MODDIR, not at /: %s" % ", ".join(bad))


def test_the_installer_is_not_a_recipe():
    """installer/ sits outside pkgs/ because its two files are never packages.

    They are text spliced into FlashForge's run.sh by bin/patch.sh. Calling
    them a package -- or filing them under a recipe as though they could
    become one -- would be the only untrue path in the tree.
    """
    d = os.path.join(ROOT, "installer")
    assert os.path.isdir(d)
    assert not os.path.exists(os.path.join(d, "pkg.conf"))
    assert sorted(os.listdir(d)) == ["run-append.sh", "run-pre.sh"]


# ------------------------------------------------------------ the two levels
#
# pkgs/<name>/            a recipe that carries FILES OF THIS REPO.
# pkgs/3rdparty/<name>/   a recipe that builds a pinned tarball and carries
#                         none.
#
# The split exists so that `ls pkgs/` is the four things a person edits rather
# than thirty-eight with those four buried. It is mechanical on purpose: "do
# we actively modify it" drifts, and the day somebody patches zlib nobody
# would agree on which side it belongs. "Does it carry files of ours" is a
# fact about the tree, and the two tests below are the whole of the rule.


def test_a_3rdparty_recipe_carries_no_files_of_ours():
    wrong = []
    for name in sorted(os.listdir(THIRD)):
        d = os.path.join(THIRD, name)
        if not os.path.isfile(os.path.join(d, "pkg.conf")):
            continue
        have = sorted(s for s in RECIPE_DIRS if os.path.isdir(os.path.join(d, s)))
        if have:
            wrong.append("%s has %s" % (name, "/".join(have)))
    assert not wrong, (
        "a recipe under 3rdparty/ builds a pinned tarball and stages nothing "
        "from this checkout. These carry files of ours and belong one level "
        "up, in pkgs/: %s" % ", ".join(wrong))


def test_a_first_party_recipe_carries_something():
    """The rule from the other side, so the levels cannot both drift empty.

    A recipe at the top level with no payload/ or seed/ is
    indistinguishable from a 3rdparty one and should move down -- otherwise
    the top level slowly refills and the split stops meaning anything.
    """
    wrong = []
    base = os.path.join(ROOT, "pkgs")
    for name in sorted(os.listdir(base)):
        d = os.path.join(base, name)
        if name == "3rdparty" or not os.path.isfile(os.path.join(d, "pkg.conf")):
            continue
        if not any(os.path.isdir(os.path.join(d, s)) for s in RECIPE_DIRS):
            wrong.append(name)
    assert not wrong, (
        "these carry no files of this repo, so they are 3rdparty recipes and "
        "belong under pkgs/3rdparty/: %s" % ", ".join(wrong))


def test_recipe_names_are_unique_across_the_two_levels():
    """pkg_out, pkg_stamp and the .ipk filename are all keyed by the bare name.

    A name at both levels would resolve to whichever pkgs/lib.sh's pkg_dir
    searches first and quietly build the other one's package.
    """
    names = [n for n, _ in recipes()]
    dupes = sorted({n for n in names if names.count(n) > 1})
    assert not dupes, (
        "recipe name at both levels: %s -- pkg_dir would silently pick one"
        % ", ".join(dupes))
