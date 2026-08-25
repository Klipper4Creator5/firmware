#!/usr/bin/env python3
"""Hand the toolhead boards over from their bootloader to their application.

Three of the four boards Klipper talks to answer only after a handshake: the
board's bootloader sends "Ready", the host replies 'A', the board acks and
jumps to its application. On stock firmware, firmwareExe carried that routine
three times over -- bootSerialHeatMcu, bootSerialMainEboardMcu and
bootSerialLevelBoardMcu, byte-identical apart from a hard-coded device path.

Replacing firmwareExe took all three away, and /usr/prog/klipper/start.sh
covered only two of the four boards:

    /dev/ttyS2  mcu           cmd_mcu bootup, in start.sh      still stock
    /dev/ttyS5  eboard        checkEboard                      NOW HERE
    /dev/ttyS4  eheaterboard  NOBODY   <- klippy cannot connect
    /dev/ttyS7  levelboard    NOBODY

so this covers the two that were left out, and since it does the job better
than checkEboard did, the eboard as well. It has to run before klippy opens
the ports.

WHY checkEboard IS GONE. It is 9KB containing one function --
_Z23bootSerialMainEboardMcuv, an older -O2 build of the same routine, hard
wired to /dev/ttyS5 -- and its only imports are the tty calls and printf. It
flashes nothing and touches no other device, so nothing is lost by dropping
it. What is gained is the ttyS5 half of the ready phase: stock sets isReady on
ANY byte from that port, so checkEboard cheerfully sends 'A' at an eboard that
is already running Klipper and merely returning garbage at the wrong baud.
Here only a banner earns a write. Doing all three ports in one pass is also
strictly better than doing ttyS5 afterwards, for the reason in the first
bullet below: a port nobody holds open is shut down in the driver, so the
banners it sends while another port is being polled are lost.

Doing nothing is always a valid outcome: a board that already started its
application never sends the banner, and then we must not write to its port at
all -- it is speaking the Klipper protocol by that point. 'A' is therefore
only ever sent inside the branch that matched "Ready".

Three things the first version got wrong, all of them seen on a real printer:

  * It polled one port at a time. A serial port that nobody has open is shut
    down in the driver, so while ttyS4 was being polled every banner ttyS7
    sent was dropped on the floor -- which is why the two ports took turns
    reporting a banner across consecutive runs. Every port is opened up
    front now and they are polled together.

  * It bounded the wait by a read count, not by time. VTIME=1 makes a read
    return after 0.1s only when the board says nothing; a board that is
    saying anything at all returns reads instantly, so 50 reads could elapse
    in milliseconds and still be reported as a full wait.

  * "No banner" was reported as "already running". It is not the same thing:
    ttyS4 was declared already-running on one pass and then sent a bootloader
    banner on the next. The banner repeats on a period longer than the old 5s
    window, so a board can be sitting in its bootloader and simply be between
    banners. That verdict is reported now as what it is -- unknown.

The ack byte is logged but no longer required to be 0x06. That is not a
guess -- the three bootSerial* routines were disassembled out of the 1.9.7
firmwareExe, and stock sends 'A' fifty times and ignores everything the
board sends back except as a reason to stop early. See handshake() for the
decompiled loop. The level board answers 0x01 every time while the heat
board answers 0x06, and refusing the handshake over that byte is what left
the level board in its bootloader with klippy timing out on
identify_response.

What actually tells us whether a board left the bootloader is whether it
goes on repeating the banner, so that is what is checked: after 'A' is sent,
a board that stays quiet for QUIET_S has moved on, and one that banners
again gets another round of 'A'. Stock never checks that at all -- it
returns success on the strength of the ready phase alone.
"""

import os
import sys
import termios
import time

BANNER = b"Ready"
GOOD_ACK = 0x06
GO = b"A"
# Total wall-clock budget for the whole pass, all ports together. It has to
# span more than one banner period -- 5s did not.
DEADLINE_S = 24.0
# How long a board must stay quiet after a non-0x06 ack before we believe it
# really jumped to its application. This MUST be longer than the bootloader's
# banner period, or a board still sitting in its bootloader looks quiet just
# by being between banners -- the exact mistake the old version made. The
# period is known only to be longer than 5s (the old window missed it), so
# this is set well clear of that. Only the odd-ack path pays it: a 0x06 ack
# is conclusive on its own and returns immediately.
QUIET_S = 9.0
# How many times to resend 'A' before falling back to the quiet check.
# 50 is what firmwareExe does, exactly (slti $v0, $v0, 0x32).
ACK_TRIES = 50
DEFAULT_PORTS = ("/dev/ttyS4", "/dev/ttyS5", "/dev/ttyS7")

