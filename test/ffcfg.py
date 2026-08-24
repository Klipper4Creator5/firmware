"""Shared pieces of the test/ Python checks.

`sections()` parses Klipper config the way klippy's own parser sees it; the
reporting helpers keep the PASS/FAIL output format run-tests.sh consumes.

This module exists so test-chamber.py, test-base-cfg.py and test-printer-db.py
stop re-implementing the reporting and stop loading test-macros.py through
importlib machinery just to reach its parser (the dash in that filename made a
plain import impossible).
"""
import re

SECTION = re.compile(r"^\[([^\]]+)\]\s*$")
# Klipper's own option regex: name, colon or equals, value.
OPTION = re.compile(r"^([^:=\s][^:=]*)\s*[:=]\s*(.*)$")


def sections(path):
    """Yield (section_name, {option: value}) the way Klipper's parser sees it."""
    cur, opts, name = None, {}, None
    key = None
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        m = SECTION.match(line.strip())
        if m:
            if cur:
                yield cur, opts
            cur, opts, key = m.group(1), {}, None
            continue
        if cur is None:
            continue
        if line[:1] in " \t" and key:            # continuation line
            opts[key] += "\n" + line
            continue
        m = OPTION.match(line)
        if m:
            key = m.group(1).strip()
            opts[key] = m.group(2)
    if cur:
        yield cur, opts


P, F = [], []


def ok(name):
    P.append(name)
    print("  \033[32mPASS\033[0m  %s" % name)


def bad(name, detail=""):
    F.append(name)
    print("  \033[31mFAIL\033[0m  %s" % name)
    if detail:
        print("        %s" % detail)


def finish():
    """Print the summary line; return the process exit code."""
    print("\n  %d passed, %d failed" % (len(P), len(F)))
    return 1 if F else 0
