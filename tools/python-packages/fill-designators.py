#!/usr/bin/env python3
"""Make C++ designated initializers digestible by gcc 7.2.

    fill-designators.py <include/python3.13> <file.cpp> [file.cpp ...]

WHY THIS EXISTS. greenlet 3.x writes its PyTypeObject, PyNumberMethods and
friends as C++ designated initializers:

    PyTypeObject PyGreenlet_Type = {
        .ob_base=PyVarObject_HEAD_INIT(NULL, 0)
        .tp_name="greenlet.greenlet",
        .tp_basicsize=sizeof(PyGreenlet),
        .tp_dealloc=(destructor)green_dealloc,
        ...

Designated initializers are C++20. gcc 7.2 -- the Ingenic toolchain, and the
only compiler this printer's ABI has -- supports them as an extension, but
only IN DECLARATION ORDER AND CONTIGUOUS. Measured, probe-desig.sh:

    in order, contiguous     OK
    in order, TRAILING gap   OK   -- the only gap gcc 7.2 tolerates
    in order, INTERIOR gap   sorry, unimplemented: non-trivial designated
                             initializers not supported
    in order, LEADING gap    same -- {.nb_bool=x} on a PyNumberMethods whose
                             first field is nb_add is already too much
    out of order             same

Every one of greenlet's initializers skips fields -- a PyTypeObject naming 20
of its 50 slots is the normal way to write one -- so all of them are interior
gaps, and the build stops on the first.

WHAT THIS DOES. It reads the field order out of the TARGET interpreter's own
headers and writes the skipped fields back in as explicit zeros. That is a
no-op semantically: these are objects of static storage duration, so every
field this inserts was already going to be zero-initialized. It is not a
behaviour patch, it is the same initializer spelled in a way gcc 7.2 will
accept, and if a designator ever appears that is NOT in the header's field
list the script fails loudly rather than guessing.

Every field it fills is a pointer or an integer, so `= 0` is the right zero;
the script asserts that too, rather than trusting it.
"""
import os
import re
import sys

INCLUDE = sys.argv[1]
FILES = sys.argv[2:]

# The initializer types greenlet uses. Each is (C type name as written in the
# source, the header declaration to read the field order from).
STRUCTS = {
    "PyTypeObject": ("cpython/object.h", "struct _typeobject"),
    "PyNumberMethods": ("cpython/object.h", "typedef struct"),
    "PyAsyncMethods": ("cpython/object.h", "typedef struct"),
    "PySequenceMethods": ("cpython/object.h", "typedef struct"),
    "PyMappingMethods": ("cpython/object.h", "typedef struct"),
    "PyModuleDef": ("moduleobject.h", "struct PyModuleDef"),
}

# A field declaration line. Two shapes in CPython's headers that a naive
# regex gets wrong, and both appear in PyTypeObject:
#   * `PyObject_VAR_HEAD` -- a MACRO, not a declaration; it expands to the
#     `ob_base` field the source designates by name.
#   * `Py_ssize_t tp_basicsize, tp_itemsize;` -- two declarators on one line.
FIELD = re.compile(r"^\s*(?:const\s+|struct\s+|unsigned\s+)*"
                   r"[A-Za-z_][A-Za-z0-9_]*\s*"
                   r"(?P<decls>[^;{}()]*);\s*$")
DECLARATOR = re.compile(r"\**\s*([A-Za-z_][A-Za-z0-9_]*)\s*(?:\[[^]]*\])?$")
HEAD_MACROS = {"PyObject_HEAD": "ob_base", "PyObject_VAR_HEAD": "ob_base"}


def read_header(path):
    for root, _dirs, files in os.walk(INCLUDE):
        if os.path.basename(path) in files and root.endswith(
                os.path.dirname(path) or root[len(root):] or ""):
            return open(os.path.join(root, os.path.basename(path))).read()
    # fall back: anywhere under the include tree
    for root, _dirs, files in os.walk(INCLUDE):
        if os.path.basename(path) in files:
            return open(os.path.join(root, os.path.basename(path))).read()
    raise SystemExit("no header %s under %s" % (path, INCLUDE))


