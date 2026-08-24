"""Shared fixtures for the Python half of the suite.

Being a package directory with a conftest.py is also what lets these modules
import ffcfg by name. The old scripts were called test-chamber.py and
test-macros.py, and the dash made `import test_macros` impossible, so one of
them reached the other's parser through importlib machinery. Underscores and
a conftest remove the whole problem.
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


def pytest_configure(config):
    config.addinivalue_line(
        "markers",
        "rootfs: needs the printer's extracted rootfs, i.e. the proprietary "
        "package. run-tests.sh runs `-m 'not rootfs'` in the half that works "
        "on a plain pull request and `-m rootfs` once it has extracted one, "
        "so neither lane reports skips it did not expect.")


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

    This is the one Python fixture that needs the proprietary package. A skip
    here is a gate that did not run: run-tests.sh reports it as SKIP rather
    than as a pass, and refuses to call the suite clean.
    """
    path = os.path.join(ROOT, "work", "rootfs")
    if not os.path.isdir(os.path.join(path, "bin")):
        pytest.skip("no printer rootfs -- run 'make rootfs' first")
    return path
