# One-shot migration helpers from firmwareExe's per-unit JSON to Klipper config.
#
# Nothing here runs during normal operation. Load it with an empty
# [ff_legacy] section when you need it, run the command once, SAVE_CONFIG,
# and you can remove the section again.
#
#   FF_IMPORT_FIRMWARE_CONFIG [DIR=/usr/data/firmwareRes/config] [APPLY=1]
#
# reads extruder.json / test.json / zoffset.json and
#   * stages the CALIBRATION data for SAVE_CONFIG (configfile.set), exactly
#     as TOOL_OFFSET_CALIBRATE / STATION_CALIBRATE would:
#         [ff_tool n]      nozzle_x/y/z  <- t<n>_offset_x/y/z
#                          z_adjust      <- zoffset.json z_offset_t<n+1> (if != 0)
#         [ff_tool_offset] station_x/y/z <- x/y/z_station_pos
#   * PRINTS a ready-to-paste snippet for the settings that belong in the
#     hand-written part of the config and must not be autosaved (SAVE_CONFIG
#     refuses to autosave an option an include already sets):
#         [ff_tool n]      dock_x/dock_y  <- x_check_pos<n>/y_check_pos<n>
#         [ff_toolchange]  x_correction   <- grabOffset
#                          fast_feed      <- grabSpeed * 60
#                          slow_feed, release_slow_feed <- grabSpeedSlow * 60
#                          temp_offset    <- tempOffset
#         [ff_tool_offset] cylinder_x/y   <- cylinder_x/y
# APPLY=0 only prints everything and stages nothing.
#
# Key names and the struct layout were read off the binary
# (Config::loadExtruderConfig @0x64f7f8, loadTestConfig @0x654380,
# loadZOffsetConfig @0x65621c); see OKF/32-config-provenance.md. The files
# are NOT strict JSON: each ends with a trailing C comment after the closing
# brace, so we use raw_decode() and ignore the tail.

import json
import logging
import math
import os

EXTRUDER_COUNT = 4
FIRMWARE_CONFIG_DIR = '/usr/data/firmwareRes/config'


class FFFirmwareConfig:
    """Read-only view of firmwareExe's per-unit JSON configuration."""

    def __init__(self, directory):
        self.dir = directory
        self.files = {}
        self.errors = []
        for name in ('extruder', 'test', 'zoffset'):
            path = os.path.join(self.dir, name + '.json')
            try:
                with open(path, 'r') as fh:
                    text = fh.read()
            except IOError as e:
                self.errors.append("%s: %s" % (path, e))
                continue
            try:
                obj, _ = json.JSONDecoder().raw_decode(text.lstrip())
            except ValueError as e:
                self.errors.append("%s: not valid JSON (%s)" % (path, e))
                continue
            if not isinstance(obj, dict):
                self.errors.append("%s: expected a JSON object" % path)
                continue
            self.files[name] = obj

    def num(self, fname, key):
        obj = self.files.get(fname)
        if obj is None:
            return None
        val = obj.get(key)
        if isinstance(val, bool) or not isinstance(val, (int, float)):
            return None
        if not math.isfinite(val):
            return None
        return float(val)

    def tool_offsets(self):
        rows = []
        for n in range(EXTRUDER_COUNT):
            v = [self.num('extruder', 't%d_offset_%s' % (n, a)) for a in 'xyz']
            rows.append(None if None in v else tuple(v))
        return rows

    def docks(self):
        rows = []
        for n in range(EXTRUDER_COUNT):
            sfx = '' if n == 0 else '%d' % n
            x = self.num('extruder', 'x_check_pos' + sfx)
            y = self.num('extruder', 'y_check_pos' + sfx)
            rows.append(None if None in (x, y) else (x, y))
        return rows

    def station(self):
        v = [self.num('extruder', '%s_station_pos' % a) for a in 'xyz']
        return None if None in v else tuple(v)

    def z_adjust(self):
        # zoffset.json is 1-BASED: z_offset_t1 is tool 0.
        return [self.num('zoffset', 'z_offset_t%d' % (n + 1))
                for n in range(EXTRUDER_COUNT)]

    def speed(self, key):
        # mm/s in the file; the app multiplies by 60 and ignores <= 0.
        v = self.num('test', key)
        if v is None or v <= 0:
            return None
        return int(round(v * 60.0))


