"""Every klippy extra the shipped config names, imported on the interpreter that will import it.

THE FAILURE THIS EXISTS FOR

klippy moved from FlashForge's CPython 3.8.2 to our own 3.13, and 3.8.2's
rootfs had numpy where ours did not. `extras/stepper_resonance_tester.py`
opens with a bare `import numpy as np`; `printer.base.cfg` includes
FlashForge's `printer.vibration.cfg`, which declares
`[stepper_resonance_tester]`; and `klippy.py:122` walks EVERY config section
through a `load_object` whose `importlib.import_module` is not wrapped in
`except ImportError`. So the result was not a printer missing resonance
testing. It was a klippy that never reached ready.

Two repo comments asserted the opposite -- that the module guarded its own
import and the printer simply carried on without it -- and both survived
review, because nothing anywhere asked the question this file asks. The
package list, the ipk contents and the ABI sweep all passed: the missing
dependency was not a broken file, it was a file that was never there.

WHY THE REPLICA AND NOT qa/static

The config that broke us is FlashForge's. `printer.vibration.cfg` is not in
this repo and never will be -- it arrives on the printer from the stock
firmware, and `printer.base.cfg:19` merely includes it. A static test could
only check the includes we ship, which are exactly the ones that were never
the problem. The real config graph exists on a real machine, so the question
gets asked there.

WHY IT NEEDS NO MCU

Importing is what fails here, and importing happens in `_read_config`, which
klippy runs BEFORE `klippy:mcu_identify`. The replica has no /dev/ttyS4,5,7
and klippy can never reach ready on it (see test_s6rc.py) -- but it does not
need to. This walks the same graph klippy walks and imports the same modules
klippy imports, one step ahead of the hardware it does not have.

WHAT IS DELIBERATELY NOT ASSERTED

That a section maps to an extra AT ALL. Most do not: `[stepper_x]`,
`[printer]`, `[board_pins]` and every `[gcode_macro ...]` have no file under
extras/, and `load_object` returns None for them rather than failing. This
mirrors that -- a section with no module is skipped, exactly as klippy skips
it. What is asserted is the other half: where a module DOES exist, it must
import, because klippy has no path that tolerates one that does not.
"""
import re

import pytest

pytestmark = pytest.mark.replica

MODDIR = "/usr/data/anvil"

# Ours, not FlashForge's 3.8.2 -- anvil-env.sh exports this as FF_PYTHON, and
# etc/s6-rc/source/klipper/run execs it against the tree below. The whole point
# of this file is to ask about THIS interpreter's importable set.
PY = MODDIR + "/bin/python3.13"
ENV = MODDIR + "/anvil-env.sh"
KLIPPY = MODDIR + "/klipper/klippy"

# What klippy is actually given on the command line. Not printer.base.cfg:
# printer.cfg is the user's file and the one that includes it, so starting
# anywhere else would walk a graph the printer does not have.
PRINTER_CFG = "/usr/data/config/printer.cfg"

CONFIG_DIR = "/usr/data/config"

_INCLUDE = re.compile(r"^\s*\[include\s+([^\]]+)\]\s*$", re.M)
_SECTION = re.compile(r"^\s*\[([^\]]+)\]\s*$", re.M)


def _read_graph(box, path, seen):
    """Text of `path` and everything it includes, depth first.

    Klipper resolves an [include] relative to the directory of the file that
    wrote it and accepts a glob. Every config on this machine sits directly in
    /usr/data/config, so the directory is constant and the glob is expanded by
    the shell below rather than reimplemented here.
    """
    if path in seen:
        return []
    seen.add(path)
    f = box.file(path)
    if not f.exists:
        pytest.fail(
            "%s does not exist, so klippy's config graph cannot resolve and "
            "the printer would not start. An [include] naming a missing file "
            "is fatal to Klipper." % path)
    text = f.text
    out = [(path, text)]
    for spec in _INCLUDE.findall(text):
        spec = spec.strip()
        listing = box.sh("ls -1 %s/%s 2>/dev/null" % (CONFIG_DIR, spec))
        names = [ln.strip() for ln in listing.out.splitlines() if ln.strip()]
        if not names:
            pytest.fail(
                "[include %s] in %s matches no file in %s -- Klipper treats "
                "that as fatal, so this printer would not start."
                % (spec, path, CONFIG_DIR))
        for name in names:
            out.extend(_read_graph(box, name, seen))
    return out


