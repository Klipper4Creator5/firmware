"""Host side of the test harness.

Everything in here runs on YOUR machine. The scripts that run on the printer
-- tools/replica/printer/*.sh and the whole payload -- stay shell on
purpose: they are executed by the printer's own busybox ash under qemu, and
the fact that they survive that is a large part of what the suite proves.
Rewriting those in Python would test a Python the printer does not have.

Two things here exist to fix specific accidents.

`repo_root` finds the checkout by looking for a file that marks it, walking
upward until it does. The shell version computed it by counting `..` from
$0, so moving a launcher one directory deeper silently made $ROOT point at
test/ instead of the repo -- which happened, to five scripts at once, and
shipped. A search does not care where the file lives.

`Skip` is an exception, and that is the whole point of it. In the shell suite
"this gate did not run" was reported by printing the string "SKIP:" and
exiting 0, and the runner decided by grepping stdout for it. So a launcher
that had ALREADY failed -- one whose config never loaded because the path to
it was wrong -- concluded it had nothing to work on, printed those five
characters, exited 0, and was counted as a clean skip on a machine that could
have run it perfectly well. Text on stdout cannot tell you what happened
inside a process. An exception can, and nothing else can forge it.
"""
from pathlib import Path

__all__ = ["Skip", "Fail", "repo_root"]


class Skip(Exception):
    """This gate cannot run here, and that is a legitimate answer.

    No docker, no proprietary firmware. Raise it only where the precondition
    is genuinely absent -- never as a way to swallow a failure, which is the
    exact confusion this class exists to end.
    """


class Fail(Exception):
    """This gate ran and the answer was no.

    Also raised for a harness that is itself broken: a missing file, a bad
    path, a docker that will not start. That merging is deliberate. The
    alternative is a third state, and a third state is somewhere for "the
    test did not really run" to hide again.
    """


# A file that exists in this repo and nowhere above it. bin/common.sh is
# sourced by every build script, so if it ever moves the build is broken
# anyway and a loud failure here is the least of it.
_MARKER = ("bin", "common.sh")


def repo_root(start=None):
    """The checkout root, found by looking rather than by counting.

    Depth-independent by construction: this file can move to any directory in
    the repo and it still resolves correctly, which is what makes the old
    `cd "$(dirname "$0")/.."` class of bug impossible rather than merely
    tested for.
    """
    here = Path(start or __file__).resolve()
    for d in (here,) + tuple(here.parents):
        if (d.joinpath(*_MARKER)).is_file():
            return d
    raise Fail("not inside the repo: no %s above %s"
               % ("/".join(_MARKER), here))
