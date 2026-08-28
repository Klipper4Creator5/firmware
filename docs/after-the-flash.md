# After the flash

The printer has rebooted on its own and you have pulled the stick. Work
through this page in order, with the emergency stop within reach. Nothing
here moves the machine until the last section, and by then you will know
whether the parts that tell you what is happening are working.

---

## Where everything is

Everything is on the printer's own address:

| | |
|---|---|
| `http://<printer-ip>/` | Mainsail |
| `http://<printer-ip>:7125` | Moonraker's API — what slicers upload to |
| `http://<printer-ip>/webcam/` | the camera stream (mjpg-streamer on `:8080`) |
| `ssh root@<printer-ip>` | the shell — password from `anvil-password.txt` |

---

## The logs

```
/usr/data/anvil-install.log      what the installer did
/usr/data/logs/anvil-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log       klipper
/usr/data/logs/helixscreen.log   helixscreen
```

They are the first thing to read when something is wrong, and the first thing
to quote when you ask on [the Discord](https://discord.gg/ggJyfgVA4v).

---

## The safety net

Understand the safety net first, because FlashForge's UI is gone from the
screen and there is nothing to fall back to:

- ssh and Mainsail do not depend on the screen. `/etc/init.d/S50dropbear` is
  stock and runs long before the UI, and `init.d/S60nginx` and
  `init.d/S62moonraker` start the web stack independently of it — and of each
  other, so `S62moonraker restart` over ssh leaves Mainsail served. They are
  your way in when the screen is dark.
- `init.d/S70klipper` owns Klipper startup, because on stock firmware it was
  `firmwareExe` — not any init script — that ran `/usr/prog/klipper/start.sh`.
  Without this the printer would boot to a working screen and be unable to
  move.
- If the UI misbehaves, set `MOD_UI=0` in `/usr/data/anvil/anvil.conf` and
  reboot: the printer comes up **headless** — no UI started at all. ssh and
  Mainsail are unaffected either way. There is no automatic latch; nothing
  stops the UI unless you do.

---

## Go/no-go

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

Everything ticked? Then the printer is yours again, and the next thing it
needs is [calibration](calibration.md) — prints refuse to start until it has
it.