@pytest.fixture(scope="module")
def box(printer):
    """The installed machine, with the interpreter and the klippy tree."""
    for path in (PY, KLIPPY):
        if not printer.file(path).exists:
            pytest.fail(
                "there is no %s, so there is nothing to ask this of -- "
                "`make build` first." % path)
    return printer


@pytest.fixture(scope="module")
def sections(box):
    """Every section name in the real config graph, in first-word form.

    `[mcu eboard]` and `[gcode_macro FOO]` are prefix sections: klippy takes
    the module name from the FIRST word and the rest is the instance name, so
    that is what is collected here.
    """
    names = set()
    for _path, text in _read_graph(box, PRINTER_CFG, set()):
        for raw in _SECTION.findall(text):
            head = raw.split()[0].strip()
            if head:
                names.add(head)
    assert names, (
        "no sections found anywhere under %s -- the graph walk read nothing, "
        "so every assertion below would be vacuous" % PRINTER_CFG)
    return sorted(names)


def test_the_config_graph_is_not_trivial(sections):
    """Anti-vacuity. A walk that resolved one file and stopped would let the
    real test pass while asking almost nothing."""
    assert len(sections) > 20, (
        "only %d config sections found (%s) -- printer.cfg's includes did not "
        "resolve, so the import test below is not covering the machine"
        % (len(sections), ", ".join(sections)))


def test_the_vibration_config_is_in_the_graph(sections):
    """The specific section this file was written for.

    Pinned by name rather than left to the sweep, because it is the one whose
    absence would make everything else here pass for the wrong reason: if
    FlashForge's printer.vibration.cfg ever stops being included, the numpy
    dependency stops being load-bearing and nobody would notice this test had
    gone quiet.
    """
    assert "stepper_resonance_tester" in sections, (
        "[stepper_resonance_tester] is not in the config graph. Either "
        "printer.base.cfg no longer includes FlashForge's "
        "printer.vibration.cfg, or that file has changed -- and if so, "
        "anvil-klipper's Depends on anvil-python-numpy and "
        "docs/notes/44-vfa-calibration.md both need re-reading.")


def test_every_named_extra_imports(box, sections):
    """The gate.

    One interpreter start for the whole set, not one per module: each is a
    qemu-mipsel start and the sweep is dozens of modules. The script reports
    per-module rather than dying on the first failure, because "which ones are
    broken" is the question a maintainer has when this goes red.
    """
    script = r"""
. %(env)s
cd %(klippy)s
exec %(py)s - <<'PYEOF'
import importlib, os, sys
sys.path.insert(0, ".")
names = %(names)r
for name in names:
    base = os.path.join("extras", name)
    if not os.path.exists(base + ".py") and \
       not os.path.exists(os.path.join(base, "__init__.py")):
        print("SKIP %%s (no module -- klippy's load_object returns None)" %% name)
        continue
    try:
        importlib.import_module("extras." + name)
    except BaseException as exc:
        print("FAIL %%s %%s: %%s" %% (name, type(exc).__name__, exc))
    else:
        print("OK %%s" %% name)
PYEOF
""" % {"env": ENV, "klippy": KLIPPY, "py": PY, "names": list(sections)}

    res = box.sh(script, timeout=600)
    lines = [ln.strip() for ln in res.out.splitlines() if ln.strip()]
    failed = [ln for ln in lines if ln.startswith("FAIL ")]
    imported = [ln for ln in lines if ln.startswith("OK ")]

    assert imported, (
        "not one extra imported, so the interpreter or the tree is wrong "
        "rather than any single module being broken.\nexit=%s\n%s\n%s"
        % (res.code, res.out[-2000:], res.err[-2000:]))
    assert not failed, (
        "%d klippy extra(s) named by the shipped config do not import on %s. "
        "klippy.py:103 does not catch ImportError and klippy.py:122 loads "
        "every section, so each of these is a printer that never reaches "
        "ready -- not a missing feature:\n  %s"
        % (len(failed), PY, "\n  ".join(failed)))
