"""Fixtures for the replica lane.

WHAT THE `printer` FIXTURE IS

A replica of the machine WITH OUR PACKAGE ALREADY INSTALLED -- installed by the
printer's own /usr/prog/app_startup.sh, from a genuine FAT filesystem on
/dev/sda1, exactly as a user installs it off a USB stick.

That is deliberate and it is the second time this repo has had to learn it.
An earlier version of this file handed the tests a machine into which
qa/replica/actions/install-payload.sh had copied payload/*.sh and
payload/init.d/S* by hand. Two things were wrong with that:

  * it was a SECOND implementation of the install, so every assertion
    downstream described a layout the harness had built rather than one the
    installer produced -- the real installer could have broken and nothing
    here would have gone red;
  * it could only place what is in payload/, so anything the BUILD produces
    was missing. The cross-compiled s6 is the obvious one: it lives in
    work/.s6 and bin/patch.sh stages it into the package, so a hand-placed
    payload has no supervisor at all and the tests had to carry a stand-in
    scanner to paper over it.

Installing for real fixes both at once. The install is now under test because
it is the setup, and the payload under test is the built artefact -- real s6,
real CPython, real Klipper extras, staged exactly as they ship.

case-install.sh's header records the same lesson from the first time:

    An earlier version of this file replayed app_startup.sh by hand -- which
    meant a bug in our reading of it could never be caught.

COST

The install is the machine's own shell running under qemu and it takes
minutes, so it is baked into an image ONCE per package and cached under a tag
derived from the package's md5 -- the same trick
test/integration/build-printer-image.sh uses for the stock baseline. Rebuild
the package and the tag changes, so the next run bakes again instead of
testing yesterday's build.

Module-scoped containers start from that image, which is the same isolation
boundary the case scripts have: each starts from a freshly assembled machine
and none shares state with another.

Nothing here skips. A machine with no docker, no daemon or no built package
cannot answer the question these tests exist to ask, and ReplicaMissing says
so -- with the fix -- rather than reporting a clean skip. See qa/conftest.py.
"""
import pytest

from lib import replica
from lib.config import Config, ConfigError


@pytest.fixture(scope="session")
def config():
    try:
        return Config.load()
    except ConfigError as broken:
        # Not a skip. A broken config.env is a broken harness, and the reason
        # Config raises here is that the shell version could not tell the two
        # apart -- a half-sourced file left STOCK_TGZ_* empty, and the run
        # reported a clean skip on a machine that had everything.
        pytest.fail(str(broken))


@pytest.fixture(scope="session")
def mod_image(config):
    """An image that IS a printer with our package installed. Baked once."""
    return replica.installed_image(config, on_output=print)


@pytest.fixture(scope="module")
def printer(config, mod_image):
    """A live installed replica, held open for this module."""
    live = replica.start(config, image=mod_image)
    try:
        yield live
    finally:
        replica.stop(live)
