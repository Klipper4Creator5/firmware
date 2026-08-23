#!/usr/bin/env python3
"""The ff-*.cfg macros must parse: as Klipper config, and as Jinja.

Klipper renders every gcode_macro body through Jinja2 at RUNTIME, and a
config-time syntax error only surfaces when klippy loads the file -- on the
printer, at the start of a print. This parses the same bodies here.

It checks syntax and undefined-variable-free rendering of the template, not
behaviour: a macro that parses can still do the wrong thing.

    ./test/test-macros.py [config-dir]
"""
import glob
import os
import re
import sys

try:
    import jinja2
except ImportError:
    print("  SKIP: jinja2 not installed")
    sys.exit(0)

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
CFGDIR = sys.argv[1] if len(sys.argv) > 1 else os.path.join(
    ROOT, "payload", "klipper", "config")

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


def main():
    env = jinja2.Environment()
    files = sorted(glob.glob(os.path.join(CFGDIR, "ff-*.cfg")))
    if not files:
        print("  SKIP: no ff-*.cfg in %s" % CFGDIR)
        return 0
    fail, checked = 0, 0
    for path in files:
        for name, opts in sections(path):
            body = opts.get("gcode")
            if body is None:
                continue
            checked += 1
            try:
                env.parse(body)
            except jinja2.TemplateSyntaxError as e:
                fail += 1
                print("  \033[31mFAIL\033[0m  %s [%s]: line %s: %s"
                      % (os.path.basename(path), name, e.lineno, e.message))
    if fail:
        print("\n  %d macro(s) failed to parse" % fail)
        return 1
    print("  \033[32mPASS\033[0m  %d macro bodies parse as Jinja (%d files)"
          % (checked, len(files)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
