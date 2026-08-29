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
# Deliberately NOT a klippy:ready handler here: that would put a
# Creator-5-only, once-per-install chore inside a general extra and re-decide
# it on every ready, at the one moment klippy cannot know whether the rest of
# the machine is up. Running the command by hand works as it always did.
#
#   FF_IMPORT_FIRMWARE_CONFIG [DIR=/usr/data/firmwareRes/config] [APPLY=1]
#
# reads extruder.json / test.json / zoffset.json and
#   * stages the per-unit data for SAVE_CONFIG (configfile.set), exactly
#     as TOOL_CALIBRATE_TOOL_OFFSET / TOOL_LOCATE_SENSOR would:
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
            except IOError as err:
                self.errors.append("%s: %s" % (path, err))
                continue
            try:
                decoded, _tail = json.JSONDecoder().raw_decode(text.lstrip())
            except ValueError as err:
                self.errors.append("%s: not valid JSON (%s)" % (path, err))
                continue
            if not isinstance(decoded, dict):
                self.errors.append("%s: expected a JSON object" % path)
                continue
            self.files[name] = decoded

    def num(self, file_name, key):
        contents = self.files.get(file_name)
        if contents is None:
            return None

        value = contents.get(key)
        if isinstance(value, bool) or not isinstance(value, (int, float)):
            return None

        if not math.isfinite(value):
            return None

        return float(value)

    def tool_offsets(self):
        rows = []
        for index in range(EXTRUDER_COUNT):
            offset = [self.num('extruder', 't%d_offset_%s' % (index, axis))
                      for axis in 'xyz']
            rows.append(None if None in offset else tuple(offset))
        return rows

    def docks(self):
        rows = []
        for index in range(EXTRUDER_COUNT):
            # first extruder is just "extruder", next is "extruder1"
            suffix = '' if index == 0 else '%d' % index
            dock_x = self.num('extruder', 'x_check_pos' + suffix)
            dock_y = self.num('extruder', 'y_check_pos' + suffix)
            rows.append(None if None in (dock_x, dock_y) else (dock_x, dock_y))
        return rows

    def station(self):
        position = [self.num('extruder', '%s_station_pos' % axis)
                    for axis in 'xyz']
        return None if None in position else tuple(position)

    def z_adjust(self):
        # zoffset.json is 1-BASED: z_offset_t1 is tool 0.
        return [self.num('zoffset', 'z_offset_t%d' % (index + 1))
                for index in range(EXTRUDER_COUNT)]

    def speed(self, key):
        # mm/s in the file; the app multiplies by 60 and ignores <= 0.
        mm_per_second = self.num('test', key)
        if mm_per_second is None or mm_per_second <= 0:
            return None
        return int(round(mm_per_second * 60.0))


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
            report = self._import(directory, apply)
        except ValueError as err:
            raise gcmd.error(str(err))
        gcmd.respond_info("\n".join(report))
        logging.info("%s: %s", self.name, "\n".join(report))

    def _import(self, directory, apply):
        firmware = FFFirmwareConfig(directory)
        report = ["import from %s" % directory]
        report += ["  ! %s" % problem for problem in firmware.errors]
        if 'extruder' not in firmware.files:
            raise ValueError("%s: extruder.json could not be read (%s)"
                             % (self.name, "; ".join(firmware.errors)))

        configfile = self.printer.lookup_object('configfile')
        staged = []

        def stage(section, option, value):
            if apply:
                configfile.set(section, option, "%.6f" % value)
            staged.append("  [%s] %s = %.6f" % (section, option, value))

        # -- per-unit data -> autosave -----------------------------------
        nozzles = firmware.tool_offsets()
        z_adjusts = firmware.z_adjust()
        docks = firmware.docks()
        for index in range(EXTRUDER_COUNT):
            section = 'ff_tool %d' % index
            if docks[index] is not None:
                stage(section, 'dock_x', docks[index][0])
                stage(section, 'dock_y', docks[index][1])
                tool_object = self.printer.lookup_object(section, None)
                if apply and tool_object is not None:
                    tool_object.dock_x, tool_object.dock_y = docks[index]
            else:
                report.append("  ! x/y_check_pos%s missing -- T%d dock not"
                              " imported"
                              % ('' if index == 0 else index, index))
            if nozzles[index] is not None:
                stage(section, 'nozzle_x', nozzles[index][0])
                stage(section, 'nozzle_y', nozzles[index][1])
                stage(section, 'nozzle_z', nozzles[index][2])
                tool_object = self.printer.lookup_object(section, None)
                if apply and tool_object is not None:
                    tool_object.nozzle = nozzles[index]
            else:
                report.append("  ! t%d_offset_x/y/z missing -- T%d not"
                              " imported" % (index, index))
            if z_adjusts[index]:
                stage(section, 'z_adjust', z_adjusts[index])
                tool_object = self.printer.lookup_object(section, None)
                if apply and tool_object is not None:
                    tool_object.z_adjust = z_adjusts[index]
        station = firmware.station()
        if station is not None:
            stage('ff_tool_offset', 'station_x', station[0])
            stage('ff_tool_offset', 'station_y', station[1])
            stage('ff_tool_offset', 'station_z', station[2])
            offsets = self.printer.lookup_object('ff_tool_offset', None)
            if apply and offsets is not None:
                offsets.station = station
        else:
            report.append("  ! x/y/z_station_pos missing -- station not"
                          " imported")
        offsets = self.printer.lookup_object('ff_tool_offset', None)
        for option, attribute in (('cylinder_x', 'cfg_cylinder_x'),
                                  ('cylinder_y', 'cfg_cylinder_y')):
            value = firmware.num('test', option)
            if value is not None:
                stage('ff_tool_offset', option, value)
                if apply and offsets is not None:
                    setattr(offsets, attribute, value)

        toolchange = self.printer.lookup_object('ff_toolchange', None)
        if apply and toolchange is not None \
           and hasattr(toolchange, 'refresh_offsets'):
            toolchange.refresh_offsets()

        report.append("%s for SAVE_CONFIG:"
                      % ("staged" if apply else "would stage"))
        report += staged or ["  (nothing)"]

        # -- plain [ff_toolchange] settings -> snippet, only if different --
        wanted = []
        for option, key in (('x_correction', 'grabOffset'),
                            ('temp_offset', 'tempOffset')):
            value = firmware.num('test', key)
            if value is not None:
                wanted.append((option, value, "%.6g"))
        fast_feed = firmware.speed('grabSpeed')
        slow_feed = firmware.speed('grabSpeedSlow')
        if fast_feed is not None:
            wanted.append(('fast_feed', fast_feed, "%d"))
        if slow_feed is not None:
            wanted.append(('slow_feed', slow_feed, "%d"))
            wanted.append(('release_slow_feed', slow_feed, "%d"))
        snippet = []
        for option, value, fmt in wanted:
            running = (getattr(toolchange, option, None)
                       if toolchange is not None else None)
            if running is None or abs(float(running) - float(value)) > 1e-9:
                snippet.append(("%s: " + fmt) % (option, value))
        if snippet:
            report.append("[ff_toolchange] differs from the factory JSON --"
                          " set by hand in ff-toolchange.cfg if intended:")
            report += ["  " + line for line in snippet]
        if apply and staged:
            report.append("Then run SAVE_CONFIG to persist the staged values.")
        return report


def load_config(config):
    return FFLegacy(config)
