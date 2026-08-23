# Print-start / print-end entry points for the FlashForge Creator 5 Pro.
#
# Why this exists
#   The stock slicer profile's start G-code carries no toolchanger information
#   and, crucially, no G28 -- its only motion is `G1 Z5 F2400`.  On an unhomed
#   machine that raises "Must home axis first", so the file cannot be the thing
#   that prepares the machine: something must home, clean and grab a tool
#   BEFORE the file's first line.  The touchscreen app did exactly that -- it
#   ran its whole prepare sequence and only then sent M23/M24 (see
#   OKF/61-print-lifecycle-verified.md).  It never subscribed to a print-start
#   event, because it *was* the thing starting the print.
#
#   This module restores that ordering for prints started from Moonraker /
#   Mainsail, by wrapping the commands that begin a print.  Doing it here
#   rather than in the slicer means the stock OrcaSlicer profile needs no
#   modification and already-sliced files keep working.
#
# Why not idle_timeout:printing
#   `idle_timeout:printing` is emitted from handle_sync_print_time (a
#   toolhead:sync_print_time handler), i.e. synchronously inside motion
#   scheduling -- not a safe place to run a G-code script, which is why
#   Klipper runs its own idle gcode from a reactor timer instead.  It also
#   fires only once the toolhead syncs, which for a stock file is the very
#   `G1 Z5` that fails on unhomed axes: the event would arrive at the same
#   instant the print dies.  There is no usable window.
#
# What this module does NOT do
#   It contains no print policy at all.  It resolves the file, reads the
#   slicer metadata, and calls two ordinary G-code macros:
#
#       FF_BEFORE_PRINT_START ORIGIN=<cmd> [BED=] [TOOL=] [NOZZLE=] [LAYER=]
#                             [TOOLS=<tool>:<temp>,...]
#       FF_AFTER_PRINT_END    STATE=<complete|cancelled|error|...>
#
#   Both are defined in ff-print-macros.cfg and may be redefined by the user.
#   Everything derived from the file is also published in get_status, so a
#   redefined macro can read printer.ff_print.* instead of the parameters.
#
# What is read, and why this way
#   Only the head of the file, and only what the file states in its own
#   commands.  The app's parser did the same -- its string table (firmwareExe
#   ~138069) lists M104/M109/M140/M190/M141/M191 and `;HEIGHT:` among the keys
#   it scanned, and the fields it produced: fisrNozzleIndex (sic), nozzleTemp,
#   bedTemp, chamberTemp, layerHeight.
#
#   bed          the file's first `M140`/`M190 S<t>`
#   nozzle       the file's first `M104`/`M109 S<t>`
#   first tool   the first bare `Tn` -- the file's initial extruder, NOT the
#                lowest-numbered one it uses; two otherwise identical files
#                here start on T0 and T2 respectively
#   layer        the first `;HEIGHT:` -- the FIRST layer's height, which is
#                what the print Z offset's thin-layer term actually wants
#
#   Nothing is read from the slicer's config block.  That keeps this
#   slicer-agnostic: no table of plate types, no `bed_temperature_formula`,
#   nothing that breaks when a profile or slicer version changes, and no need
#   to read the far end of a 27 MB file.  (The config-block route also has a
#   trap: on a real file `; first_layer_bed_temperature` read 55 where `M140`
#   said 80.)
#
#   Per-tool clean temperatures are NOT taken from the file.  The app kept a
#   material per slot and looked the temperature up in its own table; that
#   table is already ported as _FF_FILAMENT.temps, so the material per tool is
#   configured alongside it as _FF_FILAMENT.tool_material.
#
# All of the above sits within ~8 KB of the start of the file; HEAD_BYTES is a
# wide margin around that, not a guess.

import logging
import os
import re

EXTRUDER_COUNT = 4

# Bounded reads: measured offsets are ~8 KB (first Tn) and ~24 KB (config
# block) on real files; these give a wide margin without loading a 27 MB file.
HEAD_BYTES = 256 * 1024
TAIL_BYTES = 256 * 1024

# print_stats states that mean the job is over (as opposed to paused mid-print).
FINISHED_STATES = ('complete', 'cancelled', 'error')


def _parse_metadata(path):
    """Read what the file says about itself, from its own commands.

    Returns a dict with whatever could be derived; missing keys simply are
    not present.  Never raises -- a file we cannot read just yields {}, and
    the macro then runs with no derived parameters."""
    try:
        with open(path, 'rb') as f:
            head = f.read(HEAD_BYTES).decode('utf-8', 'replace')
    except Exception:
        logging.exception("ff_print: cannot read '%s'", path)
        return {}

    meta = {}

    # Bed and nozzle: the file's own first heat command, the way the app's
    # parser did it (it scanned M104/M109/M140/M190/M141/M191 and reported
    # nozzleTemp / bedTemp / chamberTemp).
    bed = re.search(r'^M1[49]0 S([0-9]+(?:\.[0-9]+)?)', head, re.M)
    if bed is not None and float(bed.group(1)) > 0:
        meta['bed'] = int(float(bed.group(1)))
    hot = re.search(r'^M10[49] S([0-9]+(?:\.[0-9]+)?)', head, re.M)
    if hot is not None and float(hot.group(1)) > 0:
        meta['nozzle'] = int(float(hot.group(1)))

    # The file's initial extruder (the app's "fisrNozzleIndex", sic).
    first = re.search(r'^T([0-%d])\b' % (EXTRUDER_COUNT - 1), head, re.M)
    if first is not None:
        meta['tool'] = int(first.group(1))

    # First-layer height, from the per-layer marker the slicer emits in the
    # body -- one of the three keys the app looked for, and the only one that
    # appears near the start of the file.  This feeds the print Z offset's
    # thin-layer term, which is a FIRST-layer correction, so the first layer's
    # height is the value that belongs there.
    layer = re.search(r'^;HEIGHT:([0-9.]+)', head, re.M)
    if layer is not None:
        try:
            meta['layer'] = float(layer.group(1))
        except ValueError:
            pass

    return meta


