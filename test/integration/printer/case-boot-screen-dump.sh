#!/bin/sh
# Render every first-boot screen inside the replica and print each one as a
# base64 PNG on stdout.
#
# This is the answer to "I want to SEE it, not read assertions about it". The
# frames are drawn by /usr/prog/Python-3.8.2/bin/python3 -- FlashForge's own
# 3.8, running MIPS under qemu, against the printer's real rootfs -- so what
# comes out is what the panel would show, not what a developer's interpreter
# thinks it would.
#
# stdout is the only way out: every mount the replica gets is read-only. The
# frames are PNG-compressed in here (zlib is stdlib) rather than shipped raw,
# because a 1024x600x32 frame is 2.4MB and there are several of them.
#
# test/integration/sim-boot-screen.py drives this and writes the PNGs out.
MOD=/usr/data/anvil
PY=/usr/prog/Python-3.8.2/bin/python3
mkdir -p $MOD/bin
cp /tmp/payload/bin/ffscreen.py $MOD/bin/ffscreen.py
export LD_LIBRARY_PATH=/usr/prog/Python-3.8.2/lib:/usr/prog/openssl-1.0.2d/lib:/usr/prog/libffi-3.4.4/lib:$LD_LIBRARY_PATH
"$PY" - <<'PYEOF'
import base64, struct, sys, zlib
sys.path.insert(0, '/usr/data/anvil/bin')
import ffscreen

W, H, BPP = 480, 800, 32   # the real framebuffer: portrait
# Keep in step with bin/preview-boot-screen.py, which renders the same list
# on the host -- the two are expected to agree byte for byte.
PHASES = [
    ('starting-services', 'STARTING SERVICES', 0.05, ''),
    ('mcu-heater', 'WAITING FOR THE HEATER BOARD', 0.05, ''),
    ('mcu-both', 'WAITING FOR THE HEATER BOARD AND THE LEVEL BOARD', 0.05, ''),
    ('waiting', 'WAITING FOR THE PRINTER', 0.22, ''),
    ('importing', 'READING FACTORY CALIBRATION', 0.5, ''),
    ('saving', 'SAVING CALIBRATION', 0.7, ''),
    ('restarting', 'RESTARTING THE PRINTER', 0.85, ''),
    ('complete', 'SETUP COMPLETE', 1.0, ''),
    ('already', 'ALREADY CALIBRATED', 1.0, ''),
]
RETRY = 'SETUP WILL RETRY ON NEXT START'
LOG = '/USR/DATA/LOGS/ANVIL-BOOT.LOG'
for slug, reason in [
        ('fail-moonraker', 'MOONRAKER IS NOT RESPONDING'),
        ('fail-klipper-error', 'KLIPPER REPORTED AN ERROR'),
        ('fail-board', 'THE HEATER BOARD DID NOT ANSWER'),
        ('fail-klipper-startup', 'KLIPPER DID NOT FINISH STARTING (STARTUP)'),
        ('fail-tools', 'COULD NOT READ THE TOOL SETTINGS'),
        ('fail-config', 'COULD NOT READ THE PRINTER CONFIGURATION'),
        ('fail-pending', 'ANOTHER CONFIGURATION SAVE WAS ALREADY WAITING'),
        ('fail-refused', 'THE PRINTER REFUSED FF_IMPORT_FIRMWARE_CONFIG'),
        ('fail-empty', 'NO CALIBRATION FOUND IN THE FACTORY DATA'),
        ('fail-restart', 'KLIPPER DID NOT RESTART AFTER SAVING'),
        ('fail-unsaved', 'THE CALIBRATION DID NOT SAVE')]:
    PHASES.append((slug, RETRY, None, '%s. DETAILS IN %s' % (reason, LOG)))
NO_NOTE = ('complete', 'already')
for name, status, prog, detail in PHASES:
    open('/tmp/fb', 'wb').close()
    s = ffscreen.Screen('/tmp/fb', geometry=(W, H, BPP))
    note = '' if (name in NO_NOTE or detail) else 'DO NOT TURN THE PRINTER OFF'
    s.show('SETTING UP YOUR PRINTER', status, note, prog, detail, bool(detail))
    buf = open('/tmp/fb', 'rb').read()

    # Emit what the EYE sees, not the buffer: the panel is this portrait
    # buffer turned 90 degrees clockwise, so undo that on the way out.
    def px(bx, by):
        off = by * s.stride + bx * 4
        b, g, r, _ = buf[off:off + 4]
        return bytes((r, g, b))

    rows = []
    for y in range(s.height):
        row = bytearray(b'\x00')
        for x in range(s.width):
            row += px(y, s.buf_h - 1 - x)
        rows.append(bytes(row))

    def chunk(tag, data):
        body = tag + data
        return struct.pack('>I', len(data)) + body + struct.pack('>I', zlib.crc32(body))

    png = (b'\x89PNG\r\n\x1a\n'
           + chunk(b'IHDR', struct.pack('>IIBBBBB', s.width, s.height,
                                        8, 2, 0, 0, 0))
           + chunk(b'IDAT', zlib.compress(b''.join(rows), 9))
           + chunk(b'IEND', b''))
    print('PNGSTART %s' % name)
    print(base64.b64encode(png).decode())
    print('PNGEND')
PYEOF
