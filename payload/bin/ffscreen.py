# A few lines of text on /dev/fb0, for the moments when nothing else owns the
# screen and the printer would otherwise look dead.
#
# WHY THIS EXISTS. The first boot after a flash runs ff-startup.py
# before HelixScreen, and that can take a couple of minutes: it waits for
# klipper to find its MCUs (which on this machine routinely needs a restart or
# two), then makes a SAVE_CONFIG that restarts klippy again. All of it happens
# with the UI not yet started, so the panel sits black. A black panel during
# the longest wait of the install is the worst possible moment to say nothing
# -- it reads as a brick, and the fix people reach for is a power cut, which
# is the one thing that can actually leave the config half-written.
#
# So: no toolkit, no fonts on disk, no dependencies. The panel is a plain
# framebuffer -- the stock installer draws its own splash with
# `cat start.img > /dev/fb0` -- and the geometry comes from sysfs at runtime
# rather than being hardcoded, because the two models do not have to agree on
# it and a wrong guess would scribble diagonally across the screen.
#
# EVERY failure here is swallowed and turns the screen off, never into an
# error: this is decoration on top of a migration that must finish regardless.
# A printer that cannot draw still gets its calibration.
#
# THE PANEL IS MOUNTED SIDEWAYS. This machine's framebuffer is 480x800 at
# 32bpp -- PORTRAIT -- while the screen you look at is landscape 800x480. The
# display is the buffer rotated 90 degrees clockwise. Established from
# FlashForge's own boot splash: /usr/prog/start.img is 1536000 bytes, which
# the stock installer writes with `cat start.img > /dev/fb0`, and it only
# decodes into a picture at 480x800x4 -- read as landscape it comes out as
# five sheared copies. Decoded correctly it is their "Upgrading, please
# wait..." screen, and it is upright only after a 90-degree clockwise turn.
#
# So everything below draws in LANDSCAPE coordinates -- self.width x
# self.height is what the eye sees -- and _rect turns each rectangle into
# buffer coordinates on the way out. A 90-degree rotation maps an
# axis-aligned rectangle to an axis-aligned rectangle, so this costs a few
# lines of arithmetic per rectangle and nothing per pixel. Rotating a
# finished frame instead would mean a per-pixel Python loop over 384000
# pixels every repaint, on a 1GHz MIPS core.
#
# A portrait framebuffer is taken to mean a rotated panel, which is true for
# this machine and is what makes the default work with no configuration.
# rotate=0 forces the raw orientation.
#
# GEOMETRY CAN ALSO BE GIVEN. sysfs is the right source on the machine, but it
# is not always the truth elsewhere: the printer replica mounts the HOST's
# /sys read-only and makes /dev/fb0 a plain file, so probing there would
# describe the developer's monitor rather than the panel. An explicit
# (width, height, bpp) skips the probe entirely -- that is what the replica
# case passes, and what a printer whose driver exposes no sysfs would use.
import os

