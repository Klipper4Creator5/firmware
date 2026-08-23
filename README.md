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
| **A shell on your printer** | ssh as root. Dropbear is already running on stock firmware; this simply gives you a password you know. |
| **Real toolchanger Klipper** | A current Klipper with proper tool-change support, replacing the 0.12-era tree FlashForge ships. |
| **A modern touchscreen UI** | HelixScreen instead of the stock interface — optional, and the stock UI is kept on disk as a fallback. |
| **Nothing you cannot undo** | Flashing the stock FlashForge package puts every file back. |

Your printer keeps working as a printer throughout: the stock screen, the
stock boot process and the stock recovery path are all left in place until you
choose a stage that replaces them.

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

### Flash them in this order

The releases are rungs on a ladder, not a menu. Each one makes the next one
recoverable, so start at the bottom even if you only want the top:

| Stage | What it changes | Why start here |
|---|---|---|
| **probe** | **nothing at all** | Proves the whole update chain works on *your* machine, and writes a report back onto the USB stick. Costs you five minutes and rules out a bad stick, a wrong model or a broken download. |
| **ssh** | a root password | Gives you a way in before anything risky happens. |
| **web** | + Mainsail and moonraker | Turns on a web stack FlashForge already ships but leaves switched off. Printing behaviour is unchanged. |
| **full** | + toolchanger Klipper | The first stage that changes how the machine moves. |
| **helix** | + HelixScreen as the UI | The first stage where the stock screen stops driving the display. |

The go/no-go checks for each rung — what to look at, and what means stop — are
in **[docs/hardware-testing.md](docs/hardware-testing.md)**. Read it before
the first flash.

---

## If something goes wrong

**Keep a copy of the stock FlashForge package for your model on a spare USB
stick before you start.** That stick is the undo button: flashing it restores
every file this firmware touches. It is a normal FlashForge update, so it
installs the same way — stick in, power on.

A few things are deliberately built in so a bad stage cannot cost you the
machine:

* **The screen always comes back.** If the new UI cannot start or crashes
  repeatedly, the printer latches SAFE-MODE and boots the stock interface.
* **ssh stays up** even when the screen does not, so you can get in and look.
* **Your `printer.cfg` is never overwritten.** A config that already exists is
  left alone and the new one lands beside it as `.mod-new`.
* **The kernel and the motion board are never touched** by a normal package.

More detail, including what to do when the printer will not boot at all:
[docs/hardware-testing.md](docs/hardware-testing.md).

---

## Status

**No package has been installed on a real printer yet.** The build pipeline
and the full test suite pass, including installing into a replica of the
printer — its real filesystem, running its real binaries — but a simulation is
not a machine.

Start at stage 0 (`probe`), and have the stock package on a spare stick before
you begin.

---

## Documentation

| | |
|---|---|
| [docs/hardware-testing.md](docs/hardware-testing.md) | The flash ladder, stage by stage, with the checks that say go or stop |
| [docs/how-it-works.md](docs/how-it-works.md) | How the mod hooks into the stock firmware, and what the stock firmware does that surprises people |
| [docs/building.md](docs/building.md) | Building your own packages from a stock FlashForge one |
| [docs/testing.md](docs/testing.md) | The test suite, and how we know a package does not brick a printer |
| [docs/printer-replica.md](docs/printer-replica.md) | The printer replica: what is authentic, what is not |
