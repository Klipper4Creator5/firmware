# Is this for you

Reforge replaces FlashForge's own application on a Creator 5 or Creator 5 Pro
with a current Klipper, Mainsail, Moonraker and HelixScreen. It installs the
way a normal FlashForge update does and the stock package flashes back over
it, but between those two moments the printer is running software FlashForge
did not write.

What has actually been run on hardware, and what has not, is the checkbox list
on the [front page](index.md) — read that first. This page is the rest of the
decision: what stops working, what can go wrong, and what to have ready.

---

## What you give up

The mod replaces one file, `firmwareExe`, and that file is FlashForge's whole
application — so anything that lived inside it rather than in a separate
service goes with it: **the FlashForge network
API on `:8898`**, and with it FlashPrint, Orca's FlashForge profile and the
mobile app. Moonraker's API takes over — upload from OrcaSlicer or Mainsail
instead. Flashing the stock package brings the API back.

---

## The risk

This is unofficial, reverse-engineered firmware modification. It is not
endorsed by FlashForge, it voids whatever warranty you had, and **you alone
are responsible for what happens to your printer**. Mistakes here are not
hypothetical — a wrong Z offset drives the nozzle through the build plate,
and a failed grab or missing check can end like this:

<img src="molten-toolhead.jpg" alt="molten toolhead with a blob of melted plastic" width="450">

Work through [Your first print](first-print.md) before you print anything
real — it proves the offsets are being applied before a nozzle can reach the
plate — and stay next to the machine until you trust it.

---

## What to have ready

Before you flash anything:

- [ ] **The stock FlashForge package for your model, on a spare USB stick.**
      That stick is the undo button, and it is the only recovery step that
      needs nothing but a USB port — no ssh, no screen. The stock packages
      are published at [ghzserg/FF](https://github.com/ghzserg/FF/releases).
- [ ] **Your printer's model**, from Settings → About. A package for the
      other model is refused, and it is not a valid recovery image either.
- [ ] **Your printer's serial number**, also from Settings → About. The
      factory-restore image writes a placeholder serial, and you may need to
      put yours back.
- [ ] **The printer's IP address**, and a machine that can reach it.
- [ ] Time to stand at the machine. The first print after a flash is not
      something to start and walk away from.

Both sticks FAT32, each package at the **root** of its stick, not in a
folder.

Next: [Installing](installing.md).
