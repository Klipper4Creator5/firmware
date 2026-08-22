# Hardware testing: the flash ladder

CI proves the package is well-formed and that the installer does not brick a
*simulated* printer. It cannot prove anything about your actual machine. This
is the on-hardware procedure, ordered so that each step is recoverable using
what the previous step established.

**Rule: never skip a rung. Each one exists because it makes the next one
recoverable.**

---

## Step zero: check the model gate

Every package carries a gate. Its `runFirmwareExe.sh` has `MACHINE=` / `PID=`
baked in, and compares them against the values `app_startup.sh` passes from
the firmware already on the printer. A mismatch is **refused** with
"Firmware does not match machine type" — it will not install, and it is not a
valid recovery image either.

| Model | MACHINE | PID |
|---|---|---|
| Creator 5 | `Creator5` | `0028` |
| Creator 5 Pro | `Creator5Pro` | `0029` |

The gate is not cosmetic: the two models ship **different `firmwareExe`
binaries**, so a package must be built from the stock package for its own
model. `make release` builds both.

Find yours in Settings → About, or in
`/usr/data/firmwareRes/config/general.json` (`machineName`), and set
`TARGET_MACHINE` in `config.env`. Then:

```sh
make full && make verify        # one model
make release PROFILE=full       # both, into dist/
```

`verify.sh` fails loudly on a mismatch. **You must start from a stock package
built for your own model** — the mod inherits the gate from whatever package
you unpack.

## Before the first flash

- [ ] Put a copy of the **stock FlashForge package for your model** on a spare
      USB stick and keep it physically separate. That is your recovery image:
      flashing it restores every file the mod touches (proven by
      `make test-recovery`). Check it is the right model first — see above.
- [ ] Note your printer's serial number (Settings → About). The factory image
      restores a placeholder serial and you may need to put yours back.
- [ ] Confirm you can reach the printer's IP.
- [ ] `make test` passes (78 checks).
- [ ] `make rootfs && make test-ash` passes — this parses every script that
      will run on the printer using the printer's own busybox ash.

Two USB sticks, FAT32, both packages at the **root** of the stick (not in a
folder). Ship both filenames (`Creator5-*` and `Creator5Pro-*`): the Pro's
boot script globs `Creator5Pro-*.tgz`, the non-Pro globs `Creator5-*.tgz`.

---

## Stage 0 — probe (`make probe`)

**Changes nothing.** Reinstalls the stock software component byte-for-byte and
writes a diagnostic report to the USB stick.

Flash it, wait for the reboot, pull the stick and read:

| File on the stick | What it tells you |
|---|---|
| `c5mod-report.txt` | free space, partitions, installed versions, init layout, whether nginx/moonraker really exist |
| `c5mod-stock-etc.tar` | the whole `/etc`, so the init chain can be studied offline |
| `c5mod-stock-nginx.conf` | the stock nginx config (not shipped in any update package) |
| `c5mod-stock-bootscripts.tar` | `app_startup.sh`, `start.sh`, `passwd`, `shadow` as they exist on YOUR unit |

**Go/no-go:** the report exists and the printer boots normally.
If the stick comes back empty, the package never installed — nothing was
changed, and you have learned that before risking anything.

**Check in the report:**
- free space on `/usr/data` is comfortably above the size of your full package
- `moonrakerDmn: yes` and `nginx binary: yes`
- the `INIT SYSTEM` block matches expectations (busybox init, `/etc/init.d/rcS`,
  `S50dropbear` present)

---

## Stage 1 — ssh (`make ssh`)

Sets a root password you know. **Nothing else changes.**

This works because the stock rootfs already ships `/usr/sbin/dropbear` and an
enabled `/etc/init.d/S50dropbear` — port 22 is already open on a stock
printer, there is simply no published password.

Set one first:
```sh
openssl passwd -6 'your-password'      # paste into ROOT_PW_HASH in config.env
```

