"""Shared fixtures for both Python lanes.

It sits at test/ rather than in either lane because both need `root`, and
because this is what lets test/unit and test/integration import ffcfg by
name. The old scripts were called test-chamber.py and test-macros.py, and
the dash made `import test_macros` impossible, so one of them reached the
other's parser through importlib machinery. Underscores and a conftest remove the
whole problem. pytest.ini pins the rootdir so this file is found no matter
which lane is named on the command line.

Which lane a test belongs to is decided by the directory it is in:

    test/unit/          needs nothing but this checkout
    test/integration/   needs the printer's real rootfs

That used to be a `rootfs` marker with run-tests.sh passing -m expressions.
The directory says the same thing without anyone having to remember to mark
a new test, and a file in the wrong place is visible in `git status`.
"""
import os
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


@pytest.fixture(scope="session")
def cfgdir():
    """payload/klipper/config -- in the repo, so this needs no firmware."""
    return os.path.join(ROOT, "payload", "klipper", "config")


@pytest.fixture(scope="session")
def rootfs():
    """The printer's real extracted rootfs, or skip.

    This is the one Python fixture that needs the proprietary package, which
    is why everything using it lives in test/integration. A skip here is a gate
    that did not run: run-tests.sh reports it as SKIP rather than as a pass,
    and refuses to call the suite clean.
    """
    path = os.path.join(ROOT, "work", "rootfs")
    if not os.path.isdir(os.path.join(path, "bin")):
        pytest.skip("no printer rootfs -- run 'make rootfs' first")
    return path
