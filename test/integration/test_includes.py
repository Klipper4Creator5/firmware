"""printer.base.cfg must include the whole ff-*.cfg set, in a safe place.

The mod's config only takes effect if something includes it, and the one file
that may not be written by the package is printer.cfg -- it is the user's.
So printer.base.cfg carries the includes, and this checks the two things that
silently break if it stops:

  * every ff-*.cfg we ship is included, and every include resolves to a file
    we ship. A new ff-*.cfg added to pkgs/anvil-core/payload/config/ and not
    wired up would otherwise be dead weight nobody notices.
  * the includes sit after the sections they override. Klipper applies
    includes in parse order, so ff-chamber.cfg has to follow
    printer.chamber.cfg, and ff-runout.cfg the filament sensors that
    printer.filament.cfg (included at the top) declares. Putting the block at
    the end of the file satisfies both; this fails if someone moves it up.

Ordering rules that are NOT checked here because they are not real: nothing
needs to follow [virtual_sdcard], and the G28 / SHAPER_CALIBRATE wrappers do
not need their targets declared first. ff_print and gcode_macro both take
their commands over at klippy:connect, once every section is loaded.

Needs nothing proprietary: the configs are all in the repo.
"""
import os
import re

import pytest

INCLUDE = re.compile(r"^\[include\s+(\S+)\]\s*$")

# Everything the mod ships, in the order printer.base.cfg must list them.
# ff-runout and ff-chamber come after the stock sections they override.
# ff-legacy's position is not load-bearing -- it resolves tools at
# klippy:ready -- but the order is pinned so a reordering is a deliberate act.
EXPECTED = [
    "ff-toolchange.cfg",
    "ff-tool-offset.cfg",
    "ff-filament.cfg",
    "ff-print-macros.cfg",
    "ff-runout.cfg",
    "ff-chamber.cfg",
    "ff-legacy.cfg",
]


def base_cfg(cfgdir):
    return os.path.join(cfgdir, "printer.base.cfg")


def includes(cfgdir):
    """[(lineno, spec)] for every [include] in printer.base.cfg, in order."""
    out = []
    with open(base_cfg(cfgdir), encoding="utf-8", errors="replace") as fh:
        for n, raw in enumerate(fh, 1):
            m = INCLUDE.match(raw.strip())
            if m:
                out.append((n, m.group(1)))
    return out


def ff_includes(cfgdir):
    return [(n, s) for n, s in includes(cfgdir) if s.startswith("ff-")]


def shipped(cfgdir):
    return sorted(f for f in os.listdir(cfgdir)
                  if f.startswith("ff-") and f.endswith(".cfg"))


def test_some_includes_are_found(cfgdir):
    """Guard against the regex matching nothing and every test below passing."""
    assert includes(cfgdir), "no [include] parsed from printer.base.cfg"


def test_every_shipped_ff_cfg_is_included(cfgdir):
    included = {s for _, s in ff_includes(cfgdir)}
    missing = [f for f in shipped(cfgdir) if f not in included]
    assert not missing, (
        "shipped but never included, so dead on the printer: %s" % missing)


def test_every_ff_include_resolves(cfgdir):
    """A typo'd include is not a warning -- klippy refuses to start."""
    for _, spec in ff_includes(cfgdir):
        assert os.path.isfile(os.path.join(cfgdir, spec)), (
            "printer.base.cfg includes '%s', which we do not ship" % spec)


def test_ff_includes_are_the_expected_set(cfgdir):
    assert [s for _, s in ff_includes(cfgdir)] == EXPECTED


def test_ff_includes_come_last(cfgdir):
    """After every other include, so an override in ours actually wins."""
    ff_lines = [n for n, _ in ff_includes(cfgdir)]
    other = [n for n, s in includes(cfgdir) if not s.startswith("ff-")]
    assert other, "printer.base.cfg no longer includes any stock config"
    assert min(ff_lines) > max(other), (
        "an ff-*.cfg include at line %d precedes a stock include at line %d "
        "-- ours must be able to override theirs" % (min(ff_lines), max(other)))


@pytest.mark.parametrize("ours,theirs", [
    # ff-chamber.cfg's macros build on whatever the model's chamber declared.
    ("ff-chamber.cfg", "printer.chamber.cfg"),
    # ff-runout.cfg redeclares the fd_ex*/fm_ex* sensors that file sets up.
    ("ff-runout.cfg", "printer.filament.cfg"),
])
def test_override_follows_what_it_overrides(cfgdir, ours, theirs):
    by_spec = {s: n for n, s in includes(cfgdir)}
    for spec in (ours, theirs):
        assert spec in by_spec, "printer.base.cfg no longer includes %s" % spec
    assert by_spec[ours] > by_spec[theirs], (
        "%s (line %d) is included before %s (line %d), so its overrides lose"
        % (ours, by_spec[ours], theirs, by_spec[theirs]))


def test_nothing_follows_the_ff_block(cfgdir):
    """The block is the tail of the file; a section added after it would
    parse after our overrides and quietly win."""
    text = open(base_cfg(cfgdir), encoding="utf-8", errors="replace").read()
    tail = text.split("[include %s]" % EXPECTED[-1], 1)[1]
    stray = [l for l in tail.splitlines()
             if l.strip() and not l.lstrip().startswith("#")]
    assert not stray, "config lines after the ff-*.cfg include block: %s" % stray