def fields_of(cname):
    """Ordered field names of a struct, read from the target's headers."""
    header, _kind = STRUCTS[cname]
    text = read_header(header)
    # find "} <cname>;" or "struct _typeobject {"
    if cname == "PyTypeObject":
        start = text.index("struct _typeobject {")
        start = text.index("{", start) + 1
    else:
        end = re.search(r"\}\s*%s\s*;" % cname, text)
        if not end:
            return None
        # walk back to the matching "typedef struct {"
        head = text[:end.start()]
        start = head.rindex("typedef struct {") + len("typedef struct {")
        end_i = end.start()
        return _scan(text[start:end_i])
    depth = 1
    i = start
    while depth:
        if text[i] == "{":
            depth += 1
        elif text[i] == "}":
            depth -= 1
        i += 1
    return _scan(text[start:i - 1])


def _scan(body):
    body = re.sub(r"/\*.*?\*/", "", body, flags=re.S)
    body = re.sub(r"//[^\n]*", "", body)
    out = []
    depth = 0
    for line in body.splitlines():
        stripped = line.strip()
        if stripped in HEAD_MACROS:
            out.append(HEAD_MACROS[stripped])
            continue
        depth += line.count("(") - line.count(")")
        if depth:
            continue
        m = FIELD.match(line)
        if not m:
            continue
        for decl in m.group("decls").split(","):
            d = DECLARATOR.search(decl.strip())
            if d:
                out.append(d.group(1))
    return out


# ---------------------------------------------------------------- rewrite ---
# Match "<Type> <name> = {" ... matching "}" at the top level of the file.
DECL = re.compile(r"^(\s*)(?:static\s+)?(%s)\s+([A-Za-z_][A-Za-z0-9_]*)\s*=\s*\{"
                  % "|".join(STRUCTS), re.M)

changed_total = 0
for path in FILES:
    src = open(path).read()
    out = []
    pos = 0
    changed = 0
    for m in DECL.finditer(src):
        cname = m.group(2)
        order = fields_of(cname)
        if not order:
            continue
        # find the matching close brace of this initializer
        i = m.end()
        depth = 1
        while depth:
            if src[i] == "{":
                depth += 1
            elif src[i] == "}":
                depth -= 1
            i += 1
        body = src[m.end():i - 1]

        used = [d for d in re.findall(r"\.([A-Za-z_][A-Za-z0-9_]*)\s*=", body)]
        # only top-level designators: drop any that are not fields of this
        # struct (they belong to a nested brace, e.g. .ob_base={...}).
        used = [u for u in used if u in order]
        if not used:
            continue
        unknown = [u for u in re.findall(r"^\s*\.([A-Za-z_][A-Za-z0-9_]*)\s*=",
                                         body, re.M) if u not in order]
        if unknown:
            raise SystemExit("%s: %s names %r, not a field of %s -- header "
                             "and source disagree, refusing to guess"
                             % (path, m.group(3), unknown, cname))
        idx = [order.index(u) for u in used]
        if idx != sorted(idx):
            raise SystemExit("%s: %s designators are out of declaration order "
                             "(%r) -- gcc 7.2 cannot take that either and "
                             "reordering them is not this script's job"
                             % (path, m.group(3), used))

        # Insert the skipped fields, in order, as explicit zeros. Everything
        # between the first and last named field only.
        new_body = body
        gaps = []
        for a, b in zip(idx, idx[1:]):
            if b - a > 1:
                gaps.append((order[a], order[a + 1:b]))
        for after, missing in reversed(gaps):
            fill = "".join("    .%s=0,\n" % f for f in missing)
            # place the fill immediately after the entry for `after`
            am = re.search(r"\.%s\s*=" % re.escape(after), new_body)
            j = am.end()
            depth2 = 0
            while True:
                c = new_body[j]
                if c in "([{":
                    depth2 += 1
                elif c in ")]}":
                    if depth2 == 0:
                        break
                    depth2 -= 1
                elif c == "," and depth2 == 0:
                    j += 1
                    break
                j += 1
            new_body = new_body[:j] + "\n" + fill + new_body[j:]
            changed += len(missing)

        # A gap BEFORE the first designator is refused too -- greenlet's
        # `static PyNumberMethods green_as_number = {.nb_bool=...}` names the
        # tenth field and nothing before it. Fill from field zero.
        if idx[0] > 0:
            fill = "".join("    .%s=0,\n" % f for f in order[:idx[0]])
            new_body = "\n" + fill + new_body
            changed += idx[0]

        out.append(src[pos:m.end()])
        out.append(new_body)
        pos = i - 1
    out.append(src[pos:])
    if changed:
        open(path, "w").write("".join(out))
        print("  %s: filled %d skipped field(s)" % (path, changed))
        changed_total += changed

print("fill-designators: %d field(s) written back" % changed_total)
