"""The qa suite: pytest is the only framework.

This is the only suite. It decides whether a package bricks a printer. The
harness that used to stand beside it, and the host-side test/ tree it wrapped,
are both gone -- see docs/qa-migration.md.

WHAT IS DIFFERENT HERE

The suite this replaced ran one `docker run --privileged` per case script and
got one boolean back, because the assertions lived in POSIX sh inside the qemu
chroot. 6,280 lines of case-*.sh reported 13 bits between them. The rule here
is:

    shell inside the chroot performs actions; python on the host asserts.

Shell in qemu is irreplaceable for DOING things -- the printer's busybox, its
tar, its OpenSSL, and the fact that our scripts survive its ash is a large part
of what the suite proves. It is a bad place to JUDGE things. Where a fact is
only observable inside the replica, qa/lib/replica.py exposes a typed probe for
it; a case script never branches on it.

LANES

    static    needs nothing but the checkout and the lint tools. milliseconds.
    replica   needs docker + qemu + the proprietary firmware. seconds to
              minutes. The gates that decide whether a package bricks.

Select with `-m static` / `-m replica`, or by path.

SKIPS, AND WHY THERE IS NO FLAG CONTROLLING THEM

A missing tool, a missing daemon or a missing firmware image is a FAILURE, at
the point that needs it. Not a skip, and not a skip that some flag can be asked
to promote later.

This suite had a `--strict-skip=<lane|all>` for exactly one commit, and it was
the wrong shape. It was ALLOW_SKIP inverted -- and ALLOW_SKIP's defect was
never which direction it named things in, it was that THE DECISION LIVED IN THE
CI INVOCATION. An accept-list in ci.yml has to be edited whenever a gate moves;
a strict-list in ci.yml has to be remembered whenever a job is added. Both
degrade silently when someone gets the command line wrong, which is the same
disease as the printer-sim job that was gated on an unset secret and therefore
never ran once in its entire existence.

So the verdict lives with the knowledge. `shellcheck` missing means the machine
cannot run the check, and no configuration exists in which that is a complete
run, so the test fails and says how to fix it. Same for pyflakes, for the docker
CLI, for the daemon, and for the replica image.

    A GATE THAT DID NOT RUN MUST NEVER LOOK GREEN -- and the way to guarantee
    that is to not have a mode in which it can.

`pytest.skip` stays available for the case it is actually for: a question that
does not APPLY to this configuration, as opposed to one this machine happens to
be unequipped to ask. A test that only means something on a Creator5Pro is the
shape that earns it. "I could not find the tool" is not.

Three skips do not meet that bar: test_ipk.py's payload questions read
work/modpayload-root, which only bin/payload.sh produces. Noted rather than
hidden -- and note that `make test` DELETES that directory when it clears up
after its fixture build, so running the old suite quietly costs the static
lane three tests. See docs/qa-migration.md.
"""
import os
import sys

import pytest

# qa/ on the path so `from lib.replica import Printer` works from any subdir.
# Not a package install: this tree is not shipped and never will be, and a
# setup.py for it would be one more thing that can disagree with reality.
sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

LANES = ("static", "replica")


def pytest_configure(config):
    for lane in LANES:
        config.addinivalue_line(
            "markers", "%s: the %s lane -- see qa/conftest.py" % (lane, lane))
    _check_distribution(config)


def _check_distribution(config):
    """Refuse the xdist mode that would start a container per worker.

    The `printer` fixture is module-scoped, and xdist's DEFAULT distribution
    (`--dist load`) hands out individual tests. Four workers pulling tests
    from one module each instantiate that module's fixture, so `-n 4` would
    assemble four replicas of the same machine instead of one -- four binfmt
    registrations, four mount layouts, and on a locally built replica four
    stock installs under qemu. It would still pass, slowly, which is why it
    needs catching here rather than in review: the symptom is a suite that
    got mysteriously slower when it was parallelised.

    `loadscope` groups by module (`loadfile` by file, `loadgroup` by an
    explicit mark) -- any of those keeps one container per module, which is
    the whole isolation model. Enforced rather than defaulted, because
    silently rewriting somebody's -n flag is its own kind of surprise.
    """
    dist = getattr(config.option, "dist", "no")
    if dist in ("no", "loadscope", "loadfile", "loadgroup"):
        return
    raise pytest.UsageError(
        "--dist=%s would start one replica per worker per module. Use "
        "--dist=loadscope (or loadfile), which keeps each module on one "
        "worker -- see _check_distribution in qa/conftest.py." % dist)
