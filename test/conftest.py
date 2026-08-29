"""Shared fixtures for both Python lanes.

It sits at test/ rather than beside the tests because that is what lets
test/integration import ffcfg by name. The old scripts were called test-chamber.py and test-macros.py, and
the dash made `import test_macros` impossible, so one of them reached the
other's parser through importlib machinery. Underscores and a conftest remove the
whole problem. pytest.ini pins the rootdir so this file is found no matter
which lane is named on the command line.

Everything lives in test/integration. There was briefly a second directory,
test/unit, for the tests needing nothing but this checkout, and before that a
`rootfs` marker doing the same job through -m expressions. Both existed to
keep a plain pull request supplied with something to run; this repo has one
maintainer who always has the firmware, so neither was earning the split. The
`rootfs` fixture below skips instead, which is the honest report anyway.
"""
import os
import shutil
import sys

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

# TARGET_MACHINE -> the suffix bin/patch.sh derives from it. A model that is
# buildable but missing here would otherwise go untested.
MODELS = {"Creator5Pro": "creator5pro", "Creator5": "creator5"}

HEATER = "heater_generic chamber_heater"


@pytest.fixture(scope="session")
def root():
    return ROOT


# The mod's Klipper config comes out of two recipes now: anvil-klipper-config
# carries the ff-*.cfg, printer.base.cfg and both chamber configs, and
# anvil-moonraker carries moonraker.conf.
#
# THE CHAMBER CONFIGS ARE NAMED BY MACHINE in the recipe -- chamber/Creator5.cfg
# and chamber/Creator5Pro.cfg -- because one package now ships both and
# anvil-link-prog.sh symlinks whichever the printer asks for to
# printer.chamber.cfg. They used to be two packages that each installed a file
# of that name and Conflicted so only one could land.
#
# The tests still know them by the suffixed names, because on the machine
# there is exactly one printer.chamber.cfg and a test about include resolution
# has to model where files END UP, not how the recipe files them.
CFG_SOURCES = (
    (os.path.join(ROOT, "pkgs", "klipper-config", "payload", "config"), None),
    (os.path.join(ROOT, "pkgs", "moonraker", "payload", "config"), None),
)

# source basename -> the name the merged view uses.
CHAMBER_DIR = os.path.join(ROOT, "pkgs", "klipper-config",
                           "payload", "config", "chamber")
CHAMBER_NAMES = {
    "Creator5.cfg": "printer.chamber.cfg.creator5",
    "Creator5Pro.cfg": "printer.chamber.cfg.creator5pro",
}


@pytest.fixture(scope="session")
def cfgdir(tmp_path_factory):
    """The mod's Klipper config as the PRINTER sees it: one directory.

    A merged copy, not a path into the checkout, and that is the point. The
    split above is a fact about which package ships what. On the machine there
    is no split: the stock run.sh force-copies printer.base.cfg into
    /usr/data/config/ beside the ff-*.cfg, which is exactly why its includes
    are relative and bare (see the header of printer.base.cfg). A test about
    include resolution has to model where the files END UP, or it is testing
    the repository's filing system instead of the printer's.

    In the repo, so this still needs no firmware.
    """
    d = tmp_path_factory.mktemp("cfg")
    for name, dest in CHAMBER_NAMES.items():
        path = os.path.join(CHAMBER_DIR, name)
        assert os.path.isfile(path), (
            "no %s -- anvil-link-prog.sh resolves this name from "
            "app_startup.sh's MACHINE, so the recipe has to ship it" % path)
        shutil.copy2(path, str(d / dest))
    for src, suffix in CFG_SOURCES:
        for name in sorted(os.listdir(src)):
            path = os.path.join(src, name)
            if not os.path.isfile(path):
                continue
            dest = "%s.%s" % (name, suffix) if suffix else name
            assert not (d / dest).exists(), (
                "two recipes ship %s and the merged view cannot hold both -- "
                "one would silently overwrite the other" % dest)
            shutil.copy2(path, str(d / dest))
    return str(d)


@pytest.fixture(scope="session")
def rootfs():
    """The printer's real extracted rootfs, or skip.

    This is the one Python fixture that needs the proprietary package, which
    is why everything using it lives in test/integration. A skip here is a gate
    that did not run: run-tests.py reports it as SKIP rather than as a pass,
    and refuses to call the suite clean.
    """
    path = os.path.join(ROOT, "work", "rootfs")
    if not os.path.isdir(os.path.join(path, "bin")):
        pytest.skip("no printer rootfs -- run 'make rootfs' first")
    return path