# 5x7 glyphs, one byte per column, bit 0 = top row. Only the characters the
# boot messages actually use -- anything else prints as a blank, which is a
# perfectly good failure mode for a screen nobody types into.
FONT = {
    ' ': (0x00, 0x00, 0x00, 0x00, 0x00),
    '!': (0x00, 0x00, 0x5F, 0x00, 0x00),
    '-': (0x08, 0x08, 0x08, 0x08, 0x08),
    '.': (0x00, 0x60, 0x60, 0x00, 0x00),
    '/': (0x20, 0x10, 0x08, 0x04, 0x02),
    ':': (0x00, 0x36, 0x36, 0x00, 0x00),
    '0': (0x3E, 0x51, 0x49, 0x45, 0x3E),
    '1': (0x00, 0x42, 0x7F, 0x40, 0x00),
    '2': (0x42, 0x61, 0x51, 0x49, 0x46),
    '3': (0x21, 0x41, 0x45, 0x4B, 0x31),
    '4': (0x18, 0x14, 0x12, 0x7F, 0x10),
    '5': (0x27, 0x45, 0x45, 0x45, 0x39),
    '6': (0x3C, 0x4A, 0x49, 0x49, 0x30),
    '7': (0x01, 0x71, 0x09, 0x05, 0x03),
    '8': (0x36, 0x49, 0x49, 0x49, 0x36),
    '9': (0x06, 0x49, 0x49, 0x29, 0x1E),
    'A': (0x7E, 0x11, 0x11, 0x11, 0x7E),
    'B': (0x7F, 0x49, 0x49, 0x49, 0x36),
    'C': (0x3E, 0x41, 0x41, 0x41, 0x22),
    'D': (0x7F, 0x41, 0x41, 0x22, 0x1C),
    'E': (0x7F, 0x49, 0x49, 0x49, 0x41),
    'F': (0x7F, 0x09, 0x09, 0x01, 0x01),
    'G': (0x3E, 0x41, 0x41, 0x51, 0x32),
    'H': (0x7F, 0x08, 0x08, 0x08, 0x7F),
    'I': (0x00, 0x41, 0x7F, 0x41, 0x00),
    'J': (0x20, 0x40, 0x41, 0x3F, 0x01),
    'K': (0x7F, 0x08, 0x14, 0x22, 0x41),
    'L': (0x7F, 0x40, 0x40, 0x40, 0x40),
    'M': (0x7F, 0x02, 0x04, 0x02, 0x7F),
    'N': (0x7F, 0x04, 0x08, 0x10, 0x7F),
    'O': (0x3E, 0x41, 0x41, 0x41, 0x3E),
    'P': (0x7F, 0x09, 0x09, 0x09, 0x06),
    'Q': (0x3E, 0x41, 0x51, 0x21, 0x5E),
    'R': (0x7F, 0x09, 0x19, 0x29, 0x46),
    'S': (0x46, 0x49, 0x49, 0x49, 0x31),
    'T': (0x01, 0x01, 0x7F, 0x01, 0x01),
    'U': (0x3F, 0x40, 0x40, 0x40, 0x3F),
    'V': (0x1F, 0x20, 0x40, 0x20, 0x1F),
    'W': (0x7F, 0x20, 0x18, 0x20, 0x7F),
    'X': (0x63, 0x14, 0x08, 0x14, 0x63),
    'Y': (0x03, 0x04, 0x78, 0x04, 0x03),
    'Z': (0x61, 0x51, 0x49, 0x45, 0x43),
    # Punctuation the failure lines need: klipper names carry underscores,
    # paths carry slashes and dots, and a reason often wants a bracket.
    '_': (0x40, 0x40, 0x40, 0x40, 0x40),
    ',': (0x00, 0x50, 0x30, 0x00, 0x00),
    ';': (0x00, 0x56, 0x36, 0x00, 0x00),
    '(': (0x00, 0x1C, 0x22, 0x41, 0x00),
    ')': (0x00, 0x41, 0x22, 0x1C, 0x00),
    "'": (0x00, 0x00, 0x07, 0x00, 0x00),
    '?': (0x02, 0x01, 0x51, 0x09, 0x06),
    '+': (0x08, 0x08, 0x3E, 0x08, 0x08),
    '=': (0x14, 0x14, 0x14, 0x14, 0x14),
    '<': (0x00, 0x08, 0x14, 0x22, 0x41),
    '>': (0x00, 0x41, 0x22, 0x14, 0x08),
    '%': (0x23, 0x13, 0x08, 0x64, 0x62),
    '#': (0x14, 0x7F, 0x14, 0x7F, 0x14),
    '*': (0x14, 0x08, 0x3E, 0x08, 0x14),
}

GLYPH_W = 5
GLYPH_H = 7
SYSFS = '/sys/class/graphics/fb0'

BACKGROUND = (0x11, 0x14, 0x1A)
TITLE = (0xFF, 0xFF, 0xFF)
STATUS = (0x9F, 0xB4, 0xC8)
DETAIL = (0x74, 0x86, 0x99)
FAULT = (0xE2, 0x6D, 0x5A)
NOTE = (0xE0, 0xA0, 0x40)
BAR_BG = (0x23, 0x2A, 0x33)
BAR_FG = (0x3D, 0xA5, 0xF4)


def _read(path):
    with open(path) as fh:
        return fh.read().strip()


