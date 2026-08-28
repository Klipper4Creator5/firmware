# Reforge

Custom firmware for the FlashForge **Creator 5** and **Creator 5 Pro**.

It installs the way a normal FlashForge update does: copy one file to a USB
stick, plug it in, power the printer on. No jailbreak, no soldering, no
opening the case, no ssh needed to get started — the printer's own updater
does the work.

Packages are published on the
[Releases page](https://github.com/Klipper4FlashForge/firmware/releases) —
two files per release, one per model, marked *pre-release* while the mod is
young. Help and support: [the Discord](https://discord.gg/ggJyfgVA4v).

> **Unofficial and unaffiliated with FlashForge.** It voids your warranty and
> you are responsible for your machine. See [Status](#status) for what has
> actually been tried on hardware before you flash anything.

---

## Status

**It runs on a real printer** — a Creator 5 Pro, flashed and printing:

<img src="docs/helixscreen-print-status.webp" width="49%" alt="HelixScreen mid-print on the Creator 5 Pro: T2 mounted, layer 2 of 173"> <img src="docs/helixscreen-bed-mesh.webp" width="49%" alt="HelixScreen's bed-mesh screen showing a probed 10x10 mesh">

A checked box happened on that machine; an empty one has not, yet.

**For everyone:**

- [x] **Install and migration from stock firmware** — the printer's own
  updater does it; your unit's factory calibration imports itself on the
  first boot
- [x] **Printing** — gcode straight from the slicer, nothing edited
- [x] **Toolchanges** — a current Klipper with real toolchanger support, in
  place of the 0.12-era tree FlashForge ships
- [x] **Nozzle-offset calibration**
- [x] **Mainsail** at `http://<printer-ip>/`, with a current Moonraker behind
  it — anything that speaks the Klipper API works
- [x] **Camera** — mjpg-streamer, already on the printer; the mod just
  starts it
- [x] **Wifi**
- [x] **HelixScreen** on the printer's own screen
- [ ] **Chamber heater**
- [ ] **Creator 5 (non-Pro)** — its package builds and passes the same
  replica test suite, but has not touched hardware
- [ ] **Going back to stock** — proven on the printer replica, not yet
  needed on the machine. The stock package restores everything it carries;
  Moonraker is not in it, so the mod's build stays and keeps working — see
  [When something goes wrong](docs/troubleshooting.md)

**For the tinkerer:**

- [x] **ssh as root** — a random password is chosen on the **first** install
  and written to `anvil-password.txt` on your stick; updates keep it
  (`make passwd` bakes in your own)

---

## What you give up

FlashForge's application is one binary, and replacing it takes everything
that lived inside it: **the network API on `:8898`**, and with it FlashPrint,
Orca's FlashForge profile and the mobile app. Moonraker's API takes over.
Flashing the stock package brings them back. The longer version, with the
risks and what to have ready, is
[Is this for you](docs/is-this-for-you.md).

---

## Get it

**Creator 5 and Creator 5 Pro are not interchangeable.** The printer refuses
a package built for the other model — the most common reason a flash "does
nothing". Yours is in Settings → About.

| Your printer | The file on the [Releases page](https://github.com/Klipper4FlashForge/firmware/releases) |
|---|---|
| Creator 5 | `Creator5-anvil-<date>.tgz` |
| Creator 5 Pro | `Creator5Pro-anvil-<date>.tgz` |

Have the stock FlashForge package for your model on a second stick before you
begin. That stick is the undo button.

---

## Start here

| | |
|---|---|
| [Is this for you](docs/is-this-for-you.md) | What stops working, what can go wrong, what to have ready |
| [Installing](docs/installing.md) | The flash, the first boot, your root password |
| [After the flash](docs/after-the-flash.md) | Where everything is, and the go/no-go checks in order |
| [Your first print](docs/first-print.md) | Calibrate, prove the offset, then the two verification files |
| [Printing](docs/printing.md) | Slicer setup, filament, runout and clogs |
| [When something goes wrong](docs/troubleshooting.md) | Symptoms, logs, and the way back to stock |

The full manual is at
[reforge.readthedocs.io](https://reforge.readthedocs.io/). How the mod hooks
in — one file, `firmwareExe`, with the stock boot scripts, updater and
recovery path left untouched — is
[How it works](docs/how-it-works.md).

---

## Credits

Built on the work of others: [ghzserg/FF](https://github.com/ghzserg/FF)
publishes the stock packages and factory image everything here starts from;
[Mainsail](https://github.com/mainsail-crew/mainsail),
[Moonraker](https://github.com/Arksine/moonraker) and
[HelixScreen](https://github.com/Klipper4FlashForge/helixscreen) are shipped as
released; the toolchanger status API follows
[viesturz/klipper-toolchanger](https://github.com/viesturz/klipper-toolchanger)
so tool-aware UIs work unchanged.
