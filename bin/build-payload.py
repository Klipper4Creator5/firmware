#!/usr/bin/env python3
"""Build $MODDIR by installing the feed inside the printer replica.

    ./bin/build-payload.py <root-package> [<root-package> ...]

Writes the installed tree to $PAYLOAD_DIR, replacing whatever was there.

The printer's OWN opkg installs onto the printer's own filesystem, under
qemu-mipsel, and the tree is tarred back out -- so maintainer scripts run
where they will run on a machine, and the install that ships is the install
that was tested.

WHAT IT COSTS. A privileged container and the printer image, which is why
`make build` has its own docker lane. The feed itself
(bin/build-packages.sh) still needs nothing but a checkout.
"""
import os
import subprocess
import sys
from pathlib import Path

for _p in Path(__file__).resolve().parents:
    if (_p / "bin" / "common.sh").is_file():
        ROOT = _p
        sys.path.insert(0, str(_p / "tools" / "replica"))
        break

from ffsim import cli                            # noqa: E402
from ffsim.config import Config                  # noqa: E402
from ffsim.replica import Replica                # noqa: E402

CASE = "tools/replica/printer/case-build-payload.sh"


def _sh(var, default=""):
    """One value out of bin/common.sh, asked of the shell that defines it.

    Re-deriving IPK_ARCH or PKG_FEED here would be a second place for them to
    be wrong, and the two would agree until somebody edited one.
    """
    out = subprocess.run(
        ["bash", "-c", '. "%s/bin/common.sh" >/dev/null 2>&1; printf "%%s" "${%s:-%s}"'
         % (ROOT, var, default)],
        capture_output=True, text=True, cwd=str(ROOT))
    return out.stdout.strip()


def run():
    roots = sys.argv[1:]
    if not roots:
        raise SystemExit("usage: build-payload.py <root-package> ...")

    feed = Path(_sh("PKG_FEED", str(ROOT / "work" / "packages")))
    payload_dir = Path(_sh("PAYLOAD_DIR"))
    if not payload_dir.is_absolute() and not str(payload_dir).startswith(str(ROOT)):
        payload_dir = ROOT / payload_dir

    ipks = sorted(feed.glob("*.ipk"))
    if not ipks:
        raise SystemExit("no feed at %s -- run ./bin/build-packages.sh" % feed)
    index = feed / "Packages"
    if not index.is_file():
        raise SystemExit("no Packages index at %s" % index)

    # Everything the printer's opkg needs, on the simulated stick at /mnt: the
    # archives and the index that names them. `packages` is the replica's own
    # mechanism for this and copies each to /mnt/<name>.
    packages = {p.name: str(p) for p in ipks}
    packages[index.name] = str(index)

    config = Config.load()
    replica = Replica.start(config)
    out = ROOT / "work" / ".payload-out"
    replica.run_case(
        ROOT / CASE, packages=packages, out_dir=out, on_output=_echo,
        env={
            "MOD_ROOTS": " ".join(roots),
            "IPK_ARCH": _sh("IPK_ARCH", "mipsel_xburst2"),
            "SOURCE_DATE_EPOCH": os.environ.get("SOURCE_DATE_EPOCH", "1"),
            # The case compiles the s6-rc database and stamps it db-$MOD_VER.
            # Asked of common.sh like every other value here, so the database
            # name and the package versions cannot come from two clocks.
            "MOD_VER": _sh("MOD_VER"),
        })

    tar = out / "payload.tar"
    if not tar.is_file():
        raise SystemExit("the replica produced no payload.tar")

    # Replace, never merge: a surviving file from a previous build is one no
    # package accounts for, and the manifest would ship it as though it did.
    if payload_dir.exists():
        subprocess.run(["rm", "-rf", str(payload_dir)], check=True)
    payload_dir.mkdir(parents=True)
    # --strip-components=1 drops the leading anvil/ the case tarred with.
    # No -p and no --same-owner: the archive carries the printer's root, this
    # runs as the build user, and run-append.sh extracts as root on the
    # machine -- ownership in the payload means nothing.
    subprocess.run(["tar", "-xf", str(tar), "-C", str(payload_dir),
                    "--strip-components=1"], check=True)
    subprocess.run(["rm", "-rf", str(out)], check=True)
    _echo("payload: %s" % payload_dir)


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
