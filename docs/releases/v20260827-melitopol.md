Releases are named for a Ukrainian city under occupation. This one is
**Melitopol**, taken by russian forces on the first day of the full-scale
invasion, 24 February 2022, and occupied ever since. Its mayor was abducted
within days for refusing to cooperate; the city has been under occupation
longer than almost any other in Ukraine.

*https://www.youtube.com/watch?v=w3uaZEQKJpY*

---

The mod's process supervision moves to s6 (cross-built for mipsel-musl,
toolchain courtesy of Bootlin's toolchains.bootlin.com project), and
FF_PYTHON moves with it: nginx, the camera and Moonraker are now real s6
services with readiness gated on "actually listening", not "was forked".
Moonraker itself runs on a CPython 3.13 this build cross-compiles, with a
working `_sqlite3` -- the module FlashForge's bundled 3.8.2 never had --
measured serving through the full boot path (S40s6's scandir,
S62moonraker, a kill -9 respawn, a stop that stays stopped) before this
line was written. Klipper is not part of this switch: it keeps running on
FlashForge's own interpreter, started independently by
/usr/prog/klipper/start.sh.

Moonraker and the camera stream now yield CPU to Klipper on this printer's
two-core SoC (NICE_MOONRAKER / NICE_CAM in anvil.conf, 0 disables); insurance
against Klipper missing a step-generation deadline and shutting down with
"Timer too close" mid-print, not a fix for it. HelixScreen's own settings
-- theme, brightness, touch calibration, spool assignments -- now survive
a mod update instead of being reset to first-run defaults, and HelixScreen
itself is bumped to v0.99.115-creator5.2.

Full replica suite, real stock packages: 23 passed, 0 failed, 0 skipped.
