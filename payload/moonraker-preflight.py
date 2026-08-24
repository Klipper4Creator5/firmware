#!/usr/bin/env python3
# Can THIS printer's python actually run the Moonraker we are about to install?
#
# run-append.sh calls this before it moves anything, and keeps the stock server
# if it fails. It exists because reasoning about compatibility was not enough:
# a build that ran on python 3.8 everywhere else died here on
#
#     ModuleNotFoundError: No module named '_sqlite3'
#
# because FlashForge built their interpreter without it. Installed blind, that
# leaves a printer with no web UI and nothing pointing at the cause.
#
# WHY IT IMPORTS WHAT IT IMPORTS. An earlier version of this check listed four
# modules by hand and missed `authorization`, which is the one that fails when
# libsodium is not on the library path. So the list is not written down here at
# all -- it comes from Moonraker's OWN CORE_COMPONENTS, plus every section in
# the printer's moonraker.conf. That stays correct when the pin moves and when
# the user adds a component we never thought about.
#
#     usage: moonraker-preflight.py <dir containing the moonraker package>
#
# Exit 0 = safe to install. Exit 1 = do not touch the working server.
import importlib
import os
import re
import sys


def main() -> int:
    if len(sys.argv) < 2:
        print("usage: moonraker-preflight.py <parent-dir-of-moonraker-package>")
        return 1
    sys.path.insert(0, sys.argv[1])
    conf = sys.argv[2] if len(sys.argv) > 2 else "/usr/data/config/moonraker.conf"

    # Importing the server module first is itself a check, and it is where the
    # component list comes from.
    try:
        import moonraker.server as srv
    except Exception as exc:
        print("moonraker.server does not import: %r" % (exc,))
        return 1

    names = list(getattr(srv, "CORE_COMPONENTS", []))
    # Whatever the user has configured gets loaded too, so it gets checked too.
    # A section that is not a component (e.g. [server]) is skipped below.
    try:
        with open(conf) as fp:
            for line in fp:
                m = re.match(r"\s*\[\s*([A-Za-z0-9_]+)", line)
                if m:
                    names.append(m.group(1))
    except OSError:
        pass

    failures = []
    for name in dict.fromkeys(names):          # de-duplicate, keep order
        target = "moonraker.components." + name
        try:
            importlib.import_module(target)
        except ModuleNotFoundError as exc:
            # The component itself not existing is fine -- that is a config
            # section like [server], or one this Moonraker does not have. A
            # missing DEPENDENCY of a component that does exist is not fine,
            # and that is the whole point of this script.
            if getattr(exc, "name", None) == target:
                continue
            failures.append((name, repr(exc)))
        except Exception as exc:
            # libnacl raises OSError, not ImportError, when libsodium is
            # missing. Anything that stops a component loading counts.
            failures.append((name, repr(exc)))

    if failures:
        print("%d component(s) will not load on this printer:" % len(failures))
        for name, err in failures:
            print("  %s: %s" % (name, err))
        return 1
    print("preflight ok: %d components import" % len(dict.fromkeys(names)))
    return 0


if __name__ == "__main__":
    sys.exit(main())
