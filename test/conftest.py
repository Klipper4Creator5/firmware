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


# The mod's Klipper config comes out of two recipes now. The ff-*.cfg
# includes are anvil-core's and install to $MODDIR/config; printer.base.cfg
# and the per-model chamber variants are pkg/klipper's and are placed on the
# firmware partition by bin/patch.sh, which is why they sit in prog/ rather
# than payload/.
CFG_SOURCES = (
    os.path.join(ROOT, "pkg", "anvil-core", "payload", "config"),
    os.path.join(ROOT, "pkg", "klipper", "prog", "config"),
)


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
    for src in CFG_SOURCES:
        for name in sorted(os.listdir(src)):
            path = os.path.join(src, name)
            if os.path.isfile(path):
                shutil.copy2(path, str(d / name))
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
