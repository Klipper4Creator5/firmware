# Offsets & per-unit config: where the numbers live and how they are applied

## There is exactly one config directory

`Config::load` reads `/usr/data/firmwareRes/config/` and nothing else
(`initManagers` @0x412efc; `/usr/data/config/test.json` is only a one-shot install
hook — copied in, then deleted). Files: `general.json filament.json extruder.json
network.json time.json print.json test.json zoffset.json total.json userInfo.json`.

They are **not strict JSON** — each has a trailing C-style comment after the closing
brace, so use `json.JSONDecoder().raw_decode()`.

Key files:

- **extruder.json** (`loadExtruderConfig` @0x64f7f8): `t0..t3_offset_x/y/z` (per-tool
  nozzle calibration), `x/y_check_pos..3` (per-dock coords), `x/y/z_station_pos`,
  `now_extruder`.
- **test.json** (@0x654380): `grabSpeed`, `grabSpeedSlow` (mm/s, ×60; fallbacks
  24000/6000 grab, 5400 release-slow), `grabOffset` (dock X correction),
  `tempOffset` (0.00045 — see below), `generalFirmware`.
- **zoffset.json** (@0x65621c): `z_offset_t1..t4` — the USER's per-tool Z tune from
  the UI menu, **1-based** (`z_offset_t1` is tool 0). Not calibration data.

## Never write these files

`Config::syncExtruderConfig` @0x651388 rewrites the whole file from the app's
in-memory struct on every toolchange — anything written externally is clobbered, and
a partial write could revert unrelated per-unit calibration. `ff_toolchange.py` only
READS them. Precedence per option: `printer.cfg` > firmwareRes JSON > app fallback;
`TOOLCHANGE_STATUS` shows each value's provenance; `TOOLCHANGE_RELOAD` re-reads after
a touchscreen recalibration.

## Per-tool offsets — `setGrabGcodeOffsetMgr` @0x77f1dc

Applied on every grab (print start `serialPrint` and mid-print
`changeExtruderChannel` both pass the enabling flag):

```
X = t<tool>_offset_x - t<base>_offset_x
Y = t<tool>_offset_y - t<base>_offset_y
Z = z_offset_t<tool+1> + m_zOffset + (t<tool>_offset_z - t<base>_offset_z)
```

emitted as `SET_GCODE_OFFSET X=.. Y=.. MOVE=1 MOVE_SPEED=100` +
`SET_GCODE_OFFSET Z=.. MOVE=1 MOVE_SPEED=40` (3 decimals). They are **differences
against a base tool** (default T0; the app rebases to the file's initial tool via
`setBaseExtruder` — the base term cancels algebraically either way). `m_zOffset` is
the once-per-print absolute base (below) plus any live babystep the user dialed in.

Example spread on one unit: T1 sits (−0.008, −0.599, −0.089) from T0 — with offsets
omitted, T1 prints ~0.6 mm out in Y.

Babystep handling in the port: Klipper folds babysteps into the same G-code Z offset,
so the port recovers it as `current_offset − last_applied_tool_term` and re-adds it,
mirroring the app's separate register.

## The absolute print Z offset — `BuildPage::startPrint` @0x9fc148

The single most dangerous fact of the whole project: **the eddy probe's G28 Z is NOT
nozzle-at-bed zero** — after homing, the nozzle sits ~3.2 mm below where the
coordinate claims, and nothing physical prevents driving it into the plate
(`position_min: -10`).

Two sensors exist: the eddy coil on the head (used by G28 Z / bed mesh — triggers at
a coil-to-bed distance) and a fixed nozzle-touch sensor below the bed plane. Factory
calibration stores, in extruder.json:

- `z_station_pos` — Z where the EDDY triggered over the fixed sensor (≈ −1.68)
- `t0..t3_offset_z` — Z where each NOZZLE touched the same sensor (≈ +1.5)

so `t<n>_offset_z − z_station_pos` ≈ the 3.19 mm gap between the eddy trigger plane
and tool n's nozzle plane. At print start the app computes:

```
m_zOffset = t<tool>_offset_z − z_station_pos
          + (nozzle_temp − 120) × tempOffset          # thermal expansion, 0.00045/°C
          + 0.08 if bed_temp ≥ 100
          − 0.06 if layer_height ≤ 0.10
```

and sends `SET_GCODE_OFFSET X=0 Y=0 Z=<m_zOffset + z_offset_t<n+1>> MOVE=1` right
before starting the print thread. Typical value: **Z ≈ +3.24** for PLA 220/80/0.25.
A Mainsail print that skips this runs the whole job ~3.2 mm low — this exact miss
destroyed the first test print's first layer.

The port: `TOOLCHANGE_SET_PRINT_OFFSET NOZZLE= BED= LAYER= [TOOL=]` implements the
formula from the same JSON; `START_PRINT` calls it after the first grab; the babystep
recovery above carries the base through every subsequent toolchange (verified
numerically against this unit's JSON: T0 220/80/0.25 → 3.240; later T2 grab →
3.197 = m_z + (t2−t0)). END/CANCEL reset Z=0.
