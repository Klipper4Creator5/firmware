; ====================================================================
; Creator 5 / Creator 5 Pro -- timelapse check
;
; A dry run for the timelapse pipeline: no filament, no heat, and once
; the machine is homed no move in THIS FILE goes below Z50. It exists
; to answer one question -- does a frame get captured, filed and
; rendered into a video that Mainsail can play -- without spending a
; spool to find out that the camera was never streaming.
;
; It is the timelapse companion to gcode/creator5-safe-moves.gcode, and
; it borrows that file's Z50 floor for the same reason: a first check is
; the wrong time to discover a Z offset with a nozzle.
;
; It answers, in this order:
;   does the disabled gate actually refuse a frame
;   does an unparked frame catch the head wherever it happens to be
;   does a PARKED frame put the head in the same place every time
;   does the job end with a rendered .mp4 in Mainsail's Timelapse tab
;
; WHAT IT DOES NOT ANSWER
;   Nothing about retract and unretract around a park: the extruder is
;   cold, so timelapse skips both and says so (see EXPECTED NOISE
;   below). Nothing about blobbing at the park point, or about how
;   parking paces a real print. Those need heat and filament -- run
;   gcode/creator5-feature-test.gcode with timelapse on for that.
;
; ---------------------------------------------------------------------
; BEFORE YOU START -- three gates this file CANNOT open for itself
; ---------------------------------------------------------------------
;   1  THE CAMERA MUST BE STREAMING. Open Mainsail and look at the
;      webcam panel first. Frames are fetched with wget straight from
;      mjpg-streamer at http://127.0.0.1:8080/?action=snapshot, and a
;      dead camera fails silently: the print runs, every frame is
;      empty, and the render at the end has nothing to render. An empty
;      panel means no camera -- fix that before running this.
;
;   2  TIMELAPSE MUST BE ENABLED IN MAINSAIL. There are two halves to
;      the switch and this file only owns one of them. The Klipper half
;      is TIMELAPSE_TAKE_FRAME's `enable` variable, which the phases
;      below set as they please. The Moonraker half is the component's
;      own `enabled` setting, which lives in Moonraker's database and
;      is reachable only from Mainsail's Timelapse tab or the
;      /machine/timelapse/settings endpoint. With that half off the
;      macro still parks, still pauses, still says it took a frame --
;      and the component drops every one on the floor. No gcode can
;      turn it on. Turn it on there, first.
;
;   3  MODE MUST BE 'LAYER MACRO', NOT HYPERLAPSE. Same tab. Hyperlapse
;      is time-driven: the component starts its own loop when the file
;      is selected and IGNORES every TIMELAPSE_TAKE_FRAME it sees, so
;      in that mode this whole file is a no-op with a camera running.
;      Hyperlapse cannot be exercised from a gcode file at all -- it is
;      started and stopped by the component, not by the print.
;
; ---------------------------------------------------------------------
; RUN IT AS A PRINT JOB, NOT FROM THE CONSOLE
; ---------------------------------------------------------------------
;   Upload it and press Print. Do not paste it into the console.
;   The component keys the whole job off two gcode responses it watches
;   for: "File selected" wipes the frame directory and starts a fresh
;   count, and "Done printing file" is what triggers the render. Pasted
;   into the console, neither ever fires -- the frames pile onto
;   whatever the last real print left behind, and nothing renders.
;
; ---------------------------------------------------------------------
; WHAT TO WATCH, IN ORDER
; ---------------------------------------------------------------------
;   The six numbered phases below are the same six the console prints
;   as "1/6" .. "6/6".
;
;   1  GET_TIMELAPSE_SETUP dumps the live settings to the console. Read
;      them. This is also the 'before' picture -- the tail of this file
;      puts it back.
;   2  Homing, then up to Z50. The one approach to the bed.
;   3  The refusal. Three frames are asked for with the Klipper half
;      switched off, and the console must answer
;        "Timelapse: disabled, take frame ignored"
;      three times. The frame counter must NOT move. A frame taken here
;      is a real failure -- it means the gate does not gate.
;   4  36 UNPARKED frames while the head walks a raster. Fast, no
;      pause, no park move. In the finished video the head is in a
;      DIFFERENT place in every frame. That is not a fault -- it is
;      exactly what an unparked timelapse of a real print looks like,
;      and it is why park mode exists.
;   5  24 PARKED frames over the same raster, parking at CENTER. Now
;      the head walks to X152.5 Y127.5 before each shot and goes back
;      afterwards. THE VERDICT IS IN THE VIDEO: the head must be in the
;      SAME place in every one of these frames. If it is smeared or
;      caught mid-travel, the camera is being read before the head has
;      settled -- raise `park_time` in Mainsail's Timelapse settings
;      (see PARK_TIME below, which is NOT the knob you want).
;   6  12 more parked frames at a CUSTOM park point, X40 Y40, with a
;      5 mm Z hop. Same verdict, different corner -- it proves the
;      custom position is honoured and not silently ignored.
;
;   Then the settings are restored and END_PRINT hands back. The render
;   fires by itself on "Done printing file" (autorender is on by
;   default). Watch for
;     "Timelapse: Rendering started" ... "Rendering finished"
;   and then look in Mainsail's Timelapse tab.
;
; ---------------------------------------------------------------------
; EXPECTED NOISE -- none of this is a fault
; ---------------------------------------------------------------------
;   "Timelapse: Warning, minimum extruder temperature not reached!"
;     -- once on the way into every parked frame and once on the way
;     out, i.e. twice per frame through phases 5 and 6. The extruder is
;     stone cold by design, so timelapse refuses to retract or unretract
;     and says so. Correct behaviour; it is the reason this file is
;     cheap to run. It also means the retract path is NOT under test.
;   "Timelapse: disabled, take frame ignored"
;     -- exactly three times, in phase 3, and nowhere else.
;
; ---------------------------------------------------------------------
; TWO TRAPS ON THIS MACHINE SPECIFICALLY
; ---------------------------------------------------------------------
;   DO NOT PARK RIGHT. timelapse derives its corner presets straight
;     from the axis limits, so PARK_POS=FRONT_RIGHT and BACK_RIGHT both
;     mean X310 -- and the tool docks are the lane at X~297. With a head
;     on the carriage that is a park move into the docks. CENTER
;     (X152.5 Y127.5, derived the same way and safely mid-bed) and an
;     explicit CUSTOM position are the safe choices, and they are the
;     only two this file uses. The same warning applies to whatever you
;     pick in Mainsail for your real prints.
;   PARKING ZEROES YOUR BABYSTEP. Every parked frame runs
;     SET_GCODE_OFFSET X=0 Y=0 -- upstream does it so a multi-tool
;     machine parks in one spot regardless of which tool is on. On this
;     printer the per-tool offsets are applied BELOW Klipper's gcode
;     offset (docs/toolchange.md) so they are untouched, but an X/Y
;     babystep you dialled in by hand is gone after the first frame.
;
; ---------------------------------------------------------------------
; PARK_TIME IS A RED HERRING
; ---------------------------------------------------------------------
;   The PARK_TIME= parameter sets the macro's park.time, and that number
;   feeds exactly one thing: the TEST_STREAM_DELAY helper. It does NOT
;   set how long the head waits at the park point, which is why this
;   file never passes it. The real dwell is the component's own
;   `park_time` (default 0.1 s), in Moonraker's settings next to the
;   enable switch. If phase 5 gives you a smeared head, that is the
;   number to raise.
;
;   TEST_STREAM_DELAY, the helper for tuning it, is deliberately NOT
;   called from this file: it travels to X305, which is inside the dock
;   lane. Run it by hand, from the console, with NO TOOL MOUNTED and the
;   head above Z5, if you need it.
;
; ---------------------------------------------------------------------
; THE SETTINGS THIS FILE CHANGES ARE LIVE ONLY
; ---------------------------------------------------------------------
;   _SET_TIMELAPSE_SETUP writes Klipper gcode variables. It does not
;   touch Moonraker's stored settings, so Mainsail's Timelapse tab will
;   disagree with the console for as long as this file is running, and
;   Moonraker pushes its stored values back over the top at the next
;   klippy_ready. The tail of this file restores the shipped defaults --
;   enable on, park off, quiet. If you had settings of your own, re-save
;   them in Mainsail or restart Klipper afterwards to get them back.
;
; ---------------------------------------------------------------------
; WHERE THE OUTPUT LANDS
; ---------------------------------------------------------------------
;   frames  /usr/data/anvil-timelapse/frameNNNNNN.jpg  (wiped at the
;           start of the next print, not at the end of this one)
;   video   /usr/data/timelapse/timelapse_<name>_<date>.mp4, listed in
;           Mainsail's Timelapse tab
;   Both are on flash, not /tmp -- /tmp is tmpfs and a tall print's
;   frames would be hundreds of megabytes of RAM.
;
;   This file takes 72 frames. At 30 fps that is about 2.4 seconds
;   of video, plus the five duplicated tail frames the renderer adds.
;   A very short video is the expected result, not a truncated one.
;
; ---------------------------------------------------------------------
; COPYING THIS INTO YOUR OWN SLICER
; ---------------------------------------------------------------------
;   The whole integration is one line, TIMELAPSE_TAKE_FRAME, in Orca's
;   "after layer change" gcode. Nothing hooks layer changes for you --
;   the component watches no ;LAYER_CHANGE marker and no layer counter.
;   The ;LAYER_CHANGE lines below are there to show where the call
;   belongs, and are the only reason this file has any.
;
;   This file names no tool as a bare `Tn` and carries no M104/M140, so
;   ff_print derives nothing from it and the implicit prepare has
;   nothing to heat or purge. With prepare at its shipped default that
;   prepare still runs G28, the mesh load and `G1 Z10 F1200` before this
;   file's first line -- see the tail of creator5-safe-moves.gcode for
;   what that means for the Z50 floor.
; ====================================================================