# Where the progress of this pass is published, for anything that wants to
# tell a person what the printer is doing. bin/ff-startup.py reads it to put
# "WAITING FOR THE HEATER BOARD" on the panel instead of leaving them looking
# at a bar that has not moved in a minute. It lives in /tmp on purpose: that
# is a tmpfs, so it cannot survive a reboot and be mistaken for this boot's.
STATUS_FILE = "/tmp/ff-mcu-bringup.status"


def configure(fd):
    """Raw 115200, VMIN=0/VTIME=1 -- the same line settings firmwareExe uses.

    VMIN=0 with VTIME=1 is what makes every read return after 0.1s whether or
    not the board said anything, which is what paces the poll below.
    """
    iflag, oflag, cflag, lflag, _ispeed, _ospeed, cc = termios.tcgetattr(fd)

    iflag &= ~(termios.IGNBRK | termios.BRKINT | termios.PARMRK
               | termios.ISTRIP | termios.INLCR | termios.IGNCR
               | termios.ICRNL | termios.IXON | termios.IXOFF | termios.IXANY)
    oflag &= ~termios.OPOST
    lflag &= ~(termios.ECHO | termios.ECHONL | termios.ICANON
               | termios.ISIG | termios.IEXTEN)
    cflag &= ~(termios.CSIZE | termios.PARENB | termios.CSTOPB)
    cflag |= termios.CS8 | termios.CLOCAL | termios.CREAD
    cflag &= ~getattr(termios, "CRTSCTS", 0)
    # HUPCL would drop DTR when we close the port, resetting the board we
    # just started.
    cflag &= ~termios.HUPCL

    cc = list(cc)
    cc[termios.VMIN] = 0
    cc[termios.VTIME] = 1

    termios.tcsetattr(fd, termios.TCSANOW,
                      [iflag, oflag, cflag, lflag,
                       termios.B115200, termios.B115200, cc])


class Port(object):
    """One serial port, held open for the whole pass."""

    def __init__(self, dev):
        self.dev = dev
        self.fd = None
        self.done = False          # no more work to do on this port
        self.verdict = None        # what to print at the end
        self.ok = True             # counts towards the exit status
        self.banners = 0
        self.gos = 0               # how many 'A' have gone out
        self.acks = []
        self.bytes_seen = 0
        self.last_go = None        # when 'A' was last sent
        # The banner can straddle two reads, so a few trailing bytes of the
        # previous read are carried over.
        self.tail = b""

    def open(self):
        try:
            self.fd = os.open(self.dev, os.O_RDWR | os.O_NOCTTY)
        except OSError as e:
            self.fail("%s" % e.strerror)
            return False
        try:
            configure(self.fd)
        except termios.error as e:
            self.fail("cannot configure: %s" % e)
            return False
        return True

    def fail(self, msg):
        self.done = True
        self.ok = False
        self.verdict = msg
        self.close()

    def close(self):
        if self.fd is not None:
            os.close(self.fd)
            self.fd = None

    def read(self, size=64):
        try:
            return os.read(self.fd, size)
        except OSError as e:
            self.fail("read failed: %s" % e.strerror)
            return None

    def poll(self, now):
        """One 0.1s slice of attention."""
        data = self.read()
        if data is None:
            return
        if data:
            self.bytes_seen += len(data)
        buf = self.tail + data
        self.tail = buf[-(len(BANNER) - 1):] if len(BANNER) > 1 else b""

        # Deliberately stricter than stock. firmwareExe only requires a
        # literal "Ready" on the heat board; on ttyS5 and ttyS7 its ready
        # flag is set by *any* byte arriving, banner or not, and it sends 'A'
        # on the strength of that. We will not: a board that is already
        # running is speaking the Klipper protocol, and 'A' has no business
        # on that wire. The banner is the only thing that earns a write.
        if BANNER in buf:
            self.banners += 1
            self.handshake(now)
            return

        # Quiet since 'A' went out: the board took it and moved on.
        if self.last_go is not None and now - self.last_go >= QUIET_S:
            ack = self.acks[-1] if self.acks else None
            if ack is not None:
                self.verdict = ("started its application (ack 0x%02x, not "
                                "0x%02x -- but the banner stopped after %d "
                                "'A', so it did leave the bootloader)"
                                % (ack, GOOD_ACK, self.gos))
            else:
                self.verdict = ("no ack to %d 'A', but the banner stopped "
                                "-- assuming it left the bootloader"
                                % self.gos)
            self.done = True

    def handshake(self, now):
        """Banner seen: send 'A' up to 50 times, exactly as stock does.

        This loop is not guesswork; it is what _Z23bootSerialLevelBoardMcuv
        in firmwareExe compiles to, disassembled from the 1.9.7 image:

            send = 'A'
            if (isReady)
                for (j = 0; j < 0x32; j++) {
                    write(fd, &send, 1);
                    read(fd, &recv, 1);
                    printf("Levelboard mcu: send: %c , recv: %d , "
                           "recv count: %d , loop count: %d \\n", ...);
                    if (recv == 6) { isAck = 1; break; }
                }

        Two things fall out of that and both matter here:

          * 'A' goes out fifty times, not once. The board is given fifty
            chances to take it.

          * a reply that is not 0x06 is *ignored*. It only means the loop
            does not stop early. isAck is initialised to 1 before the loop
            and never assigned 0 anywhere in the function, so the ack byte
            cannot fail the handshake at all -- the return value depends
            only on isReady.

        The first version of this script sent 'A' once and treated the level
        board's 0x01 as a failure. Stock would have sent another forty-nine
        and never looked at that byte. That is what left ttyS7 in its
        bootloader with klippy timing out on identify_response.

        (bootSerialHeatMcu and bootSerialMainEboardMcu are the same function
        with a different device path and different printf strings; the only
        logic difference anywhere in the three is in the ready phase, handled
        in Port.poll().)
        """
        self.last_go = now
        for _ in range(ACK_TRIES):
            os.write(self.fd, GO)
            self.gos += 1
            # Each read is one VTIME tick, so this paces itself at ~10 'A'/s
            # and the whole loop is bounded by 50 * 0.1s = 5s.
            ack = self.read(1)
            if ack is None:
                return
            if ack:
                self.acks.append(ack[0])
                if ack[0] == GOOD_ACK:
                    self.verdict = ("started its application (ack 0x%02x "
                                    "after %d 'A', %d banner(s))"
                                    % (ack[0], self.gos, self.banners))
                    self.done = True
                    return
        # Drop anything left over from the banner so the next poll does not
        # re-match it, and start the quiet timer from here.
        self.tail = b""
        self.last_go = time.monotonic()

    def finish(self, waited):
        """Called once the deadline expires with the port still undecided."""
        if self.done:
            return
        if self.last_go is not None:
            ack = self.acks[-1] if self.acks else None
            self.verdict = ("still bannering after %d 'A' (%d banners, last "
                            "ack %s) -- did NOT leave the bootloader"
                            % (self.gos, self.banners,
                               "0x%02x" % ack if ack is not None else "none"))
            self.ok = False
        elif self.bytes_seen:
            self.verdict = ("no banner in %.0fs but the port is talking "
                            "(%d bytes) -- already running"
                            % (waited, self.bytes_seen))
        else:
            self.verdict = ("silent for %.0fs -- no banner and no traffic; "
                            "already running, or not answering at all"
                            % waited)
        self.done = True


