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
    section, options = None, {}
    key = None
    for raw in open(path, encoding="utf-8", errors="replace"):
        line = raw.rstrip("\n")
        if not line.strip() or line.lstrip().startswith("#"):
            continue
        header = SECTION.match(line.strip())
        if header:
            if section:
                yield section, options
            section, options, key = header.group(1), {}, None
            continue
        if section is None:
            continue
        if line[:1] in " \t" and key:            # continuation line
            options[key] += "\n" + line
            continue
        option = OPTION.match(line)
        if option:
            key = option.group(1).strip()
            options[key] = option.group(2)
    if section:
        yield section, options