G90
M83

; --------------------------------------------------------------------
; 1  Report the setup before anything moves. Read it: the tail of
;    this file puts these same values back.
; --------------------------------------------------------------------
M117 1/6 setup
GET_TIMELAPSE_SETUP
TOOLCHANGE_STATUS
G4 P3000

; --------------------------------------------------------------------
; 2  Home, then up to the Z50 floor. The G28 wrapper docks a
;    mounted tool before homing Z -- watch for that.
; --------------------------------------------------------------------
M117 2/6 homing
G28
G1 Z50 F1200
G1 X125.000 Y125.000 F6000
G4 P1000

; --------------------------------------------------------------------
; 3  The disabled gate. Three frames asked for with the Klipper
;    half switched off. The console must refuse three times and the
;    frame count must not move. A frame taken here is a failure.
; --------------------------------------------------------------------
M117 3/6 gate: expect 3 refusals
_SET_TIMELAPSE_SETUP ENABLE=False VERBOSE=True
GET_TIMELAPSE_SETUP
TIMELAPSE_TAKE_FRAME
G4 P1000
TIMELAPSE_TAKE_FRAME
G4 P1000
TIMELAPSE_TAKE_FRAME
G4 P1000

; --------------------------------------------------------------------
; 4  36 unparked frames. No pause, no park move -- the shot is
;    taken wherever the head is. In the video the head is in a
;    different place every frame. That is the point of this phase:
;    it is what an unparked timelapse of a real print looks like.
; --------------------------------------------------------------------
M117 4/6 36 unparked frames
_SET_TIMELAPSE_SETUP ENABLE=True PARK_ENABLE=False VERBOSE=True
GET_TIMELAPSE_SETUP
;LAYER_CHANGE
G1 X40.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y176.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y176.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y176.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y176.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y176.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y176.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y210.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y210.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y210.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y210.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y210.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y210.000 F9000
TIMELAPSE_TAKE_FRAME

