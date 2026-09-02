# Known issues

## OrcaSlicer sends a 3MF file instead of G-code

Some OrcaSlicer profiles can upload a `.3mf` project rather than the sliced
`.gcode` file. Reforge expects the G-code file for printing, so the job may
not appear or start correctly in Mainsail.

In OrcaSlicer, open **Printer Settings**, change the upload protocol from
**FlashForge** to **Moonraker**, and uncheck:

> Use 3MF instead of G-code

Slice the model again and upload the resulting `.gcode` file through the
Moonraker upload target.
