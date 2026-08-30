"""Running one gate on its own, from the command line.

`make boot-screen-sim` lands here -- it is the only caller left. The qa suite
does not:
pytest
imports the gate functions and calls them, so nothing between a gate and the
thing counting results has to agree on a text format.

Which is why the "SKIP:" printed below is now only a message to a person. It
used to be a protocol -- run-tests.sh decided a gate had been skipped by
grepping its child's stdout for that string, so a launcher that printed it
after already failing was counted as cleanly skipped. Nothing parses it any
more. If you find yourself writing a grep for it, that is the bug coming back.
"""
import os
import sys
import traceback

from . import Fail, Skip


def main(fn):
    """Run fn(), map its outcome to an exit code, and say what happened.

    A skip exits 0: not being able to run a gate on this machine is a normal
    state for a laptop without docker or without the proprietary firmware.
    REQUIRE_PRINTER_SIM=1 makes it an error instead, which is what a release
    wants -- a package that shipped without the replica gates running has not
    been tested for the thing that matters.
    """
    try:
        fn()
    except Skip as exc:
        if os.environ.get("REQUIRE_PRINTER_SIM") == "1":
            sys.stderr.write("  FAIL: %s (REQUIRE_PRINTER_SIM=1)\n" % exc)
            return 1
        sys.stdout.write("  SKIP: %s\n" % exc)
        return 0
    except Fail as exc:
        sys.stderr.write("  FAIL: %s\n" % exc)
        return 1
    except Exception:
        # A broken harness, not a failed test. The traceback is the point:
        # guessing from a one-line message is how a working launcher gets
        # rewritten by mistake.
        sys.stderr.write("  FAIL: the harness itself broke\n")
        traceback.print_exc()
        return 1
    return 0
