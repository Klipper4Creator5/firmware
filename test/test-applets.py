#!/usr/bin/env python3
"""Every command the payload runs must actually exist on the printer.

The printer's busybox is a 1.31.1 build with a specific applet set. It has no
`timeout`, no `bash`, no `systemctl`. A script that reaches for one of those
fails at boot, on the machine, with the screen already blank -- so the check
belongs here, against the real extracted rootfs.
"""
import os
import re
import sys

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
RFS = os.path.join(ROOT, "work", "rootfs")

KEYWORDS = set("""
if then else elif fi for while until do done case esac in function select time
return exit local export readonly set unset shift eval exec trap break continue
true false echo cd test read printf source wait umask alias command type hash
getopts times ulimit jobs fg bg kill let
""".split())

SEPARATORS = re.compile(r"[;&|\n]|\$\(|`|\(\s|\bthen\b|\bdo\b|\belse\b")
WORD = re.compile(r"[A-Za-z_][A-Za-z0-9_.:-]*")


def strip_quotes_and_comments(text):
    """Blank out comments and quoted text so prose cannot look like a command."""
    out, i, n = [], 0, len(text)
    quote = None
    while i < n:
        c = text[i]
        if quote is None and c == "#" and (not out or out[-1] in " \t\n;&|(`"):
            while i < n and text[i] != "\n":
                i += 1
            continue
        if quote is None and c in "'\"":
            quote = c
            out.append(" ")
            i += 1
            continue
        if quote is not None:
            if c == "\\" and quote == '"':
                out.append(" ")
                i += 2
                continue
            if c == quote:
                quote = None
                out.append(" ")
                i += 1
                continue
            # keep $(...) and `...` inside double quotes: they are real commands
            out.append(c if (quote == '"' and c in "$()`") else " ")
            i += 1
            continue
        out.append(c)
        i += 1
    return "".join(out)


ARITH = re.compile(r"\$\(\([^()]*\)\)")


def command_words(text):
    text = strip_quotes_and_comments(text)
    while ARITH.search(text):          # $((...)) is arithmetic, not a command
        text = ARITH.sub(" ", text)
    words = []
    for segment in SEPARATORS.split(text):
        segment = segment.lstrip(" \t()")
        m = WORD.match(segment)
        if not m:
            continue
        word = m.group(0)
        rest = segment[m.end():].lstrip()
        if rest.startswith("=") or rest.startswith(")"):
            continue          # assignment, or a case label
        words.append(word)
    return words


def main():
    if not os.path.isdir(os.path.join(RFS, "bin")):
        print("  SKIP: no printer rootfs -- run 'make rootfs' first")
        return 0

    avail = set()
    for d in ("bin", "sbin", "usr/bin", "usr/sbin"):
        p = os.path.join(RFS, d)
        if os.path.isdir(p):
            avail.update(os.listdir(p))

    allow = set()
    allow_file = os.path.join(ROOT, "test", "applets.allow")
    if os.path.exists(allow_file):
        for line in open(allow_file):
            line = line.split("#")[0].strip()
            if line:
                allow.add(line)

    files = []
    for dirpath, _, names in os.walk(os.path.join(ROOT, "payload")):
        for n in names:
            if n.endswith(".sh") or n == "firmwareExe" or re.match(r"^S\d", n):
                files.append(os.path.join(dirpath, n))
    files.sort()

    fail = False
    for f in files:
        src = open(f, encoding="utf-8", errors="replace").read()
        funcs = set(re.findall(r"^\s*([A-Za-z_][A-Za-z0-9_]*)\s*\(\)", src, re.M))
        rel = os.path.relpath(f, ROOT)
        for w in sorted(set(command_words(src))):
            if w in KEYWORDS or w in funcs or w in avail or w in allow:
                continue
            print(f"  FAIL  {rel}: \"{w}\" is not on the printer "
                  f"and not in test/applets.allow")
            fail = True
        # Absolute paths into the rootfs must exist. /usr/prog and /usr/data
        # live on partitions the rootfs does not contain; the install
        # simulation covers those.
        for p in sorted(set(re.findall(
                r"(?<![\w.])(/(?:bin|sbin|etc)/[A-Za-z0-9_./-]+|"
                r"/usr/(?:bin|sbin)/[A-Za-z0-9_./-]+)", src))):
            if not os.path.exists(RFS + p):
                print(f"  FAIL  {rel}: {p} does not exist on the printer")
                fail = True

    if not fail:
        print("  every command the payload uses exists on the printer")
    return 1 if fail else 0


if __name__ == "__main__":
    sys.exit(main())
