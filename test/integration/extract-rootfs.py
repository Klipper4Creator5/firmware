#!/usr/bin/env python3
"""Extract the printer's REAL root filesystem from the stock update package.

    ./test/integration/extract-rootfs.py

The kernel-*.tar.xz component carries ota_kernel_emmc/ota_v1/rootfs.squashfs
-- the genuine buildroot rootfs: busybox 1.31.1, /etc/inittab, /etc/init.d
including the stock S50dropbear, /usr/sbin/dropbear, the real ash.

sim-install.py uses it to run the installer inside the ACTUAL printer userland
under qemu-mipsel, where `uname -m` genuinely reports "mips" and busybox
applets behave exactly as they do on the machine. That is a far better test
than approximating with a Debian container.

Never committed: it is FlashForge's proprietary firmware.
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
    gates.extract_rootfs(Config.load(), on_output=_echo)


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
