#!/usr/bin/env python3
"""Recovery test on the real printer userland: mod in, stock back out.

    ./test/integration/sim-roundtrip.py <mod.tgz> <stock.tgz>

This is the gate behind the promise that flashing a stock FlashForge package
restores every file the mod touches.
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
    if len(sys.argv) != 3:
        raise SystemExit("usage: sim-roundtrip.py <mod.tgz> <stock.tgz>")
    gates.roundtrip(Config.load(), sys.argv[1], sys.argv[2], on_output=_echo)


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
