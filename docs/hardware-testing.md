# Hardware testing

CI installs the package into a replica of the printer -- the real
`rootfs.squashfs` running under qemu-mipsel, on the printer's own busybox and
`unTar` (see [printer-replica.md](printer-replica.md)) -- and proves the
machine would still boot. What it cannot do is drive the screen, the MCUs, the
toolchanger or a print. This is the on-hardware procedure.

There is one flash: the firmware package for your model.

**Rule: have the stock FlashForge package for your model on a spare stick
before you flash anything.** Flashing it back is the uninstall, and it is the
only recovery step that needs nothing but a USB port — no ssh, no screen. It
is proven by `make test-recovery`, which installs the mod into the printer
replica and then flashes the stock package over it.

---

## Step zero: check the model gate

Every package carries a gate. Its `runFirmwareExe.sh` has `MACHINE=` / `PID=`
baked in, and compares them against the values `app_startup.sh` passes from
the firmware already on the printer. A mismatch is **refused** with
"Firmware does not match machine type" — it will not install, and it is not a
valid recovery image either.

| Model | MACHINE | PID |
|---|---|---|
| Creator 5 | `Creator5` | `0028` |
| Creator 5 Pro | `Creator5Pro` | `0029` |

The gate is not cosmetic: the two models ship **different `firmwareExe`
binaries**, so a package must be built from the stock package for its own
model. `make release` builds both.

Find yours in Settings → About, or in
`/usr/data/firmwareRes/config/general.json` (`machineName`), and set
`TARGET_MACHINE` in `config.env`. Then:

```sh
make build && make verify          # one model
make release                       # both, into dist/
```

`verify.sh` fails loudly on a mismatch. **You must start from a stock package
built for your own model** — the mod inherits the gate from whatever package
you unpack.

## Before the first flash

- [ ] Put a copy of the **stock FlashForge package for your model** on a spare
      USB stick and keep it physically separate. That is your recovery image:
      flashing it restores every file the mod touches (proven by
      `make test-recovery`). Check it is the right model first — see above.
- [ ] Note your printer's serial number (Settings → About). The factory image
      restores a placeholder serial and you may need to put yours back.
- [ ] Confirm you can reach the printer's IP.
- [ ] `make test` passes.
- [ ] `make rootfs && make test-install` passes — this parses every script that
      will run on the printer using the printer's own busybox ash.

Two USB sticks, FAT32, both packages at the **root** of the stick (not in a
folder). Ship both filenames (`Creator5-*` and `Creator5Pro-*`): the Pro's
boot script globs `Creator5Pro-*.tgz`, the non-Pro globs `Creator5-*.tgz`.

---

## The flash (`make build`)

One flash brings up everything: a root password you know, Mainsail and
moonraker, the forked Klipper with the toolchanger extras, and HelixScreen on
the touchscreen in place of FlashForge's UI.

**The root password is generated on the printer.** Nothing is baked into the
package: the installer picks a random one, sets it, and writes it to
`anvil-password.txt` on the USB stick you flashed from. Pull the stick after
the flash and read it — then save the password somewhere safe and delete the
file. If the stick is not writable no password is set at all, and the install
log says so.

To choose your own instead, set it before you build:
```sh
openssl passwd -6 'your-password'      # paste into ROOT_PW_HASH in config.env
```

ssh works because the stock rootfs already ships `/usr/sbin/dropbear` and an
enabled `/etc/init.d/S50dropbear` — port 22 is already open on a stock
printer, there is simply no published password. That shell is your recovery
channel, so confirm it before you touch anything else.

**Before flashing**, re-read the warnings about Z offsets in
[docs/toolchange.md](toolchange.md). A wrong offset drives the nozzle into
the plate.

Understand the safety net first, because FlashForge's UI is gone from the
screen and there is nothing to fall back to:

- ssh and Mainsail do not depend on the screen. `/etc/init.d/S50dropbear` is
  stock and runs long before the UI, and `init.d/S60web` starts nginx and
  moonraker independently. They are your way in when the screen is dark.
- `init.d/S70klipper` owns Klipper startup, because on stock firmware it was
  `firmwareExe` — not any init script — that ran `/usr/prog/klipper/start.sh`.
  Without this the printer would boot to a working screen and be unable to
  move.
- If the UI dies repeatedly, `SAFE-MODE` latches after 3 boots and the printer
  boots **headless** — no UI started at all — rather than crash-looping. ssh
  and Mainsail stay up. Delete `/usr/data/anvil/SAFE-MODE` to try again.

**Go/no-go, in this order — with the emergency stop within reach:**

Access first, so that everything below is diagnosable:
- [ ] `ssh root@PRINTER` gets you a shell (password from `anvil-password.txt` on the stick)
- [ ] `http://PRINTER/` loads Mainsail
- [ ] Mainsail shows the printer as **ready**, not "Klipper reports: ERROR"

If Mainsail loads but Klipper errors, stop here and read
`/usr/data/logs/printer.log` over ssh. Do not go on to motion.

Then the screen:
- [ ] HelixScreen appears on the touchscreen
- [ ] Klipper is still running — this is the one people miss
- [ ] heaters and motion respond from the touchscreen

Then motion, which is the part that can damage the machine:
- [ ] `ssh root@PRINTER 'grep -i error /usr/data/logs/printer.log | tail'` is clean
- [ ] `TOOLCHANGE_STATUS` responds in the Mainsail console
- [ ] home all axes — watch the first Z move
- [ ] one tool change, by hand, at temperature
- [ ] `gcode/creator5-safe-moves.gcode` — cold, 50 mm above the plate
- [ ] `gcode/creator5-feature-test.gcode` — the real thing, two tools

