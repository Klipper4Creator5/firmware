#!/usr/bin/env python3
"""HelixScreen must pick the right Creator 5 entry for the machine it is on.

The Pro and the plain Creator 5 are the same printer except for the chamber
heating element, so the two database entries are identical apart from one
discriminating heuristic each:

    Pro      object_exists  heater_generic chamber_heater
    non-Pro  object_exists  temperature_sensor chamber

This asserts three invariants against the configs we actually ship:

  1. the two entries are identical apart from the chamber heuristic,
  2. each entry's chamber heuristic carries positive confidence,
  3. each discriminating object exists on exactly one model (because
     printer.chamber.cfg.<model> declares one or the other).

Together those force the right entry to win under ANY scoring in which an
extra matching heuristic never lowers a score: the shared heuristics
contribute identically to both entries, and only the correct entry gains its
discriminator. An earlier version of this test additionally re-implemented
PrinterDetector's confidence formula from printer_detector.cpp -- a model of
someone else's code that would keep passing if the fork changed its formula,
while proving nothing the invariants above do not already prove.

    ./test/test-printer-db.py
"""
import glob
import json
import os
import re
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))
from ffcfg import F, ok, bad, finish

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGDIR = os.path.join(ROOT, "payload", "klipper", "config")
DB = os.path.join(ROOT, "payload", "helixscreen", "printer_database.d",
                  "flashforge_creator5.json")
MODELS = {"Creator5Pro": ("creator5pro", "flashforge_creator5_pro"),
          "Creator5": ("creator5", "flashforge_creator5")}
DISCRIMINATORS = {"flashforge_creator5_pro": "heater_generic chamber_heater",
                  "flashforge_creator5": "temperature_sensor chamber"}
SECTION = re.compile(r"^\[([^\]]+)\]\s*$")


def objects_for(suffix):
    """Klipper object names this model's shipped config declares.

    Section headers are the object names -- [heater_generic chamber_heater]
    becomes the object "heater_generic chamber_heater" -- which is exactly
    what the heuristics pattern-match against.
    """
    files = [os.path.join(CFGDIR, "printer.base.cfg"),
             os.path.join(CFGDIR, "printer.chamber.cfg.%s" % suffix)]
    files += sorted(glob.glob(os.path.join(CFGDIR, "ff-*.cfg")))
    objs = set()
    for path in files:
        if not os.path.exists(path):
            continue
        for line in open(path, encoding="utf-8", errors="replace"):
            m = SECTION.match(line.strip())
            if m and not m.group(1).startswith("include "):
                objs.add(m.group(1))
    return objs


def main():
    db = json.load(open(DB, encoding="utf-8"))
    entries = {p["id"]: p for p in db["printers"]}

    for machine, (_sfx, want_id) in sorted(MODELS.items()):
        if want_id in entries:
            ok("database has an entry for %s (%s)" % (machine, want_id))
        else:
            bad("database has an entry for %s (%s)" % (machine, want_id),
                "have %r" % sorted(entries))
    if F:
        return finish()

    # The two entries must differ ONLY in the discriminating heuristic, or the
    # winner could turn on something unrelated to the chamber.
    def chamber_split(e):
        shared = [h for h in e["heuristics"]
                  if "chamber" not in h.get("pattern", "").lower()]
        disc = [h for h in e["heuristics"] if h not in shared]
        return shared, disc

    pro_shared, pro_disc = chamber_split(entries["flashforge_creator5_pro"])
    np_shared, np_disc = chamber_split(entries["flashforge_creator5"])
    if pro_shared == np_shared:
        ok("the two entries are identical apart from the chamber heuristic")
    else:
        bad("the two entries are identical apart from the chamber heuristic")

    # Each entry's discriminator: exactly one, object_exists, the expected
    # pattern, and positive confidence -- so matching it genuinely helps.
    for want_id, disc in (("flashforge_creator5_pro", pro_disc),
                          ("flashforge_creator5", np_disc)):
        pat = DISCRIMINATORS[want_id]
        label = "%s discriminates on '%s' with positive confidence" % (want_id, pat)
        if (len(disc) == 1 and disc[0].get("type") == "object_exists"
                and disc[0].get("pattern", "").lower() == pat
                and disc[0].get("confidence", 0) > 0):
            ok(label)
        else:
            bad(label, "heuristics mentioning 'chamber': %r" % disc)

    # And each discriminating object must exist on exactly one model.
    for pat, owner in (("heater_generic chamber_heater", "Creator5Pro"),
                       ("temperature_sensor chamber", "Creator5")):
        present = [m for m, (sfx, _) in MODELS.items()
                   if any(pat.lower() in o.lower() for o in objects_for(sfx))]
        if present == [owner]:
            ok("'%s' exists only on %s" % (pat, owner))
        else:
            bad("'%s' exists only on %s" % (pat, owner), "present on %r" % present)

    return finish()


if __name__ == "__main__":
    sys.exit(main())
