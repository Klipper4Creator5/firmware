#!/usr/bin/env python3
"""The real Moonraker, on the CPython 3.13 this repo cross-builds, supervised.

    ./test/integration/sim-moonraker313.py

A thin wrapper around gates.moonraker313_s6, in the shape sim-install.py and
sim-roundtrip.py already have: one gate, run on its own, without the rest of
the suite in front of it.

It exists rather than a printer-exec.py line in the Makefile because this gate
takes THREE tarballs and one of them is not a directory that can be handed to
`tar -c`: the Moonraker tree is repacked out of the pinned sdist in vendor/
with its commit-named top directory removed and the mod's own assets/*.conf
added beside it. That is a dozen lines of assembly, it has to agree exactly
with what the suite builds for itself, and writing it twice -- once in
test/ffsim/gates.py and once in shell in the Makefile -- is how the two would
come to disagree. One definition, called from both.

See test/integration/printer/case-moonraker313-s6.sh for what runs inside, and
the gate's own docstring for why it is a third moonraker case rather than an
extension of either of the other two.
"""
import sys
from pathlib import Path

for _p in Path(__file__).resolve().parents:
    if (_p / "bin" / "common.sh").is_file():
        sys.path.insert(0, str(_p / "test"))
        break

from ffsim import cli                            # noqa: E402
from ffsim.config import Config                  # noqa: E402
from ffsim import gates                          # noqa: E402


def run():
    if len(sys.argv) != 1:
        raise SystemExit("usage: sim-moonraker313.py")
    gates.moonraker313_s6(Config.load(), on_output=_echo)


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
