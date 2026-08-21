# Per-tool configuration for the FlashForge Creator 5 Pro toolchanger.
#
# Hand-written (ff-toolchange.cfg):
#   [ff_tool 0]
#   dock_x: 296.558        # carriage X at which this tool's dock is engaged
#   dock_y: 56.236         # Y of the dock
#
# Autosaved into printer.cfg's SAVE_CONFIG block -- never write these in an
# included file (SAVE_CONFIG refuses: "conflicts with included value"):
#   #*# [ff_tool 0]
#   #*# nozzle_x = 16.416023   MEASUREMENT. The station bore axis as probed
#   #*# nozzle_y = 212.585861  with this tool's nozzle, raw machine coords,
#   #*# nozzle_z = 1.515972    G-code offset zeroed. Written as a triple by
#                              TOOL_OFFSET_CALIBRATE; all three or none.
#   #*# z_adjust = -0.020      USER CORRECTION. A persistent per-tool Z tweak
#                              added on top of the measured difference at
#                              every grab (the app's zoffset.json). Klipper's
#                              own babystep (SET_GCODE_OFFSET Z_ADJUST) is
#                              global, so this is the only per-tool one.
#                              Set with TOOL_Z_ADJUST, persisted by SAVE_CONFIG.
#
# Offsets applied on a grab are DIFFERENCES against a base tool (ff_toolchange):
#   X = nozzle_x[tool] - nozzle_x[base]
#   Y = nozzle_y[tool] - nozzle_y[base]
#   Z = nozzle_z[tool] - nozzle_z[base] + z_adjust[tool]
# Absolute values are stored, so recalibrating one tool leaves the others
# valid. nozzle_z - station_z ([ff_tool_offset]) is the nozzle-to-eddy-trigger
# gap the print-start Z offset is built from.

import logging


class FFTool:
    def __init__(self, config):
        self.printer = config.get_printer()
        self.name = config.get_name()
        try:
            self.index = int(self.name.split()[-1])
        except ValueError:
            raise config.error("%s: section name must be 'ff_tool <n>'"
                               % self.name)
        if self.index < 0:
            raise config.error("%s: tool index must be >= 0" % self.name)
        self.dock_x = config.getfloat('dock_x')
        self.dock_y = config.getfloat('dock_y')
        # Klipper's own naming: tool 0 is [extruder], tool n is [extruderN].
        self.extruder_name = ('extruder' if self.index == 0
                              else 'extruder%d' % self.index)
        # Measured (TOOL_OFFSET_CALIBRATE) -- one probe run yields all three.
        nozzle = [config.getfloat('nozzle_' + a, None) for a in 'xyz']
        if None in nozzle and nozzle != [None, None, None]:
            raise config.error("%s: nozzle_x, nozzle_y and nozzle_z must be"
                               " set together" % self.name)
        self.nozzle = None if nozzle[0] is None else tuple(nozzle)
        # User's persistent per-tool Z correction (TOOL_Z_ADJUST).
        self.z_adjust = config.getfloat('z_adjust', 0.0)
        self.printer.register_event_handler('klippy:connect',
                                            self._handle_connect)

    def _handle_connect(self):
        if self.printer.lookup_object(self.extruder_name, None) is None:
            raise self.printer.config_error(
                "%s: extruder '%s' not found" % (self.name, self.extruder_name))

    def calibrated(self):
        return self.nozzle is not None

    def set_nozzle(self, x, y, z):
        """Adopt a new measurement live and stage it for SAVE_CONFIG."""
        self.nozzle = (float(x), float(y), float(z))
        configfile = self.printer.lookup_object('configfile')
        configfile.set(self.name, 'nozzle_x', "%.6f" % x)
        configfile.set(self.name, 'nozzle_y', "%.6f" % y)
        configfile.set(self.name, 'nozzle_z', "%.6f" % z)
        logging.info("%s: nozzle = (%.6f, %.6f, %.6f)", self.name, x, y, z)

    def set_z_adjust(self, z):
        self.z_adjust = float(z)
        configfile = self.printer.lookup_object('configfile')
        configfile.set(self.name, 'z_adjust', "%.6f" % z)

    def get_status(self, eventtime):
        nx, ny, nz = self.nozzle if self.nozzle else (None, None, None)
        return {'index': self.index, 'dock_x': self.dock_x,
                'dock_y': self.dock_y, 'extruder': self.extruder_name,
                'z_adjust': self.z_adjust, 'calibrated': self.nozzle is not None,
                'nozzle_x': nx, 'nozzle_y': ny, 'nozzle_z': nz}


def load_config_prefix(config):
    return FFTool(config)
