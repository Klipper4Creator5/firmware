# Is this for you

Reforge replaces FlashForge's application on a Creator 5 or Creator 5 Pro
with a current Klipper, Mainsail, Moonraker and HelixScreen. It installs the
way a normal FlashForge update does, and flashing the stock package puts
everything back.

While it is installed, your printer runs software FlashForge did not write
and will not support. There is no help desk behind it — just the people on
[the Discord](https://discord.gg/ggJyfgVA4v), who help because they want to.

For most owners the answer is no. The two lists below are the whole
decision.

---

## Stay on stock if

* **Your prints come out the way you want them.** Nothing here is aimed at
  print quality. It is the same machine, the same nozzles and the same bed;
  what changes is how much of the printer you can reach and change. If the
  thing you want is better prints, this is the wrong lever.
* **You like the printer's own screen and app.** FlashForge's UI is gone
  after the flash — it is the file the mod replaces. HelixScreen takes its
  place, and it is not the same interface.
* **You print from FlashPrint or the mobile app.** They talk to an API that
  lives inside the application being replaced, so they stop working. You
  would be uploading from OrcaSlicer or Mainsail instead.
* **This is the printer you depend on**, with work due on it. Flashing back
  to stock is quick, but "quick" still means noticing the problem, finding
  the stick and standing at the machine.
* **A shell prompt is not somewhere you are comfortable.** See
  [What it asks of you](#what-it-asks-of-you) below — this is the one that
  people underestimate.

The stock firmware works. If it does what you need, keep it.

---

## It is for you if

The stock machine calibrates its tools, meshes its bed and prints well. What
it will not do is let anything but FlashForge's own software drive it.

* **You want to print from your own slicer, over the network.** Stock does not
  toolchange for a Mainsail-started print: its Klipper raises a flag and waits
  for the app, so the print hangs at the first `T2`.
* **You want the print lifecycle to be yours.** Start, end, pause, resume, the
  purge before a print, the refusal when a tool is missing — app policy on
  stock, Klipper macros here.
* **You want Mainsail to work properly.** FlashForge's Moonraker is a 2022
  build, old enough that a current Mainsail hides what it cannot see; the
  webcam panel disappears while the stream is fine.
* **You want the machine's numbers in `printer.cfg`**, written by
  `SAVE_CONFIG`, rather than inside the application's JSON.
* **ssh as root.**

---

## What it asks of you

You do not need to be a developer. You do need to be comfortable in two
places:

* **Klipper configuration.** Knowing what `printer.cfg` is, what an include
  does, what `SAVE_CONFIG` writes, and how to restate a section to override
  it. The calibration you run after flashing is Klipper commands and their
  output, not a wizard with a Next button.
* **A command line, over ssh.** Not for daily printing — for the day
  something is wrong. The screen is the first thing to go dark and the last
  thing you can fix on the machine: there is no fallback interface, so when
  it is dark, ssh and Mainsail are how you find out why. If reading
  `printer.log` over ssh is not something you would do, the recovery path
  here is one stick-flash long and then you are out of moves.

Expect to lose a print or two to a refusal you have not met before.

---

## What you give up

FlashForge's application is one program, and it did far more than draw the
touchscreen: the network connection your slicer and phone talk to, the cloud
link, and a set of features that were never Klipper's at all. Replacing it
takes all of them at once.

| What you lose | What happens instead |
|---|---|
| **Sending prints from FlashForge's own software** — FlashPrint, FlashForge Studio, Orca's FlashForge printer profile | You upload through Mainsail in a browser, or from OrcaSlicer's Klipper/Moonraker target |
| **The mobile app, and remote control through FlashForge's cloud** | Mainsail, from anything on your network. Reaching it from outside your home becomes your job to set up, and nobody else's to secure |
| **The printer's own touchscreen interface** | HelixScreen, on the same screen. It is a different interface, not a reskin |
| **Power-loss recovery** | A print interrupted by a power cut is lost |
| **Timelapse** | Gone |
| **The filament drying box** | It has its own controller that only the FlashForge app spoke to. Nothing drives it after the flash |
| **Automatic spool swap when filament runs out** | The print pauses at the tool that ran out, and waits for you |
| **A door opening pausing the print** | Nothing happens when you open one |
| **FlashForge firmware updates** | You install packages from the Releases page yourself. A FlashForge update, if you ever ran one, would overwrite the mod |

---

## The risk

This is unofficial, reverse-engineered firmware modification. It is not
endorsed by FlashForge, it voids whatever warranty you had, and **you alone
are responsible for what happens to your printer**. Mistakes here are not
hypothetical — a wrong Z offset drives the nozzle through the build plate,
and a failed grab or missing check can end like this:

<img src="molten-toolhead.jpg" alt="molten toolhead with a blob of melted plastic" width="450">

Still want it? [Installing](installing.md) is next, and it starts with what
to have on hand before you flash.
