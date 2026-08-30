"""A `[ -f $MODDIR/... ]` guard that can only ever be false.

THE BUG THIS EXISTS FOR. `installer/runFirmwareExe.sh` replaces FlashForge's
`klipperDaemon` -- whose `start` forks a second, unsupervised klippy beside the
s6-supervised one -- and it guarded that work with

    if [ -f $MODDIR/bin/klipperDaemon ] && [ -d /usr/prog/klipper ]; then

The file ships at `$MODDIR/prog/klipperDaemon`. It moved there in 057a3a1 and
the guard did not, so the test was false on every printer and the whole block
was skipped IN SILENCE -- no error, no log line, just a stock `klipperDaemon`
left in place for release after release.

Nothing could have caught it. `sh -n` parses it, shellcheck likes it, and both
lanes stay green because the branch simply never runs. `test_no_undefined_names`
is the same idea for Python; this is the shell half.

WHY EXISTENCE GUARDS AND NOT EVERY $MODDIR PATH. Most `$MODDIR/...` references
are things a script CREATES or writes, and demanding those exist in a package
would be wrong. A `[ -f ]` / `[ -x ]` / `[ -d ]` is different: it is a claim
that something is already there, and the only two ways it can be true are that
a package ships it or that an earlier step wrote it. The second is the
allowlist below, and it is deliberately short so that adding to it is a
decision somebody makes rather than a way to silence this test.
"""
import re

import pytest

from lib.paths import ROOT

pytestmark = pytest.mark.static

# Scripts that read $MODDIR expecting the payload to be installed.
SOURCES = sorted(
    set(ROOT.glob("installer/*.sh"))
    | set(ROOT.glob("pkgs/*/payload/prog/*"))
    | set(ROOT.glob("pkgs/*/payload/bin/*.sh"))
    | set(ROOT.glob("pkgs/*/payload/etc/s6-rc/source/*/run"))
)

# `[ -f $MODDIR/a/b ]`, `[ -x ${MODDIR}/a/b ]`. Only literal paths: anything
# with a variable or a glob in it cannot be resolved here and is skipped.
GUARD = re.compile(r"\[\s+-[fxdesr]\s+\$\{?MODDIR\}?/([A-Za-z0-9_.][A-Za-z0-9_./-]*)")

# Not shipped by any package, and correctly so.
ALLOWED = {
    # Inside anvil-helixscreen's upstream tarball, which pkgs/helixscreen
    # unpacks at build time -- so it is shipped, just not committed here.
    "helixscreen/bin/helix-launcher.sh",
}


def _shipped():
    """Every path any recipe ships, relative to $MODDIR."""
    out = set()
    for payload in ROOT.glob("pkgs/*/payload"):
        for p in payload.rglob("*"):
            out.add(str(p.relative_to(payload)))
    return out


def test_every_moddir_existence_guard_names_something_that_ships():
    shipped = _shipped()
    missing = []
    for src in SOURCES:
        try:
            text = src.read_text(encoding="utf-8", errors="replace")
        except OSError:
            continue
        for lineno, line in enumerate(text.splitlines(), 1):
            for path in GUARD.findall(line):
                path = path.rstrip("/")
                if path in ALLOWED or path in shipped:
                    continue
                missing.append(
                    "%s:%d  $MODDIR/%s"
                    % (src.relative_to(ROOT), lineno, path))

    assert not missing, (
        "%d existence guard(s) name a $MODDIR path no recipe ships, so the "
        "test is false on every printer and whatever it guards never runs -- "
        "silently, which is how the klipperDaemon replacement was skipped for "
        "several releases:\n  %s\n"
        "Either the path is wrong, or the file should be in a package, or it "
        "is written at runtime and belongs in ALLOWED with a reason."
        % (len(missing), "\n  ".join(missing)))
