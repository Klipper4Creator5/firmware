# Bed mesh

No build plate is perfectly flat. A bed mesh is a map of yours — the printer
probes a grid of points across it and remembers how far each one sits above
or below the ideal plane, so the first layer can follow the plate instead of
digging into one corner and floating over another.

Your printer already has one. FlashForge probed a mesh at the factory and
saved it, the mod imports it with the rest of your machine's numbers, and
**every print loads a mesh before it starts** — that is not optional here, and
it was not optional on the stock firmware either.

So for most people this page is nothing to do.

---

## When to probe a new one

The factory mesh describes the plate the printer left the factory with. Probe
a fresh one when that is no longer the plate you have:

* you have swapped or replaced the build plate
* the printer has been moved any distance, or the bed has been worked on
* first layers are consistently good in one region of the bed and bad in
  another — the signature of a mesh that no longer matches

A first layer that is uniformly too high or too low across the *whole* plate
is not this. That is nozzle offset, and it belongs to
[XYZ tool calibration](calibration.md).

---

## Probing one

With the plate on and the bed at the temperature you print at — a hot plate
is a different shape from a cold one:

```gcode
G28
BED_MESH_CALIBRATE
```

It probes a 10×10 grid with the sensor on the carriage and takes a few
minutes. The result is live immediately, and HelixScreen's bed-mesh screen
will draw it.

That result is not saved yet, and it is not yet the mesh a print will load.
To keep it, and to have prints use it:

```gcode
BED_MESH_PROFILE SAVE=MESH_DATA
SAVE_CONFIG
```

`MESH_DATA` is the name of the mesh a print loads. Saving over it replaces
the factory mesh with yours, permanently — that is the point, but it is also
the reason to be sure the probe ran cleanly before you do it. `SAVE_CONFIG`
restarts Klipper, so do it between prints.

---

## Checking it

```gcode
BED_MESH_OUTPUT
```

prints the probed points, and HelixScreen draws the same data as a surface.
What you are looking for is a shape that looks like a plate — a gentle bow or
tilt — rather than one point far away from its neighbours, which usually
means the probe was disturbed rather than the bed being that shape.