def publish(status_file, state, ports):
    """Say what this pass is still working on, one line per port.

    Best effort in every direction: a reader may see a half-written file and
    must cope, and a write that fails must not disturb the bring-up. The
    format is deliberately dumb -- "state" first, then "<dev> <word>" -- so
    the reader needs no parser and no json.
    """
    if not status_file:
        return
    lines = ["state %s" % state]
    for p in ports:
        if not p.done:
            word = "working"
        elif p.ok:
            word = "ok"
        else:
            word = "failed"
        lines.append("%s %s" % (p.dev, word))
    try:
        tmp = status_file + ".new"
        with open(tmp, "w") as fh:
            fh.write("\n".join(lines) + "\n")
        os.rename(tmp, status_file)      # readers never see a partial file
    except OSError:
        pass


def bringup(devs, deadline_s=DEADLINE_S, status_file=STATUS_FILE):
    ports = [Port(d) for d in devs]
    live = [p for p in ports if p.open()]
    publish(status_file, "running", ports)
    try:
        end = time.monotonic() + deadline_s
        waiting = None
        while True:
            pending = [p for p in live if not p.done]
            if not pending or time.monotonic() >= end:
                break
            # Republish only when the set actually shrinks: this loop spins
            # hard, and rewriting the file every pass would be pure noise.
            names = tuple(p.dev for p in pending)
            if names != waiting:
                publish(status_file, "running", ports)
                waiting = names
            for p in pending:
                p.poll(time.monotonic())
        for p in live:
            p.finish(deadline_s)
    finally:
        for p in live:
            p.close()
        publish(status_file, "finished", ports)

    ok = True
    for p in ports:
        print("mcu-bringup: %s %s" % (p.dev, p.verdict))
        if not p.ok:
            ok = False
    return ok


def main(argv):
    args = argv[1:]
    deadline = DEADLINE_S
    if len(args) >= 2 and args[0] == "-t":
        deadline = float(args[1])
        args = args[2:]
    ports = args or list(DEFAULT_PORTS)
    return 0 if bringup(ports, deadline) else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
