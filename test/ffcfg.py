"""Klipper config parsing for the test suite.

`sections()` parses Klipper config the way klippy's own parser sees it.

This used to also carry ok()/bad()/finish() reporting helpers, because the
checks were standalone scripts that printed their own PASS/FAIL lines and
returned an exit code. They are pytest tests now, so pytest does the
reporting and only the parser is left.
"""
import re

SECTION = re.compile(r"^\[([^\]]+)\]\s*$")
# Klipper's own option regex: name, colon or equals, value.
OPTION = re.compile(r"^([^:=\s][^:=]*)\s*[:=]\s*(.*)$")


def sections(path):
    """Yield (section_name, {option: value}) the way Klipper's parser sees it."""
    cur, opts = None, {}
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
