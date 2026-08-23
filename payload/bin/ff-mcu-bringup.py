#!/usr/bin/env python3
"""Hand the toolhead boards over from their bootloader to their application.

Three of the four boards Klipper talks to answer only after a handshake: the
board's bootloader sends "Ready", the host replies 'A', the board acks 0x06
and jumps to its application. On stock firmware, firmwareExe carries that
routine three times over -- bootSerialHeatMcu, bootSerialMainEboardMcu and
bootSerialLevelBoardMcu, byte-identical apart from a hard-coded device path.

Replacing firmwareExe took all three away, and /usr/prog/klipper/start.sh
covers only two of the four boards:

    /dev/ttyS2  mcu           cmd_mcu bootup, in start.sh      ok
    /dev/ttyS5  eboard        checkEboard, in start.sh         ok
    /dev/ttyS4  eheaterboard  NOBODY   <- klippy cannot connect
    /dev/ttyS7  levelboard    NOBODY

so this covers the two that were left out. It has to run before klippy opens
the ports.

Doing nothing is always a valid outcome: a board that already started its
application never sends the banner, and then we must not write to its port at
all -- it is speaking the Klipper protocol by that point. 'A' is therefore
only ever sent inside the branch that matched "Ready".
"""

import os
import sys
import termios

BANNER = b"Ready"
ACK = 0x06
GO = b"A"
# VTIME is in tenths of a second, so 50 reads is a ~5s ceiling per port.
MAX_READS = 50
DEFAULT_PORTS = ("/dev/ttyS4", "/dev/ttyS7")


def configure(fd):
    """Raw 115200, VMIN=0/VTIME=1 -- the same line settings firmwareExe uses.

    VMIN=0 with VTIME=1 is what makes every read return after 0.1s whether or
    not the board said anything, which is what bounds the loop below.
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


def poke(dev):
    """Returns True if the board was handed over or was already running."""
    try:
        fd = os.open(dev, os.O_RDWR | os.O_NOCTTY)
    except OSError as e:
        print("mcu-bringup: %s: %s" % (dev, e.strerror))
        return False
    try:
        try:
            configure(fd)
        except termios.error as e:
            print("mcu-bringup: %s: cannot configure: %s" % (dev, e))
            return False
        for attempt in range(1, MAX_READS + 1):
            try:
                data = os.read(fd, 64)
            except OSError as e:
                print("mcu-bringup: %s: read failed: %s" % (dev, e.strerror))
                return False
            if BANNER not in data:
                continue
            os.write(fd, GO)
            ack = os.read(fd, 1)
            if ack and ack[0] == ACK:
                print("mcu-bringup: %s started its application "
                      "(ack 0x%02x, %d reads)" % (dev, ack[0], attempt))
                return True
            print("mcu-bringup: %s sent the banner but acked %r"
                  % (dev, ack))
            return False
        print("mcu-bringup: %s sent no banner -- already running" % dev)
        return True
    finally:
        os.close(fd)


def main(argv):
    ports = argv[1:] or list(DEFAULT_PORTS)
    ok = True
    for dev in ports:
        if not poke(dev):
            ok = False
    return 0 if ok else 1


if __name__ == "__main__":
    sys.exit(main(sys.argv))