; --------------------------------------------------------------------
; 5  24 parked frames at CENTER (X152.5 Y127.5). The head now
;    walks to the park point before every shot and returns after.
;    THE VERDICT: in the video the head must be in the SAME place in
;    every one of these frames. A smeared or mid-travel head means
;    the snapshot is being taken before it settles -- raise the
;    component's park_time in Mainsail, not the macro's PARK_TIME.
;
;    Expect the cold-extruder retract warning twice per frame.
;
;    NOT front_right or back_right: those derive from the axis
;    limits and land on X310, in the dock lane at X~297.
; --------------------------------------------------------------------
M117 5/6 24 parked frames, centre
_SET_TIMELAPSE_SETUP ENABLE=True PARK_ENABLE=True PARK_POS=CENTER VERBOSE=True
GET_TIMELAPSE_SETUP
;LAYER_CHANGE
G1 X40.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y108.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y142.000 F9000
TIMELAPSE_TAKE_FRAME

; --------------------------------------------------------------------
; 6  12 parked frames at a CUSTOM point, X40 Y40, with a 5 mm Z
;    hop. Same verdict as phase 5, different corner: it proves the
;    custom coordinates are honoured and not quietly ignored.
;
;    PARK_POS=CUSTOM must come in the SAME call as the CUSTOM_POS_*
;    values or later -- the coordinates are resolved when PARK_POS
;    is parsed, so setting them afterwards has no effect until the
;    next PARK_POS.
; --------------------------------------------------------------------
M117 6/6 12 parked frames, custom
_SET_TIMELAPSE_SETUP ENABLE=True PARK_ENABLE=True CUSTOM_POS_X=40 CUSTOM_POS_Y=40 CUSTOM_POS_DZ=5 PARK_POS=CUSTOM VERBOSE=True
GET_TIMELAPSE_SETUP
;LAYER_CHANGE
G1 X40.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y40.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X210.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X176.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X142.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X108.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X74.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME
;LAYER_CHANGE
G1 X40.000 Y74.000 F9000
TIMELAPSE_TAKE_FRAME

; --------------------------------------------------------------------
; Restore the shipped defaults -- enable on, park off, quiet -- and
; hand back to the machine end block. The render is NOT called from
; here: autorender fires by itself on "Done printing file", and
; calling TIMELAPSE_RENDER as well would render the same frames
; twice. Add it above END_PRINT only if you want the job to block
; until the video is written.
; --------------------------------------------------------------------
M117 done: 72 frames
_SET_TIMELAPSE_SETUP ENABLE=True PARK_ENABLE=False VERBOSE=False
GET_TIMELAPSE_SETUP
G1 Z50 F1200
TOOLCHANGE_STATUS

;end_gcode
END_PRINT
;end_gcode end
; 72 frames taken; no filament used and no heater ever given a target.
