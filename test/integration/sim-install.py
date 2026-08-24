#!/usr/bin/env python3
"""End-to-end update test: put the package on a USB stick in a replica of the
printer and let the machine install it the way it really does.

    ./test/integration/sim-install.py <package.tgz>

The replica is the real extracted rootfs.squashfs running under qemu-mipsel,
with /usr/prog installed by the stock updater itself. The package sits on a
genuine FAT filesystem at /dev/sda1 and the printer's own app_startup.sh finds
it, mounts it, decrypts it and runs the installer -- three boots, the last one
with the stick pulled. Every command involved is the printer's.

See test/integration/printer/case-install.sh for what runs inside.
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
    if len(sys.argv) != 2:
        raise SystemExit("usage: sim-install.py <package.tgz>")
    gates.install(Config.load(), sys.argv[1], on_output=_echo)


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
