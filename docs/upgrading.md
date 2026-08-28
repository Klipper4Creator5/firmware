# Upgrading, and your files

A newer release installs exactly like the first flash: stick in, power on.
Nothing you have set is asked for again. This page is the line between the
files that are yours and the files the mod overwrites without asking, because
that line is what makes an update safe.

---

## Your files and the mod's files

| File | Whose |
|---|---|
| `/usr/data/config/printer.cfg` | **Yours** — never overwritten. Overrides go here, after the includes: restate only what you change, the last value wins. |
| `moonraker-custom.conf` | **Yours** — created once, never rewritten, included last so your settings win. Do not delete it. |
| `ff-*.cfg`, `printer.base.cfg`, `moonraker.conf` | **The mod's** — overwritten on every update; do not edit. |
| `anvil/helixscreen/config/settings.json` | **Yours** — everything you set on the screen. Written by HelixScreen itself; carried across updates along with `helixscreen.env` and its spool map. |

---

## Upgrading

A newer release installs exactly like the first flash: stick in, power on.
Your `printer.cfg` with its saved calibration, `moonraker-custom.conf`, **your
root password** and everything you set on the screen survive; the `ff-*.cfg`
family is replaced. If a release changes `helixscreen.env`, yours is kept and
the new one is left beside it as `helixscreen.env.mod-new`.

---

## The config files in detail

The `.cfg` includes are wired up **for** you: `printer.base.cfg` ends with
the seven `[include ff-*.cfg]` lines, so a flash brings the mod up by itself.
Your `printer.cfg` is not touched. The factory dock and nozzle numbers are
pulled in for you too: on the first boot after the flash, `[ff_legacy]` imports
firmwareExe's per-unit JSON and persists it with its own `SAVE_CONFIG`, so
Klipper restarts once, right after coming up — before the screen is on its
feet. `TOOL_OFFSET_STATUS` afterwards should show a nozzle triple for every
tool and no `NOT CALIBRATED`.

The included files are the mod's, and every update overwrites them without
asking — `ff-*.cfg` and `printer.base.cfg` alike. Do not edit them. Put changes
at the end of `printer.cfg`, restating only the option or macro you are
changing: Klipper merges same-named sections and the last value wins, so
everything you leave out keeps the shipped value and your overrides survive
every flash. Each of those files opens with a header saying as much.

`moonraker.conf` is mod-owned too — it is overwritten on every update, which
is how the `[webcam]` block and the API lockdown reach the printer. Its seam is
`moonraker-custom.conf` beside it: created once, never written again, and
included at the *end* of `moonraker.conf`, so anything you set there wins.
Do not delete it — Moonraker treats an include that matches no file as fatal
and will refuse to start. An empty one is fine.

If you edit `moonraker.conf` itself anyway, the installer notices and keeps
your copy, landing the new version beside it as `.mod-new`.

---

## A FlashForge OTA update is a different thing

  overwrite `/usr/prog/klipper/`, deleting the extras. Keep this repo and
  re-run step 1 after every firmware update. The `#*#` block in
  `printer.cfg` is on the data partition and survives.

---

## Going back to stock

Flashing the stock FlashForge package for your model is the uninstall — it
installs the same way, and it restores every file the mod touches. The one
thing it cannot bring back is FlashForge's Moonraker, which the stock package
does not carry: the mod's build stays, it works, and Mainsail is happy with
it. The details, and the ladder below it, are in
[When something goes wrong](troubleshooting.md).