class FFLegacy:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name()
        self.gcode = self.printer.lookup_object('gcode')
        self.gcode.register_command(
            'FF_IMPORT_FIRMWARE_CONFIG', self.cmd_FF_IMPORT_FIRMWARE_CONFIG,
            desc=self.cmd_FF_IMPORT_FIRMWARE_CONFIG_help)

    cmd_FF_IMPORT_FIRMWARE_CONFIG_help = (
        "Import firmwareExe's extruder/test/zoffset.json into [ff_tool n] /"
        " [ff_tool_offset] ([DIR=<path>] [APPLY=1])")

    def cmd_FF_IMPORT_FIRMWARE_CONFIG(self, gcmd):
        directory = gcmd.get('DIR', FIRMWARE_CONFIG_DIR)
        apply = gcmd.get_int('APPLY', 1, minval=0, maxval=1)
        fw = FFFirmwareConfig(directory)
        out = ["import from %s" % directory]
        out += ["  ! %s" % e for e in fw.errors]
        if 'extruder' not in fw.files:
            raise gcmd.error("%s: extruder.json could not be read (%s)"
                             % (self.name, "; ".join(fw.errors)))

        configfile = self.printer.lookup_object('configfile')
        staged = []

        def stage(section, option, value):
            if apply:
                configfile.set(section, option, "%.6f" % value)
            staged.append("  [%s] %s = %.6f" % (section, option, value))

        # -- calibration data -> autosave --------------------------------
        tools = fw.tool_offsets()
        zadj = fw.z_adjust()
        for n in range(EXTRUDER_COUNT):
            sec = 'ff_tool %d' % n
            if tools[n] is not None:
                stage(sec, 'nozzle_x', tools[n][0])
                stage(sec, 'nozzle_y', tools[n][1])
                stage(sec, 'nozzle_z', tools[n][2])
                obj = self.printer.lookup_object(sec, None)
                if apply and obj is not None:
                    obj.nozzle = tools[n]
            else:
                out.append("  ! t%d_offset_x/y/z missing -- T%d not imported"
                           % (n, n))
            if zadj[n]:
                stage(sec, 'z_adjust', zadj[n])
                obj = self.printer.lookup_object(sec, None)
                if apply and obj is not None:
                    obj.z_adjust = zadj[n]
        st = fw.station()
        if st is not None:
            stage('ff_tool_offset', 'station_x', st[0])
            stage('ff_tool_offset', 'station_y', st[1])
            stage('ff_tool_offset', 'station_z', st[2])
            obj = self.printer.lookup_object('ff_tool_offset', None)
            if apply and obj is not None:
                obj.station = st
        else:
            out.append("  ! x/y/z_station_pos missing -- station not imported")

        tc = self.printer.lookup_object('ff_toolchange', None)
        if apply and tc is not None and hasattr(tc, 'refresh_offsets'):
            tc.refresh_offsets()

        out.append("%s for SAVE_CONFIG:" % ("staged" if apply else "would stage"))
        out += staged or ["  (nothing)"]

        # -- hand-written settings -> snippet ----------------------------
        snippet = []
        docks = fw.docks()
        for n in range(EXTRUDER_COUNT):
            snippet.append("[ff_tool %d]" % n)
            if docks[n] is not None:
                snippet.append("dock_x: %.6f" % docks[n][0])
                snippet.append("dock_y: %.6f" % docks[n][1])
            else:
                snippet.append("# x/y_check_pos%s missing in extruder.json"
                               % ('' if n == 0 else n))
            snippet.append("")
        snippet.append("[ff_toolchange]")
        for opt, key in (('x_correction', 'grabOffset'),
                         ('temp_offset', 'tempOffset')):
            v = fw.num('test', key)
            if v is not None:
                snippet.append("%s: %.6g" % (opt, v))
        fast = fw.speed('grabSpeed')
        slow = fw.speed('grabSpeedSlow')
        if fast is not None:
            snippet.append("fast_feed: %d" % fast)
        if slow is not None:
            snippet.append("slow_feed: %d" % slow)
            snippet.append("release_slow_feed: %d" % slow)
        snippet.append("")
        snippet.append("[ff_tool_offset]")
        for opt in ('cylinder_x', 'cylinder_y'):
            v = fw.num('test', opt)
            if v is not None:
                snippet.append("%s: %.6g" % (opt, v))
        out.append("paste into the hand-written config (NOT autosaved):")
        out += ["  " + l for l in snippet]
        if apply and staged:
            out.append("Then run SAVE_CONFIG to persist the staged values.")
        gcmd.respond_info("\n".join(out))
        logging.info("%s: %s", self.name, "\n".join(out))


def load_config(config):
    return FFLegacy(config)
