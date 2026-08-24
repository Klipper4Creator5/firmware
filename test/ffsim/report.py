"""Counting what ran, what did not, and why.

The rule this file exists to enforce: a gate that did not run must never look
like one that passed. test-abi.sh sat in the suite for a long time printing
green while checking nothing at all -- the wiring deleted work/modpayload
immediately before it ran and CI set KLIPPER_FORK="", so it had no targets on
any run, and "no targets" rendered as success. A handful of gates carry this
whole suite; one of them quietly doing nothing is the worst failure the
harness has.

So a skip is counted apart from a pass, the summary refuses to call a run with
skips clean, and ALLOW_SKIP is the only way to accept the gap -- which is what
a laptop without docker or without the proprietary package wants, said out
loud.

ALLOW_SKIP names what it accepts:

    ALLOW_SKIP=1                     accept ANY gate that did not run
    ALLOW_SKIP="pytest,the printer replica"    accept exactly these two

The list form is what CI uses, and the difference matters. `1` is a standing
promise that no gate skipping will ever be noticed again -- put it in a
workflow and a replica gate that starts skipping on a machine that has the
firmware is accepted in silence, forever. The list accepts the two gaps that
are structural on that runner and fails on a third.

Whatever the setting, every skip is listed again in the summary with its
reason. Accepting a gap is a decision; hiding it is the bug this suite exists
to catch.

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
                self.reporter.skip(self.name, str(exc))
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
        self.passed = self.failed = 0
        # Kept as a list, not a counter: the summary has to say WHICH gates did
        # not run. A bare "2 skipped" is the same non-answer as the shell
        # suite's grep -- it tells you something is missing and not what.
        self.skips = []
        self.out = out
        self.t0 = time.time()

    @property
    def skipped(self):
        return len(self.skips)

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

    def skip(self, name, reason=""):
        self.skips.append((name, reason))
        shown = "%s (%s)" % (name, reason) if reason else name
        self._say("  %sSKIP%s %s\n" % (YELLOW, OFF, shown))

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

    def _annotate(self, level, text):
        """A GitHub annotation, so a skip is visible without opening the log.

        The whole point of listing skips is that somebody sees them. In CI
        nobody reads a green job's output, so an accepted gap that only exists
        in stdout is accepted invisibly -- which is the thing being fixed.
        """
        if os.environ.get("GITHUB_ACTIONS") == "true":
            self._say("::%s::%s\n" % (level, text.replace("\n", " ")))

    def summary(self):
        """Print the totals and return the exit code the run deserves."""
        self._say("\n%s%d passed, %d failed, %d skipped%s\n"
                  % (BOLD, self.passed, self.failed, self.skipped, OFF))

        allow = os.environ.get("ALLOW_SKIP", "").strip()
        allowed = set()
        if allow and allow != "1":
            allowed = {a.strip().lower() for a in allow.split(",") if a.strip()}

        # The roll-call happens whatever ALLOW_SKIP says. Accepting a gap is a
        # decision that should still be readable six months later.
        unexpected = []
        for name, reason in self.skips:
            ok = allow == "1" or name.strip().lower() in allowed
            if not ok:
                unexpected.append((name, reason))
            mark = "accepted" if ok else "NOT ACCEPTED"
            self._say("  %sdid not run%s  %s -- %s  [%s]\n"
                      % (YELLOW, OFF, name, reason or "no reason given", mark))
            self._annotate("warning" if ok else "error",
                           "gate did not run: %s -- %s" % (name, reason))

        if unexpected:
            self._say("\n%s%d gate(s) did not run and were not accepted.%s\n"
                      % (RED, len(unexpected), OFF))
            self._say("Set STOCK_TGZ_CREATOR5PRO in config.env and make docker\n"
                      "available, or name them in ALLOW_SKIP, e.g.\n"
                      "    ALLOW_SKIP=%s\n"
                      % ",".join('"%s"' % n for n, _ in unexpected))
            return 1

        if self.skips:
            self._say("%s%d gate(s) did not run, accepted by ALLOW_SKIP=%s.%s\n"
                      % (YELLOW, self.skipped, allow, OFF))
        return 1 if self.failed else 0
