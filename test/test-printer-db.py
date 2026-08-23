#!/usr/bin/env python3
"""HelixScreen must pick the right Creator 5 entry for the machine it is on.

The Pro and the plain Creator 5 are the same printer except for the chamber
heating element, so the two database entries are identical apart from one
heuristic each:

    Pro      object_exists  heater_generic chamber_heater
    non-Pro  object_exists  temperature_sensor chamber

Exactly one of those objects exists on any given machine, because
printer.chamber.cfg.<model> declares one or the other. This checks that claim
against the configs we actually ship, then scores both entries the way
PrinterDetector does and asserts the right one wins.

The scoring below mirrors src/printer/printer_detector.cpp (execute_heuristic
+ calculate_confidence): base = highest single matching confidence, then
+3 per additional match capped at +12. It is a MODEL of that code, not the
code itself -- if HelixScreen changes its formula this test will keep passing
while reality changes, so re-check it against the fork when bumping HelixScreen.

    ./test/test-printer-db.py
"""
import glob
import json
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGDIR = os.path.join(ROOT, "payload", "klipper", "config")
DB = os.path.join(ROOT, "payload", "helixscreen", "printer_database.d",
                  "flashforge_creator5_pro.json")
MODELS = {"Creator5Pro": ("creator5pro", "flashforge_creator5_pro"),
          "Creator5": ("creator5", "flashforge_creator5")}
SECTION = re.compile(r"^\[([^\]]+)\]\s*$")

P, F = [], []


def ok(n):
    P.append(n)
    print("  \033[32mPASS\033[0m  %s" % n)


def bad(n, d=""):
    F.append(n)
    print("  \033[31mFAIL\033[0m  %s" % n)
    if d:
        print("        %s" % d)


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


def score(entry, objects, hostname):
    """PrinterDetector's confidence for one entry. 0 = no identifying match."""
    hits = []
    for h in entry["heuristics"]:
        t, pat, conf = h["type"], h.get("pattern", ""), h.get("confidence", 0)
        if t == "object_exists":
            if any(pat.lower() in o.lower() for o in objects):
                hits.append(conf)
        elif t == "hostname_match":
            if pat.lower() in hostname.lower():
                hits.append(conf)
        else:
            raise AssertionError("unmodelled heuristic type %r -- update this test" % t)
    if not hits:
        return 0
    return max(hits) + min(3 * (len(hits) - 1), 12)


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
        print("\n  %d passed, %d failed" % (len(P), len(F)))
        return 1

    # The two entries must differ ONLY in the discriminating heuristic, or the
    # winner could turn on something unrelated to the chamber.
    def without_chamber(e):
        return [h for h in e["heuristics"]
                if "chamber" not in h.get("pattern", "").lower()]
    a, b = (without_chamber(entries["flashforge_creator5_pro"]),
            without_chamber(entries["flashforge_creator5"]))
    if a == b:
        ok("the two entries are identical apart from the chamber heuristic")
    else:
        bad("the two entries are identical apart from the chamber heuristic")

    # Each discriminator must exist on exactly one model.
    for pat, owner in (("heater_generic chamber_heater", "Creator5Pro"),
                       ("temperature_sensor chamber", "Creator5")):
        present = [m for m, (sfx, _) in MODELS.items()
                   if any(pat.lower() in o.lower() for o in objects_for(sfx))]
        if present == [owner]:
            ok("'%s' exists only on %s" % (pat, owner))
        else:
            bad("'%s' exists only on %s" % (pat, owner), "present on %r" % present)

    # And the right entry must actually win -- with and without the hostname
    # hint, since that one matches both entries equally and only shifts counts.
    for hostname in ("creator5", "printer"):
        for machine, (sfx, want_id) in sorted(MODELS.items()):
            objs = objects_for(sfx)
            scores = {i: score(e, objs, hostname) for i, e in entries.items()}
            win = max(scores, key=lambda i: scores[i])
            margin = scores[win] - max(v for i, v in scores.items() if i != win)
            label = "%s wins on %s (hostname %r)" % (want_id, machine, hostname)
            if win == want_id and margin > 0:
                ok("%s -- %s, margin %d" % (label, scores, margin))
            else:
                bad(label, "scores %s" % scores)

    print("\n  %d passed, %d failed" % (len(P), len(F)))
    return 1 if F else 0


if __name__ == "__main__":
    sys.exit(main())
