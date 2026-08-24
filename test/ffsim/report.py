"""Counting what ran, what did not, and why.

The rule this file exists to enforce: a gate that did not run must never look
like one that passed. test-abi.sh sat in the suite for a long time printing
green while checking nothing at all -- the wiring deleted work/modpayload
immediately before it ran and CI set KLIPPER_FORK="", so it had no targets on
any run, and "no targets" rendered as success. A handful of gates carry this
whole suite; one of them quietly doing nothing is the worst failure the
harness has.

So a skip is counted apart from a pass, the summary refuses to call a run with
skips clean, and ALLOW_SKIP=1 is the only way to accept the gap -- which is
what a laptop without docker or without the proprietary package wants, said
out loud.

What changed from the shell version is how a skip is DECIDED. There it was a
grep of the child's stdout for "SKIP:", so any process that printed those
characters and exited 0 was recorded as skipped, whatever had actually
happened to it. Here a gate raises Skip or it does not, and no amount of
output can imitate that.
"""
import os
import subprocess
import sys
import time
import traceback

from . import Fail, Skip

BOLD, GREEN, RED, YELLOW, GREY, OFF = (
    "\033[1m", "\033[32m", "\033[31m", "\033[33m", "\033[90m", "\033[0m")


class _Gate:
    def __init__(self, reporter, name):
        self.reporter, self.name = reporter, name

    def __enter__(self):
        return self

    def __exit__(self, exc_type, exc, tb):
        if exc_type is None:
            self.reporter.ok(self.name)
        elif exc_type is Skip:
            # REQUIRE_PRINTER_SIM turns every skip into a failure. Fine on a
            # laptop, fatal in a release: a package that shipped without the
            # replica gates running has not been tested for the thing that
            # matters.
            if os.environ.get("REQUIRE_PRINTER_SIM") == "1":
                self.reporter.fail("%s -- %s (REQUIRE_PRINTER_SIM=1)"
                                   % (self.name, exc))
            else:
                self.reporter.skip("%s (%s)" % (self.name, exc))
        elif exc_type is Fail:
            self.reporter.fail("%s: %s" % (self.name, exc))
        else:
            # An unexpected exception is a broken harness. Print the traceback
            # -- guessing from a one-line message is how you end up rewriting
            # a launcher that was fine.
            self.reporter.fail("%s: %s: %s"
                               % (self.name, exc_type.__name__, exc))
            traceback.print_exception(exc_type, exc, tb)
        return True  # handled: one bad gate must not end the run


class Reporter:
    def __init__(self, out=sys.stdout):
        self.passed = self.failed = self.skipped = 0
        self.out = out
        self.t0 = time.time()

    def _say(self, text):
        self.out.write(text)
        self.out.flush()

    def hdr(self, title):
        # Every section carries the elapsed time. The suite is mostly waiting
        # on qemu and xz, and without a clock it is guesswork which.
        self._say("\n%s== %s ==%s %s[%ds]%s\n"
                  % (BOLD, title, OFF, GREY, time.time() - self.t0, OFF))

    def ok(self, msg):
        self.passed += 1
        self._say("  %sok%s   %s\n" % (GREEN, OFF, msg))

    def fail(self, msg):
        self.failed += 1
        self._say("  %sFAIL%s %s\n" % (RED, OFF, msg))

    def skip(self, msg):
        self.skipped += 1
        self._say("  %sSKIP%s %s\n" % (YELLOW, OFF, msg))

    def gate(self, name):
        """`with r.gate("name"): ...` -- the body's outcome is the verdict."""
        return _Gate(self, name)

    def run(self, cmd, cwd=None, env=None, quiet_ok=True, tail=25):
        """A subprocess whose failure is a failure, full stop.

        Output is held back while it succeeds, so 25 green lines saying
        "syntax ok" do not bury the two that matter, and printed on failure.
        """
        proc = subprocess.run(
            [str(c) for c in cmd], cwd=cwd and str(cwd), env=env,
            capture_output=True, text=True)
        if proc.returncode != 0:
            body = (proc.stdout or "") + (proc.stderr or "")
            lines = body.rstrip("\n").split("\n")[-tail:]
            raise Fail("%s exited %d\n%s"
                       % (" ".join(str(c) for c in cmd), proc.returncode,
                          "\n".join("       " + ln for ln in lines)))
        if not quiet_ok and proc.stdout:
            self._say("".join("  " + ln + "\n"
                              for ln in proc.stdout.rstrip("\n").split("\n")))
        return proc

    def summary(self):
        """Print the totals and return the exit code the run deserves."""
        self._say("\n%s%d passed, %d failed, %d skipped%s\n"
                  % (BOLD, self.passed, self.failed, self.skipped, OFF))

        if self.skipped and os.environ.get("ALLOW_SKIP") != "1":
            self._say("%s%d gate(s) did not run.%s Set STOCK_TGZ_CREATOR5PRO "
                      "in config.env\n" % (YELLOW, self.skipped, OFF))
            self._say("and make docker available, or pass ALLOW_SKIP=1 to "
                      "accept the gap.\n")
            return 1
        return 1 if self.failed else 0
