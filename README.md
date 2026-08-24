# creator5-custom-firmware

Custom firmware for the FlashForge **Creator 5** and **Creator 5 Pro**.

It installs the way a normal FlashForge update does: copy one file to a USB
stick, plug it in, power the printer on. No jailbreak, no soldering, no
opening the case, no ssh needed to get started — the printer's own updater
does the work.

Packages are published on the
[Releases page](https://github.com/Klipper4FlashForge/firmware/releases) —
two files per release, one per model, deliberately marked *pre-release* for
as long as the status below holds. Releases are tagged `v<date>-<city>`, each
named for a Ukrainian city under occupation.

> **Unofficial and unaffiliated with FlashForge.** It voids your warranty and
> you are responsible for your machine. Nothing here has been installed on a
> printer yet — see [Status](#status) before you flash anything.

---

## Status

**No package has been installed on a real printer yet.** The build pipeline
and the full test suite pass — including the end-to-end update test, where the
package sits on a real FAT filesystem in a replica of the printer and the
machine's own boot script finds it, installs it, and boots again with the mod
running. That replica is the printer's real filesystem running its real
binaries. It is still not a machine.

Have the stock package for your model on a spare stick before you begin.

---

## What you get

| | |
|---|---|
| **Mainsail in your browser** | The full Klipper web interface at `http://<printer-ip>/` — upload gcode, watch the print, tune on the fly. Moonraker comes with it, so anything that speaks the Klipper API works. |
| **A shell on your printer** | ssh as root. Dropbear is already running on stock firmware; this simply gives you a password you know. Every package -- the releases here included -- picks its own random root password on the **first** install and writes it to `anvil-password.txt` on your USB stick; read it there, then pull the stick. Updates keep the password the printer already has, so the stick sees it exactly once. Nothing crackable is shipped in the package. Build with `ROOT_PW_HASH` set (`make passwd`) to bake in a password of your own instead. |
| **Real toolchanger Klipper** | A current Klipper with proper tool-change support, replacing the 0.12-era tree FlashForge ships. |
| **A current Moonraker** | Replacing the 2022 build FlashForge ships, which is too old for today's Mainsail — with it, the camera panel never appears at all. |
| **A modern touchscreen UI** | HelixScreen replaces the stock interface on the printer's own screen. |
| **Nothing you cannot undo** | Flashing the stock FlashForge package restores every file the mod replaced, and the printer behaves as it did before — with one exception, Moonraker; see [If something goes wrong](#if-something-goes-wrong). |

How the mod hooks in — one file, `firmwareExe`, with the stock boot scripts,
updater and recovery path left untouched — is
[docs/how-it-works.md](docs/how-it-works.md).

### What you give up

That one file is FlashForge's whole application, so anything that lived inside
it rather than in a separate service goes with it:

* **The FlashForge network API on `:8898`**, and with it FlashPrint, Orca's
  FlashForge profile and the mobile app. Moonraker's API takes over, which is
  what Mainsail, OrcaSlicer's Klipper/Moonraker upload and Fluidd speak.
  Slice for the toolchanger and send it there instead.

The camera is **not** on that list, though the app did serve it: mjpg-streamer
is already on the printer, unused, and this firmware simply starts it. The
stream shows up in Mainsail as usual.

Flashing the stock package brings the API back.

---

## Which file do I need

**Creator 5 and Creator 5 Pro are not interchangeable.** Each package is built
for one model and the printer refuses a package meant for the other, so pick
the file whose name matches your machine on the
[Releases page](https://github.com/Klipper4FlashForge/firmware/releases):

| Your printer | The file |
|---|---|
| Creator 5 | `Creator5-anvil-<date>.tgz` |
| Creator 5 Pro | `Creator5Pro-anvil-<date>.tgz` |

Not sure which you have? On the printer: **Settings → About**.

---

## How to flash

### Before you start

* **Check the model.** A `Creator5Pro-` package will not install on a Creator 5
  and vice versa; the printer refuses it outright, which is annoying rather
  than dangerous, but it is the most common reason a flash "does nothing".
* **Put the stock FlashForge package for your model on a second stick**, and
  keep it separate. That stick is the undo button — see
  [If something goes wrong](#if-something-goes-wrong).
* **Read [docs/hardware-testing.md](docs/hardware-testing.md)** before the
  first flash: it has the go/no-go checks — what to look at after the flash,
  in what order, and what means stop.

### The flash

1. **Format a USB stick as FAT32.** Not exFAT, not NTFS.
2. **Copy the file for your model to the root of the stick.** Not in a folder.
   Leave the name exactly as it is — the printer looks for that pattern.
3. **Power the printer off.**
4. **Plug the stick in and power the printer on.** It finds the package by
   itself, shows the update screen and installs. This takes a few minutes.
5. **Wait for it to reboot on its own**, then pull the stick — your root
   password is on it, in `anvil-password.txt`.

---

## After the flash

Everything is on the printer's own address:

| | |
|---|---|
| `http://<printer-ip>/` | Mainsail |
| `http://<printer-ip>:7125` | Moonraker's API — what slicers upload to |
| `http://<printer-ip>/webcam/` | the camera stream (mjpg-streamer on `:8080`) |
| `ssh root@<printer-ip>` | the shell — password from `anvil-password.txt` |

Logs worth reading, all on the data partition and all surviving a reboot:

```
/usr/data/anvil-install.log      what the installer did
/usr/data/logs/anvil-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log       klipper
/usr/data/logs/helixscreen.log   helixscreen
```

Then run the go/no-go checks in
[docs/hardware-testing.md](docs/hardware-testing.md), in order, with the
emergency stop within reach.

---

## Before your first print: calibrate

**Prints refuse to start on an uncalibrated toolchanger — by design.** The
sequence is short, and the first part happens without you.

1. Your unit's factory calibration imports itself on the first boot after the
   flash and is saved automatically — Klipper restarts once, before the
   screen is up, and that is the last you hear of it. Check it took:
   `TOOL_OFFSET_STATUS` should show a nozzle triple for every tool.

2. **Take the PEI sheet off** — the calibration station sits below the bed
   plane — then home and calibrate:

   ```gcode
   STATION_CALIBRATE PLATE_REMOVED=1
   TOOL_OFFSET_CALIBRATE TOOL=ALL PLATE_REMOVED=1
   SAVE_CONFIG
   ```

3. `TOOLCHANGE_STATUS` and `TOOL_OFFSET_STATUS` — every tool should show a
   nozzle triple and a dock position, and nothing should say `NOT CALIBRATED`.

4. Check the Z offset against a sheet of paper before trusting a first layer —
   the [Verify](docs/toolchange.md#verify) section shows the exact moves. If
   the nozzle presses into the plate, stop.

The full procedure — what each command does, what it refuses and why — is
[docs/toolchange.md](docs/toolchange.md). Two files under
[`gcode/`](gcode/) are there for the first runs: `creator5-safe-moves.gcode`
(cold, nothing below Z50) and then `creator5-feature-test.gcode` (the real
thing, two tools).

---

## Slicer setup

OrcaSlicer, with the stock FlashForge profile left alone: `START_PRINT` is
derived from the sliced file itself. The one field to touch is **Change
filament G-code**, which must be cleared down to a bare `Tn` — the
toolchanger takes it from there. Upload through Orca's Klipper/Moonraker
target or drop the file into Mainsail. Details, including the explicit
`START_PRINT` route: [docs/toolchange.md](docs/toolchange.md#orcaslicer-setup).

---

## Your files and the mod's files

| File | Whose |
|---|---|
| `/usr/data/config/printer.cfg` | **Yours** — never overwritten. Overrides go here, after the includes: Klipper merges same-named sections and the last value wins, so restate only what you change. |
| `moonraker-custom.conf` | **Yours** — created once, included last, never rewritten, so your Moonraker settings win. Do not delete it: Moonraker refuses to start if the include matches nothing. |
| `/usr/data/anvil/anvil.conf` | **Yours** — the runtime switches: `MOD_WEB`, `MOD_CAM` (with optional `MOD_CAM_RES` / `MOD_CAM_FPS` / `MOD_CAM_PORT`), `MOD_UI`, `MOD_WIFI`. Edit over ssh, reboot. |
| `ff-*.cfg`, `printer.base.cfg`, `moonraker.conf` | **The mod's** — overwritten on every update, so do not edit them; each file's header says so. |

### Upgrading

A newer release installs exactly like the first flash: stick in, power on.
The table above is what an upgrade does — your `printer.cfg` with its saved
calibration, `moonraker-custom.conf`, `anvil.conf` **and your root password**
survive; the `ff-*.cfg` family is replaced.

---

## If something goes wrong

**Keep a copy of the stock FlashForge package for your model on a spare USB
stick before you start.** That stick is the undo button: flashing it restores
every file this firmware touches. It is a normal FlashForge update, so it
installs the same way — stick in, power on.

A few things are deliberately built in so a bad flash cannot cost you the
machine:

* **A crashing UI cannot lock you out.** The screen is not how you reach the
  printer: ssh and Mainsail come up from their own services, before and
  independently of the UI, so a dead screen costs you the screen and nothing
  else — you can still print. It is not repairable on the machine, though:
  HelixScreen is the only UI there is, and getting a working screen back means
  flashing a package again. `MOD_UI=0` in `/usr/data/anvil/anvil.conf` stops
  it being started at all.
* **ssh stays up** even when the screen does not, so you can get in and look.
* **The kernel and the motion board are never touched** by a normal package.

**Going back to stock** restores everything the mod replaced, with one
exception: Moonraker ships only on the factory image, so a stock reflash has
nothing to restore it from and the mod's build stays — it works, and Mainsail
is happy with it. The details, including what a stock reflash leaves behind
inert, are in [docs/how-it-works.md](docs/how-it-works.md#recovery).

More detail, including what to do when the printer will not boot at all:
[docs/hardware-testing.md](docs/hardware-testing.md).

---

## Versions

| Component | Pinned at |
|---|---|
| Stock FlashForge base | `1.9.7-1.2.9-20260810`, fetched from [ghzserg/FF](https://github.com/ghzserg/FF) at build time |
| Klipper | a current fork with the `ff_*` toolchanger extras |
| Mainsail | `v2.18.2` |
| Moonraker | commit `9d0d09d` — a commit, not a release, for a hard reason: [docs/how-it-works.md](docs/how-it-works.md#moonraker) |
| HelixScreen | `v0.99.115-creator5.1` |

---

## Documentation

| | |
|---|---|
| [docs/hardware-testing.md](docs/hardware-testing.md) | The on-hardware procedure, with the checks that say go or stop |
| [docs/how-it-works.md](docs/how-it-works.md) | How the mod hooks into the stock firmware, and what the stock firmware does that surprises people |
| [docs/toolchange.md](docs/toolchange.md) | The toolchanger mod: the `ff_*` Klipper extras, the `ff-*.cfg` configs, and the Z offsets to get right before you print |
| [docs/notes/70-error-codes.md](docs/notes/70-error-codes.md) | Every error code the firmware can raise, by subsystem |
| [docs/building.md](docs/building.md) | Building your own packages from a stock FlashForge one |
| [docs/testing.md](docs/testing.md) | The test suite, and how we know a package does not brick a printer |
| [docs/printer-replica.md](docs/printer-replica.md) | The printer replica: what is authentic, what is not |
| [docs/notes/](docs/notes/) | Reverse-engineering notes on the stock firmware, behind the toolchanger work |
| [gcode/](gcode/) | The two verification files for the first runs on hardware |

---

## Credits

Built on the work of others: [ghzserg/FF](https://github.com/ghzserg/FF)
publishes the stock packages and factory image everything here starts from;
[Mainsail](https://github.com/mainsail-crew/mainsail),
[Moonraker](https://github.com/Arksine/moonraker) and
[HelixScreen](https://github.com/Klipper4Creator5/helixscreen) are shipped as
released; the toolchanger status API follows
[viesturz/klipper-toolchanger](https://github.com/viesturz/klipper-toolchanger)
so tool-aware UIs work unchanged.
