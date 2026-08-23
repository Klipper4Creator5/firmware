# creator5-custom-firmware

Custom firmware for the FlashForge **Creator 5** and **Creator 5 Pro**.

It installs the way a normal FlashForge update does: copy one file to a USB
stick, plug it in, power the printer on. No jailbreak, no soldering, no
opening the case, no ssh needed to get started — the printer's own updater
does the work.

> **Unofficial and unaffiliated with FlashForge.** It voids your warranty and
> you are responsible for your machine. Nothing here has been installed on a
> printer yet — see [Status](#status) before you flash anything.

---

## What you get

| | |
|---|---|
| **Mainsail in your browser** | The full Klipper web interface at `http://<printer-ip>/` — upload gcode, watch the print, tune on the fly. Moonraker comes with it, so anything that speaks the Klipper API works. |
| **A shell on your printer** | ssh as root. Dropbear is already running on stock firmware; this simply gives you a password you know — the installer picks a random one and writes it to `anvil-password.txt` on your USB stick. |
| **Real toolchanger Klipper** | A current Klipper with proper tool-change support, replacing the 0.12-era tree FlashForge ships. |
| **A modern touchscreen UI** | HelixScreen replaces the stock interface on the printer's own screen. |
| **Nothing you cannot undo** | Flashing the stock FlashForge package puts every file back. |

The stock boot process and the stock recovery path are left in place: the mod
replaces one file (`firmwareExe`) and nothing in `rcS` or `app_startup.sh` is
patched, so flashing the stock FlashForge package puts the printer back exactly
as it was.

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
the file whose name matches your machine:

| Your printer | The file |
|---|---|
| Creator 5 | `Creator5-anvil-<date>.tgz` |
| Creator 5 Pro | `Creator5Pro-anvil-<date>.tgz` |

Not sure which you have? On the printer: **Settings → About**.

---

## How to flash

1. **Format a USB stick as FAT32.** Not exFAT, not NTFS.
2. **Copy the file for your model to the root of the stick.** Not in a folder.
   Leave the name exactly as it is — the printer looks for that pattern.
3. **Power the printer off.**
4. **Plug the stick in and power the printer on.** It finds the package by
   itself, shows the update screen and installs. This takes a few minutes.
5. **Wait for it to reboot on its own**, then pull the stick.

Afterwards, `http://<printer-ip>/` gets you Mainsail. The install log is on
the printer at `/usr/data/anvil-install.log`.

### Before you do

One file per model, one flash — but do two things first, because they are the
cheap version of every problem people hit:

* **Check the model.** A `Creator5Pro-` package will not install on a Creator 5
  and vice versa; the printer refuses it outright, which is annoying rather
  than dangerous, but it is the most common reason a flash "does nothing".
* **Put the stock FlashForge package for your model on a second stick**, and
  keep it separate. That stick is the undo button — see below.

The go/no-go checks — what to look at after the flash, in what order, and what
means stop — are in **[docs/hardware-testing.md](docs/hardware-testing.md)**.
Read it before the first flash.

---

## If something goes wrong

**Keep a copy of the stock FlashForge package for your model on a spare USB
stick before you start.** That stick is the undo button: flashing it restores
every file this firmware touches. It is a normal FlashForge update, so it
installs the same way — stick in, power on.

A few things are deliberately built in so a bad flash cannot cost you the
machine:

* **A crashing UI cannot lock you out.** If HelixScreen cannot start or
  crashes repeatedly, the printer latches SAFE-MODE and boots *headless* —
  no UI at all — instead of looping. Delete `/usr/data/anvil/SAFE-MODE` over
  ssh to try again.
* **ssh stays up** even when the screen does not, so you can get in and look.
* **Your `printer.cfg` is never overwritten** — it is not a file this
  firmware ships. Of the configs it does ship, one you have edited is left
  alone and the new version lands beside it as `.mod-new`; one you never
  touched is updated in place.
* **The kernel and the motion board are never touched** by a normal package.

More detail, including what to do when the printer will not boot at all:
[docs/hardware-testing.md](docs/hardware-testing.md).

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

## Documentation

| | |
|---|---|
| [docs/hardware-testing.md](docs/hardware-testing.md) | The on-hardware procedure, with the checks that say go or stop |
| [docs/how-it-works.md](docs/how-it-works.md) | How the mod hooks into the stock firmware, and what the stock firmware does that surprises people |
| [docs/building.md](docs/building.md) | Building your own packages from a stock FlashForge one |
| [docs/testing.md](docs/testing.md) | The test suite, and how we know a package does not brick a printer |
| [docs/printer-replica.md](docs/printer-replica.md) | The printer replica: what is authentic, what is not |
| [docs/toolchange.md](docs/toolchange.md) | The toolchanger mod: the `ff_*` Klipper extras, the `ff-*.cfg` configs, and the Z offsets to get right before you print |
| [docs/notes/](docs/notes/) | Reverse-engineering notes on the stock firmware, behind the toolchanger work |
