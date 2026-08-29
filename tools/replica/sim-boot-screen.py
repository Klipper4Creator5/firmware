#!/usr/bin/env python3
"""Draw the first-boot screen in the replica and write it out as PNGs.

    ./tools/replica/sim-boot-screen.py [--out DIR]

ffscreen.py packs pixels by hand, and the only honest way to review that is to
look at the result -- rendered by the interpreter that will really run it.
This drives case-boot-screen-dump.sh, which draws every phase inside the
replica using our own cross-built CPython 3.13 (FF_PYTHON) on MIPS, and
decodes the base64 PNGs it prints back into files.

`make boot-screen` renders the same list on the host in a fraction of the time
and needs no docker; the two are expected to agree byte for byte, and this is
what establishes that they do.
"""
import argparse
import base64
import re
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
from ffsim.gates import _python_tarball          # noqa: E402

CASE = ("tools", "replica", "printer", "case-boot-screen-dump.sh")
FRAME = re.compile(r"PNGSTART (\S+)\n(.*?)\nPNGEND", re.S)


def run():
    ap = argparse.ArgumentParser(description=__doc__)
    ap.add_argument("--out", default=str(ROOT / "work" / "boot-screen-sim"))
    args = ap.parse_args()

    config = Config.load()
    tree = _python_tarball(config)
    if not tree:
        raise SystemExit("nothing in work/pkg/python -- run ./bin/patch.sh first")
    replica = Replica.start(config, want_output=_echo)
    # The frames come back on stdout as base64, so this body is the payload --
    # not just a log. It is deliberately not echoed.
    body = replica.run_case(str(ROOT.joinpath(*CASE)), packages={"py.tgz": tree})

    out = Path(args.out)
    out.mkdir(parents=True, exist_ok=True)
    # Same reason as the host preview: never leave a stale frame behind.
    for stale in out.glob("*.png"):
        stale.unlink()
    found = 0
    for name, blob in FRAME.findall(body):
        png = base64.b64decode("".join(blob.split()))
        path = out / ("%s.png" % name)
        path.write_bytes(png)
        _echo("%-18s %s  (%d bytes)" % (name, path, len(png)))
        found += 1
    if not found:
        raise SystemExit("the replica printed no frames:\n%s" % body[-2000:])
    _echo("\n%d frames in %s" % (found, out))


def _echo(text):
    sys.stdout.write(str(text).rstrip("\n") + "\n")
    sys.stdout.flush()


if __name__ == "__main__":
    sys.exit(cli.main(run))
