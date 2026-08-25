"""ff-mcu-bringup.py's progress callback, and the ports it owns.

The handshake itself is covered by the replica gate (make test-mcu), which
runs it against the printer's own python. What is tested here is the small
thing bolted onto it: while it works, it says which ports are still
outstanding, so bin/ff-startup.py can put THE HEATER BOARD on the panel
instead of a bar that has not moved in a minute.

It is a callback rather than a file because ff-startup.py calls bringup()
directly -- it owns when klippy opens the ports, so it owns handing the
boards over first, and there are no two processes left to talk to each other.
"""
import importlib.util
import os

import pytest

ROOT = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))


def _load():
    path = os.path.join(ROOT, "payload", "bin", "ff-mcu-bringup.py")
    spec = importlib.util.spec_from_file_location("ff_mcu_bringup", path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


bringup = _load()


PORTS = ("/dev/ttyS4", "/dev/ttyS5", "/dev/ttyS7")


def test_it_owns_every_board_that_needs_a_handover(tmp_path):
    # ttyS5 is in here because checkEboard no longer runs: start.sh dropped
    # it, so a bring-up that quietly stopped covering ttyS5 would strand the
    # eboard with nothing left to notice.
    assert bringup.DEFAULT_PORTS == PORTS


def test_the_progress_callback_reports_what_is_outstanding(tmp_path):
    # No devices exist here, so every port fails to open and the pass is over
    # immediately -- which is itself the contract: the callback is still told
    # that nothing is outstanding, so a caller never waits forever.
    seen = []
    bringup.bringup(list(PORTS), 0.1, on_progress=seen.append)
    assert seen and seen[-1] == []


def test_no_callback_is_fine(tmp_path):
    bringup.bringup(list(PORTS), 0.1)


def test_the_status_file_is_gone():
    # It existed to carry this across a process boundary that no longer
    # exists. Leaving it would mean two ways to learn the same thing, one of
    # them stale.
    assert not hasattr(bringup, "publish")
    assert not hasattr(bringup, "STATUS_FILE")


def test_what_it_reports_is_what_the_startup_program_names(tmp_path):
    # The two halves checked against each other rather than against a copy of
    # the port list written down twice.
    spec = importlib.util.spec_from_file_location(
        "ff_startup", os.path.join(ROOT, "payload", "bin", "ff-startup.py"))
    startup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(startup)
    for dev in bringup.DEFAULT_PORTS:
        assert startup.board_name(dev).startswith("THE ")
