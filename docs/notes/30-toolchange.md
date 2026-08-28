# Toolchange: sequences, sensors, mounted-tool state

Address-verified against the live binary (`CommMgr` methods). Ported in
`pkgs/klipper/prog/klippy/extras/ff_toolchange.py`; divergences are deliberate and listed at the end.

## Physical model

- 4 docks on the right, X ≈ 297 (250 and 280 are the staging and approach
  waypoints, `x_safe` / `x_approach`), per-dock X/Y from `extruder.json`
  (`x/y_check_pos..3`), station base `x/y/z_station_pos`.
- Lock motor on the carriage grabs/releases the head. Its endstop is registered on
  `manual_stepper gear_stepper`; `MOTOR_GRAB`/`MOTOR_RELEASE` are STOP_ON_ENDSTOP-style
  moves that respond "endstop triggered / not triggered".
- Sensors (`gcode_button`): `extruder_pos1..4` = head present in dock N;
  `extruder_grab(1..4)` = something locked on the carriage. The app also names
  `servo_min`/`servo_max` (lock mechanism end positions), but this printer's
  config declares neither -- see `10-hardware.md` for the family that actually
  exists.
- Invariant checked constantly: a head is EITHER in its dock OR on the carriage
  (E0127-134, E0139-146 cover every disagreement).

## Grab — `doGrabExtruderLatest` @0x7a8190

1. Home gate (abort if not homed, E0160).
2. Dock-must-be-OCCUPIED precheck: 20 × 50 ms polls of `checkInLocation(tool)`;
   failure → E0127+tool, no motion.
3. `SET_VELOCITY_LIMIT ACCEL=8000`; `SET_GCODE_OFFSET X=0 Y=0 MOVE=1 MOVE_SPEED=100`.
4. Approach, once, before the retry loop: `G1 X250 F<fast>` (`x_safe`),
   `G1 Y<dockY>`, `G1 X280` (`x_approach`).
5. Then up to 3 attempts. Each begins by re-engaging the dock —
   `G1 X<dockX> F<slow>` (+`grabOffset` correction from test.json) — which is
   what undoes the previous attempt's back-off. Poll the grab sensor for up to
   1 s; on success `MOTOR_GRAB`, `G1 X<dockX-20> F4800` (the app's literal
   pullback feed, not the calibrated one), `MOTOR_GRAB2`, and leave the loop.
   On failure back off to `G1 X280` and wait. `G1 X250 F1500` is the retreat
   after the loop, not part of an attempt.
6. Verify: dock sensor released AND grab sensor pressed → else E0051+tool
   (`ERR_GRAB_VERIFY_BASE`; the app's own code here was not recovered).
7. Apply per-tool G-code offsets (see `40-offsets.md`).
8. `SET_VELOCITY_LIMIT ACCEL=20000`.

Feedrates: test.json `grabSpeed`/`grabSpeedSlow` × 60, fallbacks 24000/6000.

## Release — `doReleaseExtruderLatest` @0x7aa394

Not symmetric with grab; the details matter:

1. Home gate.
2. Dock-must-be-EMPTY precheck, 20 × 50 ms; failure → E0131+tool, no motion.
3. `ACCEL=8000`; clear X/Y offsets. No ACTIVATE_EXTRUDER anywhere on release.
4. Approach once: `G1 X250 F<fast>`, `G1 Y<dockY>`. **No X280 stage** (grab-only).
5. Up to 3 attempts, each: `G1 X<dockX-10>` (no F, modal feed) → `G1 X<dockX> F<slow>`
   (slow fallback here is **5400**, not 6000) → wait up to 20 × 50 ms for the dock
   sensor to read "seated" → only then `MOTOR_RELEASE` → supervise the lock endstop;
   "ended untriggered" → re-issue MOTOR_RELEASE, max 3 sends per attempt.
6. Success only: retreat `G1 X250 F4800`. On failure the carriage stays at the dock.
7. Verify: in dock AND grab sensor clear → else E0144; all-attempts-exhausted →
   E0135+tool.
8. Unconditional tail (success AND failure): `MOTOR_STOP`, `ACCEL=20000`
   (hence try/finally in the port).

In-process advantage: the app greps response text for "endstop (not) triggered" and
polls 40 × 50 ms; a klippy extra just catches `printer.command_error` from
`MOTOR_RELEASE` synchronously — a strictly stronger signal.

## Mid-print change (`changeExtruderChannel`)

Save state (`SAVE_GCODE_STATE NAME=PAUSE_state`), manage temps, release old → grab
new, prime `G1 E15 F240` / retract with part-fan ooze control, `RESTORE_GCODE_STATE
MOVE=1`, restore `M220`.

## Which tool is mounted

The app persists an imperative index (`now_extruder` in extruder.json), reset to −1 by
homing, and never derives it from sensors — because its grab-sensor read
(`getGrabSensorStatus` @0x76f294) is a plain OR of four bytes: it knows only *that*
something is held, never *which*.

`ff_toolchange.py` derives identity instead: `extruder_pos1..4` are per-tool dock
switches, so **the mounted tool is the one whose dock is empty** (while the grab
sensor is pressed). Exactly-one-empty + held → that tool; all-occupied + held, or
several-empty + held → abort (faulty switch / ambiguous — refusing beats guessing,
since guessing wrong would drop the carried tool into another tool's dock).
Nothing is persisted; the value cannot go stale. `now_extruder` is never written
(see `40-offsets.md` on why writing the JSON is forbidden), and it is no longer
read either: the JSON reader was removed, so `TOOLCHANGE_STATUS` reports only
sensors and Klipper config and has nothing to compare against.

## Deliberate divergences in the port

1. No 4th unsupervised `MOTOR_RELEASE` (the app fires one before checking its own
   failure counter — energising the lock with nobody watching).
2. No `M119` refresh polls — Klipper's `gcode_button` state is event-driven; the
   20 × 50 ms *gating* semantics are kept as wall-clock deadlines.
3. `now_extruder` not written; identity is sensor-derived.
4. Modal-state restore added: the app leaks G90 + last feedrate + accel into whatever
   runs next; the port snapshots and restores absolute/relative mode, feedrate, and
   the pre-sequence accel limit.
