"""Absolute paths the payload uses must exist on the printer.

What is left of this check is the half that earns its keep: every literal
/bin, /sbin, /etc, /usr/bin, /usr/sbin path in an on-printer script has to
exist in the real extracted rootfs. Its value is the branches no simulation
ever reaches -- S50wifi bails at `[ -d /sys/class/net/wlan0 ]`, which the
replica has not got, so /sbin/udhcpc, /sbin/ifconfig, /usr/sbin/wpa_supplicant
and /usr/sbin/wpa_cli are verified here and nowhere else.

The bare-command-word scan that used to live here is gone, along with
test/applets.allow. It extracted only the first word of a simple, unprefixed
command, so `if timeout 5 foo; then` yielded ['if','echo','fi'] -- the exact
failure its own docstring claimed to guard was invisible to it, as were
`VAR=1 cmd`, `nohup cmd`, and everything reached through a variable or an
absolute path, which is how the payload invokes essentially everything. Its
allowlist had drifted to nine entries that excused nothing. What it could
really catch, case-install.sh catches properly by booting the machine and
grepping the boot log for "command not found".

/usr/prog and /usr/data are deliberately not checked: they live on partitions
the rootfs does not contain, and the install simulation covers them.
"""
import os
import re

import pytest

PATHS = re.compile(
    r"(?<![\w.])(/(?:bin|sbin|etc)/[A-Za-z0-9_./-]+|/usr/(?:bin|sbin)/[A-Za-z0-9_./-]+)")


def payload_scripts(root):
    out = []
    for dirpath, _, names in os.walk(os.path.join(root, "payload")):
        for n in names:
            if n.endswith(".sh") or n == "firmwareExe" or re.match(r"^S\d", n):
                out.append(os.path.join(dirpath, n))
    return sorted(out)


def absolute_paths(root):
    """(script, path) for every rootfs-absolute path the payload names."""
    for f in payload_scripts(root):
        src = open(f, encoding="utf-8", errors="replace").read()
        for p in sorted(set(PATHS.findall(src))):
            yield os.path.relpath(f, root), p


def test_payload_scripts_are_found(root):
    assert payload_scripts(root), "no on-printer scripts found under payload/"


def test_some_absolute_paths_are_checked(root):
    """Guard against the regex silently matching nothing and the test passing."""
    assert list(absolute_paths(root)), "no absolute paths extracted -- regex broken?"


@pytest.mark.rootfs
def test_absolute_paths_exist_on_the_printer(root, rootfs):
    missing = ["%s: %s" % (script, p)
               for script, p in absolute_paths(root)
               if not os.path.exists(rootfs + p)]
    assert not missing, \
        "paths that do not exist on the printer:\n  " + "\n  ".join(missing)


@pytest.mark.rootfs
@pytest.mark.parametrize("binary", [
    "/sbin/ifconfig", "/sbin/udhcpc", "/usr/sbin/wpa_supplicant", "/usr/sbin/wpa_cli",
])
def test_wifi_binaries_exist(rootfs, binary):
    """Named explicitly: S50wifi's connect() never runs in any simulation."""
    assert os.path.exists(rootfs + binary), "%s missing from the printer rootfs" % binary