## The two verification files

`gcode/` holds them. They are hand-maintained G-code, not generated: send them
to the printer the way you send any print — Mainsail's upload, or OrcaSlicer's
Klipper/Moonraker target. Each one's own header repeats everything below, so
whoever is standing at the machine has it in front of them.

### First: `creator5-safe-moves.gcode`

The feature print with the heat and the filament taken out. Once homed, no move
in it goes below Z50; nothing extrudes and no heater is given a target. It
answers three questions — does the `G28` wrapper home safely, docking a mounted
tool first; does a tool change latch and release; do the fans, the chamber gate
and `END_PRINT` do what they claim — and it answers them before a nozzle can
reach the plate.

It names no tool as a bare `Tn` and carries no `M104`/`M140`, so `ff_print`
derives nothing from it and the implicit prepare has nothing to heat or purge.
That makes it safe whether `FF_BEFORE_PRINT_START.prepare` is 0 or 1.

Two refusals it may produce are the gates working, not faults: the calibration
refusal from Mainsail's print entry point (override deliberately with
`SET_GCODE_VARIABLE MACRO=_FF_JOB VARIABLE=allow_uncalibrated VALUE=1`), and
"Refusing to home Z: cannot tell whether a tool is mounted", which means the
dock switches disagree — run `TOOLCHANGE_STATUS` and find the one that is lying.

### Then: `creator5-feature-test.gcode`

Not a model. One file that drives every macro the mod adds, in the order a real
print drives them, and leaves something on the plate you can measure:

| Phase | What it proves |
|---|---|
| start block | `START_PRINT` with `TOOLS=`: the preflight gate, then one purge + wipe per tool at the chute while the bed heats |
| 0 | `TOOLCHANGE_STATUS` / `TOOL_OFFSET_STATUS` dumped into `printer.log` alongside the print itself |
| 1 | nested squares, one ring per tool, 2 mm apart. Cold, the gap on left vs right is that tool's X offset error; front vs back its Y |
| 2 | a solid single first layer — squish is the verdict on `TOOLCHANGE_SET_PRINT_OFFSET` |
| 3 | the `M106 P<n>` fan map, one target at a time with a dwell |
| 4 | `M141`: a Pro heats, a plain Creator 5 says so and prints on. An abort here is a real failure |
| 5 | a tower with one tool change per layer, hot, mid-print |
| 6 | `END_PRINT` via the machine end block |

Two things it deliberately does **not** do. It never calibrates —
`TOOL_OFFSET_CALIBRATE` and `STATION_CALIBRATE` need the build plate off, which
a print does not have, so the file only reads the geometry. And it contains no
`PAUSE`: press Pause in Mainsail during the tower and then Resume, which is the
one check that wants a human at the machine.

Unlike the safe file, this one **needs** the implicit prepare turned off — it
is the deliberate exception, because it carries its own `START_PRINT` with the
`TOOLS=` list the automatic path cannot derive. For this print only:

```
SET_GCODE_VARIABLE MACRO=FF_BEFORE_PRINT_START VARIABLE=prepare VALUE=0
```

and put it back afterwards, with `VALUE=1` or simply a `RESTART`.

Preparing twice misplaces nothing, but it re-homes and re-purges every tool for
no reason.

**Do not persist the 0** by editing `variable_prepare`. Every ordinary file
printed here relies on the automatic path: the stock Orca profile calls no
`START_PRINT` and carries no `G28`, so with prepare off nothing homes or heats
the bed and the profile's first move — `G1 Z5 F2400` — runs on unhomed axes.

It is set up for T0 and T1 at 220 °C on a 60 °C bed. To exercise different
tools, edit the `TOOLS=` list in `START_PRINT` and the `T<n>` lines in the body
to match — `make test-py` will tell you if the two disagree, which is the one
mistake that costs a print.

### Keeping them honest

`make test-py` checks both files against the shipped macros and the configured
axis limits: every command in them must be one `payload/klipper/config/` or
`payload/klipper/extras/` defines, `TOOLS=` must list every tool the feature
print uses, and the safe file must stay cold and above Z50. A renamed macro
breaks the suite rather than the print.

The `.cfg` includes are **not** wired up automatically — a tuned `printer.cfg`
is never modified. New files arrive as `*.mod-new`. Add the includes by hand
in the order given in the toolchanger README, then run
`FF_IMPORT_FIRMWARE_CONFIG` once.

**Recovering from a bad UI, in increasing severity:**
```sh
ssh root@PRINTER
/usr/data/anvil/init.d/S80ui status        # what did it choose, and why
touch /usr/data/anvil/SAFE-MODE            # boot headless next time (ssh + Mainsail only)
reboot
```
If ssh is gone too, flash the stock FlashForge package for your model.

---

## If something goes wrong

| Symptom | Do this |
|---|---|
| Printer boots, screen blank | ssh in; `/usr/data/anvil/init.d/S80ui status`; `touch /usr/data/anvil/SAFE-MODE`; reboot |
| No ssh, no screen | flash the stock package for your model |
| Recovery stick does not help | try a newer stock FlashForge package for your model |
| Still broken | factory package (`Creator5Pro-factory-*.tgz` **plus** the separate `Creator5Pro-factory.tar.xz` on the same stick; needs 800 MB free) |

The mod never creates a mount point named like a mod, specifically so that
FlashForge's factory-restore package — which greps the mount table for a
known community mod's name and refuses to run when it matches — remains
usable as a last resort.

**Logs worth reading, all on the data partition and all surviving a reboot:**
```
/usr/data/anvil-install.log      what the installer did
/usr/data/logs/anvil-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log     klipper
/usr/data/logs/helixscreen.log helixscreen
```