class FFPrint:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.reactor = self.printer.get_reactor()
        self.gcode = self.printer.lookup_object('gcode')
        self.before_macro = config.get('before_macro', 'FF_BEFORE_PRINT_START')
        self.after_macro = config.get('after_macro', 'FF_AFTER_PRINT_END')
        self.hook_commands = [c.strip().upper() for c
                              in config.getlist('hook_commands',
                                                ['SDCARD_PRINT_FILE', 'M23'])
                              if c.strip()]
        self.prev_handlers = {}
        self.meta = {}
        self.filename = None
        self.origin = None
        # Latch: only a print WE announced may fire the end macro.
        self.active = False
        self.end_state = 'complete'
        self.end_timer = None
        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)
        self.printer.register_event_handler('idle_timeout:ready',
                                            self._handle_ready)

    def _handle_connect(self):
        # Same rename dance gcode_macro uses for rename_existing: take the
        # command over and keep the previous handler to chain to.
        for cmd in self.hook_commands:
            prev = self.gcode.register_command(cmd, None)
            if prev is None:
                raise self.printer.config_error(
                    "ff_print: command '%s' is not registered -- [ff_print]"
                    " must be loaded after [virtual_sdcard]" % (cmd,))
            self.prev_handlers[cmd] = prev
            self.gcode.register_command(
                cmd, self._make_handler(cmd),
                desc="%s (ff_print: runs %s first)"
                     % (cmd, self.before_macro))
        self.end_timer = self.reactor.register_timer(self._run_end_macro)

    def _make_handler(self, cmd):
        def handler(gcmd):
            self._cmd_start(cmd, gcmd)
        return handler

    def get_status(self, eventtime):
        return {
            'filename': self.filename,
            'origin': self.origin,
            'active': self.active,
            'tool': self.meta.get('tool'),
            'nozzle': self.meta.get('nozzle'),
            'bed': self.meta.get('bed'),
            'layer': self.meta.get('layer'),
        }

    def _resolve(self, gcmd, cmd):
        """Path of the file this command is about, mirroring virtual_sdcard's
        own resolution (a plain join under sdcard_dirname)."""
        if cmd == 'M23':
            name = gcmd.get_raw_command_parameters().strip()
        else:
            name = gcmd.get('FILENAME', '')
        name = name.strip()
        if name.startswith('/'):
            name = name[1:]
        if not name:
            return None
        vsd = self.printer.lookup_object('virtual_sdcard', None)
        if vsd is None:
            return None
        return os.path.join(vsd.sdcard_dirname, name)

    def _cmd_start(self, cmd, gcmd):
        path = self._resolve(gcmd, cmd)
        self.filename = path
        self.origin = cmd
        self.meta = _parse_metadata(path) if path else {}
        if self.meta:
            logging.info("ff_print: %s -> %s", path, self.meta)
        else:
            logging.info("ff_print: %s -> no slicer metadata found", path)

        params = ['ORIGIN=%s' % (cmd,)]
        for key, name, fmt in (('bed', 'BED', '%d'), ('tool', 'TOOL', '%d'),
                               ('nozzle', 'NOZZLE', '%d'),
                               ('layer', 'LAYER', '%s')):
            if self.meta.get(key) is not None:
                params.append('%s=%s' % (name, fmt % (self.meta[key],)))

        # Let the macro raise: a refusal here must stop the print BEFORE the
        # base command loads and resumes the file.
        self.gcode.run_script_from_command(
            '%s %s' % (self.before_macro, ' '.join(params)))
        # Arm the end latch only once prepare succeeded.
        self.active = True
        self.prev_handlers[cmd](gcmd)

    def _handle_ready(self, print_time):
        """idle_timeout:ready fires whenever the queue drains -- including a
        long M190 mid-print and any manual jog.  Only a job we announced, and
        only one print_stats calls finished, is a real end of print."""
        if not self.active:
            return
        stats = self.printer.lookup_object('print_stats', None)
        if stats is None:
            return
        state = stats.get_status(self.reactor.monotonic()).get('state')
        if state not in FINISHED_STATES:
            return
        self.active = False
        self.end_state = state
        # Run the macro from a timer, not from this event: the handler runs in
        # the idle_timeout timeout path and should not block on a G-code script.
        self.reactor.update_timer(self.end_timer, self.reactor.NOW)

    def _run_end_macro(self, eventtime):
        state = self.end_state
        try:
            self.gcode.run_script('%s STATE=%s' % (self.after_macro, state))
        except Exception:
            logging.exception("ff_print: %s failed", self.after_macro)
        return self.reactor.NEVER


def load_config(config):
    return FFPrint(config)
