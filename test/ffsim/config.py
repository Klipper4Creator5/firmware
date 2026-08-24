"""config.env and test.env, read the way the build reads them.

The two files are shell, and bin/*.sh still sources them, so they stay shell:
they use quoting, `$ROOT`, and occasionally a command substitution, and a
hand-rolled `KEY=VALUE` parser would agree with bash right up until the day it
did not. So bash reads them and reports back what it ended up with. That keeps
exactly one definition of what these files mean.

    config.env   the BUILD config. Everything that can reach a printer.
    test.env     replica-only: the factory image, the partition sizes.
                 Kept apart so nothing in it can end up inside a package.

THE ENVIRONMENT WINS OVER BOTH FILES, which is a rule the shell version had to
work for with a save-and-restore dance around the sourcing. An empty
`PRINTER_IMAGE=` sitting in test.env used to overwrite an explicit
`PRINTER_IMAGE=foo ./test/integration/sim-install.py ...`, so the override
silently did nothing and the run tested a different image than the one it was
told to. Note the rule is about being SET, not about being non-empty: an empty
string in the environment is still a decision, and `PRINTER_IMAGE= make
test-install` deliberately means "build locally", not "use whatever the file
says".
"""
import os
import subprocess

from . import Fail, repo_root

# What the harness reads. Anything else in those files belongs to the build.
WANTED = (
    "FF_KEY",
    "STOCK_TGZ", "STOCK_TGZ_CREATOR5PRO", "STOCK_TGZ_CREATOR5",
    "PRINTER_IMAGE", "PROG_DUMP", "PROG_MB", "DATA_MB",
)

# Of those, the ones a caller is expected to override per-run.
OVERRIDABLE = ("PRINTER_IMAGE", "PROG_DUMP", "PROG_MB", "DATA_MB", "FF_KEY")

# `.` on a file with a syntax error returns non-zero and does NOT stop the
# shell, so the && form quietly carried on with half the file applied. That is
# the whole disease being cured here: a broken config that looks like an
# absent one. Each source is checked, and its own exit code says which file.
_DUMP = r'''
set -a
if [ -f "$1" ]; then . "$1" || exit 91; fi
if [ -f "$2" ]; then . "$2" || exit 92; fi
set +a
for k in %s; do
    eval "v=\${$k-}"
    printf '%%s=%%s\0' "$k" "$v"
done
''' % " ".join(WANTED)


class Config:
    """What the two files say, with the environment layered back on top."""

    def __init__(self, values, root, config_env, test_env):
        self.values = values
        self.root = root
        self.config_env = config_env
        self.test_env = test_env

    @classmethod
    def load(cls, root=None):
        root = root or repo_root()
        config_env = os.environ.get("CONFIG_ENV") or str(root / "config.env")
        test_env = os.environ.get("TEST_ENV") or str(root / "test.env")

        proc = subprocess.run(
            ["bash", "-c", _DUMP, "ffsim", config_env, test_env],
            cwd=str(root), capture_output=True, text=True)
        if proc.returncode != 0:
            # A syntax error in config.env is a BROKEN harness, not a missing
            # precondition. The shell version could not tell the two apart:
            # the half-sourced file left STOCK_TGZ_* empty, the launcher
            # concluded there was nothing to test, and it reported a clean
            # skip. Naming the file that failed is the entire point.
            which = {91: config_env, 92: test_env}.get(proc.returncode)
            raise Fail("could not read %s:\n%s"
                       % (which or ("%s / %s" % (config_env, test_env)),
                          proc.stderr.strip()))

        values = {}
        for item in proc.stdout.split("\0"):
            if "=" in item:
                k, _, v = item.partition("=")
                values[k] = v

        # The environment wins -- see the module docstring. Being SET is what
        # counts, so this tests membership rather than truthiness.
        for k in OVERRIDABLE:
            if k in os.environ:
                values[k] = os.environ[k]

        return cls(values, root, config_env, test_env)

    def get(self, key, default=""):
        return self.values.get(key, default) or default

    @property
    def ff_key(self):
        return self.get("FF_KEY", "FFP0331&*%root")

    def stock_for(self, package_name=None):
        """The stock package that is the authentic baseline for this build.

        With a package name, pick by its model prefix the way the launchers
        always have -- the two models ship different firmwareExe binaries and
        each refuses to install on the other, so the baseline has to match.
        """
        if package_name:
            if package_name.startswith("Creator5Pro-"):
                keys = ("STOCK_TGZ_CREATOR5PRO",)
            elif package_name.startswith("Creator5-"):
                keys = ("STOCK_TGZ_CREATOR5",)
            else:
                keys = ("STOCK_TGZ",)
        else:
            keys = ("STOCK_TGZ_CREATOR5PRO", "STOCK_TGZ")

        for k in keys:
            path = self.get(k)
            if path and os.path.isfile(path):
                return path
        return ""
