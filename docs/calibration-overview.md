# Calibration

**Your printer is already calibrated when it starts.** That is worth saying
first, because "flash custom firmware" usually means "and now measure
everything from scratch".

The first time the mod boots, it reads the per-unit numbers the stock
firmware kept for your machine — where each dock is, where each nozzle sits,
where the calibration station is — and saves them into Klipper's own
configuration. They are the numbers FlashForge measured for your printer at
the factory, and the same ones the stock application was printing with an
hour earlier. Nothing is reset, and you do not start from zero.

So on a normal first boot the machine comes up knowing its own geometry, and
`TOOL_OFFSET_STATUS` shows a nozzle position for every tool rather than
`NOT CALIBRATED`.

One of them runs without you: a [bed mesh](bed-mesh.md) is loaded at the
start of every print, from the map FlashForge probed at the factory.

The pages in this section are the calibrations you run yourself. What each
one actually measures, and how those numbers reach a first layer, is
[How calibration works](how-calibration-works.md).
