#!/usr/bin/env python3
"""Run an arbitrary case script inside the printer replica.

    ./test/integration/printer-exec.py <case-script> [name=package.tgz ...]

The case script is executed by the printer's own busybox inside a chroot of
the real extracted rootfs.squashfs, with MIPS binaries running under qemu.
Named packages appear on the simulated USB stick as /mnt/<name>.

    BASE_PKG=<stock .tgz>  install stock firmware first, so /usr/prog holds
                           the genuine klipper tree, unTar, app_startup.sh and
                           firmwareExe rather than hand-written fakes
    USB_STICK=1            put the packages on a real FAT filesystem exposed
                           as /dev/sda1 instead of dropping them into /mnt, so
                           the printer's own app_startup.sh has to discover and
                           mount them. Required by case-install.sh.
    PROG_DUMP=<tar|dir>    a real /usr/prog taken off a printer. With one, the
                           replica has no invented files left at all.
"""
import os
import sys
from pathlib import Path

for _p in Path(__file__).resolve().parents:
    if (_p / "bin" / "common.sh").is_file():
        sys.path.insert(0, str(_p / "test"))
        break

from ffsim import cli                            # noqa: E402
from ffsim.config import Config                  # noqa: E402
from ffsim.replica import Replica                # noqa: E402


def run():
    if len(sys.argv) < 2:
        raise SystemExit("usage: printer-exec.py <case-script> "
                         "[name=pkg.tgz ...]")
    case = sys.argv[1]
    packages = {}
    for spec in sys.argv[2:]:
        name, _, path = spec.partition("=")
        packages[name] = path

    config = Config.load()
    replica = Replica.start(config, want_output=_echo)
    replica.run_case(case, packages=packages,
                     base_pkg=os.environ.get("BASE_PKG") or None,
                     usb_stick=os.environ.get("USB_STICK") == "1",
                     on_output=_echo)


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