**Go/no-go:**
```sh
ssh root@PRINTER
```
- [ ] you get a shell
- [ ] the printer still prints normally

From here on you have a real recovery channel, which is what makes every
later stage safe.

---

## Stage 2 — web (`make web`)

Starts nginx (Mainsail on :80) and moonraker (:7125). Klipper and the
touchscreen stay stock, so printing behaviour is unchanged.

**Go/no-go:**
- [ ] `http://PRINTER/` loads Mainsail
- [ ] Mainsail shows the printer as **ready** (not "Klipper reports: ERROR")
- [ ] the touchscreen still works
- [ ] a small test print completes from the touchscreen

If Mainsail loads but Klipper errors, stop here and read
`/usr/data/logs/printer.log` over ssh. Do not continue.

---

## Stage 3 — full (`make full`)

Replaces the Klipper tree with the fork and installs the toolchanger extras.
**This is the first stage that changes how the machine moves.**

Before flashing, re-read the warnings in `creator5-toolchange/README.md`
about Z offsets. A wrong offset drives the nozzle into the plate.

**Go/no-go — with the emergency stop within reach:**
- [ ] Klipper starts (`ssh root@PRINTER 'grep -i error /usr/data/logs/printer.log | tail'`)
- [ ] `TOOLCHANGE_STATUS` responds in the Mainsail console
- [ ] home all axes — watch the first Z move
- [ ] one tool change, by hand, at temperature
- [ ] a single-tool test print
- [ ] a multi-tool test print

The `.cfg` includes are **not** wired up automatically — a tuned `printer.cfg`
is never modified. New files arrive as `*.mod-new`. Add the includes by hand
in the order given in the toolchanger README, then run
`FF_IMPORT_FIRMWARE_CONFIG` once.

---

## Stage 4 — helix (`make helix`)

HelixScreen replaces FlashForge's `firmwareExe` as the touchscreen UI.

This is the stage where the stock UI stops driving the screen, so understand
the safety net before flashing:

- The genuine binary is kept on disk as `firmwareExe.stock` and is the
  fallback. Nothing is deleted.
- `init.d/S70klipper` owns Klipper startup, because on stock firmware it was
  `firmwareExe` — not any init script — that ran `/usr/prog/klipper/start.sh`.
  Without this the printer would boot to a working screen and be unable to
  move.
- If the UI dies repeatedly, `SAFE-MODE` latches after 3 boots and the printer
  falls back to the stock UI on its own.

**Go/no-go:**
- [ ] HelixScreen appears on the touchscreen
- [ ] Klipper is running (Mainsail says ready) — this is the one people miss
- [ ] heaters and motion respond from the touchscreen
- [ ] a test print from the touchscreen

**Recovering from a bad UI, in increasing severity:**
```sh
ssh root@PRINTER
/usr/data/mod/init.d/S80ui status        # what did it choose, and why
touch /usr/data/mod/SAFE-MODE            # force the stock UI on next boot
reboot
```
If ssh is gone too, flash the uninstall stick.

---

## If something goes wrong

| Symptom | Do this |
|---|---|
| Printer boots, screen blank | ssh in; `touch /usr/data/mod/SAFE-MODE`; reboot |
| No ssh, no screen | flash the stock package for your model |
| Recovery stick does not help | try a newer stock FlashForge package for your model |
| Still broken | factory package (`Creator5Pro-factory-*.tgz` **plus** the separate `Creator5Pro-factory.tar.xz` on the same stick; needs 800 MB free) |

The mod never creates a mount point named like a mod, specifically so that
FlashForge's factory-restore package — which refuses to run when
`mount | grep zmod` matches — remains usable as a last resort.

**Logs worth reading, all on the data partition and all surviving a reboot:**
```
/usr/data/mod-install.log      what the installer did
/usr/data/logs/mod-boot.log    services + UI choice at each boot
/usr/data/logs/printer.log     klipper
/usr/data/logs/helixscreen.log helixscreen
```
