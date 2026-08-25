# A few lines of text on /dev/fb0, for the moments when nothing else owns the
# screen and the printer would otherwise look dead.
#
# WHY THIS EXISTS. The first boot after a flash runs ff-firstboot-import.py
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
}

GLYPH_W = 5
GLYPH_H = 7
SYSFS = '/sys/class/graphics/fb0'

BACKGROUND = (0x11, 0x14, 0x1A)
TITLE = (0xFF, 0xFF, 0xFF)
STATUS = (0x9F, 0xB4, 0xC8)
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

    def __init__(self, device='/dev/fb0', sysfs=SYSFS, geometry=None):
        self.device = device
        self.ok = False
        self.width = self.height = self.bpp = self.stride = 0
        self._last = None
        if geometry is not None:
            self.width, self.height, self.bpp = geometry
            self.stride = 0
        else:
            try:
                xres, yres = _read(
                    os.path.join(sysfs, 'virtual_size')).split(',')
                self.width, self.height = int(xres), int(yres)
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
            self.stride = self.width * (self.bpp // 8)
        if self.bpp not in (16, 32) or self.width <= 0 or self.height <= 0:
            return
        if not os.path.exists(self.device):
            return
        self.ok = True


    # -- pixels ------------------------------------------------------------

    def _pixel(self, rgb):
        r, g, b = rgb
        if self.bpp == 32:
            # The usual Linux packing: B, G, R, then an ignored byte.
            return bytes((b, g, r, 0xFF))
        v = ((r & 0xF8) << 8) | ((g & 0xFC) << 3) | (b >> 3)
        return bytes((v & 0xFF, v >> 8))

    def _blank(self):
        row = self._pixel(BACKGROUND) * self.width
        pad = b'\x00' * (self.stride - len(row))
        return bytearray((row + pad) * self.height)

    def _rect(self, buf, x, y, w, h, rgb):
        px = self._pixel(rgb)
        x0, y0 = max(0, x), max(0, y)
        x1, y1 = min(self.width, x + w), min(self.height, y + h)
        if x1 <= x0 or y1 <= y0:
            return
        span = px * (x1 - x0)
        step = self.bpp // 8
        for row in range(y0, y1):
            start = row * self.stride + x0 * step
            buf[start:start + len(span)] = span

    def _text(self, buf, x, y, text, scale, rgb):
        for ch in text.upper():
            glyph = FONT.get(ch)
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

    # -- what callers use --------------------------------------------------

    def show(self, title, status='', note='', progress=None):
        """Paint one frame. Repeating a frame identical to the last one costs
        nothing, so callers may call this as often as they like."""
        if not self.ok:
            return
        frame = (title, status, note,
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

            # One centred column: title, status, bar, note. The gaps are in
            # units of text height so they stay proportional when scaled.
            title_y = int(self.height * 0.30)
            self._center(buf, title, title_y, title_scale, TITLE)
            if status:
                self._center(buf, status,
                             title_y + GLYPH_H * title_scale
                             + GLYPH_H * status_scale, status_scale, STATUS)
            if progress is not None:
                bw = int(self.width * 0.56)
                bh = max(4, self.height // 100)
                bx = (self.width - bw) // 2
                by = int(self.height * 0.58)
                self._rect(buf, bx, by, bw, bh, BAR_BG)
                filled = int(bw * min(1.0, max(0.0, progress)))
                self._rect(buf, bx, by, filled, bh, BAR_FG)
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
                fh.write(bytearray(self.stride * self.height))
        except Exception:
            pass
        self._last = None


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
