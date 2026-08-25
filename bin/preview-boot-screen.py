#!/usr/bin/env python3
# Render the first-boot screen to PNGs so you can LOOK at it.
#
# payload/bin/ffscreen.py draws onto a framebuffer, which is a flat array of
# pixels and therefore untestable by reading the code. This wraps it in the
# smallest possible harness -- a file standing in for /dev/fb0 -- and converts
# the result to a PNG with nothing but the standard library, so reviewing a
# layout change does not require a printer, a replica, or Pillow.
#
#     ./bin/preview-boot-screen.py [--out DIR] [--size 480x800@32]
#
# The default size is the real one: this machine's framebuffer is PORTRAIT
# 480x800, and the panel is that buffer turned 90 degrees clockwise. What gets
# written here is therefore rotated back before it becomes a PNG, so the file
# shows what a person standing at the printer would see rather than the
# sideways buffer behind it.
#
# It renders every phase the migration actually goes through, in order, so a
# change that only looks right for one message is visible immediately.
import argparse
import glob
import importlib.util
import os
import struct
import sys
import zlib

ROOT = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))

# Every (status, progress) ff-startup.py can put on the panel, in the
# order it happens. Keep this in step with the panel.say() calls there.
PHASES = [
    ('starting-services', 'STARTING SERVICES', 0.05),
    ('mcu-boards', 'WAKING THE TOOLHEAD BOARDS', 0.05),
    ('mcu-heater', 'WAKING THE HEATER BOARD', 0.08),
    ('mcu-both', 'WAKING THE HEATER BOARD AND THE LEVEL BOARD', 0.08),
    ('waiting', 'WAITING FOR THE PRINTER', 0.22),
    ('importing', 'READING FACTORY CALIBRATION', 0.5),
    ('saving', 'SAVING CALIBRATION', 0.7),
    ('restarting', 'RESTARTING THE PRINTER', 0.85),
    ('complete', 'SETUP COMPLETE', 1.0),
    ('already', 'ALREADY CALIBRATED', 1.0),
]
NO_NOTE = ('complete', 'already')

# Every way the migration can end badly, with the reason it puts on the panel.
# Kept in step with the panel.failed() calls in ff-startup.py.
FAILURES = [
    ('fail-moonraker', 'MOONRAKER IS NOT RESPONDING'),
    ('fail-klipper-error', 'KLIPPER REPORTED AN ERROR'),
    ('fail-board', 'THE HEATER BOARD DID NOT ANSWER'),
    ('fail-nostart', 'KLIPPER COULD NOT BE STARTED'),
    ('fail-klipper-startup', 'KLIPPER DID NOT FINISH STARTING (STARTUP)'),
    ('fail-tools', 'COULD NOT READ THE TOOL SETTINGS'),
    ('fail-config', 'COULD NOT READ THE PRINTER CONFIGURATION'),
    ('fail-pending', 'ANOTHER CONFIGURATION SAVE WAS ALREADY WAITING'),
    ('fail-refused', 'THE PRINTER REFUSED FF_IMPORT_FIRMWARE_CONFIG'),
    ('fail-empty', 'NO CALIBRATION FOUND IN THE FACTORY DATA'),
    ('fail-restart', 'KLIPPER DID NOT RESTART AFTER SAVING'),
    ('fail-unsaved', 'THE CALIBRATION DID NOT SAVE'),
]
RETRY = 'SETUP WILL RETRY ON NEXT START'
LOGFILE = '/USR/DATA/LOGS/ANVIL-BOOT.LOG'


