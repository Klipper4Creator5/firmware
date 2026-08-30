"""config.env and test.env, read the way the build reads them.

Lifted from tools/replica/ffsim/config.py rather than imported from it. The
endgame is that ffsim is deleted, and a qa/ that imports from it would block
that deletion or break on it. The file format is stable and the parser is
thirty lines; the coupling would cost more than the duplication.

The two files are shell, and bin/*.sh still sources them, so they stay shell:
they use quoting, `$ROOT`, and occasionally a command substitution, and a
hand-rolled KEY=VALUE parser would agree with bash right up until the day it
did not. So bash reads them and reports back what it ended up with. That keeps
exactly one definition of what these files mean.

    config.env   the BUILD config. Everything that can reach a printer.
    test.env     replica-only: the factory image, the partition sizes.
                 Kept apart so nothing in it can end up inside a package.

THE ENVIRONMENT WINS OVER BOTH FILES. An empty `PRINTER_IMAGE=` sitting in
test.env used to overwrite an explicit `PRINTER_IMAGE=foo ...` on the command
line, so the override silently did nothing and the run tested a different image
than the one it was told to. The rule is about being SET, not about being
non-empty: `PRINTER_IMAGE= make qa-replica` deliberately means "build locally",
not "use whatever the file says".
"""
import os
import subprocess

from .paths import ROOT

# What the harness reads. Anything else in those files belongs to the build.
WANTED = (
    "FF_KEY",
    "STOCK_TGZ", "STOCK_TGZ_CREATOR5PRO", "STOCK_TGZ_CREATOR5",
    "PRINTER_IMAGE", "PROG_MB", "DATA_MB",
)

# Of those, the ones a caller is expected to override per-run.
OVERRIDABLE = ("PRINTER_IMAGE", "PROG_MB", "DATA_MB", "FF_KEY")

# `.` on a file with a syntax error returns non-zero and does NOT stop the
# shell, so the && form quietly carried on with half the file applied. That is
# the disease being cured here: a broken config that looks like an absent one.
# Each source is checked, and its own exit code says which file.
_DUMP = r'''
set -a
if [ -f "$1" ]; then . "$1" || exit 91; fi
if [ -f "$2" ]; then . "$2" || exit 92; fi
set +a
for key in %s; do
    eval "value=\${$key-}"
    printf '%%s=%%s\0' "$key" "$value"
done
''' % " ".join(WANTED)


class ConfigError(Exception):
    """The config itself is broken -- not absent, broken.

    Deliberately not a skip. A syntax error in config.env leaves STOCK_TGZ_*
    empty, and a harness that treats that as "nothing to test here" reports a
    clean skip on a machine that could have run everything. Naming the file
    that failed is the entire point.
    """


class Config:
    """What the two files say, with the environment layered back on top."""

    def __init__(self, values, config_env, test_env):
        self.values = values
        self.root = ROOT
        self.config_env = config_env
        self.test_env = test_env

    @classmethod
    def load(cls):
        config_env = os.environ.get("CONFIG_ENV") or str(ROOT / "config.env")
        test_env = os.environ.get("TEST_ENV") or str(ROOT / "test.env")

        dumped = subprocess.run(
            ["bash", "-c", _DUMP, "qa", config_env, test_env],
            cwd=str(ROOT), capture_output=True, text=True)
        if dumped.returncode != 0:
            which = {91: config_env, 92: test_env}.get(dumped.returncode)
            raise ConfigError(
                "could not read %s:\n%s"
                % (which or ("%s / %s" % (config_env, test_env)),
                   dumped.stderr.strip()))

        values = {}
        for item in dumped.stdout.split("\0"):
            if "=" in item:
                key, _, value = item.partition("=")
                values[key] = value

        # The environment wins -- see the module docstring. Being SET is what
        # counts, so this tests membership rather than truthiness.
        for key in OVERRIDABLE:
            if key in os.environ:
                values[key] = os.environ[key]

        return cls(values, config_env, test_env)

    def get(self, key, default=""):
        return self.values.get(key, default) or default

    @property
    def ff_key(self):
        return self.get("FF_KEY", "FFP0331&*%root")

    def stock_for(self, package_name=None):
        """The stock package that is the authentic baseline for this build.

        With a package name, pick by its model prefix: the two models ship
        different firmwareExe binaries and each refuses to install on the
        other, so the baseline has to match.
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
