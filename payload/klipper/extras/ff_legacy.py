# One-shot migration helpers from firmwareExe's per-unit JSON to Klipper config.
#
# [ff_legacy] is shipped permanently (printer.base.cfg includes ff-legacy.cfg)
# and does exactly one thing: it registers the command below. It has no
# startup behaviour at all.
#
# WHO RUNS IT. On a fresh install the migration is driven from outside klippy,
# by /usr/data/anvil/bin/ff-startup.py, which the firmwareExe wrapper
# runs once before HelixScreen. That program waits until klipper, moonraker
# and Mainsail are all up, sends FF_IMPORT_FIRMWARE_CONFIG and SAVE_CONFIG
# over the moonraker API, and stamps the install so it never runs again.
#
# This used to be a klippy:ready handler here (auto_import / auto_save), which
# meant a Creator-5-only, once-per-install chore lived inside a general extra
# and re-decided itself on every ready, at the one moment klippy cannot know
# whether the rest of the machine is up. Both options are gone; the command
# is unchanged, and running it by hand still works exactly as it did.
#
#   FF_IMPORT_FIRMWARE_CONFIG [DIR=/usr/data/firmwareRes/config] [APPLY=1]
#
# reads extruder.json / test.json / zoffset.json and
#   * stages the per-unit data for SAVE_CONFIG (configfile.set), exactly
#     as TOOL_OFFSET_CALIBRATE / STATION_CALIBRATE would:
#         [ff_tool n]      dock_x/dock_y  <- x_check_pos<n>/y_check_pos<n>
#                          nozzle_x/y/z   <- t<n>_offset_x/y/z
#                          z_adjust       <- zoffset.json z_offset_t<n+1> (if != 0)
#         [ff_tool_offset] station_x/y/z  <- x/y/z_station_pos
#                          cylinder_x/y   <- cylinder_x/y
#   * PRINTS a snippet for the few [ff_toolchange] settings that are plain
#     config (and so cannot be autosaved), only when the JSON disagrees with
#     the running value -- on a stock unit it never does:
#         [ff_toolchange]  x_correction   <- grabOffset
#                          fast_feed      <- grabSpeed * 60
#                          slow_feed, release_slow_feed <- grabSpeedSlow * 60
#                          temp_offset    <- tempOffset
# APPLY=0 only prints everything and stages nothing.
#
# Key names and the struct layout were read off the binary
# (Config::loadExtruderConfig @0x64f7f8, loadTestConfig @0x654380,
# loadZOffsetConfig @0x65621c); see docs/notes/40-offsets.md. The files
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
        for index in range(EXTRUDER_COUNT):
            offset = [self.num('extruder', 't%d_offset_%s' % (index, axis)) for axis in 'xyz']
            rows.append(None if None in offset else tuple(offset))
        return rows

    def docks(self):
        rows = []
        for n in range(EXTRUDER_COUNT):
            # first extruder is just "extruder", next is "extruder1"
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
        # Where the command looks when it is given no DIR= of its own. The
        # first-boot importer passes nothing, so this is the path it gets.
        self.default_dir = config.get('firmware_config_dir',
                                      FIRMWARE_CONFIG_DIR)

    cmd_FF_IMPORT_FIRMWARE_CONFIG_help = (
        "Import firmwareExe's extruder/test/zoffset.json into [ff_tool n] /"
        " [ff_tool_offset] ([DIR=<path>] [APPLY=1])")

    def cmd_FF_IMPORT_FIRMWARE_CONFIG(self, gcmd):
        directory = gcmd.get('DIR', self.default_dir)
        apply = gcmd.get_int('APPLY', 1, minval=0, maxval=1)
        try:
            out = self._import(directory, apply)
        except ValueError as e:
            raise gcmd.error(str(e))
        gcmd.respond_info("\n".join(out))
        logging.info("%s: %s", self.name, "\n".join(out))

    def _import(self, directory, apply):
        fw = FFFirmwareConfig(directory)
        out = ["import from %s" % directory]
        out += ["  ! %s" % e for e in fw.errors]
        if 'extruder' not in fw.files:
            raise ValueError("%s: extruder.json could not be read (%s)"
                             % (self.name, "; ".join(fw.errors)))

        configfile = self.printer.lookup_object('configfile')
        staged = []

        def stage(section, option, value):
            if apply:
                configfile.set(section, option, "%.6f" % value)
            staged.append("  [%s] %s = %.6f" % (section, option, value))

        # -- per-unit data -> autosave -----------------------------------
        tools = fw.tool_offsets()
        zadj = fw.z_adjust()
        docks = fw.docks()
        for n in range(EXTRUDER_COUNT):
            sec = 'ff_tool %d' % n
            if docks[n] is not None:
                stage(sec, 'dock_x', docks[n][0])
                stage(sec, 'dock_y', docks[n][1])
                obj = self.printer.lookup_object(sec, None)
                if apply and obj is not None:
                    obj.dock_x, obj.dock_y = docks[n]
            else:
                out.append("  ! x/y_check_pos%s missing -- T%d dock not imported"
                           % ('' if n == 0 else n, n))
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
        obj = self.printer.lookup_object('ff_tool_offset', None)
        for opt, attr in (('cylinder_x', 'cfg_cylinder_x'),
                          ('cylinder_y', 'cfg_cylinder_y')):
            v = fw.num('test', opt)
            if v is not None:
                stage('ff_tool_offset', opt, v)
                if apply and obj is not None:
                    setattr(obj, attr, v)

        tc = self.printer.lookup_object('ff_toolchange', None)
        if apply and tc is not None and hasattr(tc, 'refresh_offsets'):
            tc.refresh_offsets()

        out.append("%s for SAVE_CONFIG:" % ("staged" if apply else "would stage"))
        out += staged or ["  (nothing)"]

        # -- plain [ff_toolchange] settings -> snippet, only if different --
        wanted = []
        for opt, key in (('x_correction', 'grabOffset'),
                         ('temp_offset', 'tempOffset')):
            v = fw.num('test', key)
            if v is not None:
                wanted.append((opt, v, "%.6g"))
        fast = fw.speed('grabSpeed')
        slow = fw.speed('grabSpeedSlow')
        if fast is not None:
            wanted.append(('fast_feed', fast, "%d"))
        if slow is not None:
            wanted.append(('slow_feed', slow, "%d"))
            wanted.append(('release_slow_feed', slow, "%d"))
        snippet = []
        for opt, v, fmt in wanted:
            cur = getattr(tc, opt, None) if tc is not None else None
            if cur is None or abs(float(cur) - float(v)) > 1e-9:
                snippet.append(("%s: " + fmt) % (opt, v))
        if snippet:
            out.append("[ff_toolchange] differs from the factory JSON --"
                       " set by hand in ff-toolchange.cfg if intended:")
            out += ["  " + l for l in snippet]
        if apply and staged:
            out.append("Then run SAVE_CONFIG to persist the staged values.")
        return out


def load_config(config):
    return FFLegacy(config)
