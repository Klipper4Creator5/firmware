# Print-start / print-end entry points for the FlashForge Creator 5 Pro.
#
# The stock slicer profile's start G-code carries no toolchanger information
# and no G28 -- its only motion is `G1 Z5 F2400`, which on an unhomed machine
# raises "Must home axis first". So the file cannot be what prepares the
# machine: something must home, clean and grab a tool BEFORE its first line,
# which is exactly what the touchscreen app did before sending M23/M24. This
# module restores that ordering for prints started from Moonraker/Mainsail by
# wrapping the commands that begin a print, so the stock OrcaSlicer profile
# needs no modification.
#
# NOT via idle_timeout:printing: that is emitted synchronously inside motion
# scheduling, which is no place to run a G-code script, and it fires only once
# the toolhead syncs -- which for a stock file is the very `G1 Z5` that fails.
#
# It contains no print policy. It resolves the file, reads the slicer
# metadata, and calls two ordinary macros defined in ff-print-macros.cfg:
#
#       FF_BEFORE_PRINT_START ORIGIN=<cmd> [BED=] [TOOL=] [NOZZLE=] [LAYER=]
#       FF_AFTER_PRINT_END    STATE=<complete|cancelled|error|...>
#
# Everything derived is also published in get_status as printer.ff_print.*.
#
# Only the head of the file is read, and only what the file states in its own
# commands -- as the app's own parser did:
#   bed          the first `M140`/`M190 S<t>`
#   nozzle       the first `M104`/`M109 S<t>`
#   first tool   the first bare `Tn` -- the file's initial extruder, NOT the
#                lowest-numbered one it uses
#   layer        the first `;HEIGHT:` -- the FIRST layer's height, which is
#                what the print Z offset's thin-layer term wants
#
# Nothing is read from the slicer's config block: that keeps this
# slicer-agnostic and avoids reading the far end of a 27 MB file. It is also
# unreliable -- on a real file `; first_layer_bed_temperature` read 55 where
# `M140` said 80.
#
# Per-tool clean temperatures are NOT taken from the file; the app's material
# table is ported as _FF_FILAMENT.temps, with the material per tool alongside.

import logging
import os
import re

EXTRUDER_COUNT = 4

# Bounded read: everything parsed sits within ~8 KB of the start on real
# files, so this is a wide margin rather than a guess.
HEAD_BYTES = 256 * 1024

# print_stats states that mean the job is over (as opposed to paused mid-print).
FINISHED_STATES = ('complete', 'cancelled', 'error')


def _parse_metadata(path):
    """Read what the file says about itself, from its own commands.

    Returns a dict with whatever could be derived; missing keys simply are
    not present.  Never raises -- a file we cannot read just yields {}, and
    the macro then runs with no derived parameters."""
    try:
        with open(path, 'rb') as fh:
            head = fh.read(HEAD_BYTES).decode('utf-8', 'replace')
    except Exception:
        logging.exception("ff_print: cannot read '%s'", path)
        return {}

    metadata = {}

    # Bed and nozzle: the file's own first heat command, the way the app's
    # parser did it (it scanned M104/M109/M140/M190/M141/M191 and reported
    # nozzleTemp / bedTemp / chamberTemp).
    bed_match = re.search(r'^M1[49]0 S([0-9]+(?:\.[0-9]+)?)', head, re.M)
    if bed_match is not None and float(bed_match.group(1)) > 0:
        metadata['bed'] = int(float(bed_match.group(1)))
    nozzle_match = re.search(r'^M10[49] S([0-9]+(?:\.[0-9]+)?)', head, re.M)
    if nozzle_match is not None and float(nozzle_match.group(1)) > 0:
        metadata['nozzle'] = int(float(nozzle_match.group(1)))

    # The file's initial extruder (the app's "fisrNozzleIndex", sic).
    tool_match = re.search(r'^T([0-%d])\b' % (EXTRUDER_COUNT - 1),
                           head, re.M)
    if tool_match is not None:
        metadata['tool'] = int(tool_match.group(1))

    # First-layer height, from the per-layer marker the slicer emits. This
    # feeds the print Z offset's thin-layer term, which is a FIRST-layer
    # correction.
    layer_match = re.search(r'^;HEIGHT:([0-9.]+)', head, re.M)
    if layer_match is not None:
        try:
            metadata['layer'] = float(layer_match.group(1))
        except ValueError:
            pass

    return metadata


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
        self.previous_handlers = {}
        self.metadata = {}
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
            previous = self.gcode.register_command(cmd, None)
            if previous is None:
                raise self.printer.config_error(
                    "ff_print: command '%s' is not registered -- is there a"
                    " [virtual_sdcard] section in the config? (Section ORDER"
                    " does not matter: this runs at klippy:connect, after"
                    " every section is loaded.)" % (cmd,))
            self.previous_handlers[cmd] = previous
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
            'tool': self.metadata.get('tool'),
            'nozzle': self.metadata.get('nozzle'),
            'bed': self.metadata.get('bed'),
            'layer': self.metadata.get('layer'),
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
        virtual_sdcard = self.printer.lookup_object('virtual_sdcard', None)
        if virtual_sdcard is None:
            return None
        return os.path.join(virtual_sdcard.sdcard_dirname, name)

    def _cmd_start(self, cmd, gcmd):
        path = self._resolve(gcmd, cmd)
        self.filename = path
        self.origin = cmd
        self.metadata = _parse_metadata(path) if path else {}
        if self.metadata:
            logging.info("ff_print: %s -> %s", path, self.metadata)
        else:
            logging.info("ff_print: %s -> no slicer metadata found", path)

        params = ['ORIGIN=%s' % (cmd,)]
        for key, name, fmt in (('bed', 'BED', '%d'), ('tool', 'TOOL', '%d'),
                               ('nozzle', 'NOZZLE', '%d'),
                               ('layer', 'LAYER', '%s')):
            if self.metadata.get(key) is not None:
                params.append('%s=%s' % (name, fmt % (self.metadata[key],)))

        # Let the macro raise: a refusal here must stop the print BEFORE the
        # base command loads and resumes the file.
        self.gcode.run_script_from_command(
            '%s %s' % (self.before_macro, ' '.join(params)))
        # Arm the end latch only once prepare succeeded.
        self.active = True
        self.previous_handlers[cmd](gcmd)

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
