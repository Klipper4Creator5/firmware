# Installing

The printer's own updater does the work: one file on a FAT32 stick, plugged
in at power-on. No jailbreak, no soldering, no opening the case, no ssh.

Have the things in [Is this for you](is-this-for-you.md#what-to-have-ready)
ready before you start — above all the stock package for your model, on a
second stick.

---

## Which file do I need

**Creator 5 and Creator 5 Pro are not interchangeable.** The printer refuses
a package built for the other model — the most common reason a flash "does
nothing" — so pick the file whose name matches your machine on the
[Releases page](https://github.com/Klipper4FlashForge/firmware/releases):

| Your printer | The file |
|---|---|
| Creator 5 | `Creator5-anvil-<date>.tgz` |
| Creator 5 Pro | `Creator5Pro-anvil-<date>.tgz` |

Not sure which you have? On the printer: **Settings → About**.

---

## The flash

1. **Format a USB stick as FAT32.** Not exFAT, not NTFS.
2. **Copy the file for your model to the root of the stick.** Not in a folder.
   Leave the name exactly as it is — the printer looks for that pattern.
3. **Power the printer off.**
4. **Plug the stick in and power the printer on.** It finds the package by
   itself, shows the update screen and installs. This takes a few minutes.
5. **Wait for it to reboot on its own**, then pull the stick — your root
   password is on it, in `anvil-password.txt`.

---

## What the first boot does

The first boot after a flash is longer than the ones after it, and the screen
shows a progress bar rather than HelixScreen for most of it. Two things happen
that happen only once:

* **Your unit's factory calibration imports itself.** `[ff_legacy]` reads
  firmwareExe's per-unit JSON — the dock and nozzle numbers measured for your
  machine at the factory — and persists them into `printer.cfg` with its own
  `SAVE_CONFIG`. Klipper restarts once because of it, before the screen is up.
* **A root password is chosen**, and written to the stick. See below.

Do not cut the power during the first boot. A power cut in the middle of that
`SAVE_CONFIG` is the one moment where the calibration import can be lost.

---

## Your root password

Every package — the official releases included — picks a random root password
on the printer during the **first** install, sets it, and writes it to
`anvil-password.txt` on the USB stick you flashed from. Pull the stick after
the flash and read it, then save the password somewhere safe and delete the
file.

* If the stick is not writable, no password is set at all, and the install
  log says so.
* Updates keep whatever root password the printer already has — including one
  you set yourself with `passwd` — so the stick gets a password exactly once.
* Only a package built with `ROOT_PW_HASH` set carries one baked in instead;
  that is a build-time option, described in
  [Building packages](building.md).

ssh works because the stock rootfs already ships `/usr/sbin/dropbear` and an
enabled `/etc/init.d/S50dropbear` — port 22 is already open on a stock
printer, there is simply no published password. That shell is your recovery
channel, so confirm it works before you touch anything else.

---

## What the package touches, and what it does not

A package needs no config editing at all. It ships:

* the `ff_*.py` Klipper extras, into the Klipper tree it flashes
* the `ff-*.cfg` config files, to `/usr/data/config/`, keeping any you edited
  and leaving the new one beside it as `.mod-new`
* the `[include]` lines for all seven, at the end of `printer.base.cfg` —
  which the stock installer force-copies to `/usr/data/config/` on every flash

`printer.cfg` is never touched by any of that, by design: it is your file.
That is also why the includes live in `printer.base.cfg` and not there — and
it is what makes the undo button work, since flashing the stock FlashForge
package restores its own `printer.base.cfg` and the includes go with it.
Which files are yours and which the mod overwrites is
[Upgrading, and your files](upgrading.md).

Then go through the checks in [After the flash](after-the-flash.md), in
order, with the emergency stop within reach.
