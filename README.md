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

### Flash the probe first

There are two files per model, and they are not a menu — flash them in order:

| Stage | What it changes | Why |
|---|---|---|
| **probe** | **nothing at all** | Proves the whole update chain works on *your* machine, and writes a report back onto the USB stick. Costs you five minutes and rules out a bad stick, the wrong model or a truncated download. |
| **firmware** | everything: Mainsail, ssh, toolchanger Klipper, HelixScreen | The actual firmware. Flash it once the probe has come back clean. |

The go/no-go checks — what to look at after each flash, and what means stop —
are in **[docs/hardware-testing.md](docs/hardware-testing.md)**. Read it before
the first flash.

---

## If something goes wrong

**Keep a copy of the stock FlashForge package for your model on a spare USB
stick before you start.** That stick is the undo button: flashing it restores
every file this firmware touches. It is a normal FlashForge update, so it
installs the same way — stick in, power on.

A few things are deliberately built in so a bad flash cannot cost you the
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
and the full test suite pass — including the end-to-end update test, where the
package sits on a real FAT filesystem in a replica of the printer and the
machine's own boot script finds it, installs it, and boots again with the mod
running. That replica is the printer's real filesystem running its real
binaries. It is still not a machine.

Flash the probe first, and have the stock package on a spare stick before you
begin.

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