class Screen:
    """A framebuffer we can paint a handful of centred lines onto.

    Construct it and check .ok -- a false one means every method below is a
    no-op, which is exactly what the caller wants when there is no panel, no
    permission, or an unfamiliar pixel format."""

    def __init__(self, device='/dev/fb0', sysfs=SYSFS, geometry=None,
                 rotate=None):
        self.device = device
        self.ok = False
        # buf_* is the framebuffer as the kernel has it; width/height are the
        # landscape surface everything above _rect draws on. They differ
        # whenever the panel is mounted rotated, which here it is.
        self.buf_w = self.buf_h = self.bpp = self.stride = 0
        self.width = self.height = 0
        self.rotate = 0
        self._last = None
        if geometry is not None:
            self.buf_w, self.buf_h, self.bpp = geometry
            self.stride = 0
        else:
            try:
                width_text, height_text = _read(
                    os.path.join(sysfs, 'virtual_size')).split(',')
                self.buf_w, self.buf_h = int(width_text), int(height_text)
                self.bpp = int(_read(os.path.join(sysfs, 'bits_per_pixel')))
            except Exception:
                return
            # stride is not on every kernel; the packed width is the right
            # guess when it is missing, and the only one we could make anyway.
            try:
                self.stride = int(_read(os.path.join(sysfs, 'stride')))
            except Exception:
                self.stride = 0
        if self.stride <= 0:
            self.stride = self.buf_w * (self.bpp // 8)
        if self.bpp not in (16, 32) or self.buf_w <= 0 or self.buf_h <= 0:
            return
        if rotate is None:
            # Taller than wide means the panel is turned; see the header.
            rotate = 90 if self.buf_h > self.buf_w else 0
        if rotate not in (0, 90, 270):
            return
        self.rotate = rotate
        if rotate:
            self.width, self.height = self.buf_h, self.buf_w
        else:
            self.width, self.height = self.buf_w, self.buf_h
        if not os.path.exists(self.device):
            return
        self.ok = True


    # -- pixels ------------------------------------------------------------

    def _pixel(self, rgb):
        r, g, b = rgb
        if self.bpp == 32:
            # The usual Linux packing: B, G, R, then an ignored byte.
            return bytes((b, g, r, 0xFF))
        packed = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        return bytes((packed & 0xFF, packed >> 8))

    def _blank(self):
        row = self._pixel(BACKGROUND) * self.buf_w
        pad = b'\x00' * (self.stride - len(row))
        return bytearray((row + pad) * self.buf_h)

    def _rect(self, buf, x, y, w, h, rgb):
        """Fill a rectangle given in LANDSCAPE coordinates.

        Clipping happens in those coordinates, then the surviving rectangle
        is turned into buffer coordinates -- which stays a rectangle, because
        the rotation is a right angle."""
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.width, x + w), min(self.height, y + h)
        if x1 <= x0 or y1 <= y0:
            return
        w, h = x1 - x0, y1 - y0
        if self.rotate == 90:
            # display(x, y) lives at buffer(y, buf_h - 1 - x)
            dest_x, dest_y, dest_w, dest_h = y0, self.buf_h - x0 - w, h, w
        elif self.rotate == 270:
            dest_x, dest_y, dest_w, dest_h = self.buf_w - y0 - h, x0, h, w
        else:
            dest_x, dest_y, dest_w, dest_h = x0, y0, w, h

        pixel = self._pixel(rgb)
        row_bytes = pixel * dest_w
        bytes_per_pixel = self.bpp // 8
        for row in range(dest_y, dest_y + dest_h):
            offset = row * self.stride + dest_x * bytes_per_pixel
            buf[offset:offset + len(row_bytes)] = row_bytes

    def _text(self, buf, x, y, text, scale, rgb):
        for char in text.upper():
            glyph = FONT.get(char)
            if glyph:
                for col in range(GLYPH_W):
                    bits = glyph[col]
                    for row in range(GLYPH_H):
                        if bits & (1 << row):
                            self._rect(buf, x + col * scale, y + row * scale,
                                       scale, scale, rgb)
            x += (GLYPH_W + 1) * scale

    def _width_of(self, text, scale):
        return max(0, len(text) * (GLYPH_W + 1) * scale - scale)

    def _center(self, buf, text, y, scale, rgb):
        self._text(buf, (self.width - self._width_of(text, scale)) // 2,
                   y, text, scale, rgb)

    def _fit(self, text, wanted, margin=40):
        """Largest scale at which the line still fits across the panel."""
        room = max(1, self.width - 2 * margin)
        scale = wanted
        while scale > 1 and self._width_of(text, scale) > room:
            scale -= 1
        return scale

    def _wrap(self, text, scale, max_lines=2, margin=40):
        """Break a reason across at most max_lines, on spaces.

        A failure line is written by the program, not by a person, so it can
        be long -- and a line that runs off the panel would hide the very
        word that says what went wrong. What does not fit is dropped with an
        ellipsis rather than silently clipped by _rect."""
        room = max(1, self.width - 2 * margin)
        lines, current = [], ''
        for word in text.split():
            trial = (current + ' ' + word).strip()
            if current and self._width_of(trial, scale) > room:
                lines.append(current)
                current = word
                if len(lines) == max_lines:
                    break
            else:
                current = trial
        if len(lines) < max_lines and current:
            lines.append(current)
        # Anything still too wide on its own (one very long word) gets cut.
        clipped = []
        for line in lines:
            while len(line) > 1 and self._width_of(line, scale) > room:
                line = line[:-1]
            clipped.append(line)
        return clipped

    # -- what callers use --------------------------------------------------

    def show(self, title, status='', note='', progress=None, detail='',
             fault=False):
        """Paint one frame. Repeating a frame identical to the last one costs
        nothing, so callers may call this as often as they like.

        detail is the line under the status: what actually went wrong, for
        the frames where something did. fault colours it as a fault and
        gives it room -- a failure is the one frame someone stands and reads,
        so it should not look like the running ones."""
        if not self.ok:
            return
        frame = (title, status, note, detail, fault,
                 None if progress is None else round(progress, 2))
        if frame == self._last:
            return
        try:
            buf = self._blank()
            # Scales come from the panel width so the same layout works on
            # whatever the two models turn out to have. The title wants about
            # two thirds of the width; the status line is deliberately much
            # smaller, because it changes and the title does not.
            title_scale = self._fit(title, max(2, self.width // 180))
            status_scale = max(2, (title_scale * 4) // 9)
            note_scale = max(1, status_scale)

            # One centred column: title, status, detail, bar, note. The gaps
            # are in units of text height so they stay proportional when
            # scaled. A frame with no bar and no note is all text, so it
            # starts lower and sits nearer the middle of the panel.
            if progress is not None or note:
                title_y = int(self.height * 0.30)
            elif fault:
                title_y = int(self.height * 0.40)
            else:
                title_y = int(self.height * 0.36)
            self._center(buf, title, title_y, title_scale, TITLE)
            y = title_y + GLYPH_H * title_scale
            if status:
                y += GLYPH_H * status_scale
                self._center(buf, status, y, status_scale, STATUS)
                y += GLYPH_H * status_scale
            if detail:
                # Dimmer than the status, and only smaller if it has to be:
                # this is the line someone reads to find out what went wrong,
                # so it keeps the status size whenever it still fits in two.
                detail_scale = status_scale
                if len(self._wrap(detail, detail_scale, 3)) > 2:
                    detail_scale = max(1, status_scale - 1)
                # A fault gets a clear gap under the status line rather than
                # reading as its continuation.
                y += GLYPH_H * detail_scale * (2 if fault else 1)
                colour = FAULT if fault else DETAIL
                for line in self._wrap(detail, detail_scale):
                    self._center(buf, line, y, detail_scale, colour)
                    y += GLYPH_H * detail_scale + 2 * detail_scale
            if progress is not None:
                bar_width = int(self.width * 0.56)
                bar_height = max(4, self.height // 100)
                bar_x = (self.width - bar_width) // 2
                bar_y = int(self.height * 0.58)
                self._rect(buf, bar_x, bar_y, bar_width, bar_height, BAR_BG)
                filled = int(bar_width * min(1.0, max(0.0, progress)))
                self._rect(buf, bar_x, bar_y, filled, bar_height, BAR_FG)
            if note:
                self._center(buf, note, int(self.height * 0.78),
                             note_scale, NOTE)
            with open(self.device, 'wb') as fh:
                fh.write(buf)
            self._last = frame
        except Exception:
            # A panel that stops accepting writes must not take the migration
            # down with it. Stop trying and stay quiet.
            self.ok = False

    def clear(self):
        """Leave the panel black, so whatever starts next owns a clean one."""
        if not self.ok:
            return
        try:
            with open(self.device, 'wb') as fh:
                fh.write(bytearray(self.stride * self.buf_h))
        except Exception:
            pass
        self._last = None


def main(argv):
    """Draw one frame from the command line.

    The firmwareExe wrapper uses this to put something on the panel the
    moment it gets control. Without it the screen is black from power-on
    until HelixScreen paints -- on EVERY boot, not just the first, because
    the migration exits at its stamp and draws nothing.
    """
    import argparse
    parser = argparse.ArgumentParser(description='draw one frame on /dev/fb0')
    parser.add_argument('--fb', default='/dev/fb0')
    parser.add_argument('--size', default='480x800@32',
                        help='WxH@BPP; default: 480x800@32')
    parser.add_argument('--rotate', type=int, default=None,
                        choices=[0, 90, 270])
    parser.add_argument('--title', default='')
    parser.add_argument('--status', default='')
    parser.add_argument('--detail', default='')
    parser.add_argument('--note', default='')
    parser.add_argument('--progress', type=float, default=None)
    parser.add_argument('--fault', action='store_true')
    parser.add_argument('--clear', action='store_true')
    args = parser.parse_args(argv)
    try:
        screen = Screen(args.fb, geometry=parse_geometry(args.size),
                        rotate=args.rotate)
        if not screen.ok:
            return 0        # no panel is not an error; see the header
        if args.clear:
            screen.clear()
        else:
            screen.show(args.title, args.status, args.note, args.progress,
                        args.detail, args.fault)
    except Exception:
        return 0            # nor is a panel that misbehaves
    return 0


def parse_geometry(text):
    """'1024x600@32' -> (1024, 600, 32). Returns None for anything else, so a
    typo in a config file disables the screen instead of drawing garbage."""
    if not text:
        return None
    try:
        size, _, bpp = text.partition('@')
        width, _, height = size.lower().partition('x')
        return int(width), int(height), int(bpp or 32)
    except ValueError:
        return None


if __name__ == '__main__':
    import sys
    sys.exit(main(sys.argv[1:]))
