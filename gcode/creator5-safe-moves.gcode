; ====================================================================
; Creator 5 / Creator 5 Pro -- safe first check
;
; The feature print with the heat and the filament taken out. Once the
; machine is homed, no move in THIS FILE goes below Z50 (the implicit
; prepare that runs before it does -- see the note at the end); nothing
; extrudes, and no heater is ever given a target. It is the file to run
; FIRST on a freshly flashed machine, so that the expensive way to
; discover a wrong Z offset or a dock that does not latch is not a
; nozzle in the plate.
;
; The one approach to the bed is G28 itself, which has to touch the eddy
; sensor to find Z. That is the moment to have a finger on the stop.
;
; It answers three questions, in this order:
;   does the G28 wrapper home safely, docking a mounted tool first
;   does a tool change actually latch and release
;   do the fans, the chamber gate and END_PRINT do what they claim
;
; WHAT IT DOES NOT ANSWER
;   Nothing about the print Z offset, the nozzle clean, the bed mesh or
;   extrusion. Those need heat and filament and are what
;   gcode/creator5-feature-test.gcode is for. Run this one, watch it,
;   then run that one.
;
; BEFORE YOU START
;   * no filament needed, and none should be pushed -- there is not a
;     single E word in this file.
;   * T0 and T1 must be docked or mounted. Change the SELECT_TOOL lines
;     below for other tools; they are the only place a tool is named.
;   * clear the plate. Nothing comes near it, but a first check is the
;     wrong time to find out your clip is 60 mm tall.
;   * KEEP THE EMERGENCY STOP WITHIN REACH. This is the first time the
;     machine moves under this firmware.
;
; TWO REFUSALS THAT ARE CORRECT BEHAVIOUR, NOT FAULTS
;   "Not calibrated: station_z=None ..."   -- Mainsail's print entry
;     point gates every job on the calibration, and it runs before this
;     file's first line. On a machine that has not been calibrated yet,
;     that refusal is the gate working. To go ahead anyway, deliberately:
;       SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1
;   "Refusing to home Z: cannot tell whether a tool is mounted"
;     -- the dock switches disagree. Run TOOLCHANGE_STATUS and find the
;     one that is lying before you move anything.
;
; This file names no tool as a bare `Tn`, and carries no M104/M140, so
; ff_print derives nothing from it and the implicit prepare has nothing
; to heat or purge -- unlike the feature print, which wants prepare at 0.
;
; With prepare at 1 (the shipped default) the implicit START_PRINT still
; runs G28, BED_MESH_PROFILE LOAD=MESH_DATA and `G1 Z10 F1200` before
; this file's own first line. That Z10 is in the raw eddy frame, ~6.8 mm
; physical. The G28 and the offset move before it also take Z well below
; 50 -- homing is what drops you, as the opening note says. None of it
; heats or extrudes. Set prepare to 0 if you want the Z50 floor to hold
; from power-on to the last line.
; ====================================================================

G90
M83

; --------------------------------------------------------------------
; 1  Report the geometry before anything moves
; --------------------------------------------------------------------
M117 1/6 status
TOOLCHANGE_STATUS
TOOL_OFFSET_STATUS
G4 P2000

; --------------------------------------------------------------------
; 2  Home. The G28 wrapper docks a mounted tool before homing Z --
;    watch for that. Homing Z with a head on drives it into the plate,
;    which is the whole reason the wrapper exists.
; --------------------------------------------------------------------
M117 2/6 homing
G28
G1 Z50 F1200
G4 P1000

; --------------------------------------------------------------------
; 3  The bed, at 50 mm. Slow lap first, then a fast one: a belt that
;    skips does it at speed, and the second lap ending where the first
;    did is the check.
; --------------------------------------------------------------------
M117 3/6 slow lap
G1 X125.000 Y125.000 F6000
G1 X20.000 Y20.000 F6000
G1 X230.000 Y20.000 F6000
G1 X230.000 Y230.000 F6000
G1 X20.000 Y230.000 F6000
G1 X20.000 Y20.000 F6000
G1 X125.000 Y125.000 F6000
G4 P1000

M117 3/6 fast lap
G1 X20.000 Y20.000 F18000
G1 X230.000 Y20.000 F18000
G1 X230.000 Y230.000 F18000
G1 X20.000 Y230.000 F18000
G1 X20.000 Y20.000 F18000
G1 X125.000 Y125.000 F18000
G4 P1000

; A diagonal each way. On corexy a single failing motor shows here and
; nowhere else -- the head tracks an L instead of a diagonal.
M117 3/6 diagonals
G1 X20.000 Y20.000 F9000
G1 X230.000 Y230.000 F9000
G1 X20.000 Y230.000 F9000
G1 X230.000 Y20.000 F9000
G1 X125.000 Y125.000 F9000
G4 P1000

; Z, well clear of everything.
M117 3/6 Z travel
G1 Z150.000 F1200
G1 Z50.000 F1200
G4 P1000

; --------------------------------------------------------------------
; 4  Tool changes, cold and empty.
;
;    SELECT_TOOL rather than a bare `T0`: the same code path, but
;    ff_print scans a file's first bare Tn to decide which tool to
;    prepare, and a file that names one would get a purge it does not
;    want. [ff_toolchange] also ships restore_axis unset, so a change
;    restores NO position -- every move after one re-states itself
;    below, which is what your own sliced files must do too.
; --------------------------------------------------------------------
M117 4/6 grab T0
SELECT_TOOL T=0
G1 Z50.000 F1200
G1 X125.000 Y125.000 F6000
G4 P2000
TOOLCHANGE_STATUS

M117 4/6 change to T1
SELECT_TOOL T=1
G1 Z50.000 F1200
G1 X125.000 Y125.000 F6000
G4 P2000
TOOLCHANGE_STATUS

M117 4/6 park
TOOLCHANGE_PARK
G1 Z50.000 F1200
G4 P1000
TOOLCHANGE_STATUS

; --------------------------------------------------------------------
; 5  Fans, one at a time. P101 is a no-op by design: printer.macro.cfg's
;    M106 has that branch commented out. Bare M106 and P1 are the part
;    fan, P2 the chamber loop + cool pair, P3 the chamber fan.
; --------------------------------------------------------------------
M117 5/6 P101 -- nothing should spin
M106 P101 S255
G4 P3000
M117 5/6 part fan full
M106 S255
G4 P3000
M117 5/6 part fan half
M106 S128
G4 P3000
M117 5/6 part fan off
M106 S0
G4 P3000
M117 5/6 P2 chamber loop + cool
M106 P2 S255
G4 P3000
M106 P2 S0
M117 5/6 P3 chamber fan
M106 P3 S255
G4 P3000
M106 P3 S0
G4 P1000

; --------------------------------------------------------------------
; 6  The chamber gate. A Pro starts heating. A plain Creator 5 answers
;    "no chamber heater on this model -- ignoring TARGET=40.0" and
;    carries on. An ABORT here is a real failure. Set back to 0 straight
;    away: this file is not a soak test.
; --------------------------------------------------------------------
M117 6/6 chamber gate
M141 S40
G4 P3000
M141 S0

M117 6/6 end
TOOLCHANGE_STATUS

;end_gcode
END_PRINT
;end_gcode end
