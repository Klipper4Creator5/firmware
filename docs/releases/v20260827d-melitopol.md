Releases are named for a Ukrainian city under occupation. This one is
**Melitopol** again, taken by russian forces on the first day of the full-scale
invasion, 24 February 2022, and occupied ever since. Its mayor was abducted
within days for refusing to cooperate; the city has been under occupation
longer than almost any other in Ukraine.

*https://www.youtube.com/watch?v=w3uaZEQKJpY*

---

**HelixScreen moves to v0.99.115-creator5.5.** The auto pressure-advance
calibration screen now recognizes the Creator 5 Pro's own `FF_PA_CALIBRATE`
sweep as a provider, detected through the `ff_pa` klippy extra rather than a
macro. Tool changers with a per-tool Z correction get a target selector in the
tune overlay, so squishing one nozzle no longer drags every other tool's
height with it — hidden on machines without that capability. A clipped
"locked while runnin" note in the calibration column is fixed, and the
filament panel's design tokens are regenerated to drop a couple of stale
entries left over from the last rebuild.

**FF_PA_CALIBRATE and FF_PA_PROBE stop leaving the hotend hot.** `TEMP=` on
either macro heated the nozzle for the sweep and then never put the target
back, so a calibration run left the hotend sitting at its sweep temperature
indefinitely. Both macros now snapshot the heater's target before heating and
restore it in a `finally`, so the heater comes back down even when the run
fails partway through. A target the operator set by hand before calling the
macro — no `TEMP=` given — is left alone, the same rule the rest of the
calibration guard already follows.