def load_ffscreen():
    path = os.path.join(ROOT, 'payload', 'bin', 'ffscreen.py')
    spec = importlib.util.spec_from_file_location('ffscreen', path)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def png(path, width, height, rgb_rows):
    def chunk(tag, data):
        body = tag + data
        return (struct.pack('>I', len(data)) + body
                + struct.pack('>I', zlib.crc32(body)))

    # One filter byte (0 = none) per scanline, then the raw RGB triples.
    raw = b''.join(b'\x00' + row for row in rgb_rows)
    with open(path, 'wb') as fh:
        fh.write(b'\x89PNG\r\n\x1a\n')
        fh.write(chunk(b'IHDR', struct.pack('>IIBBBBB', width, height,
                                            8, 2, 0, 0, 0)))
        fh.write(chunk(b'IDAT', zlib.compress(raw, 6)))
        fh.write(chunk(b'IEND', b''))


def to_rows(buf, screen):
    """Framebuffer bytes -> one RGB triple per pixel, per row, AS DISPLAYED.

    The buffer is read in its own orientation and then turned by whatever
    the panel turns it by, so the PNG matches the screen and not the memory.
    """
    step = screen.bpp // 8

    def pixel(bx, by):
        off = by * screen.stride + bx * step
        px = buf[off:off + step]
        if step == 4:
            return bytes((px[2], px[1], px[0]))         # B,G,R,X on the wire
        v = px[0] | (px[1] << 8)                        # RGB565
        return bytes((((v >> 11) & 0x1F) << 3,
                      ((v >> 5) & 0x3F) << 2,
                      (v & 0x1F) << 3))

    # The inverse of the mapping in ffscreen._rect.
    rows = []
    for y in range(screen.height):
        row = bytearray()
        for x in range(screen.width):
            if screen.rotate == 90:
                row += pixel(y, screen.buf_h - 1 - x)
            elif screen.rotate == 270:
                row += pixel(screen.buf_w - 1 - y, x)
            else:
                row += pixel(x, y)
        rows.append(bytes(row))
    return rows


def main(argv):
    ap = argparse.ArgumentParser(description='render the first-boot screen')
    ap.add_argument('--out', default=os.path.join(ROOT, 'work', 'boot-screen'))
    ap.add_argument('--size', default='480x800@32',
                    help='the FRAMEBUFFER, not the panel (default: the real one)')
    ap.add_argument('--rotate', type=int, default=None, choices=[0, 90, 270])
    args = ap.parse_args(argv)

    ffscreen = load_ffscreen()
    geometry = ffscreen.parse_geometry(args.size)
    if geometry is None:
        raise SystemExit('--size wants WxH@BPP, e.g. 1024x600@32')
    # Clear first: a renamed or removed phase would otherwise leave its old
    # frame lying in the directory, and a stale frame in a gallery of current
    # ones is worse than a missing one.
    os.makedirs(args.out, exist_ok=True)
    for stale in glob.glob(os.path.join(args.out, '*.png')):
        os.remove(stale)

    frames = [(n, s, p, '') for n, s, p in PHASES]
    frames += [(n, RETRY, None, '%s. DETAILS IN %s' % (r, LOGFILE))
               for n, r in FAILURES]

    fb = os.path.join(args.out, 'fb0.raw')
    for name, status, progress, detail in frames:
        open(fb, 'wb').close()
        screen = ffscreen.Screen(fb, geometry=geometry, rotate=args.rotate)
        if not screen.ok:
            raise SystemExit('ffscreen refused this geometry: %s' % args.size)
        note = '' if (name in NO_NOTE or detail) else 'DO NOT TURN THE PRINTER OFF'
        screen.show('SETTING UP YOUR PRINTER', status, note, progress,
                    detail, bool(detail))
        with open(fb, 'rb') as fh:
            buf = fh.read()
        out = os.path.join(args.out, '%s.png' % name)
        png(out, screen.width, screen.height, to_rows(buf, screen))
        print('%-30s %s  (%dx%d panel, %dx%d buffer)'
              % (status, out, screen.width, screen.height,
                 screen.buf_w, screen.buf_h))
    os.remove(fb)
    return 0


if __name__ == '__main__':
    sys.exit(main(sys.argv[1:]))
