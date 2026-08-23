#!/usr/bin/env python3
"""Our printer.base.cfg must be FlashForge's, minus only the chamber block.

We ship our own printer.base.cfg because Klipper config can override an option
but cannot un-declare a SECTION, and the plain Creator 5 has no chamber
heating element -- the heater has to be absent from the file, not neutralised
in it. Carrying a copy of someone else's 377-line pin map is only safe if
something proves it is still their file, so this reconstructs the stock one:

    ours (with [include printer.chamber.cfg] resolved to the Pro's variant)
        ==  stock printer.base.cfg,  section for section, option for option

A FlashForge change to printer.base.cfg therefore fails the build rather than
being silently overridden by a stale copy.

    ./test/test-base-cfg.py [stock-printer.base.cfg]
"""
import importlib.util
import os
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGDIR = os.path.join(ROOT, "payload", "klipper", "config")
OURS = os.path.join(CFGDIR, "printer.base.cfg")
PRO = os.path.join(CFGDIR, "printer.chamber.cfg.creator5pro")
NONPRO = os.path.join(CFGDIR, "printer.chamber.cfg.creator5")
INCLUDE = "[include printer.chamber.cfg]"
STOCK = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, "work", "software", "klipper", "config", "printer.base.cfg")

_spec = importlib.util.spec_from_file_location(
    "test_macros", os.path.join(ROOT, "test", "test-macros.py"))
_tm = importlib.util.module_from_spec(_spec)
_spec.loader.exec_module(_tm)

P = F = 0


def ok(name):
    global P
    P += 1
    print("  \033[32mPASS\033[0m  %s" % name)


def bad(name, detail=""):
    global F
    F += 1
    print("  \033[31mFAIL\033[0m  %s" % name)
    if detail:
        print("        %s" % detail)


def parse(path):
    return list(_tm.sections(path))


def main():
    global F
    if not os.path.exists(STOCK):
        print("  SKIP: no stock printer.base.cfg at %s" % STOCK)
        print("        (run ./bin/unpack.sh first)")
        return 0

    # --- the reconstruction -------------------------------------------------
    text = open(OURS, encoding="utf-8").read()
    if INCLUDE not in text:
        bad("our printer.base.cfg includes printer.chamber.cfg")
        return 1
    rebuilt = text.replace(INCLUDE, open(PRO, encoding="utf-8").read())
    tmp = OURS + ".rebuilt"
    open(tmp, "w", encoding="utf-8").write(rebuilt)
    try:
        mine, stock = parse(tmp), parse(STOCK)
    finally:
        os.unlink(tmp)

    mine_names = [n for n, _ in mine]
    stock_names = [n for n, _ in stock]
    if mine_names == stock_names:
        ok("same %d sections, same order, as stock" % len(stock_names))
    else:
        only_stock = [n for n in stock_names if n not in mine_names]
        only_mine = [n for n in mine_names if n not in stock_names]
        bad("same sections, same order, as stock",
            "missing %r, extra %r" % (only_stock, only_mine))

    diffs = []
    for (n, a), (_, b) in zip(mine, stock):
        if a != b:
            keys = set(a) | set(b)
            diffs += ["[%s] %s: %r != %r" % (n, k, a.get(k), b.get(k))
                      for k in sorted(keys) if a.get(k) != b.get(k)]
    if not diffs:
        ok("every option matches stock")
    else:
        bad("every option matches stock", "; ".join(diffs[:5]))

    # --- and the non-Pro really has no heater -------------------------------
    np = dict(parse(NONPRO))
    heaters = [n for n in np
               if n.startswith("heater_generic") or n.startswith("verify_heater")]
    if not heaters:
        ok("Creator 5 declares no chamber heater at all")
    else:
        bad("Creator 5 declares no chamber heater at all", repr(heaters))

    sensor = np.get("temperature_sensor chamber")
    if sensor:
        ok("Creator 5 still declares the chamber sensor")
    else:
        bad("Creator 5 still declares the chamber sensor", repr(sorted(np)))

    # The reading must be the stock one: same pin, type and bounds as the
    # heater section it replaces, or the chamber would read differently on the
    # two models for no reason.
    pro = dict(parse(PRO)).get("heater_generic chamber_heater", {})
    if sensor:
        mismatch = [k for k in ("sensor_type", "sensor_pin", "min_temp", "max_temp")
                    if sensor.get(k) != pro.get(k)]
        if not mismatch:
            ok("Creator 5's sensor matches the Pro's pin, type and bounds")
        else:
            bad("Creator 5's sensor matches the Pro's pin, type and bounds",
                ", ".join("%s: %r != %r" % (k, sensor.get(k), pro.get(k))
                          for k in mismatch))

    print("\n  %d passed, %d failed" % (P, F))
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main())
