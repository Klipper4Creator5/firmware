"""ff-mcu-bringup.py's progress file.

The handshake itself is covered by the replica gate (make test-mcu), which
runs it against the printer's own python. What is tested here is the small
thing bolted onto it: while it works, it publishes which ports are still
outstanding, so bin/ff-startup.py can put THE HEATER BOARD on the panel
instead of a bar that has not moved in a minute.

The contract is mostly about not mattering: a reader must never see a
half-written file, and a write that fails must not disturb a bring-up.
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


class FakePort:
    def __init__(self, dev, done=False, ok=True):
        self.dev = dev
        self.done = done
        self.ok = ok


def read(path):
    with open(path) as fh:
        return fh.read()


def test_it_publishes_what_is_still_outstanding(tmp_path):
    path = str(tmp_path / "status")
    ports = [FakePort("/dev/ttyS4"), FakePort("/dev/ttyS7", done=True)]
    bringup.publish(path, "running", ports)
    assert read(path) == "state running\n/dev/ttyS4 working\n/dev/ttyS7 ok\n"


def test_a_failed_port_says_so(tmp_path):
    path = str(tmp_path / "status")
    bringup.publish(path, "finished",
                    [FakePort("/dev/ttyS7", done=True, ok=False)])
    assert read(path) == "state finished\n/dev/ttyS7 failed\n"


def test_the_file_is_swapped_into_place_not_written_in_place(tmp_path):
    # A reader polls this every second while it is being rewritten. Renaming
    # over the top is what stops it ever seeing half a file.
    path = str(tmp_path / "status")
    bringup.publish(path, "running", [FakePort("/dev/ttyS4")])
    bringup.publish(path, "finished", [FakePort("/dev/ttyS4", done=True)])
    assert read(path).startswith("state finished")
    assert not os.path.exists(path + ".new")


def test_an_unwritable_path_is_swallowed(tmp_path):
    # The bring-up is the job; the progress note is not worth failing over.
    bringup.publish(str(tmp_path / "nodir" / "status"), "running",
                    [FakePort("/dev/ttyS4")])


def test_no_path_means_no_file(tmp_path):
    bringup.publish("", "running", [FakePort("/dev/ttyS4")])
    assert list(tmp_path.iterdir()) == []


def test_what_it_writes_is_what_the_startup_program_reads(tmp_path):
    # The two halves of the contract, checked against each other rather than
    # against a copy of the format written down twice.
    spec = importlib.util.spec_from_file_location(
        "ff_startup", os.path.join(ROOT, "payload", "bin", "ff-startup.py"))
    startup = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(startup)

    path = str(tmp_path / "status")
    bringup.publish(path, "running",
                    [FakePort("/dev/ttyS4"), FakePort("/dev/ttyS7", done=True)])
    assert startup.read_mcu_status(path) == ("running", ["/dev/ttyS4"])

    bringup.publish(path, "finished",
                    [FakePort("/dev/ttyS4", done=True),
                     FakePort("/dev/ttyS7", done=True)])
    assert startup.read_mcu_status(path) == ("finished", [])
    # and every port it can name has a friendly name on the other side
    for dev in bringup.DEFAULT_PORTS:
        assert startup.board_name(dev).startswith("THE ")


def test_the_status_file_lives_on_a_tmpfs(tmp_path):
    # /tmp is cleared on boot. A status file that survived one would describe
    # the previous boot's bring-up, which is worse than having none.
    assert bringup.STATUS_FILE.startswith("/tmp/")
