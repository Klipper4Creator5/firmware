"""The harness's own self-checks: the probes, against text they will really see.

Printer.ps() and Printer.listening() are parsers, and parsers are where a
harness goes quietly wrong. A `listening()` that never matches makes every
readiness assertion pass by vacuous absence of contradiction; a `ps()` that
drops rows makes "stop left nothing behind" true for the wrong reason. Neither
failure looks like a failure -- they look like a green suite.

So they are exercised here, in the static lane, against captured output rather
than against a running replica. That is deliberate: these are pure functions of
text, they need no docker, and the fixtures below are real samples -- qemu-
prefixed command lines, busybox's /proc/net/tcp with its uppercase hex and its
IPv6 rows -- rather than something shaped to make the parser look good.
"""
import pytest

from lib.replica import Printer, Result, Timeout

pytestmark = pytest.mark.static


class Stub(Printer):
    """A Printer whose only replica is a dict of canned command output.

    Subclassed rather than mocked so the methods under test are the real
    ones -- only sh() is replaced, which is exactly the seam the docker exec
    lives behind.
    """

    def __init__(self, output=""):
        Printer.__init__(self, container="stub", docker="docker", config=None)
        self.output = output
        self.asked = []

    def sh(self, script, timeout=120):
        self.asked.append(script)
        return Result(["stub"], 0, self.output, "")


# --------------------------------------------------------------------- ps()

# Real shapes. Note what makes `ps | grep` unusable here and why /proc is read
# instead: every command line is prefixed by the emulator and its arguments, so
# a grep for "s6-svscan" matches the qemu invocation as readily as the process,
# and busybox ps would have truncated the row long before the interesting part.
PROC_SAMPLE = """\
1\t/bin/sh /tmp/case.sh
2\t
147\t/usr/bin/qemu-mipsel-static /usr/data/anvil/bin/s6-svscan /usr/data/anvil/etc/s6
152\t/usr/bin/qemu-mipsel-static /usr/data/anvil/bin/s6-supervise nginx
160\tsleep 3600
"""


def test_ps_parses_pid_and_argv():
    found = Stub(PROC_SAMPLE).ps()
    assert [p.pid for p in found] == ["1", "147", "152", "160"]


def test_ps_drops_kernel_threads():
    """A kernel thread has an empty cmdline. Keeping it would give every
    process-table assertion a row it can neither name nor kill."""
    assert "2" not in [p.pid for p in Stub(PROC_SAMPLE).ps()]


def test_ps_keeps_the_whole_command_line():
    """Including the qemu prefix. Trimming it here would be a lie about what
    is running, and the tests that match on a path still match."""
    scanner = [p for p in Stub(PROC_SAMPLE).ps() if "svscan" in p.cmdline][0]
    assert scanner.cmdline.startswith("/usr/bin/qemu-mipsel-static")
    assert "/usr/data/anvil/bin/s6-svscan" in scanner.cmdline


def test_pgrep_finds_by_substring():
    assert len(Stub(PROC_SAMPLE).pgrep("s6-")) == 2
    assert Stub(PROC_SAMPLE).pgrep("nginx")[0].pid == "152"


def test_pgrep_does_not_match_itself():
    """The case scripts all carry `grep -v grep` and `grep -v case.sh` because
    a shell pipeline appears in its own output. There is no pipeline here, so
    the guard is unnecessary rather than merely omitted -- but a /tmp/case.sh
    row does exist in the table, and a search for something it does not
    contain must not find it."""
    assert Stub(PROC_SAMPLE).pgrep("s6-svscan")[0].pid == "147"


def test_ps_survives_empty_output():
    assert Stub("").ps() == []


# -------------------------------------------------------------- listening()

# From a real /proc/net/tcp. Ports are uppercase hex: 1F90 is 8080, 1BD5 is
# 7125, 0050 is 80. st 0A is LISTEN; 01 is ESTABLISHED and must not count.
TCP_SAMPLE = """\
  sl  local_address rem_address   st tx_queue rx_queue tr tm->when retrnsmt   uid  timeout inode
   0: 00000000:1F90 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12345 1
   1: 0100007F:1BD5 00000000:0000 0A 00000000:00000000 00:00000000 00000000     0        0 12346 1
   2: 0100007F:0050 0100007F:C1A2 01 00000000:00000000 00:00000000 00000000     0        0 12347 1
"""


@pytest.mark.parametrize("port", [8080, 7125])
def test_listening_finds_a_listening_port(port):
    assert Stub(TCP_SAMPLE).listening(port)


def test_listening_ignores_an_established_connection():
    """Port 80 appears in the table, but as a connection, not a listener. A
    parser that matched the port alone would report nginx up whenever a
    browser had a socket open to something."""
    assert not Stub(TCP_SAMPLE).listening(80)


def test_listening_is_false_for_an_absent_port():
    assert not Stub(TCP_SAMPLE).listening(1234)


def test_listening_survives_empty_output():
    """The failure that matters: if this ever raised or returned True on no
    input, every readiness assertion in the suite would stop meaning anything
    and nothing would go red."""
    assert not Stub("").listening(7125)


def test_listening_reads_both_tcp_tables():
    """A service bound to :: is in /proc/net/tcp6 and nowhere else. The s6 run
    scripts read only tcp, which is correct for them because they know what
    they bound; a general probe that did the same would silently miss it."""
    asked = Stub("")
    asked.listening(7125)
    assert "/proc/net/tcp6" in asked.asked[0]


# ------------------------------------------------------------------- Result

def test_text_is_stdout_and_stderr_together():
    """`cmd 2>&1` is what the case scripts captured, and what nearly every
    assertion here wants: a service's complaint is as much its answer as its
    report."""
    assert Result([], 0, "out\n", "err\n").text == "out\nerr\n"


def test_first_line_skips_blanks():
    assert Result([], 0, "\n\n  nginx: running\nmore\n", "").first_line \
        == "  nginx: running"


def test_first_line_of_nothing_is_empty_not_an_error():
    """A service that printed nothing is a failure the tests report
    themselves. The probe must not raise first and turn a clear assertion
    into an IndexError traceback."""
    assert Result([], 0, "", "").first_line == ""


def test_ok_is_exit_zero():
    assert Result([], 0, "", "").ok
    assert not Result([], 1, "", "").ok


def test_a_plain_result_did_not_time_out():
    """Every Result answers `timed_out`, so no caller needs a hasattr."""
    assert Result([], 0, "", "").timed_out is False


def test_a_timeout_is_a_result_that_says_so():
    """A timeout is a verdict, not an exception: the init sequence must
    return, and 'it did not come back' is the answer the negative control is
    specifically looking for."""
    import subprocess
    expired = subprocess.TimeoutExpired(cmd="x", timeout=15)
    timed = Timeout([], expired, 15)
    assert timed.timed_out
    assert not timed.ok
    assert "did not return within 15s" in timed.text
